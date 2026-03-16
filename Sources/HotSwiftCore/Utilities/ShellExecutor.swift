//
//  ShellExecutor.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

// Cross-platform process execution — uses Process on macOS, popen on iOS simulator

#if DEBUG
#if os(macOS)
import Foundation

/// Result of a shell command execution (text mode).
struct ShellResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Result of a shell command execution (binary mode).
struct ShellDataResult {
    let exitCode: Int32
    let stdoutData: Data
    let stderr: String
}

/// Cross-platform shell command executor.
///
/// On macOS, uses `Process` (NSTask) for full subprocess control with separate
/// stdout/stderr capture and timeout support. On iOS (simulator), falls back to
/// `popen()` since `Process` is not available in the iOS SDK.
enum ShellExecutor {

    /// Run an executable with the given arguments.
    ///
    /// - Parameters:
    ///   - executablePath: Absolute path to the executable.
    ///   - arguments: Command-line arguments.
    ///   - timeout: Maximum time in seconds before the process is killed. Default: 30s.
    /// - Returns: A `ShellResult` with exit code, stdout, and stderr.
    static func run(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval = 30
    ) -> ShellResult {
        #if os(macOS)
        return runWithProcess(executablePath: executablePath, arguments: arguments, timeout: timeout)
        #else
        return runWithPopen(executablePath: executablePath, arguments: arguments)
        #endif
    }

    // MARK: - macOS (Process)

    #if os(macOS)
    private static func runWithProcess(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ShellResult(
                exitCode: -1,
                stdout: "",
                stderr: "Failed to launch process: \(error.localizedDescription)"
            )
        }

        // Timeout guard
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
            guard let process = process, process.isRunning else { return }
            process.terminate()
        }

        // Read pipes on background threads to avoid buffer deadlock
        var stdoutData = Data()
        var stderrData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        process.waitUntilExit()
        group.wait()

        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
    #endif

    // MARK: - iOS Simulator (popen)

    #if !os(macOS)
    private static func runWithPopen(
        executablePath: String,
        arguments: [String]
    ) -> ShellResult {
        // Build a shell-safe command string
        let escapedArgs = arguments.map { shellEscape($0) }
        let command = ([shellEscape(executablePath)] + escapedArgs).joined(separator: " ")

        // Capture stderr to a temp file since popen only captures stdout
        let stderrPath = NSTemporaryDirectory() + "hotswift_stderr_\(ProcessInfo.processInfo.processIdentifier)_\(Int.random(in: 0...999999)).txt"
        let fullCommand = "\(command) 2>\(shellEscape(stderrPath))"

        var stdoutOutput = ""

        guard let pipe = popen(fullCommand, "r") else {
            return ShellResult(exitCode: -1, stdout: "", stderr: "popen failed")
        }

        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while fgets(buffer, Int32(bufferSize), pipe) != nil {
            stdoutOutput += String(cString: buffer)
        }

        let rawStatus = pclose(pipe)

        // pclose returns the full wait status; extract the exit code
        let exitCode: Int32
        #if canImport(Darwin)
        exitCode = (rawStatus >> 8) & 0xFF
        #else
        exitCode = rawStatus
        #endif

        let stderrOutput = (try? String(contentsOfFile: stderrPath, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: stderrPath)

        return ShellResult(
            exitCode: exitCode,
            stdout: stdoutOutput,
            stderr: stderrOutput
        )
    }

    /// Escape a string for safe use in a POSIX shell command.
    private static func shellEscape(_ string: String) -> String {
        // If it only contains safe characters, no escaping needed
        let safeChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/-_.=:@,+"))
        if string.unicodeScalars.allSatisfy({ safeChars.contains($0) }) {
            return string
        }
        // Wrap in single quotes, escaping any embedded single quotes
        return "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    #endif

    // MARK: - Binary Output

    /// Run an executable and capture stdout as raw Data (for binary output like gunzip).
    static func runForData(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval = 60
    ) -> ShellDataResult {
        #if os(macOS)
        return runForDataWithProcess(executablePath: executablePath, arguments: arguments, timeout: timeout)
        #else
        return runForDataWithPopen(executablePath: executablePath, arguments: arguments)
        #endif
    }

    #if os(macOS)
    private static func runForDataWithProcess(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> ShellDataResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ShellDataResult(
                exitCode: -1,
                stdoutData: Data(),
                stderr: "Failed to launch process: \(error.localizedDescription)"
            )
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
            guard let process = process, process.isRunning else { return }
            process.terminate()
        }

        var stdoutData = Data()
        var stderrData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        process.waitUntilExit()
        group.wait()

        return ShellDataResult(
            exitCode: process.terminationStatus,
            stdoutData: stdoutData,
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
    #endif

    #if !os(macOS)
    private static func runForDataWithPopen(
        executablePath: String,
        arguments: [String]
    ) -> ShellDataResult {
        let escapedArgs = arguments.map { shellEscape($0) }
        let command = ([shellEscape(executablePath)] + escapedArgs).joined(separator: " ")

        let stderrPath = NSTemporaryDirectory() + "hotswift_stderr_\(ProcessInfo.processInfo.processIdentifier)_\(Int.random(in: 0...999999)).txt"
        let fullCommand = "\(command) 2>\(shellEscape(stderrPath))"

        var outputData = Data()

        guard let pipe = popen(fullCommand, "r") else {
            return ShellDataResult(exitCode: -1, stdoutData: Data(), stderr: "popen failed")
        }

        let bufferSize = 65536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while true {
            let bytesRead = fread(buffer, 1, bufferSize, pipe)
            if bytesRead > 0 {
                outputData.append(buffer, count: bytesRead)
            }
            if bytesRead < bufferSize { break }
        }

        let rawStatus = pclose(pipe)
        let exitCode: Int32
        #if canImport(Darwin)
        exitCode = (rawStatus >> 8) & 0xFF
        #else
        exitCode = rawStatus
        #endif

        let stderrOutput = (try? String(contentsOfFile: stderrPath, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: stderrPath)

        return ShellDataResult(
            exitCode: exitCode,
            stdoutData: outputData,
            stderr: stderrOutput
        )
    }
    #endif
}
#endif // os(macOS)
#endif // DEBUG
