//
//  DiagnosticEngine.swift
//  HotSwiftDiagnostics
//
//  Parses raw swiftc compiler output into structured diagnostics
//  with optional friendly hints for common errors.
//

#if DEBUG
import Foundation

// MARK: - CompilerDiagnostic

/// A single diagnostic emitted by the Swift compiler.
///
/// Parsed from the standard `swiftc` stderr format:
/// ```
/// /path/to/File.swift:42:10: error: some message here
/// ```
public struct CompilerDiagnostic: Sendable, Equatable {

    /// The severity of the diagnostic.
    public enum Severity: String, Sendable, Equatable {
        case error
        case warning
        case note
    }

    /// Severity level (error, warning, or note).
    public let severity: Severity

    /// Absolute path to the source file that triggered the diagnostic.
    public let filePath: String

    /// 1-based line number in the source file.
    public let line: Int

    /// 1-based column number in the source file.
    public let column: Int

    /// The compiler's diagnostic message.
    public let message: String

    /// An optional user-friendly explanation for common error patterns.
    /// `nil` when no matching hint is available.
    public let friendlyHint: String?
}

// MARK: - DiagnosticEngine

/// Parses raw `swiftc` stderr output into an array of ``CompilerDiagnostic`` values.
///
/// Usage:
/// ```swift
/// let engine = DiagnosticEngine()
/// let diagnostics = engine.parse(compilerOutput: stderrString)
/// for diag in diagnostics {
///     print("\(diag.severity): \(diag.message)")
///     if let hint = diag.friendlyHint {
///         print("  Hint: \(hint)")
///     }
/// }
/// ```
public final class DiagnosticEngine {

    // MARK: - Types

    /// A pattern-to-hint mapping for common compiler errors.
    private struct HintRule {
        let pattern: NSRegularExpression
        let hint: String
    }

    // MARK: - Properties

    /// Regex matching a single swiftc diagnostic line.
    /// Format: `/path/to/file.swift:42:10: error: message text`
    private static let diagnosticPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"^(.+?):(\d+):(\d+):\s+(error|warning|note):\s+(.+)$"#,
            options: .anchorsMatchLines
        )
    }()

    /// Ordered list of hint rules, checked top-to-bottom on each diagnostic message.
    private let hintRules: [HintRule] = {
        let mappings: [(String, String)] = [
            (
                #"use of undeclared type"#,
                "New types require a full rebuild. HotSwift will trigger auto-rebuild."
            ),
            (
                #"cannot find '.+' in scope"#,
                "Check if the symbol exists. New declarations need a rebuild."
            ),
            (
                #"value of type '.+' has no member"#,
                "If you added a new property, this requires a rebuild."
            ),
            (
                #"cannot convert value of type"#,
                "Check type compatibility. If you changed a type signature, a rebuild may be needed."
            ),
            (
                #"stored property.+cannot be hot-reloaded"#,
                "Stored property changes cannot be hot-reloaded. This change requires a full rebuild."
            ),
            (
                #"missing return in"#,
                "Ensure all code paths return a value of the expected type."
            ),
            (
                #"protocol requires function"#,
                "A required protocol method is missing. Add the conformance or stub."
            ),
            (
                #"ambiguous use of"#,
                "Multiple candidates match. Add explicit type annotations to disambiguate."
            ),
        ]

        return mappings.compactMap { (pattern, hint) in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                return nil
            }
            return HintRule(pattern: regex, hint: hint)
        }
    }()

    // MARK: - Initialization

    public init() {}

    // MARK: - Public API

    /// Parse raw `swiftc` stderr output into structured diagnostics.
    ///
    /// - Parameter compilerOutput: The full stderr string from a `swiftc` invocation.
    /// - Returns: An array of parsed diagnostics in the order they appeared.
    public func parse(compilerOutput: String) -> [CompilerDiagnostic] {
        let fullRange = NSRange(compilerOutput.startIndex..., in: compilerOutput)
        let matches = Self.diagnosticPattern.matches(in: compilerOutput, options: [], range: fullRange)

        return matches.compactMap { match -> CompilerDiagnostic? in
            guard match.numberOfRanges == 6 else { return nil }

            guard
                let fileRange = Range(match.range(at: 1), in: compilerOutput),
                let lineRange = Range(match.range(at: 2), in: compilerOutput),
                let colRange = Range(match.range(at: 3), in: compilerOutput),
                let sevRange = Range(match.range(at: 4), in: compilerOutput),
                let msgRange = Range(match.range(at: 5), in: compilerOutput)
            else {
                return nil
            }

            let filePath = String(compilerOutput[fileRange])
            let message = String(compilerOutput[msgRange])

            guard
                let line = Int(compilerOutput[lineRange]),
                let column = Int(compilerOutput[colRange]),
                let severity = CompilerDiagnostic.Severity(rawValue: String(compilerOutput[sevRange]))
            else {
                return nil
            }

            let hint = friendlyHint(for: message)

            return CompilerDiagnostic(
                severity: severity,
                filePath: filePath,
                line: line,
                column: column,
                message: message,
                friendlyHint: hint
            )
        }
    }

    // MARK: - Private Helpers

    /// Check the message against known error patterns and return a friendly hint if matched.
    private func friendlyHint(for message: String) -> String? {
        let range = NSRange(message.startIndex..., in: message)
        for rule in hintRules {
            if rule.pattern.firstMatch(in: message, options: [], range: range) != nil {
                return rule.hint
            }
        }
        return nil
    }
}

#else

// MARK: - Release Stubs

/// Minimal stub so downstream code compiles without `#if DEBUG` guards everywhere.
public struct CompilerDiagnostic: Sendable, Equatable {
    public enum Severity: String, Sendable { case error, warning, note }
    public let severity: Severity
    public let filePath: String
    public let line: Int
    public let column: Int
    public let message: String
    public let friendlyHint: String?
}

/// No-op engine in release builds.
public final class DiagnosticEngine {
    public init() {}
    public func parse(compilerOutput: String) -> [CompilerDiagnostic] { [] }
}

#endif
