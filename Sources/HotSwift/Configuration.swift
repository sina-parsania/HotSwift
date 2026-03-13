//
//  Configuration.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

// Public configuration for the HotSwift hot-reload engine

import Foundation

#if DEBUG

/// Configuration for the HotSwift hot-reload engine.
///
/// Customize watch paths, exclude patterns, debounce timing, and verbosity.
/// In most cases the defaults work well — HotSwift auto-detects project paths
/// from the `#file` macro at the call site.
///
/// ```swift
/// // Default configuration (auto-detects everything):
/// HotSwift.start()
///
/// // Custom configuration:
/// var config = HotSwiftConfiguration()
/// config.verbose = true
/// config.debounceInterval = 0.5
/// HotSwift.start(config: config)
/// ```
public struct HotSwiftConfiguration {

    // MARK: - Properties

    /// Directories to watch for Swift file changes.
    ///
    /// If empty (the default), HotSwift walks up from the calling file's `#file` path
    /// to find the project root (the directory containing `.xcodeproj` or `.xcworkspace`).
    public var watchPaths: [String]

    /// Path component patterns to exclude from file watching.
    ///
    /// Supports two matching strategies:
    /// - **Plain strings** match any path component exactly (e.g. `"DerivedData"`).
    /// - **Glob prefixes** starting with `*` match the filename suffix (e.g. `"*.generated.swift"`).
    public var excludePatterns: [String]

    /// Debounce interval in seconds.
    ///
    /// After detecting a file change, HotSwift waits this long for additional changes
    /// before triggering a reload. This coalesces rapid successive saves into a single
    /// compile-and-reload cycle. Default: 0.3 seconds.
    public var debounceInterval: TimeInterval

    /// Whether to log verbose output to the console.
    ///
    /// When `true`, every pipeline step (file change detection, compilation, loading)
    /// is logged. Useful during initial setup; noisy for day-to-day use.
    public var verbose: Bool

    /// Path to the project's `project.pbxproj` file.
    ///
    /// Used by the auto-add feature to register new files with Xcode's project navigator.
    /// If `nil`, HotSwift attempts to auto-detect it from the watch paths.
    public var pbxprojPath: String?

    /// The project name used for DerivedData lookup.
    ///
    /// HotSwift locates build artifacts in `~/Library/Developer/Xcode/DerivedData/<projectName>-<hash>/`.
    /// If `nil`, auto-detected from the `.xcodeproj` directory name.
    public var projectName: String?

    // MARK: - Initialization

    /// Creates a new configuration with the specified settings.
    ///
    /// All parameters have sensible defaults. In most projects, `HotSwiftConfiguration()` is sufficient.
    ///
    /// - Parameters:
    ///   - watchPaths: Directories to watch. Empty = auto-detect from `#file`.
    ///   - excludePatterns: Path patterns to exclude from watching.
    ///   - debounceInterval: Seconds to wait after a change before reloading. Default: 0.3.
    ///   - verbose: Log every pipeline step. Default: `false`.
    ///   - pbxprojPath: Explicit path to `project.pbxproj`. Default: auto-detect.
    ///   - projectName: Explicit project name for DerivedData. Default: auto-detect.
    public init(
        watchPaths: [String] = [],
        excludePatterns: [String] = [
            "DerivedData",
            "Pods",
            ".build",
            "Carthage",
            ".git",
            "xcuserdata"
        ],
        debounceInterval: TimeInterval = 0.3,
        verbose: Bool = false,
        pbxprojPath: String? = nil,
        projectName: String? = nil
    ) {
        self.watchPaths = watchPaths
        self.excludePatterns = excludePatterns
        self.debounceInterval = debounceInterval
        self.verbose = verbose
        self.pbxprojPath = pbxprojPath
        self.projectName = projectName
    }

    // MARK: - Defaults

    /// A configuration with all default settings.
    ///
    /// Equivalent to `HotSwiftConfiguration()`. Provided for clarity at call sites:
    /// ```swift
    /// HotSwift.start(config: .default)
    /// ```
    public static let `default` = HotSwiftConfiguration()
}

#else

// MARK: - Release Stub

/// Release stub — all properties are inert. HotSwift is a no-op in non-DEBUG builds.
public struct HotSwiftConfiguration {
    public var watchPaths: [String] = []
    public var excludePatterns: [String] = []
    public var debounceInterval: TimeInterval = 0
    public var verbose: Bool = false
    public var pbxprojPath: String? = nil
    public var projectName: String? = nil

    public init(
        watchPaths: [String] = [],
        excludePatterns: [String] = [],
        debounceInterval: TimeInterval = 0,
        verbose: Bool = false,
        pbxprojPath: String? = nil,
        projectName: String? = nil
    ) {
        self.watchPaths = watchPaths
        self.excludePatterns = excludePatterns
        self.debounceInterval = debounceInterval
        self.verbose = verbose
        self.pbxprojPath = pbxprojPath
        self.projectName = projectName
    }

    public static let `default` = HotSwiftConfiguration()
}

#endif
