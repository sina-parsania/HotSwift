//
//  PollingFileWatcher.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

// Timer-based file watcher for platforms without FSEvents (iOS simulator)

#if DEBUG
import Foundation

/// A file watcher that periodically scans directories for changes.
///
/// Used as a fallback on platforms where FSEvents is not available (iOS simulator).
/// Polls the file system at a configurable interval and reports created, modified,
/// and deleted files by comparing modification dates between scans.
final class PollingFileWatcher: FileWatching {

    // MARK: - Configuration

    private let allowedExtensions: Set<String>
    private let excludePatterns: [String]
    private let pollInterval: TimeInterval

    // MARK: - State

    private var timer: DispatchSourceTimer?
    private let watchQueue = DispatchQueue(label: "com.hotswift.polling-watcher", qos: .utility)
    private var knownFiles: [String: Date] = [:]
    private var onChange: (([FileEvent]) -> Void)?
    private var _isWatching = false
    private var watchedPaths: [String] = []

    var isWatching: Bool {
        watchQueue.sync { _isWatching }
    }

    // MARK: - Initialization

    /// Creates a new polling file watcher.
    ///
    /// - Parameters:
    ///   - pollInterval: Time between scans in seconds. Defaults to 1.0s.
    ///   - allowedExtensions: File extensions to watch. Defaults to Swift files only.
    ///   - excludePatterns: Path components or glob patterns to ignore.
    init(
        pollInterval: TimeInterval = 1.0,
        allowedExtensions: Set<String> = ["swift"],
        excludePatterns: [String] = [
            "DerivedData", "Pods", ".build", "Carthage",
            "*.generated.swift", ".git", "xcuserdata"
        ]
    ) {
        self.pollInterval = pollInterval
        self.allowedExtensions = allowedExtensions
        self.excludePatterns = excludePatterns
    }

    deinit {
        timer?.cancel()
        timer = nil
    }

    // MARK: - FileWatching

    func start(paths: [String], onChange: @escaping ([FileEvent]) -> Void) {
        stop()

        watchQueue.sync {
            self.onChange = onChange
            self.watchedPaths = paths
            self.knownFiles = self.scanFiles(in: paths)
            self._isWatching = true

            let timer = DispatchSource.makeTimerSource(queue: watchQueue)
            timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
            timer.setEventHandler { [weak self] in
                self?.poll()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        watchQueue.sync {
            timer?.cancel()
            timer = nil
            _isWatching = false
            onChange = nil
            knownFiles.removeAll()
            watchedPaths.removeAll()
        }
    }

    // MARK: - Polling

    private func poll() {
        let currentFiles = scanFiles(in: watchedPaths)
        var events: [FileEvent] = []

        // Detect modified or deleted files
        for (path, oldDate) in knownFiles {
            if let newDate = currentFiles[path] {
                if newDate > oldDate {
                    events.append(FileEvent(path: path, type: .modified, timestamp: Date()))
                }
            } else {
                events.append(FileEvent(path: path, type: .deleted, timestamp: Date()))
            }
        }

        // Detect new files
        for path in currentFiles.keys where knownFiles[path] == nil {
            events.append(FileEvent(path: path, type: .created, timestamp: Date()))
        }

        knownFiles = currentFiles

        if !events.isEmpty {
            onChange?(events)
        }
    }

    // MARK: - Directory Scanning

    private func scanFiles(in paths: [String]) -> [String: Date] {
        var result: [String: Date] = [:]
        let fm = FileManager.default

        for basePath in paths {
            guard let enumerator = fm.enumerator(atPath: basePath) else { continue }

            while let relativePath = enumerator.nextObject() as? String {
                let fullPath = (basePath as NSString).appendingPathComponent(relativePath)

                // Skip excluded directories early
                let lastComponent = (relativePath as NSString).lastPathComponent
                if isExcludedDirectory(lastComponent) {
                    enumerator.skipDescendants()
                    continue
                }

                let url = URL(fileURLWithPath: fullPath)

                // Only process files with allowed extensions
                guard allowedExtensions.contains(url.pathExtension) else { continue }

                // Skip editor temp files
                if lastComponent.hasPrefix(".") || lastComponent.hasSuffix("~")
                    || lastComponent.hasSuffix(".swp") || lastComponent.hasSuffix(".tmp") {
                    continue
                }

                // Check full path exclude patterns
                guard !isExcluded(path: fullPath) else { continue }

                // Record modification date
                if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                   let modDate = attrs[.modificationDate] as? Date {
                    result[fullPath] = modDate
                }
            }
        }

        return result
    }

    // MARK: - Exclude Pattern Matching

    private func isExcludedDirectory(_ name: String) -> Bool {
        for pattern in excludePatterns {
            if !pattern.hasPrefix("*") && name == pattern {
                return true
            }
        }
        return false
    }

    private func isExcluded(path: String) -> Bool {
        let components = path.components(separatedBy: "/")
        let fileName = components.last ?? ""

        for pattern in excludePatterns {
            if pattern.hasPrefix("*") {
                let suffix = String(pattern.dropFirst())
                if fileName.hasSuffix(suffix) { return true }
            } else {
                if components.contains(pattern) { return true }
            }
        }
        return false
    }
}
#endif
