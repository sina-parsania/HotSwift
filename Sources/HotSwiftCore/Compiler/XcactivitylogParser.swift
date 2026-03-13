//
//  XcactivitylogParser.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

// Parses Xcode xcactivitylog files to extract Swift compile commands

#if DEBUG
import Foundation

// MARK: - Errors

enum XcactivitylogParserError: LocalizedError {
    case fileNotFound(String)
    case decompressionFailed(String)
    case invalidLogContent
    case noCompileCommandsFound

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "xcactivitylog not found at: \(path)"
        case .decompressionFailed(let reason):
            return "Failed to decompress xcactivitylog: \(reason)"
        case .invalidLogContent:
            return "xcactivitylog content could not be decoded as UTF-8 text"
        case .noCompileCommandsFound:
            return "No Swift compile commands found in xcactivitylog"
        }
    }
}

// MARK: - Parser

/// Parses Xcode's `.xcactivitylog` files to extract per-file Swift compile commands.
///
/// xcactivitylog files are gzip-compressed. After decompression the content is in SLF0 format,
/// which is largely text containing the full compile commands Xcode invoked during the build.
/// This parser scans for lines invoking `swift-frontend` or `swiftc` and maps each source file
/// to its corresponding compiler arguments.
struct XcactivitylogParser {

    // MARK: - Public API

    /// Parse the xcactivitylog file and extract compile commands.
    ///
    /// - Parameter logPath: Absolute path to the `.xcactivitylog` file.
    /// - Returns: A dictionary mapping source file paths to their compile command arguments.
    /// - Throws: `XcactivitylogParserError` if the file cannot be read, decompressed, or parsed.
    func parse(logPath: String) throws -> [String: [String]] {
        let decompressedData = try decompressLog(at: logPath)

        guard !decompressedData.isEmpty else {
            throw XcactivitylogParserError.invalidLogContent
        }

        let compileCommands = extractCompileCommands(from: decompressedData)
        return mapSourceFilesToArguments(commands: compileCommands)
    }

    // MARK: - Decompression

    /// Decompresses the gzip-compressed xcactivitylog file.
    ///
    /// Uses the `gunzip` command via `Process` since Foundation's `NSData` decompression
    /// is not available on all deployment targets and xcactivitylog files can be large.
    private func decompressLog(at path: String) throws -> Data {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            throw XcactivitylogParserError.fileNotFound(path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["--stdout", path]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw XcactivitylogParserError.decompressionFailed(error.localizedDescription)
        }

        // Kill the process if it exceeds the timeout — prevents indefinite hangs
        // on corrupted logs. Must fire BEFORE waitUntilExit to unblock it.
        let timeoutSeconds: Double = 60
        let timeoutWorkItem = DispatchWorkItem { [weak process] in
            guard let process = process, process.isRunning else { return }
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWorkItem)

        // Read both pipes on background threads to avoid pipe deadlock
        // when output is larger than the pipe buffer (~64 KB).
        var outputData = Data()
        var stderrData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        process.waitUntilExit()
        timeoutWorkItem.cancel()
        group.wait()

        guard process.terminationStatus == 0 else {
            let stderrString = String(data: stderrData, encoding: .utf8) ?? "unknown error"
            throw XcactivitylogParserError.decompressionFailed(stderrString)
        }

        return outputData
    }

    // MARK: - Command Extraction

    /// Scans the decompressed log data for Swift compilation command lines.
    ///
    /// SLF0 content contains various build log entries separated by newlines and null bytes.
    /// We split on both delimiters and look for lines containing `swift-frontend` or `/swiftc`.
    ///
    /// This processes the raw `Data` directly to avoid creating a massive intermediate
    /// `String` copy (xcactivitylogs can decompress to 100+ MB).
    private func extractCompileCommands(from data: Data) -> [String] {
        var commands: [String] = []
        var lineStart = data.startIndex

        for i in data.indices {
            let byte = data[i]
            // Split on newline (0x0A) or null byte (0x00)
            guard byte == 0x0A || byte == 0x00 else { continue }

            if i > lineStart,
               let line = String(data: data[lineStart..<i], encoding: .utf8)?
                   .trimmingCharacters(in: .whitespaces),
               !line.isEmpty,
               (line.contains("/swift-frontend ") || line.contains("/swiftc ")),
               // Validate it looks like an actual invocation (starts with a path)
               line.hasPrefix("/") || line.contains(" /usr/") || line.contains(" /Applications/") {
                commands.append(line)
            }
            lineStart = data.index(after: i)
        }

        // Handle trailing content without a final delimiter
        if lineStart < data.endIndex,
           let line = String(data: data[lineStart..<data.endIndex], encoding: .utf8)?
               .trimmingCharacters(in: .whitespaces),
           !line.isEmpty,
           (line.contains("/swift-frontend ") || line.contains("/swiftc ")),
           line.hasPrefix("/") || line.contains(" /usr/") || line.contains(" /Applications/") {
            commands.append(line)
        }

        return commands
    }

    // MARK: - Argument Mapping

    /// Maps each source file to its compile arguments from the extracted commands.
    ///
    /// A single `swift-frontend` invocation may compile multiple files (whole-module mode)
    /// or a single file. This method identifies source `.swift` files in each command and
    /// maps them to the full argument list.
    private func mapSourceFilesToArguments(commands: [String]) -> [String: [String]] {
        var result: [String: [String]] = [:]

        for command in commands {
            let tokens = tokenize(command: command)
            guard tokens.count > 1 else { continue }

            // Skip the executable path itself (first token)
            let arguments = Array(tokens.dropFirst())

            // Find all .swift source files referenced in the arguments.
            // Source files are arguments that end with .swift and are not preceded by
            // flags like -output-file-map, -supplementary-output-file-map, etc.
            let sourceFiles = extractSourceFiles(from: arguments)

            for sourceFile in sourceFiles {
                result[sourceFile] = arguments
            }
        }

        return result
    }

    /// Extracts source `.swift` file paths from a tokenized argument list.
    ///
    /// Skips `.swift` paths that appear as values for output-related flags.
    private func extractSourceFiles(from arguments: [String]) -> [String] {
        var sourceFiles: [String] = []
        let outputFlags: Set<String> = [
            "-o", "-output-file-map", "-supplementary-output-file-map",
            "-emit-module-path", "-emit-objc-header-path",
            "-serialize-diagnostics-path", "-index-store-path",
            "-emit-dependencies-path", "-pch-output-dir",
            "-emit-module-doc-path", "-emit-module-source-info-path"
        ]

        var skipNext = false

        for arg in arguments {
            if skipNext {
                skipNext = false
                continue
            }

            // If this argument is a flag that takes a path value, skip its next argument
            if outputFlags.contains(arg) {
                skipNext = true
                continue
            }

            // If the argument starts with a dash, it's a flag (not a source file)
            if arg.hasPrefix("-") {
                continue
            }

            // Check if this looks like a Swift source file
            if arg.hasSuffix(".swift") && !arg.contains("/.build/") {
                // Resolve to absolute path if needed
                let resolvedPath: String
                if arg.hasPrefix("/") {
                    resolvedPath = arg
                } else {
                    resolvedPath = (FileManager.default.currentDirectoryPath as NSString)
                        .appendingPathComponent(arg)
                }

                // Verify the file actually exists to avoid matching output file patterns
                if FileManager.default.fileExists(atPath: resolvedPath) {
                    sourceFiles.append(resolvedPath)
                }
            }
        }

        return sourceFiles
    }

    // MARK: - Tokenization

    /// Tokenizes a shell command string, respecting quoted paths that may contain spaces.
    ///
    /// Handles:
    /// - Single-quoted strings: `'/path/with spaces/file.swift'`
    /// - Double-quoted strings: `"/path/with spaces/file.swift"`
    /// - Backslash-escaped spaces: `/path/with\ spaces/file.swift`
    /// - Regular space-separated tokens
    func tokenize(command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var escapeNext = false

        for character in command {
            if escapeNext {
                current.append(character)
                escapeNext = false
                continue
            }

            if character == "\\" && !inSingleQuote {
                escapeNext = true
                continue
            }

            if character == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                continue
            }

            if character == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                continue
            }

            if character == " " && !inSingleQuote && !inDoubleQuote {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(character)
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }
}
#endif
