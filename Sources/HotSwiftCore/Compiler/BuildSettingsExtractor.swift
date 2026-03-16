//
//  BuildSettingsExtractor.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

// Extracts build settings from DerivedData for recompilation of individual Swift files

#if DEBUG
#if os(macOS)
import Foundation

// MARK: - Errors

enum BuildSettingsError: LocalizedError {
    case derivedDataNotFound
    case projectNotFound(String)
    case noActivityLogs(String)
    case fileNotFoundInBuildLog(String)
    case unableToExtractSettings(String)

    var errorDescription: String? {
        switch self {
        case .derivedDataNotFound:
            return "DerivedData directory not found at ~/Library/Developer/Xcode/DerivedData/"
        case .projectNotFound(let name):
            return "No matching project found in DerivedData for: \(name)"
        case .noActivityLogs(let path):
            return "No xcactivitylog files found in: \(path)"
        case .fileNotFoundInBuildLog(let file):
            return "No compile command found for file: \(file)"
        case .unableToExtractSettings(let reason):
            return "Unable to extract build settings: \(reason)"
        }
    }
}

// MARK: - BuildSettings

/// Extracted build settings required to recompile a single Swift file into a dynamic library.
struct BuildSettings {
    /// Path to the SDK (e.g. iPhoneSimulator.sdk or MacOSX.sdk)
    let sdkPath: String
    /// Target triple (e.g. arm64-apple-ios17.0-simulator)
    let targetTriple: String
    /// Framework search paths (`-F` flags)
    let frameworkSearchPaths: [String]
    /// Import/header search paths (`-I` flags)
    let importPaths: [String]
    /// Library search paths (`-L` flags)
    let libraryPaths: [String]
    /// Module name for the target being compiled
    let moduleName: String
    /// Additional Swift compiler flags
    let otherSwiftFlags: [String]
    /// Linker flags
    let otherLinkerFlags: [String]
}

// MARK: - Cache Entry

/// Holds cached build settings and the modification date of the source xcactivitylog.
private struct CacheEntry {
    let settings: [String: [String]]
    let logModificationDate: Date
    let logPath: String
}

// MARK: - BuildSettingsExtractor

/// Extracts build settings from Xcode's DerivedData by parsing xcactivitylog files.
///
/// The extractor:
/// 1. Locates the project's DerivedData folder
/// 2. Finds the most recent xcactivitylog
/// 3. Parses it with `XcactivitylogParser` to get compile commands
/// 4. Extracts `BuildSettings` from the command for the requested file
/// 5. Caches results and invalidates when the log file changes
final class BuildSettingsExtractor {

    // MARK: - Constants

    private static let derivedDataPath: String = {
        let home: String
        #if os(macOS)
        home = FileManager.default.homeDirectoryForCurrentUser.path
        #else
        // On iOS simulator, use the host macOS home directory for DerivedData access
        home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"]
            ?? ProcessInfo.processInfo.environment["HOME"]
            ?? NSHomeDirectory()
        #endif
        return (home as NSString).appendingPathComponent(
            "Library/Developer/Xcode/DerivedData"
        )
    }()

    // MARK: - Properties

    private let parser = XcactivitylogParser()
    private var cache: CacheEntry?

    // MARK: - Public API

    /// Find and extract build settings for a given Swift source file.
    ///
    /// - Parameters:
    ///   - filePath: Absolute path to the Swift source file.
    ///   - projectName: Optional project name to narrow down the DerivedData search.
    ///     If `nil`, the most recently modified project folder is used.
    /// - Returns: `BuildSettings` containing all flags needed for recompilation.
    /// - Throws: `BuildSettingsError` if the project or file cannot be found.
    func extractSettings(forFile filePath: String, projectName: String?) throws -> BuildSettings {
        let projectDir = try findProjectDerivedData(projectName: projectName)
        let logPath = try findMostRecentActivityLog(in: projectDir)

        let compileCommands = try loadCompileCommands(logPath: logPath)

        // Try exact match first, then match by filename only
        let fileName = (filePath as NSString).lastPathComponent
        let arguments: [String]

        if let exactMatch = compileCommands[filePath] {
            arguments = exactMatch
        } else if let fuzzyMatch = compileCommands.first(where: { key, _ in
            (key as NSString).lastPathComponent == fileName
        }) {
            arguments = fuzzyMatch.value
        } else {
            throw BuildSettingsError.fileNotFoundInBuildLog(filePath)
        }

        return try parseArguments(arguments)
    }

    // MARK: - DerivedData Discovery

    /// Finds the project's DerivedData directory.
    ///
    /// Xcode stores per-project build artifacts in `DerivedData/{ProjectName}-{hash}/`.
    /// If a project name is provided, we match against it. Otherwise we pick the most
    /// recently modified directory.
    private func findProjectDerivedData(projectName: String?) throws -> String {
        let fileManager = FileManager.default
        let derivedData = Self.derivedDataPath

        guard fileManager.fileExists(atPath: derivedData) else {
            throw BuildSettingsError.derivedDataNotFound
        }

        let contents: [String]
        do {
            contents = try fileManager.contentsOfDirectory(atPath: derivedData)
        } catch {
            throw BuildSettingsError.derivedDataNotFound
        }

        // Filter to directories that contain a Build/ subfolder
        let projectDirs = contents.compactMap { name -> (path: String, modified: Date)? in
            let fullPath = (derivedData as NSString).appendingPathComponent(name)
            let buildPath = (fullPath as NSString).appendingPathComponent("Build")

            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: buildPath, isDirectory: &isDir),
                  isDir.boolValue else {
                return nil
            }

            // If a project name is given, filter to matching directories
            if let projectName = projectName {
                // DerivedData dirs are "ProjectName-<28 lowercase hex chars>"
                // Use regex to strip the hash so hyphenated project names work correctly.
                let dirProjectName: String
                if let range = name.range(of: "-[a-z]{28}$", options: .regularExpression) {
                    dirProjectName = String(name[name.startIndex..<range.lowerBound])
                } else {
                    dirProjectName = name.components(separatedBy: "-").dropLast().joined(separator: "-")
                }
                guard dirProjectName.lowercased() == projectName.lowercased() else {
                    return nil
                }
            }

            let attributes = try? fileManager.attributesOfItem(atPath: fullPath)
            let modified = attributes?[.modificationDate] as? Date ?? .distantPast
            return (path: fullPath, modified: modified)
        }

        // Sort by most recently modified
        guard let best = projectDirs.sorted(by: { $0.modified > $1.modified }).first else {
            throw BuildSettingsError.projectNotFound(projectName ?? "any project")
        }

        return best.path
    }

    /// Finds the most recently modified `.xcactivitylog` in the project's `Logs/Build/` directory.
    private func findMostRecentActivityLog(in projectDir: String) throws -> String {
        let logsDir = (projectDir as NSString).appendingPathComponent("Logs/Build")
        let fileManager = FileManager.default

        let contents: [String]
        do {
            contents = try fileManager.contentsOfDirectory(atPath: logsDir)
        } catch {
            throw BuildSettingsError.noActivityLogs(logsDir)
        }

        let logFiles = contents
            .filter { $0.hasSuffix(".xcactivitylog") }
            .compactMap { name -> (path: String, modified: Date)? in
                let fullPath = (logsDir as NSString).appendingPathComponent(name)
                let attributes = try? fileManager.attributesOfItem(atPath: fullPath)
                let modified = attributes?[.modificationDate] as? Date ?? .distantPast
                return (path: fullPath, modified: modified)
            }
            .sorted { $0.modified > $1.modified }

        guard let mostRecent = logFiles.first else {
            throw BuildSettingsError.noActivityLogs(logsDir)
        }

        return mostRecent.path
    }

    // MARK: - Caching

    /// Loads compile commands from the xcactivitylog, using cache if still valid.
    ///
    /// Cache is invalidated when the log file's modification date changes, indicating
    /// a new build has occurred.
    private func loadCompileCommands(logPath: String) throws -> [String: [String]] {
        let fileManager = FileManager.default
        let attributes = try? fileManager.attributesOfItem(atPath: logPath)
        let currentModDate = attributes?[.modificationDate] as? Date ?? Date()

        // Check cache validity
        if let cached = cache,
           cached.logPath == logPath,
           cached.logModificationDate == currentModDate {
            return cached.settings
        }

        // Parse fresh
        let compileCommands = try parser.parse(logPath: logPath)

        // Update cache
        cache = CacheEntry(
            settings: compileCommands,
            logModificationDate: currentModDate,
            logPath: logPath
        )

        return compileCommands
    }

    // MARK: - Argument Parsing

    /// Parses a tokenized compile command into a structured `BuildSettings` value.
    ///
    /// Walks the argument list looking for known flags and collecting their values.
    private func parseArguments(_ arguments: [String]) throws -> BuildSettings {
        var sdkPath = ""
        var targetTriple = ""
        var frameworkSearchPaths: [String] = []
        var importPaths: [String] = []
        var libraryPaths: [String] = []
        var moduleName = ""
        var otherSwiftFlags: [String] = []
        var otherLinkerFlags: [String] = []

        // Flags to skip entirely (flag + its value are not forwarded)
        let skipFlags: Set<String> = [
            "-o", "-output-file-map", "-supplementary-output-file-map",
            "-emit-module-path", "-emit-objc-header-path",
            "-serialize-diagnostics-path", "-index-store-path",
            "-emit-dependencies-path", "-pch-output-dir",
            "-emit-module-doc-path", "-emit-module-source-info-path",
            "-num-threads", "-working-directory"
        ]

        // Flags that are standalone (no value) and should be collected as other flags
        let interestingStandaloneFlags: Set<String> = [
            "-parse-as-library", "-whole-module-optimization",
            "-enable-batch-mode", "-enforce-exclusivity=checked",
            "-enable-bare-slash-regex", "-enable-library-evolution"
        ]

        var index = 0
        while index < arguments.count {
            let arg = arguments[index]

            if skipFlags.contains(arg) {
                // Skip this flag and its value
                index += 2
                continue
            }

            // Source files are not flags — skip them
            if arg.hasSuffix(".swift") && !arg.hasPrefix("-") {
                index += 1
                continue
            }

            let hasNextValue = index + 1 < arguments.count

            switch arg {
            case "-sdk" where hasNextValue:
                sdkPath = arguments[index + 1]
                index += 2

            case "-target" where hasNextValue:
                targetTriple = arguments[index + 1]
                index += 2

            case "-F" where hasNextValue:
                frameworkSearchPaths.append(arguments[index + 1])
                index += 2

            case "-I" where hasNextValue:
                importPaths.append(arguments[index + 1])
                index += 2

            case "-L" where hasNextValue:
                libraryPaths.append(arguments[index + 1])
                index += 2

            case "-module-name" where hasNextValue:
                moduleName = arguments[index + 1]
                index += 2

            case "-Xlinker" where hasNextValue:
                otherLinkerFlags.append(contentsOf: ["-Xlinker", arguments[index + 1]])
                index += 2

            case "-import-objc-header" where hasNextValue:
                // Store bridging header path
                otherSwiftFlags.append(contentsOf: ["-import-objc-header", arguments[index + 1]])
                index += 2

            default:
                // Handle -F/path (no space between flag and value)
                if arg.hasPrefix("-F") && arg.count > 2 {
                    frameworkSearchPaths.append(String(arg.dropFirst(2)))
                    index += 1
                } else if arg.hasPrefix("-I") && arg.count > 2 {
                    importPaths.append(String(arg.dropFirst(2)))
                    index += 1
                } else if arg.hasPrefix("-L") && arg.count > 2 {
                    libraryPaths.append(String(arg.dropFirst(2)))
                    index += 1
                } else if arg.hasPrefix("-D") && arg.count > 2 {
                    otherSwiftFlags.append(arg)
                    index += 1
                    continue
                } else if arg == "-Xcc" && hasNextValue {
                    otherSwiftFlags.append(contentsOf: ["-Xcc", arguments[index + 1]])
                    index += 2
                    continue
                } else if arg == "-Xfrontend" && hasNextValue {
                    otherSwiftFlags.append(contentsOf: ["-Xfrontend", arguments[index + 1]])
                    index += 2
                    continue
                } else if arg == "-swift-version" && hasNextValue {
                    otherSwiftFlags.append(contentsOf: ["-swift-version", arguments[index + 1]])
                    index += 2
                } else if interestingStandaloneFlags.contains(arg) {
                    otherSwiftFlags.append(arg)
                    index += 1
                } else if arg.hasPrefix("-enable-") || arg.hasPrefix("-disable-") {
                    otherSwiftFlags.append(arg)
                    index += 1
                } else {
                    // Unrecognized flag — skip
                    index += 1
                }
            }
        }

        guard !sdkPath.isEmpty else {
            throw BuildSettingsError.unableToExtractSettings("missing -sdk in compile command")
        }

        guard !targetTriple.isEmpty else {
            throw BuildSettingsError.unableToExtractSettings("missing -target in compile command")
        }

        return BuildSettings(
            sdkPath: sdkPath,
            targetTriple: targetTriple,
            frameworkSearchPaths: frameworkSearchPaths,
            importPaths: importPaths,
            libraryPaths: libraryPaths,
            moduleName: moduleName,
            otherSwiftFlags: otherSwiftFlags,
            otherLinkerFlags: otherLinkerFlags
        )
    }
}
#endif // os(macOS)
#endif // DEBUG
