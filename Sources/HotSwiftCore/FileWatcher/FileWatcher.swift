//
//  FileWatcher.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

// Protocol and types for file watching

#if DEBUG
import Foundation

/// Types of file system events
enum FileEventType {
    case created
    case modified
    case deleted
}

/// A detected file change
struct FileEvent: Equatable, Hashable {
    let path: String
    let type: FileEventType
    let timestamp: Date
}

/// Protocol for file watching implementations
protocol FileWatching: AnyObject {
    /// Start watching given paths for changes
    func start(paths: [String], onChange: @escaping ([FileEvent]) -> Void)
    /// Stop watching
    func stop()
    /// Whether the watcher is currently active
    var isWatching: Bool { get }
}
#endif
