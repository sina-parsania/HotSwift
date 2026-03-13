//
//  FSEventsWatcher.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

// FSEvents-based file watcher for detecting Swift file changes on macOS

#if DEBUG
import Foundation
import CoreServices

/// A file watcher built on macOS FSEvents that monitors directories for Swift file changes.
///
/// Features:
/// - File-level granularity via `kFSEventStreamCreateFlagFileEvents`
/// - Runs on a dedicated serial dispatch queue (never blocks the main thread)
/// - Filters to `.swift` files only (configurable via `allowedExtensions`)
/// - Excludes common non-source directories (DerivedData, Pods, .build, etc.)
/// - Debounces rapid saves and emits batched change sets
final class FSEventsWatcher: FileWatching {

    // MARK: - Configuration

    /// File extensions to watch. Only events matching these extensions are reported.
    private let allowedExtensions: Set<String>

    /// Path components or patterns that cause a file event to be ignored.
    /// Supports simple glob suffix matching for entries that start with `*` (e.g. `*.generated.swift`).
    private let excludePatterns: [String]

    /// The debounce interval in seconds. Rapid changes within this window are batched together.
    let debounceInterval: TimeInterval

    // MARK: - State

    /// Thread-safe accessor for whether the watcher is currently observing file system events.
    /// Internal mutations use `_isWatching` directly (they already run on watchQueue).
    private var _isWatching: Bool = false
    var isWatching: Bool {
        watchQueue.sync { _isWatching }
    }

    // MARK: - Private Properties

    /// The underlying FSEvents stream reference. `nil` when not watching.
    private var eventStream: FSEventStreamRef?

    /// Dedicated serial queue for FSEvents delivery and all internal state mutations.
    private let watchQueue = DispatchQueue(label: "com.hotswift.fsevents-watcher", qos: .utility)

    /// Key used to detect whether the current execution context is already on `watchQueue`.
    private static let queueKey = DispatchSpecificKey<Bool>()

    /// The user-provided callback invoked with a batch of detected file events.
    private var onChange: (([FileEvent]) -> Void)?

    /// Accumulated events during the debounce window, keyed by path to deduplicate.
    private var pendingEvents: [String: FileEvent] = [:]

    /// The currently scheduled debounce work item. Cancelled and replaced on each new event burst.
    private var debounceWorkItem: DispatchWorkItem?

    // MARK: - Initialization

    /// Creates a new FSEvents watcher.
    /// - Parameters:
    ///   - debounceInterval: Time in seconds to wait after the last event before emitting
    ///     the accumulated batch. Defaults to 0.3 seconds.
    ///   - allowedExtensions: File extensions to watch. Defaults to Swift files only.
    ///   - excludePatterns: Path components or glob patterns to ignore.
    init(
        debounceInterval: TimeInterval = 0.3,
        allowedExtensions: Set<String> = ["swift"],
        excludePatterns: [String] = ["DerivedData", "Pods", ".build", "Carthage", "*.generated.swift", ".git", "xcuserdata"]
    ) {
        self.debounceInterval = debounceInterval
        self.allowedExtensions = allowedExtensions
        self.excludePatterns = excludePatterns
        watchQueue.setSpecific(key: Self.queueKey, value: true)
    }

    deinit {
        // Direct teardown — no sync dispatch. By the time deinit runs, no external
        // references exist, so there is no data-race risk. Using watchQueue.sync
        // here would deadlock if the last reference was released on watchQueue.
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        pendingEvents.removeAll()

        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
            // Balance the passRetained in createAndStartStream.
            Unmanaged.passUnretained(self).release()
        }

        _isWatching = false
        onChange = nil
    }

    // MARK: - FileWatching

    /// Start watching the given directory paths for Swift file changes.
    ///
    /// - Parameters:
    ///   - paths: Directory paths to recursively monitor.
    ///   - onChange: Callback invoked on the watch queue with a batch of detected changes.
    func start(paths: [String], onChange: @escaping ([FileEvent]) -> Void) {
        // Ensure we don't double-start
        stop()

        dispatchOnWatchQueue { [weak self] in
            guard let self = self else { return }
            self.onChange = onChange
            self.createAndStartStream(paths: paths)
        }
    }

    /// Stop watching and release all resources.
    func stop() {
        dispatchOnWatchQueue { [weak self] in
            guard let self = self else { return }
            self.tearDownStream()
        }
    }

    // MARK: - Queue Helpers

    /// Execute a block on `watchQueue`, avoiding deadlock if already on the queue.
    private func dispatchOnWatchQueue(_ block: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) == true {
            block()
        } else {
            watchQueue.sync(execute: block)
        }
    }

    // MARK: - Stream Lifecycle

    /// Creates the FSEvents stream and schedules it on the watch queue.
    /// Must be called on `watchQueue`.
    private func createAndStartStream(paths: [String]) {
        let cfPaths = paths as CFArray

        // Retain self to prevent use-after-free if FSEvents dispatches a callback
        // after the watcher is deallocated. Balanced by a release in tearDownStream().
        let contextInfo = Unmanaged.passRetained(self).toOpaque()

        var context = FSEventStreamContext(
            version: 0,
            info: contextInfo,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagFileEvents) |
            UInt32(kFSEventStreamCreateFlagUseCFTypes) |
            UInt32(kFSEventStreamCreateFlagNoDefer)

        // Use a small FSEvents latency; the software debounce handles user-facing coalescing.
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &context,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            flags
        ) else {
            return
        }

        eventStream = stream

        // Schedule on our dedicated serial queue — NOT the main thread.
        FSEventStreamSetDispatchQueue(stream, watchQueue)
        FSEventStreamStart(stream)
        _isWatching = true
    }

    /// Tears down and invalidates the current stream, cancels pending debounce, and clears state.
    /// Must be called on `watchQueue`.
    private func tearDownStream() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        pendingEvents.removeAll()

        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
            // Balance the passRetained in createAndStartStream.
            Unmanaged.passUnretained(self).release()
        }

        _isWatching = false
        onChange = nil
    }

    // MARK: - Event Processing

    /// Processes raw FSEvents flags for a single path, filtering and accumulating valid events.
    /// Called on the watch queue from the FSEvents callback.
    fileprivate func handleRawEvent(path: String, flags: FSEventStreamEventFlags) {
        // Only process events that target actual items (files), not directory-level meta events.
        guard flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 else { return }

        // Filter by allowed file extensions.
        let url = URL(fileURLWithPath: path)
        guard allowedExtensions.contains(url.pathExtension) else { return }

        // Filter editor temp files (atomic saves, vim swap files, etc.)
        let fileName = url.lastPathComponent
        if fileName.hasPrefix(".") || fileName.hasSuffix("~") || fileName.hasSuffix(".swp") || fileName.hasSuffix(".tmp") {
            return
        }

        // Check exclude patterns.
        guard !isExcluded(path: path) else { return }

        // Determine the event type from the flags.
        let eventType: FileEventType
        if flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
            eventType = .deleted
        } else if flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 {
            // Atomic save: editor writes temp, renames over original
            guard FileManager.default.fileExists(atPath: path) else { return }
            eventType = .modified
        } else if flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 {
            eventType = .created
        } else if flags & UInt32(kFSEventStreamEventFlagItemModified) != 0
                    || flags & UInt32(kFSEventStreamEventFlagItemInodeMetaMod) != 0 {
            eventType = .modified
        } else {
            // Flags we don't care about (e.g. ownership change only).
            return
        }

        let event = FileEvent(path: path, type: eventType, timestamp: Date())
        pendingEvents[path] = event

        scheduleDebouncedEmit()
    }

    /// Schedules (or reschedules) a debounced emit of accumulated events.
    /// Each call resets the timer so that rapid sequential saves are coalesced.
    private func scheduleDebouncedEmit() {
        debounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.emitPendingEvents()
        }
        debounceWorkItem = workItem

        watchQueue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    /// Emits all accumulated pending events as a single batch and clears the buffer.
    private func emitPendingEvents() {
        guard !pendingEvents.isEmpty else { return }

        let batch = Array(pendingEvents.values)
        pendingEvents.removeAll()
        debounceWorkItem = nil

        onChange?(batch)
    }

    // MARK: - Exclude Pattern Matching

    /// Checks whether a path should be excluded based on `excludePatterns`.
    ///
    /// Two matching strategies:
    /// - Glob suffix patterns (e.g. `*.generated.swift`) match against the file name.
    /// - Plain patterns match against any path component.
    private func isExcluded(path: String) -> Bool {
        let pathComponents = path.components(separatedBy: "/")
        let fileName = pathComponents.last ?? ""

        for pattern in excludePatterns {
            if pattern.hasPrefix("*") {
                // Glob suffix match: `*.generated.swift` matches `Foo.generated.swift`
                let suffix = String(pattern.dropFirst()) // e.g. ".generated.swift"
                if fileName.hasSuffix(suffix) {
                    return true
                }
            } else {
                // Exact path component match
                if pathComponents.contains(pattern) {
                    return true
                }
            }
        }

        return false
    }
}

// MARK: - FSEvents C Callback

/// The C-function callback invoked by FSEvents. Bridges back into the Swift instance
/// via the `Unmanaged` pointer stored in the stream context.
///
/// - Important: This function must have `@convention(c)` calling convention. We recover the
///   `FSEventsWatcher` instance from the raw `info` pointer without retaining it — the watcher
///   is kept alive by whoever owns it, and `stop()` invalidates the stream before deallocation.
private func fsEventsCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }

    let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()

    // FSEventStreamCreateFlagUseCFTypes gives us a CFArray of CFString paths.
    guard let cfPaths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }

    for index in 0..<numEvents {
        let path = cfPaths[index]
        let flags = eventFlags[index]
        watcher.handleRawEvent(path: path, flags: flags)
    }
}
#endif
