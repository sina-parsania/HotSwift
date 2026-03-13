//
//  ChangeType.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

// Classifies the type of source change detected during file watching

#if DEBUG

// MARK: - Change Type

/// Classifies the type of source change detected.
///
/// The pipeline uses this classification to decide whether a change can be
/// hot-reloaded in-process (the fast `dlopen` path) or requires a full
/// Xcode rebuild (and possibly a pbxproj update).
enum ChangeType {
    /// Only method bodies changed — safe for hot-reload (dlopen path).
    case bodyOnly
    /// Structural changes (new property, new type, changed signature) — needs full rebuild.
    case structural
    /// A new file was created — needs pbxproj update + rebuild.
    case newFile
    /// A file was deleted — needs pbxproj cleanup + rebuild.
    case deleted
}

#endif
