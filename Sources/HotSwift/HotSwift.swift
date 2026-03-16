//
//  HotSwift.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

// Main public entry point for the HotSwift hot-reload engine

import Foundation

#if DEBUG

#if os(macOS)
import HotSwiftCore
import Combine

/// HotSwift — Hot-Reload Engine
///
/// Drop-in hot-reload for UIKit and SwiftUI projects. HotSwift watches your Swift source
/// files for changes, recompiles them on the fly, and loads the new code into the running
/// process — no restart required.
///
/// ## Quick Start
///
/// Add a single line to your `AppDelegate` (or `@main App` struct):
///
/// ```swift
/// #if DEBUG
/// import HotSwift
///
/// // In application(_:didFinishLaunchingWithOptions:):
/// HotSwift.start()
/// #endif
/// ```
///
/// HotSwift automatically detects your project root from `#file`, watches for `.swift`
/// file changes, recompiles them using Xcode's cached build settings, and loads the
/// result into the running process.
///
/// ## How It Works
///
/// 1. **Watch** — FSEvents monitors your source directories for `.swift` file changes.
/// 2. **Compile** — The changed file is recompiled into a standalone `.dylib`.
/// 3. **Load** — The dylib is loaded into the process via `dlopen`.
/// 4. **Notify** — A `HotSwiftReloadEvent` is emitted for UI refresh.
///
/// In Release builds, HotSwift compiles to empty stubs — zero overhead, zero binary size impact.
///
/// > Note: On iOS, `start()` is a no-op because the iOS sandbox does not allow process
/// > spawning (required for `swiftc`). Run HotSwift from macOS (Xcode on Mac) to use
/// > hot-reload with the iOS Simulator.
public final class HotSwift {

    // MARK: - Shared Instance

    public static let shared = HotSwift()

    // MARK: - Public API

    public static var reloadEvents: AnyPublisher<HotSwiftReloadEvent, Never> {
        guard let pipeline = shared.pipeline else {
            return Empty().eraseToAnyPublisher()
        }

        return pipeline.events
            .map { internalEvent in
                HotSwiftReloadEvent(
                    status: internalEvent.status == .success ? .success : .failed,
                    filePath: internalEvent.filePath,
                    affectedClasses: internalEvent.affectedClasses,
                    duration: internalEvent.duration,
                    message: internalEvent.diagnostics.last ?? "",
                    timestamp: internalEvent.timestamp
                )
            }
            .eraseToAnyPublisher()
    }

    public static let didReloadNotification = Notification.Name("HotSwiftDidReload")

    // MARK: - State

    private var pipeline: ReloadPipeline?
    private var isRunning = false

    // MARK: - Start / Stop

    public static func start(
        sourceFile: String = #file,
        config: HotSwiftConfiguration = .default
    ) {
        shared.startPipeline(sourceFile: sourceFile, config: config)
    }

    public static func stop() {
        shared.stopPipeline()
    }

    // MARK: - Private Implementation

    private init() {}

    private func startPipeline(sourceFile: String, config: HotSwiftConfiguration) {
        guard !isRunning else {
            log("HotSwift is already running — ignoring duplicate start()")
            return
        }

        var resolvedConfig = config

        if resolvedConfig.watchPaths.isEmpty {
            if let projectRoot = detectProjectRoot(from: sourceFile) {
                resolvedConfig.watchPaths = [projectRoot]
            } else {
                log("Warning: Could not auto-detect project root from \(sourceFile). "
                    + "Provide explicit watchPaths in HotSwiftConfiguration.")
                return
            }
        }

        log("Starting HotSwift...")
        log("Watching: \(resolvedConfig.watchPaths.joined(separator: ", "))")
        log("Exclude patterns: \(resolvedConfig.excludePatterns.joined(separator: ", "))")
        log("Debounce: \(resolvedConfig.debounceInterval)s")

        let pipelineConfig = PipelineConfiguration(
            watchPaths: resolvedConfig.watchPaths,
            excludePatterns: resolvedConfig.excludePatterns,
            debounceInterval: resolvedConfig.debounceInterval,
            verbose: resolvedConfig.verbose,
            pbxprojPath: resolvedConfig.pbxprojPath,
            projectName: resolvedConfig.projectName
        )

        pipeline = ReloadPipeline(configuration: pipelineConfig)
        pipeline?.start()
        isRunning = true

        log("HotSwift is running. Edit a .swift file to trigger a reload.")
    }

    private func stopPipeline() {
        guard isRunning else { return }

        pipeline?.stop()
        pipeline = nil
        isRunning = false

        log("HotSwift stopped.")
    }

    // MARK: - Project Root Detection

    private func detectProjectRoot(from sourceFile: String) -> String? {
        let sourceURL = URL(fileURLWithPath: sourceFile)
        var directory = sourceURL.deletingLastPathComponent()
        let maxDepth = 10

        for _ in 0..<maxDepth {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []

            let hasProjectFile = contents.contains { item in
                item.hasSuffix(".xcodeproj") || item.hasSuffix(".xcworkspace")
            }

            if hasProjectFile {
                return directory.path
            }

            let parent = directory.deletingLastPathComponent()

            if parent.path == directory.path {
                break
            }

            directory = parent
        }

        return nil
    }

    // MARK: - Logging

    private func log(_ message: String) {
        print("[HotSwift] \(message)")
    }
}

#else // !os(macOS) — iOS / other platforms

import Foundation
import Combine

/// iOS stub — hot-reload requires macOS for process spawning (`swiftc`).
///
/// `start()` logs a diagnostic message and returns. All other APIs are no-ops.
/// HotSwiftUI (UIViewController swizzling, notification observation) still works —
/// it listens for `HotSwiftDidReload` notifications that would be posted by a
/// companion macOS process in a future network-based reload mode.
public final class HotSwift {
    public static let shared = HotSwift()
    public static let didReloadNotification = Notification.Name("HotSwiftDidReload")

    public static var reloadEvents: AnyPublisher<HotSwiftReloadEvent, Never> {
        Empty().eraseToAnyPublisher()
    }

    public static func start(
        sourceFile: String = #file,
        config: HotSwiftConfiguration = .default
    ) {
        print("[HotSwift] Hot-reload is only available on macOS. "
              + "The iOS sandbox does not allow process spawning required for compilation. "
              + "Run your app from Xcode on Mac to use hot-reload with the Simulator.")
    }

    public static func stop() {}

    private init() {}
}

#endif // os(macOS)

#else

// MARK: - Release Stub

import Combine

/// Release stub — all methods are no-ops. Zero overhead, zero binary size impact.
public final class HotSwift {
    public static let shared = HotSwift()
    public static let didReloadNotification = Notification.Name("HotSwiftDidReload")

    public static var reloadEvents: AnyPublisher<HotSwiftReloadEvent, Never> {
        Empty().eraseToAnyPublisher()
    }

    public static func start(
        sourceFile: String = #file,
        config: HotSwiftConfiguration = .default
    ) {}

    public static func stop() {}

    private init() {}
}

#endif
