//
//  ReloadPipeline.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

// Orchestrates the full hot-reload pipeline: watch → compile → load → interpose → notify

#if DEBUG
import Foundation
import Combine

// MARK: - Reload Event

/// Represents the result of a single reload attempt through the pipeline.
public struct ReloadEvent {
    /// The outcome of the reload attempt.
    public enum Status {
        /// The file was successfully recompiled and loaded.
        case success
        /// Compilation failed. Check `diagnostics` for compiler output.
        case compilationFailed
        /// The compiled dylib could not be loaded. Check `diagnostics` for dlopen errors.
        case loadFailed
        /// Symbol interposition failed (Phase 2). The dylib loaded but methods were not swapped.
        case interpositionFailed
    }

    /// The outcome of this reload attempt.
    public let status: Status
    /// The source file path that triggered the reload.
    public let filePath: String
    /// Class/struct names detected in the changed file (best-effort, may be empty).
    public let affectedClasses: [String]
    /// Wall-clock duration of the full pipeline cycle (compile + load) in seconds.
    public let duration: TimeInterval
    /// Diagnostic messages from the compiler, loader, or interposer.
    public let diagnostics: [String]
    /// When this event was created.
    public let timestamp: Date
}

// MARK: - Pipeline

/// Orchestrates the full hot-reload pipeline:
///
/// 1. **Watch** — An `FSEventsWatcher` monitors source directories for `.swift` file changes.
/// 2. **Compile** — The changed file is recompiled into a standalone `.dylib` using the same
///    flags Xcode used during the last build (extracted from DerivedData).
/// 3. **Load** — The dylib is loaded into the running process via `dlopen`.
/// 4. **Interpose** — (Phase 2) Method implementations are swapped using `fishhook` + vtable patching.
/// 5. **Notify** — A `ReloadEvent` is emitted through the Combine publisher and `NotificationCenter`.
///
/// All heavy work (compilation, loading) runs on a dedicated serial dispatch queue.
/// Events are published on the main thread for safe UI consumption.
public final class ReloadPipeline {

    // MARK: - Properties

    /// Publisher for reload events. Subscribe to receive notifications of every reload attempt.
    public let events = PassthroughSubject<ReloadEvent, Never>()

    private let configuration: PipelineConfiguration
    private let fileWatcher: FileWatching
    private let loader: DylibLoader
    private let changeAnalyzer: ChangeAnalyzer
    private let queue: DispatchQueue

    /// Thread-safe running state. Access `_isRunning` only while holding `stateLock`.
    private let stateLock = NSLock()
    private var _isRunning = false

    /// Counter for generating unique dylib output filenames.
    private var compilationCounter: Int = 0

    /// Compiler and build settings extractor for full-fidelity recompilation.
    private lazy var compiler = SwiftCompiler()
    private lazy var settingsExtractor = BuildSettingsExtractor()

    /// Tracks generated dylibs for cleanup on stop.
    private var generatedDylibs: [String] = []

    // MARK: - Initialization

    /// Creates a new pipeline with the given configuration.
    ///
    /// - Parameter configuration: The pipeline configuration containing watch paths,
    ///   exclude patterns, debounce interval, and verbosity settings.
    public init(configuration: PipelineConfiguration) {
        self.configuration = configuration
        self.fileWatcher = FSEventsWatcher(
            debounceInterval: configuration.debounceInterval,
            excludePatterns: configuration.excludePatterns
        )
        self.loader = DylibLoader()
        self.changeAnalyzer = ChangeAnalyzer()
        self.queue = DispatchQueue(label: "com.hotswift.reload-pipeline", qos: .userInitiated)
    }

    // MARK: - Lifecycle

    /// Start the hot-reload pipeline.
    ///
    /// Begins watching the configured source directories for `.swift` file changes.
    /// When a change is detected, the file is compiled, loaded, and an event is emitted.
    public func start() {
        stateLock.lock()
        guard !_isRunning else {
            stateLock.unlock()
            return
        }
        _isRunning = true
        stateLock.unlock()

        fileWatcher.start(paths: configuration.watchPaths) { [weak self] changes in
            self?.handleFileChanges(changes)
        }
    }

    /// Stop the hot-reload pipeline and release the file watcher.
    public func stop() {
        stateLock.lock()
        guard _isRunning else {
            stateLock.unlock()
            return
        }
        _isRunning = false
        stateLock.unlock()

        fileWatcher.stop()

        // Drain the pipeline queue before cleanup so no in-flight compilation
        // is still writing to `generatedDylibs` when we read it.
        queue.sync { [weak self] in
            self?.cleanupDylibs()
        }
    }

    /// Removes all generated dylibs from disk. Must be called on `queue`.
    private func cleanupDylibs() {
        for path in generatedDylibs {
            try? FileManager.default.removeItem(atPath: path)
        }
        generatedDylibs.removeAll()
    }

    // MARK: - File Change Handling

    /// Called by the file watcher when one or more files change.
    ///
    /// Routes each change through the `ChangeAnalyzer` to determine whether
    /// it can be hot-reloaded in-process or requires a full Xcode rebuild.
    private func handleFileChanges(_ changes: [FileEvent]) {
        guard !changes.isEmpty else { return }

        for change in changes {
            queue.async { [weak self] in
                self?.routeChange(change)
            }
        }
    }

    // MARK: - Smart Change Routing

    /// Routes a file event based on its `ChangeType`.
    ///
    /// - `.bodyOnly` — fast path: compile + dlopen (existing hot-reload).
    /// - `.structural` — trigger a full Xcode rebuild.
    /// - `.newFile` — add to pbxproj, then trigger rebuild.
    /// - `.deleted` — remove from pbxproj, then trigger rebuild.
    private func routeChange(_ event: FileEvent) {
        let changeType = changeAnalyzer.analyze(filePath: event.path, eventType: event.type)

        log("Change type for \(event.path): \(changeType)")

        switch changeType {
        case .bodyOnly:
            // Fast path — use the existing hot-reload pipeline.
            processChange(event)

        case .structural:
            log("Structural change detected — triggering Xcode rebuild")
            triggerXcodeRebuild(reason: "Structural change in \((event.path as NSString).lastPathComponent)")

        case .newFile:
            log("New file detected — updating pbxproj and triggering rebuild")
            addFileToPbxproj(filePath: event.path)
            triggerXcodeRebuild(reason: "New file: \((event.path as NSString).lastPathComponent)")

        case .deleted:
            log("File deleted — updating pbxproj and triggering rebuild")
            removeFileFromPbxproj(fileName: (event.path as NSString).lastPathComponent)
            triggerXcodeRebuild(reason: "Deleted file: \((event.path as NSString).lastPathComponent)")
        }
    }

    // MARK: - Pbxproj Management

    /// Add a new file to the project's pbxproj.
    private func addFileToPbxproj(filePath: String) {
        guard let pbxprojPath = configuration.pbxprojPath else {
            log("No pbxproj path configured — skipping project file update")
            return
        }

        do {
            let editor = try PbxprojEditor(pbxprojPath: pbxprojPath)
            let groupPath = (filePath as NSString).deletingLastPathComponent.components(separatedBy: "/").last ?? ""
            try editor.addFile(filePath: filePath, groupPath: groupPath)
            try editor.save()
            log("Added \((filePath as NSString).lastPathComponent) to pbxproj")
        } catch {
            log("Failed to update pbxproj: \(error.localizedDescription)")
        }
    }

    /// Remove a deleted file from the project's pbxproj.
    private func removeFileFromPbxproj(fileName: String) {
        guard let pbxprojPath = configuration.pbxprojPath else {
            log("No pbxproj path configured — skipping project file update")
            return
        }

        do {
            let editor = try PbxprojEditor(pbxprojPath: pbxprojPath)
            editor.removeFile(fileName: fileName)
            try editor.save()
            log("Removed \(fileName) from pbxproj")
        } catch {
            log("Failed to update pbxproj: \(error.localizedDescription)")
        }
    }

    // MARK: - Xcode Rebuild

    /// Ask Xcode to stop the current session and Build & Run again.
    private func triggerXcodeRebuild(reason: String) {
        log("Requesting Xcode rebuild: \(reason)")
        XcodeController.triggerRebuild { [weak self] error in
            if let error = error {
                self?.log("Xcode rebuild request failed: \(error.localizedDescription)")
            } else {
                self?.log("Xcode rebuild triggered successfully")
            }
        }
    }

    /// Processes a single file change through the full pipeline.
    ///
    /// Steps:
    /// 1. Compile the changed file into a `.dylib`
    /// 2. Load the dylib into the process
    /// 3. (Phase 2) Interpose method implementations
    /// 4. Emit a `ReloadEvent`
    private func processChange(_ event: FileEvent) {
        let startTime = Date()
        var diagnostics: [String] = []

        log("File changed: \(event.path)")

        // --- Step 1: Compile ---

        let dylibPath: String
        do {
            dylibPath = try compileFile(event.path, diagnostics: &diagnostics)
            log("Compiled successfully: \(dylibPath)")
        } catch {
            let message = "Compilation failed for \(event.path): \(error.localizedDescription)"
            diagnostics.append(message)
            log(message)
            emitEvent(
                status: .compilationFailed,
                filePath: event.path,
                affectedClasses: [],
                startTime: startTime,
                diagnostics: diagnostics
            )
            return
        }

        // --- Step 2: Load ---

        let loadedImage: LoadedImage
        do {
            loadedImage = try loader.load(dylibPath: dylibPath)
            log("Loaded dylib v\(loadedImage.version): \(dylibPath)")
        } catch {
            let message = "Load failed for \(dylibPath): \(error.localizedDescription)"
            diagnostics.append(message)
            log(message)
            emitEvent(
                status: .loadFailed,
                filePath: event.path,
                affectedClasses: [],
                startTime: startTime,
                diagnostics: diagnostics
            )
            return
        }

        // --- Step 3: Interpose (Phase 2 placeholder) ---
        // TODO: Phase 2 — Use fishhook/vtable patching to swap method implementations
        // For now, simply loading the dylib is enough for @_dynamicReplacement to take effect.

        // --- Step 4: Detect affected types (best-effort) ---
        let affectedClasses = extractClassNames(from: event.path)

        // --- Step 5: Notify ---
        let successMessage = "Reloaded \(event.path) (v\(loadedImage.version))"
        diagnostics.append(successMessage)
        log(successMessage)

        emitEvent(
            status: .success,
            filePath: event.path,
            affectedClasses: affectedClasses,
            startTime: startTime,
            diagnostics: diagnostics
        )
    }

    // MARK: - Compilation

    /// Compiles a single Swift source file into a dynamic library.
    ///
    /// Attempts to use full build settings extracted from DerivedData (via `BuildSettingsExtractor`
    /// and `SwiftCompiler`). If extraction fails (e.g. first run with no build log yet), falls
    /// back to a minimal swiftc invocation with `-Xlinker -undefined -Xlinker dynamic_lookup`.
    ///
    /// - Parameters:
    ///   - filePath: Absolute path to the `.swift` source file.
    ///   - diagnostics: Mutable array to collect diagnostic output.
    /// - Returns: The path to the compiled `.dylib`.
    /// - Throws: If compilation fails (non-zero exit code or missing output).
    private func compileFile(_ filePath: String, diagnostics: inout [String]) throws -> String {
        // Try to use full build settings from xcactivitylog
        if let settings = try? settingsExtractor.extractSettings(
            forFile: filePath,
            projectName: configuration.projectName
        ) {
            let result = compiler.compile(filePath: filePath, settings: settings)
            if !result.stderr.isEmpty {
                diagnostics.append(result.stderr)
            }
            guard result.success, let dylibPath = result.dylibPath else {
                throw CompilationError.compilationFailed(
                    exitCode: 1,
                    output: result.stderr
                )
            }
            generatedDylibs.append(dylibPath)
            return dylibPath
        }

        // Fallback: basic compilation with minimal flags
        compilationCounter += 1
        let tempDir = NSTemporaryDirectory() + "hotswift"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        let outputPath = (tempDir as NSString).appendingPathComponent("reload_\(compilationCounter).dylib")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "swiftc",
            "-emit-library",
            "-o", outputPath,
            "-module-name", "HotSwiftReload\(compilationCounter)",
            "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup",
            filePath
        ]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()

        // Read stderr async to prevent deadlock
        var stderrData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        // Timeout after 30 seconds
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak process] in
            guard let process = process, process.isRunning else { return }
            process.terminate()
        }

        process.waitUntilExit()
        group.wait()

        let stderrString = String(data: stderrData, encoding: .utf8) ?? ""
        if !stderrString.isEmpty {
            diagnostics.append(stderrString)
        }

        guard process.terminationStatus == 0 else {
            throw CompilationError.compilationFailed(
                exitCode: process.terminationStatus,
                output: stderrString
            )
        }

        guard FileManager.default.fileExists(atPath: outputPath) else {
            throw CompilationError.outputMissing(outputPath)
        }

        generatedDylibs.append(outputPath)
        return outputPath
    }

    // MARK: - Class Name Extraction

    /// Extracts class/struct names from a Swift source file using simple pattern matching.
    ///
    /// This is a best-effort heuristic — it looks for `class`, `struct`, and `enum` declarations.
    /// A full implementation would use SwiftSyntax for accurate parsing.
    ///
    /// - Parameter filePath: Path to the Swift source file.
    /// - Returns: An array of type names found in the file.
    private func extractClassNames(from filePath: String) -> [String] {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return []
        }

        var names: [String] = []
        let declarationPattern = #"(?:^|\s)(?:@\w+(?:\([^)]*\))?\s+)*(?:public\s+|private\s+|internal\s+|open\s+|fileprivate\s+)?(?:final\s+)?(?:class|struct|enum|actor)\s+(\w+)"#

        guard let regex = try? NSRegularExpression(pattern: declarationPattern, options: .anchorsMatchLines) else {
            return []
        }

        let range = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, options: [], range: range)

        for match in matches {
            if let captureRange = Range(match.range(at: 1), in: content) {
                names.append(String(content[captureRange]))
            }
        }

        return names
    }

    // MARK: - Event Emission

    /// Constructs a `ReloadEvent` and dispatches it to subscribers on the main thread.
    private func emitEvent(
        status: ReloadEvent.Status,
        filePath: String,
        affectedClasses: [String],
        startTime: Date,
        diagnostics: [String]
    ) {
        let event = ReloadEvent(
            status: status,
            filePath: filePath,
            affectedClasses: affectedClasses,
            duration: Date().timeIntervalSince(startTime),
            diagnostics: diagnostics,
            timestamp: Date()
        )

        DispatchQueue.main.async { [weak self] in
            self?.events.send(event)

            // Post a Foundation notification for observers that don't use Combine.
            NotificationCenter.default.post(
                name: Notification.Name("HotSwiftDidReload"),
                object: nil,
                userInfo: [
                    "filePath": event.filePath,
                    "affectedClasses": event.affectedClasses
                ]
            )
        }
    }

    // MARK: - Logging

    /// Logs a message. Uses HotSwiftLogger if available, falls back to print.
    private func log(_ message: String) {
        if configuration.verbose {
            print("[HotSwift] \(message)")
        }
    }
}

// MARK: - Pipeline Configuration

/// Internal configuration consumed by the pipeline.
/// Mapped from the public `HotSwiftConfiguration` at the HotSwift module boundary.
public struct PipelineConfiguration {
    public let watchPaths: [String]
    public let excludePatterns: [String]
    public let debounceInterval: TimeInterval
    public let verbose: Bool
    public let pbxprojPath: String?
    public let projectName: String?

    public init(
        watchPaths: [String],
        excludePatterns: [String],
        debounceInterval: TimeInterval,
        verbose: Bool,
        pbxprojPath: String?,
        projectName: String?
    ) {
        self.watchPaths = watchPaths
        self.excludePatterns = excludePatterns
        self.debounceInterval = debounceInterval
        self.verbose = verbose
        self.pbxprojPath = pbxprojPath
        self.projectName = projectName
    }
}

// MARK: - Compilation Errors

/// Errors specific to the compilation step of the pipeline.
enum CompilationError: LocalizedError {
    /// `swiftc` exited with a non-zero status.
    case compilationFailed(exitCode: Int32, output: String)
    /// The expected output dylib was not produced.
    case outputMissing(String)

    var errorDescription: String? {
        switch self {
        case .compilationFailed(let exitCode, let output):
            return "Compilation failed (exit \(exitCode)):\n\(output)"
        case .outputMissing(let path):
            return "Compiled dylib not found at expected path: \(path)"
        }
    }
}
#endif
