//
//  SwiftCompiler.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

// Invokes swiftc to compile a single Swift file into a dynamically loadable library

#if DEBUG
import Foundation

// MARK: - Errors

enum SwiftCompilerError: LocalizedError {
    case swiftcNotFound
    case outputDirectoryCreationFailed(String)
    case processLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .swiftcNotFound:
            return "swiftc not found. Ensure Xcode command line tools are installed."
        case .outputDirectoryCreationFailed(let reason):
            return "Failed to create output directory: \(reason)"
        case .processLaunchFailed(let reason):
            return "Failed to launch swiftc process: \(reason)"
        }
    }
}

// MARK: - CompilationResult

/// The result of a single-file compilation attempt.
struct CompilationResult {
    /// Whether the compilation succeeded (swiftc exit code 0).
    let success: Bool
    /// Absolute path to the produced dylib, or `nil` if compilation failed.
    let dylibPath: String?
    /// Standard output from swiftc.
    let stdout: String
    /// Standard error from swiftc (contains diagnostics, warnings, errors).
    let stderr: String
    /// Wall-clock time the compilation took.
    let compilationTime: TimeInterval
}

// MARK: - SwiftCompiler

/// Compiles a single Swift source file into a versioned dynamic library (`.dylib`)
/// using the build settings extracted from the project's xcactivitylog.
///
/// Each compilation produces a uniquely named dylib (`reload_1.dylib`, `reload_2.dylib`, ...)
/// so that `dlopen` always loads fresh code rather than returning a cached handle.
final class SwiftCompiler {

    // MARK: - Properties

    /// Monotonically increasing counter for versioned dylib output names.
    private var reloadCounter: Int = 0

    /// Directory where compiled dylibs are written.
    private let outputDirectory: String

    // MARK: - Initialization

    /// Creates a new compiler instance.
    ///
    /// - Parameter outputDirectory: Directory for dylib output. Defaults to `/tmp/hotswift`.
    init(outputDirectory: String = "/tmp/hotswift") {
        self.outputDirectory = outputDirectory
    }

    // MARK: - Public API

    /// Compile a single Swift file into a dynamic library.
    ///
    /// - Parameters:
    ///   - filePath: Absolute path to the Swift source file.
    ///   - settings: Build settings extracted from the project's compile command.
    /// - Returns: A `CompilationResult` with the outcome, output path, and diagnostics.
    func compile(filePath: String, settings: BuildSettings) -> CompilationResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Ensure output directory exists
        do {
            try ensureOutputDirectory()
        } catch {
            return CompilationResult(
                success: false,
                dylibPath: nil,
                stdout: "",
                stderr: error.localizedDescription,
                compilationTime: CFAbsoluteTimeGetCurrent() - startTime
            )
        }

        // Generate versioned output path
        reloadCounter += 1
        let dylibName = "reload_\(reloadCounter).dylib"
        let outputPath = (outputDirectory as NSString).appendingPathComponent(dylibName)

        // Build the swiftc argument list
        let arguments = buildArguments(
            filePath: filePath,
            outputPath: outputPath,
            settings: settings
        )

        // Locate swiftc
        let swiftcPath: String
        do {
            swiftcPath = try findSwiftc()
        } catch {
            return CompilationResult(
                success: false,
                dylibPath: nil,
                stdout: "",
                stderr: error.localizedDescription,
                compilationTime: CFAbsoluteTimeGetCurrent() - startTime
            )
        }

        // Run the compiler
        let result = runProcess(executablePath: swiftcPath, arguments: arguments)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        let success = result.exitCode == 0
        return CompilationResult(
            success: success,
            dylibPath: success ? outputPath : nil,
            stdout: result.stdout,
            stderr: result.stderr,
            compilationTime: elapsed
        )
    }

    // MARK: - Argument Construction

    /// Builds the full swiftc argument list for compiling a single file into a dylib.
    private func buildArguments(
        filePath: String,
        outputPath: String,
        settings: BuildSettings
    ) -> [String] {
        var args: [String] = []

        // Source file
        args.append(filePath)

        // Module name
        if !settings.moduleName.isEmpty {
            args.append(contentsOf: ["-module-name", settings.moduleName])
        }

        // Emit a dynamic library
        args.append("-emit-library")

        // Parse as library (no @main entry point expected)
        args.append("-parse-as-library")

        // Target triple
        if !settings.targetTriple.isEmpty {
            args.append(contentsOf: ["-target", settings.targetTriple])
        }

        // SDK
        if !settings.sdkPath.isEmpty {
            args.append(contentsOf: ["-sdk", settings.sdkPath])
        }

        // Framework search paths
        for path in settings.frameworkSearchPaths {
            args.append(contentsOf: ["-F", path])
        }

        // Import/header search paths
        for path in settings.importPaths {
            args.append(contentsOf: ["-I", path])
        }

        // Library search paths
        for path in settings.libraryPaths {
            args.append(contentsOf: ["-L", path])
        }

        // Other Swift flags (e.g. -swift-version, -enable-*, -disable-*)
        args.append(contentsOf: settings.otherSwiftFlags)

        // Linker flags
        args.append(contentsOf: settings.otherLinkerFlags)

        // Allow undefined symbols — resolved at dlopen time from the host process
        args.append(contentsOf: ["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"])

        // Output path
        args.append(contentsOf: ["-o", outputPath])

        return args
    }

    // MARK: - Process Execution

    /// Result from running a subprocess.
    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs a subprocess synchronously, capturing stdout and stderr.
    private func runProcess(executablePath: String, arguments: [String]) -> ProcessResult {
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
            return ProcessResult(
                exitCode: -1,
                stdout: "",
                stderr: "Failed to launch process: \(error.localizedDescription)"
            )
        }

        // Timeout after 30 seconds to prevent hanging
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak process] in
            guard let process = process, process.isRunning else { return }
            process.terminate()
        }

        // Read output on background threads to avoid pipe buffer deadlocks on large output
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

        let stdoutString = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrString = String(data: stderrData, encoding: .utf8) ?? ""

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdoutString,
            stderr: stderrString
        )
    }

    // MARK: - Helpers

    /// Creates the output directory if it does not already exist.
    private func ensureOutputDirectory() throws {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false

        if fileManager.fileExists(atPath: outputDirectory, isDirectory: &isDir) {
            if isDir.boolValue {
                return
            }
            // Exists but is a file — remove and recreate
            try fileManager.removeItem(atPath: outputDirectory)
        }

        do {
            try fileManager.createDirectory(
                atPath: outputDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw SwiftCompilerError.outputDirectoryCreationFailed(error.localizedDescription)
        }
    }

    /// Locates the swiftc binary, preferring the Xcode toolchain.
    private func findSwiftc() throws -> String {
        let fileManager = FileManager.default

        // Try xcrun first to get the active toolchain's swiftc
        let xcrunResult = runProcess(
            executablePath: "/usr/bin/xcrun",
            arguments: ["--find", "swiftc"]
        )

        if xcrunResult.exitCode == 0 {
            let path = xcrunResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty && fileManager.fileExists(atPath: path) {
                return path
            }
        }

        // Fallback to well-known paths
        let fallbackPaths = [
            "/usr/bin/swiftc",
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
        ]

        for path in fallbackPaths {
            if fileManager.fileExists(atPath: path) {
                return path
            }
        }

        throw SwiftCompilerError.swiftcNotFound
    }
}
#endif
