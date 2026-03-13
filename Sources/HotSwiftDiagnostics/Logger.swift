//
//  Logger.swift
//  HotSwiftDiagnostics
//
//  A thread-safe, leveled logger for HotSwift.
//  All logging compiles to no-ops in release builds.
//

#if DEBUG
import Foundation
import os.log

// MARK: - LogLevel

/// Severity levels for log messages, ordered from most to least verbose.
public enum LogLevel: Int, Comparable, Sendable {
    case debug   = 0
    case info    = 1
    case success = 2
    case warning = 3
    case error   = 4

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Text indicator shown in log output (no emoji).
    var tag: String {
        switch self {
        case .debug:   return "[DEBUG]"
        case .info:    return "[INFO]"
        case .success: return "[OK]"
        case .warning: return "[WARN]"
        case .error:   return "[ERROR]"
        }
    }

    /// Corresponding `os_log` type for system console integration.
    var osLogType: OSLogType {
        switch self {
        case .debug:   return .debug
        case .info:    return .info
        case .success: return .info
        case .warning: return .default
        case .error:   return .error
        }
    }
}

// MARK: - HotSwiftLogger

/// Thread-safe logger that writes prefixed, timestamped messages to both
/// standard output and the unified logging system (`os_log`).
///
/// Usage:
/// ```swift
/// HotSwiftLogger.shared.minimumLevel = .debug
/// HotSwiftLogger.shared.log(.info, "Server started on port 9876")
/// ```
public final class HotSwiftLogger {

    // MARK: - Singleton

    public static let shared = HotSwiftLogger()

    // MARK: - Configuration

    /// Messages below this level are silently discarded.
    /// Defaults to `.info` so debug-level noise is hidden until needed.
    public var minimumLevel: LogLevel = .info

    // MARK: - Private Properties

    private let osLog = OSLog(subsystem: "com.hotswift", category: "HotSwift")
    private let lock = NSLock()
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: - Initialization

    private init() {}

    // MARK: - Public API

    /// Log a message at the given severity level.
    ///
    /// - Parameters:
    ///   - level: The severity of this message.
    ///   - message: The human-readable log content.
    ///   - file: The source file (auto-captured).
    ///   - line: The source line (auto-captured).
    public func log(
        _ level: LogLevel,
        _ message: String,
        file: String = #file,
        line: Int = #line
    ) {
        guard level >= minimumLevel else { return }

        let timestamp = formattedTimestamp()
        let filename = (file as NSString).lastPathComponent
        let formatted = "[HotSwift] \(timestamp) \(level.tag) \(message) (\(filename):\(line))"

        // Thread-safe write to stdout
        lock.lock()
        print(formatted)
        lock.unlock()

        // Forward to the unified logging system
        os_log("%{public}@", log: osLog, type: level.osLogType, formatted)
    }

    // MARK: - Convenience Methods

    /// Log a debug-level message.
    public func debug(_ message: String, file: String = #file, line: Int = #line) {
        log(.debug, message, file: file, line: line)
    }

    /// Log an info-level message.
    public func info(_ message: String, file: String = #file, line: Int = #line) {
        log(.info, message, file: file, line: line)
    }

    /// Log a success-level message.
    public func success(_ message: String, file: String = #file, line: Int = #line) {
        log(.success, message, file: file, line: line)
    }

    /// Log a warning-level message.
    public func warning(_ message: String, file: String = #file, line: Int = #line) {
        log(.warning, message, file: file, line: line)
    }

    /// Log an error-level message.
    public func error(_ message: String, file: String = #file, line: Int = #line) {
        log(.error, message, file: file, line: line)
    }

    // MARK: - Private Helpers

    private func formattedTimestamp() -> String {
        lock.lock()
        let result = dateFormatter.string(from: Date())
        lock.unlock()
        return result
    }
}

#else

// MARK: - Release Stubs (no-ops)

/// In release builds every log level exists but all logging is stripped.
public enum LogLevel: Int, Comparable, Sendable {
    case debug = 0, info = 1, success = 2, warning = 3, error = 4

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// No-op logger for release builds. All methods are empty so the compiler
/// can eliminate them entirely.
public final class HotSwiftLogger {
    public static let shared = HotSwiftLogger()
    public var minimumLevel: LogLevel = .error

    public func log(_ level: LogLevel, _ message: String, file: String = #file, line: Int = #line) {}
    public func debug(_ message: String, file: String = #file, line: Int = #line) {}
    public func info(_ message: String, file: String = #file, line: Int = #line) {}
    public func success(_ message: String, file: String = #file, line: Int = #line) {}
    public func warning(_ message: String, file: String = #file, line: Int = #line) {}
    public func error(_ message: String, file: String = #file, line: Int = #line) {}
}

#endif
