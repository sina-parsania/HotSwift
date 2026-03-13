//
//  ClassDiffEngine.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

// Detects which classes were affected by a dylib reload by diffing method lists

#if DEBUG
import Foundation

// MARK: - Class Diff Result

/// Describes the changes detected on a single class after a dylib reload.
struct ClassDiff {
    /// The full Objective-C class name (may include module prefix).
    let className: String
    /// Methods that were added (not present before reload).
    let addedMethods: [String]
    /// Methods whose implementation pointer changed (updated code).
    let changedMethods: [String]
    /// Methods that were removed (present before, gone after).
    let removedMethods: [String]

    /// Whether this class had any detectable changes.
    var hasChanges: Bool {
        return !addedMethods.isEmpty || !changedMethods.isEmpty || !removedMethods.isEmpty
    }
}

// MARK: - Class Diff Engine

/// Compares ObjC class method lists before and after a dylib reload to determine
/// exactly which classes and methods were affected.
///
/// ## Workflow
///
/// 1. Before loading a new dylib, call `captureSnapshot(for:)` to record the
///    current method implementations of the classes that might change.
/// 2. After loading the dylib and performing interposition, call `computeDiffs(for:)`
///    to compare the current state against the captured snapshot.
/// 3. The returned `ClassDiff` array tells the `InjectionNotifier` which classes
///    need their instances refreshed.
final class ClassDiffEngine {

    // MARK: - Types

    /// Snapshot of a class's method list at a point in time.
    private struct MethodSnapshot {
        /// Maps selector name -> IMP address (as UInt).
        let methods: [String: UInt]
        /// When this snapshot was captured.
        let capturedAt: Date
    }

    // MARK: - Properties

    /// Stored snapshots keyed by full ObjC class name.
    private var snapshots: [String: MethodSnapshot] = [:]
    /// Protects `snapshots` from concurrent access across threads.
    private let lock = NSLock()

    // MARK: - Snapshot Capture

    /// Capture the current method implementations for the given class names.
    ///
    /// This records a mapping of selector name to IMP address for each class.
    /// Call this **before** loading a new dylib so you have a baseline to diff against.
    ///
    /// - Parameter classNames: Swift type names to snapshot. The engine will find
    ///   matching ObjC classes in the runtime.
    func captureSnapshot(for classNames: [String]) {
        let classes = ObjCRuntimeBridge.findClasses(named: classNames)

        for cls in classes {
            let fullName = NSStringFromClass(cls)
            let methods = ObjCRuntimeBridge.instanceMethods(of: cls)

            var methodMap = [String: UInt]()
            methodMap.reserveCapacity(methods.count)

            for method in methods {
                let impAddress = unsafeBitCast(method.implementation, to: UInt.self)
                methodMap[method.selectorName] = impAddress
            }

            lock.lock()
            snapshots[fullName] = MethodSnapshot(
                methods: methodMap,
                capturedAt: Date()
            )
            lock.unlock()
        }
    }

    // MARK: - Diff Computation

    /// Compare the current method implementations against the previously captured snapshot.
    ///
    /// For each class name, this checks:
    /// - **Added methods**: selectors present now but not in the snapshot.
    /// - **Changed methods**: selectors present in both, but with different IMP addresses.
    /// - **Removed methods**: selectors in the snapshot but no longer present.
    ///
    /// - Parameter classNames: Swift type names to diff.
    /// - Returns: An array of `ClassDiff` entries. Only classes with actual changes are included.
    func computeDiffs(for classNames: [String]) -> [ClassDiff] {
        let classes = ObjCRuntimeBridge.findClasses(named: classNames)
        var diffs = [ClassDiff]()

        for cls in classes {
            let fullName = NSStringFromClass(cls)
            let currentMethods = ObjCRuntimeBridge.instanceMethods(of: cls)

            // Build current method map.
            var currentMap = [String: UInt]()
            currentMap.reserveCapacity(currentMethods.count)
            for method in currentMethods {
                let impAddress = unsafeBitCast(method.implementation, to: UInt.self)
                currentMap[method.selectorName] = impAddress
            }

            lock.lock()
            let snapshot = snapshots[fullName]
            lock.unlock()

            guard let snapshot else {
                // No previous snapshot — treat all methods as "added".
                let diff = ClassDiff(
                    className: fullName,
                    addedMethods: currentMethods.map(\.selectorName),
                    changedMethods: [],
                    removedMethods: []
                )
                if diff.hasChanges {
                    diffs.append(diff)
                }
                continue
            }

            let previousMap = snapshot.methods

            var added = [String]()
            var changed = [String]()
            var removed = [String]()

            // Find added and changed methods.
            for (selector, currentIMP) in currentMap {
                if let previousIMP = previousMap[selector] {
                    if currentIMP != previousIMP {
                        changed.append(selector)
                    }
                } else {
                    added.append(selector)
                }
            }

            // Find removed methods.
            for selector in previousMap.keys {
                if currentMap[selector] == nil {
                    removed.append(selector)
                }
            }

            let diff = ClassDiff(
                className: fullName,
                addedMethods: added.sorted(),
                changedMethods: changed.sorted(),
                removedMethods: removed.sorted()
            )

            if diff.hasChanges {
                diffs.append(diff)
            }
        }

        return diffs
    }

    // MARK: - Convenience

    /// Captures a snapshot, then returns a closure that computes the diff when called.
    ///
    /// This is a convenience for the common pattern of snapshotting before a dylib
    /// load and diffing after.
    ///
    /// ```swift
    /// let computeDiff = diffEngine.prepareForReload(classNames: ["MyViewController"])
    /// // ... load dylib and interpose ...
    /// let diffs = computeDiff()
    /// ```
    ///
    /// - Parameter classNames: Swift type names to track.
    /// - Returns: A closure that, when called, computes and returns the diffs.
    func prepareForReload(classNames: [String]) -> () -> [ClassDiff] {
        captureSnapshot(for: classNames)
        return { [weak self] in
            return self?.computeDiffs(for: classNames) ?? []
        }
    }

    /// Clears all stored snapshots.
    func clearSnapshots() {
        snapshots.removeAll()
    }

    /// Returns the names of all classes that currently have a stored snapshot.
    var snapshotClassNames: [String] {
        return Array(snapshots.keys)
    }
}
#endif
