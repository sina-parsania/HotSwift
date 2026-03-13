//
//  GUIDGenerator.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

// Generates Xcode-compatible 24-character hex UUIDs for pbxproj entries

#if DEBUG

// MARK: - GUID Generator

/// Generates Xcode-compatible 24-character uppercase hexadecimal identifiers.
///
/// Xcode uses this format for all object references in `project.pbxproj`.
/// Example: `A1B2C3D4E5F6A7B8C9D0E1F2`
enum GUIDGenerator {

    /// Generate a single 24-character uppercase hex string.
    ///
    /// - Returns: A random 24-character string matching the Xcode pbxproj UUID format.
    static func generate() -> String {
        (0..<24).map { _ in String(format: "%X", Int.random(in: 0...15)) }.joined()
    }
}

#endif
