//
//  HotSwiftEvent.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

// Public event type exposed to consumers for reload notifications

import Foundation

#if DEBUG

/// A public event describing the result of a hot-reload attempt.
///
/// Subscribe via `HotSwift.reloadEvents` (Combine) or observe
/// `HotSwift.didReloadNotification` (NotificationCenter) to receive these events.
///
/// ```swift
/// #if DEBUG
/// HotSwift.reloadEvents
///     .filter { $0.status == .success }
///     .sink { event in
///         print("Reloaded \(event.filePath) in \(event.duration)s")
///     }
///     .store(in: &cancellables)
/// #endif
/// ```
public struct HotSwiftReloadEvent: Sendable {

    /// The outcome of a reload attempt.
    public enum Status: Sendable {
        /// The file was successfully recompiled and loaded into the process.
        case success
        /// The reload failed at some stage (compilation, loading, or interposition).
        case failed
    }

    /// Whether the reload succeeded or failed.
    public let status: Status

    /// The absolute path of the source file that triggered the reload.
    public let filePath: String

    /// Class, struct, or enum names detected in the changed file (best-effort).
    ///
    /// This list is populated via simple pattern matching and may not be exhaustive.
    /// An empty array means no type names could be extracted.
    public let affectedClasses: [String]

    /// Wall-clock duration of the reload pipeline cycle in seconds.
    public let duration: TimeInterval

    /// A human-readable summary of the reload result.
    ///
    /// On success, contains a confirmation message. On failure, contains the
    /// compiler output or loader error for debugging.
    public let message: String

    /// When this event was created.
    public let timestamp: Date
}

#else

/// Release stub — duplicates the public event type so consumers compile without `#if DEBUG`.
public struct HotSwiftReloadEvent: Sendable {
    public enum Status: Sendable { case success, failed }
    public let status: Status
    public let filePath: String
    public let affectedClasses: [String]
    public let duration: TimeInterval
    public let message: String
    public let timestamp: Date
}

#endif
