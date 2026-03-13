//
//  HotSwift.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

// Main public entry point for the HotSwift hot-reload engine

import Foundation

#if DEBUG
import HotSwiftCore
import Combine

/// HotSwift — iOS Hot-Reload Engine
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
/// ## Observing Reload Events
///
/// **Combine:**
/// ```swift
/// HotSwift.reloadEvents
///     .filter { $0.status == .success }
///     .sink { event in print("Reloaded: \(event.filePath)") }
///     .store(in: &cancellables)
/// ```
///
/// **NotificationCenter:**
/// ```swift
/// NotificationCenter.default.addObserver(
///     forName: HotSwift.didReloadNotification,
///     object: nil, queue: .main
/// ) { notification in
///     // Refresh your UI
/// }
/// ```
///
/// ## How It Works
///
/// 1. **Watch** — FSEvents monitors your source directories for `.swift` file changes.
/// 2. **Compile** — The changed file is recompiled into a standalone `.dylib`.
/// 3. **Load** — The dylib is loaded into the process via `dlopen`.
/// 4. **Notify** — A `HotSwiftReloadEvent` is emitted for UI refresh.
///
/// In Release builds, HotSwift compiles to empty stubs — zero overhead, zero binary size impact.
public final class HotSwift {

    // MARK: - Shared Instance

    /// The shared singleton instance.
    public static let shared = HotSwift()

    // MARK: - Public API

    /// A Combine publisher that emits an event after every reload attempt.
    ///
    /// Events are delivered on the **main thread** and include both successes and failures.
    /// Filter by `.status` to handle only the cases you care about.
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

    /// Notification posted after every reload attempt.
    ///
    /// The `userInfo` dictionary contains:
    /// - `"filePath"`: The source file path (`String`)
    /// - `"affectedClasses"`: Detected type names (`[String]`)
    public static let didReloadNotification = Notification.Name("HotSwiftDidReload")

    // MARK: - State

    private var pipeline: ReloadPipeline?
    private var isRunning = false

    // MARK: - Start / Stop

    /// Start the hot-reload engine with the given configuration.
    ///
    /// Call this once during app launch, guarded by `#if DEBUG`:
    ///
    /// ```swift
    /// #if DEBUG
    /// HotSwift.start()
    /// #endif
    /// ```
    ///
    /// If `config.watchPaths` is empty, the project root is auto-detected by walking
    /// up from the calling file's location until an `.xcodeproj` or `.xcworkspace` is found.
    ///
    /// - Parameters:
    ///   - sourceFile: The caller's file path (auto-populated by `#file`). Used for
    ///     project root detection when `watchPaths` is empty.
    ///   - config: Configuration options. Defaults to `HotSwiftConfiguration.default`.
    public static func start(
        sourceFile: String = #file,
        config: HotSwiftConfiguration = .default
    ) {
        shared.startPipeline(sourceFile: sourceFile, config: config)
    }

    /// Stop the hot-reload engine and release all resources.
    ///
    /// The file watcher is stopped and the pipeline is torn down. You can call
    /// `start()` again to restart.
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

        // Auto-detect project root from #file if no watch paths are provided.
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

    /// Walks up the directory tree from the given source file path to find the project root.
    ///
    /// The project root is defined as the first directory that contains a `.xcodeproj`
    /// or `.xcworkspace` bundle. Searches up to 10 levels to avoid walking to `/`.
    ///
    /// - Parameter sourceFile: A file path within the project (typically from `#file`).
    /// - Returns: The detected project root path, or `nil` if not found.
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

            // Stop if we've reached the filesystem root.
            if parent.path == directory.path {
                break
            }

            directory = parent
        }

        return nil
    }

    // MARK: - Logging

    /// Prints a prefixed log message to the console.
    private func log(_ message: String) {
        print("[HotSwift] \(message)")
    }
}

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
