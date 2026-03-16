//
//  XcodeController.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

// Controls Xcode via AppleScript to trigger rebuilds when structural changes are detected

#if DEBUG
#if os(macOS)
import Foundation

// MARK: - Xcode Controller

/// Controls the running Xcode instance via AppleScript to stop the current
/// build/run session and trigger a fresh Build & Run.
///
/// Used when the `ChangeAnalyzer` detects structural changes (new types,
/// changed signatures, etc.) that cannot be hot-reloaded via `dlopen`.
enum XcodeController {

    // MARK: - Public API

    /// Debounce lock to prevent rapid successive rebuild triggers.
    private static var pendingRebuild: DispatchWorkItem?
    private static let rebuildLock = NSLock()

    /// Stop the current Xcode build/run session and trigger a fresh Build & Run.
    ///
    /// Activates Xcode first to ensure keystrokes land correctly, then sends
    /// `Cmd+.` (stop), waits briefly, then sends `Cmd+R` (build & run).
    /// Debounced to coalesce rapid successive calls (e.g. git branch switch).
    ///
    /// - Parameter completion: Called on completion with an optional error.
    static func triggerRebuild(completion: ((Error?) -> Void)? = nil) {
        rebuildLock.lock()
        pendingRebuild?.cancel()
        let work = DispatchWorkItem {
            let script = """
            tell application "Xcode" to activate
            delay 0.3
            tell application "System Events"
                tell process "Xcode"
                    keystroke "." using command down
                    delay 1.0
                    keystroke "r" using command down
                end tell
            end tell
            """

            let result = runAppleScript(script)
            DispatchQueue.main.async {
                completion?(result)
            }
        }
        pendingRebuild = work
        rebuildLock.unlock()

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Stop the current Xcode build/run session without restarting.
    ///
    /// Sends `Cmd+.` (stop) to Xcode.
    ///
    /// - Parameter completion: Called on completion with an optional error.
    static func stopBuild(completion: ((Error?) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let script = """
            tell application "Xcode" to activate
            delay 0.3
            tell application "System Events"
                tell process "Xcode"
                    keystroke "." using command down
                end tell
            end tell
            """

            let result = runAppleScript(script)
            DispatchQueue.main.async {
                completion?(result)
            }
        }
    }

    // MARK: - Private Methods

    /// Execute an AppleScript string via `osascript` and return any error.
    private static func runAppleScript(_ source: String) -> Error? {
        let result = ShellExecutor.run(
            executablePath: "/usr/bin/osascript",
            arguments: ["-e", source],
            timeout: 10
        )

        guard result.exitCode == 0 else {
            return XcodeControllerError.appleScriptFailed(
                exitCode: result.exitCode,
                message: result.stderr.isEmpty ? "Unknown osascript error" : result.stderr
            )
        }

        return nil
    }
}

// MARK: - Errors

/// Errors from `XcodeController` operations.
enum XcodeControllerError: LocalizedError {
    /// The `osascript` process exited with a non-zero status.
    case appleScriptFailed(exitCode: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .appleScriptFailed(let exitCode, let message):
            return "AppleScript failed (exit \(exitCode)): \(message)"
        }
    }
}

#endif // os(macOS)
#endif // DEBUG
