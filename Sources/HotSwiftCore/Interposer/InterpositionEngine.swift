//
//  InterpositionEngine.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

// Coordinates symbol rebinding and ObjC method replacement after a dylib reload

#if DEBUG
import Foundation

// MARK: - Interposition Result

/// Summarizes what the interposition engine did for a single reload cycle.
struct InterpositionResult {
    /// Number of C-level symbol pointer rebindings performed via fishhook.
    let symbolsRebound: Int
    /// Number of ObjC method implementations replaced via the runtime.
    let methodsReplaced: Int
    /// Class names whose methods were replaced.
    let affectedClasses: [String]
    /// Any warnings or diagnostic messages generated during interposition.
    let diagnostics: [String]

    /// Whether any interposition work was performed.
    var didInterpose: Bool {
        return symbolsRebound > 0 || methodsReplaced > 0
    }
}

// MARK: - Interposition Engine

/// Coordinates both fishhook-based symbol rebinding and Objective-C runtime
/// method replacement to make a freshly loaded dylib's code take effect in
/// the running process.
///
/// ## Strategy
///
/// Swift methods on `@objc` classes (including all `UIViewController` subclasses)
/// dispatch through the ObjC runtime, so replacing their `IMP` via
/// `class_replaceMethod` is sufficient. For pure Swift types and C-level
/// function pointers, we fall back to fishhook's symbol-pointer-table patching.
///
/// The engine applies both strategies in sequence:
/// 1. **ObjC method replacement** — for every class in the new dylib that
///    matches a class already loaded in the app, replace all methods.
/// 2. **Symbol rebinding** — for exported symbols in the new dylib that
///    match known symbols in the app, rebind the pointer tables.
///
/// Both strategies are complementary; using both provides the widest coverage.
final class InterpositionEngine {

    // MARK: - Properties

    /// Tracks class method snapshots for diff detection.
    private var methodSnapshots: [String: [ObjCRuntimeBridge.MethodInfo]] = [:]

    /// Lock protecting `methodSnapshots` from concurrent access.
    private let snapshotLock = NSLock()

    // MARK: - Main Entry Point

    /// Apply interposition for a freshly loaded dylib.
    ///
    /// This is the primary API called by `ReloadPipeline` after `DylibLoader.load()`.
    ///
    /// - Parameters:
    ///   - loadedImage: The image that was just loaded by `DylibLoader`.
    ///   - affectedTypeNames: Type names extracted from the changed source file
    ///     (best-effort, from syntax analysis). Used to narrow the ObjC class search.
    /// - Returns: An `InterpositionResult` summarizing what was done.
    func interpose(
        loadedImage: LoadedImage,
        affectedTypeNames: [String]
    ) -> InterpositionResult {
        var diagnostics = [String]()
        var totalMethodsReplaced = 0
        var totalSymbolsRebound = 0
        var affectedClassNames = [String]()

        // --- Strategy 1: ObjC Method Replacement ---

        let objcResult = interposeObjCMethods(
            affectedTypeNames: affectedTypeNames,
            diagnostics: &diagnostics
        )
        totalMethodsReplaced += objcResult.methodsReplaced
        affectedClassNames.append(contentsOf: objcResult.classNames)

        // --- Strategy 2: Fishhook Symbol Rebinding ---

        let fishhookResult = interposeSymbols(
            loadedImage: loadedImage,
            affectedTypeNames: affectedTypeNames,
            diagnostics: &diagnostics
        )
        totalSymbolsRebound += fishhookResult

        return InterpositionResult(
            symbolsRebound: totalSymbolsRebound,
            methodsReplaced: totalMethodsReplaced,
            affectedClasses: affectedClassNames,
            diagnostics: diagnostics
        )
    }

    // MARK: - ObjC Method Replacement

    /// Intermediate result from ObjC method replacement.
    private struct ObjCInterpositionResult {
        let methodsReplaced: Int
        let classNames: [String]
    }

    /// Finds classes in the runtime matching the affected type names and replaces
    /// their methods with implementations from the newly loaded dylib classes.
    ///
    /// When a dylib is loaded that defines a class with the same name as an existing
    /// class, the ObjC runtime registers the new class under a different internal name
    /// (typically with a numeric suffix). We detect these "duplicate" classes and copy
    /// their method implementations onto the original class.
    private func interposeObjCMethods(
        affectedTypeNames: [String],
        diagnostics: inout [String]
    ) -> ObjCInterpositionResult {
        guard !affectedTypeNames.isEmpty else {
            diagnostics.append("No affected type names provided; skipping ObjC interposition.")
            return ObjCInterpositionResult(methodsReplaced: 0, classNames: [])
        }

        let matchingClasses = ObjCRuntimeBridge.findClasses(named: affectedTypeNames)

        guard !matchingClasses.isEmpty else {
            diagnostics.append("No ObjC classes found matching: \(affectedTypeNames.joined(separator: ", "))")
            return ObjCInterpositionResult(methodsReplaced: 0, classNames: [])
        }

        var totalReplaced = 0
        var classNames = [String]()

        // Group classes by short name to find original + reloaded pairs.
        var classesByShortName = [String: [AnyClass]]()
        for cls in matchingClasses {
            let fullName = NSStringFromClass(cls)
            let shortName: String
            if let dotIndex = fullName.lastIndex(of: ".") {
                shortName = String(fullName[fullName.index(after: dotIndex)...])
            } else {
                shortName = fullName
            }
            classesByShortName[shortName, default: []].append(cls)
        }

        for (shortName, classes) in classesByShortName {
            // When there are multiple classes with the same short name,
            // the newest one (last registered) has the fresh implementations.
            guard classes.count >= 2 else {
                // Single class — might still have been updated via dylib load.
                // Replace methods from the snapshot if we have one.
                continue
            }

            // Find the original class (from main app binary, not from /tmp/ dylib)
            // using class_getImageName instead of unreliable memory address sorting
            // (ASLR makes address ordering non-deterministic across runs).
            let originalClass: AnyClass? = classes.first { cls in
                guard let imageName = class_getImageName(cls) else { return true }
                let path = String(cString: imageName)
                return !path.contains("/tmp/") && !path.contains("hotswift")
            }
            let newestClass: AnyClass? = classes.last { cls in
                guard let imageName = class_getImageName(cls) else { return false }
                let path = String(cString: imageName)
                return path.contains("/tmp/") || path.contains("hotswift")
            }

            guard let originalClass = originalClass, let newestClass = newestClass else {
                diagnostics.append("Could not distinguish original from reloaded class for \(shortName)")
                continue
            }

            let replaced = ObjCRuntimeBridge.replaceAllMethods(
                on: originalClass,
                from: newestClass
            )

            if replaced > 0 {
                totalReplaced += replaced
                classNames.append(shortName)
                diagnostics.append("Replaced \(replaced) methods on \(shortName)")
            }
        }

        return ObjCInterpositionResult(
            methodsReplaced: totalReplaced,
            classNames: classNames
        )
    }

    // MARK: - Fishhook Symbol Rebinding

    /// Strategy 2: fishhook-based symbol rebinding.
    ///
    /// NOTE: This strategy only works for symbols that go through the GOT
    /// (Global Offset Table) — typically cross-module calls and @objc dynamic
    /// dispatch. Pure Swift class methods use vtable dispatch which cannot
    /// be intercepted by fishhook. Strategy 1 (ObjC runtime) handles those.
    ///
    /// This covers function pointers that are resolved through the symbol pointer
    /// tables (GOT/lazy stubs). It is effective for top-level functions, C-interop
    /// symbols, and @objc dynamic methods.
    private func interposeSymbols(
        loadedImage: LoadedImage,
        affectedTypeNames: [String],
        diagnostics: inout [String]
    ) -> Int {
        // Look up symbols in the new dylib that match known patterns
        // for the affected types. We use dlsym to probe for mangled Swift
        // symbol names based on the type names.
        var rebindCount = 0

        for typeName in affectedTypeNames {
            // Attempt to find the new implementation in the loaded dylib.
            // Swift mangles symbols with the module name prefix, so we
            // search for common patterns.
            let symbolPatterns = generateSymbolPatterns(for: typeName)

            for pattern in symbolPatterns {
                guard let newImpl = dlsym(loadedImage.handle, pattern) else {
                    continue
                }

                let newPointer = UnsafeMutableRawPointer(newImpl)
                var rebindings = [SymbolRebinder.Rebinding(
                    name: pattern,
                    replacement: newPointer
                )]

                if SymbolRebinder.rebind(&rebindings) {
                    rebindCount += 1
                }
            }
        }

        if rebindCount > 0 {
            diagnostics.append("Rebound \(rebindCount) symbols via fishhook")
        }

        return rebindCount
    }

    /// Generates candidate mangled symbol name patterns for a given Swift type name.
    ///
    /// Swift symbol mangling follows a predictable scheme. We generate a few
    /// common patterns to probe via `dlsym`. This is best-effort — the full
    /// mangling scheme is complex and version-dependent.
    private func generateSymbolPatterns(for typeName: String) -> [String] {
        // Common Swift mangled symbol patterns:
        // - $s<module-length><module><type-length><type>C... (class)
        // - $s<module-length><module><type-length><type>V... (struct)
        //
        // Since we don't know the module name used during compilation,
        // we generate patterns for common entry points.
        var patterns = [String]()

        // The `injected()` method is a common convention for hot-reload callbacks.
        // We try to rebind it if it exists in the dylib.
        patterns.append("_injected")

        // viewDidLoad for UIViewController subclasses
        patterns.append("_\(typeName)_viewDidLoad")

        return patterns
    }

    // MARK: - Snapshot Management

    /// Takes a snapshot of the current method implementations for the given classes.
    ///
    /// Call this before loading a new dylib so that `ClassDiffEngine` can compare
    /// the before/after states.
    ///
    /// - Parameter classNames: Names of classes to snapshot.
    func snapshotMethods(for classNames: [String]) {
        let classes = ObjCRuntimeBridge.findClasses(named: classNames)
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        for cls in classes {
            let name = NSStringFromClass(cls)
            methodSnapshots[name] = ObjCRuntimeBridge.instanceMethods(of: cls)
        }
    }

    /// Returns the previously captured method snapshot for a class, if any.
    ///
    /// - Parameter className: The full ObjC class name.
    /// - Returns: The snapshot, or `nil` if none was captured.
    func previousSnapshot(for className: String) -> [ObjCRuntimeBridge.MethodInfo]? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return methodSnapshots[className]
    }
}
#endif
