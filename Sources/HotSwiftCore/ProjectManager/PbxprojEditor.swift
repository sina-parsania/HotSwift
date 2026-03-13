//
//  PbxprojEditor.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

// Parse and edit Xcode's project.pbxproj file to add/remove Swift source files

#if DEBUG
import Foundation

// MARK: - Pbxproj Editor

/// Reads, modifies, and writes Xcode's `project.pbxproj` file to add or
/// remove Swift source files from the project.
///
/// The pbxproj file is an old-style Apple plist. Rather than using a full
/// plist parser (which does not round-trip comments), this editor operates
/// on the raw text using targeted insertions and deletions.
///
/// **Adding a file** requires three mutations:
/// 1. Insert a `PBXFileReference` entry.
/// 2. Insert a `PBXBuildFile` entry that references the file ref.
/// 3. Insert the file ref UUID into the appropriate `PBXGroup` children list
///    and the build file UUID into the `PBXSourcesBuildPhase` files list.
///
/// **Removing a file** reverses all three steps.
final class PbxprojEditor {

    // MARK: - Properties

    /// Absolute path to the `project.pbxproj` file.
    private let pbxprojPath: String

    /// The raw text content of the pbxproj file, loaded on init and
    /// mutated in memory before being written back atomically.
    private var content: String

    // MARK: - Initialization

    /// Create an editor for the given pbxproj path.
    ///
    /// - Parameter pbxprojPath: Absolute path to `project.pbxproj`.
    /// - Throws: If the file cannot be read.
    init(pbxprojPath: String) throws {
        self.pbxprojPath = pbxprojPath
        self.content = try String(contentsOfFile: pbxprojPath, encoding: .utf8)
    }

    // MARK: - Public API

    /// Add a Swift source file to the Xcode project.
    ///
    /// - Parameters:
    ///   - filePath: Absolute path to the `.swift` file.
    ///   - groupPath: The directory path (relative to the project) where the
    ///     file should appear in the Xcode group hierarchy.
    /// - Returns: A tuple of (fileRefUUID, buildFileUUID) for reference.
    ///   Returns empty strings if the file already exists in the project.
    /// - Throws: If a required pbxproj section cannot be found.
    @discardableResult
    func addFile(filePath: String, groupPath: String) throws -> (fileRef: String, buildFile: String) {
        let fileName = (filePath as NSString).lastPathComponent

        // Duplicate detection: check by path reference (not just filename) to handle
        // same-name files in different directories.
        guard !content.contains("path = \(pbxprojSafeFileName(fileName)); sourceTree") else {
            return (fileRef: "", buildFile: "")
        }

        let fileRefUUID = GUIDGenerator.generate()
        let buildFileUUID = GUIDGenerator.generate()

        try insertFileReference(uuid: fileRefUUID, fileName: fileName)
        try insertBuildFile(uuid: buildFileUUID, fileRefUUID: fileRefUUID, fileName: fileName)
        insertIntoGroup(fileRefUUID: fileRefUUID, fileName: fileName, groupPath: groupPath)
        try insertIntoSourcesBuildPhase(buildFileUUID: buildFileUUID, fileName: fileName)

        return (fileRefUUID, buildFileUUID)
    }

    /// Remove a Swift source file from the Xcode project.
    ///
    /// Searches for the file by name and removes its `PBXFileReference`,
    /// `PBXBuildFile`, group membership, and build phase entries.
    ///
    /// - Parameter fileName: The file name (e.g. `MyView.swift`).
    func removeFile(fileName: String) {
        removeFileReference(fileName: fileName)
        removeBuildFile(fileName: fileName)
        removeFromGroups(fileName: fileName)
        removeFromSourcesBuildPhase(fileName: fileName)
    }

    /// Write the modified content back to disk atomically.
    ///
    /// - Throws: If the file cannot be written.
    func save() throws {
        // Create backup before writing to protect against corrupted in-memory content.
        let backupPath = pbxprojPath + ".hotswift.bak"
        let fm = FileManager.default
        if fm.fileExists(atPath: pbxprojPath) {
            try? fm.removeItem(atPath: backupPath)
            try? fm.copyItem(atPath: pbxprojPath, toPath: backupPath)
        }

        try content.write(toFile: pbxprojPath, atomically: true, encoding: .utf8)
    }

    // MARK: - PBXFileReference

    /// Escapes and quotes a file name for safe use in pbxproj plist syntax.
    private func pbxprojSafeFileName(_ fileName: String) -> String {
        let needsQuoting = fileName.contains(" ") || fileName.contains("\"")
        guard needsQuoting else { return fileName }
        let escaped = fileName.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Insert a `PBXFileReference` entry into the `/* Begin PBXFileReference section */`.
    private func insertFileReference(uuid: String, fileName: String) throws {
        let safeFileName = pbxprojSafeFileName(fileName)
        let entry = "\t\t\(uuid) /* \(fileName) */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \(safeFileName); sourceTree = \"<group>\"; };\n"

        guard let insertionPoint = content.range(of: "/* End PBXFileReference section */") else {
            throw PbxprojEditorError.sectionNotFound("PBXFileReference")
        }

        content.insert(contentsOf: entry, at: insertionPoint.lowerBound)
    }

    /// Remove all `PBXFileReference` lines mentioning the given file name.
    private func removeFileReference(fileName: String) {
        removeLinesContaining(fileName, inSection: "PBXFileReference")
    }

    // MARK: - PBXBuildFile

    /// Insert a `PBXBuildFile` entry into the `/* Begin PBXBuildFile section */`.
    private func insertBuildFile(uuid: String, fileRefUUID: String, fileName: String) throws {
        let entry = "\t\t\(uuid) /* \(fileName) in Sources */ = {isa = PBXBuildFile; fileRef = \(fileRefUUID) /* \(fileName) */; };\n"

        guard let insertionPoint = content.range(of: "/* End PBXBuildFile section */") else {
            throw PbxprojEditorError.sectionNotFound("PBXBuildFile")
        }

        content.insert(contentsOf: entry, at: insertionPoint.lowerBound)
    }

    /// Remove all `PBXBuildFile` lines mentioning the given file name.
    private func removeBuildFile(fileName: String) {
        removeLinesContaining(fileName, inSection: "PBXBuildFile")
    }

    // MARK: - PBXGroup

    /// Insert the file reference UUID into the `PBXGroup` whose path matches `groupPath`.
    ///
    /// If no matching group is found, the file is inserted into the first
    /// `PBXGroup` that has a `children` array (project root group as fallback).
    private func insertIntoGroup(fileRefUUID: String, fileName: String, groupPath: String) {
        let childEntry = "\t\t\t\t\(fileRefUUID) /* \(fileName) */,\n"

        // Try to find the group by path (escape regex metacharacters in the path).
        // Use `};` as boundary to stay within a single pbxproj object entry.
        let escapedGroupPath = NSRegularExpression.escapedPattern(for: groupPath)
        let groupPattern = "path = \(escapedGroupPath);[^}]*?children = \\([^)]*\\)"
        if let groupRange = content.range(of: groupPattern, options: .regularExpression) {
            // Find the opening paren of the children array WITHIN the matched range.
            if let parenRange = content.range(of: "(\n", range: groupRange) {
                let insertionPoint = parenRange.upperBound
                content.insert(contentsOf: childEntry, at: insertionPoint)
                return
            }
        }

        // Fallback: find the first PBXGroup children array with the matching path name.
        let groupDirName = (groupPath as NSString).lastPathComponent
        let escapedGroupDirName = NSRegularExpression.escapedPattern(for: groupDirName)
        let fallbackPattern = "name = \(escapedGroupDirName);[^}]*?children = \\([^)]*\\)"
        if let groupRange = content.range(of: fallbackPattern, options: .regularExpression) {
            if let parenRange = content.range(of: "(\n", range: groupRange) {
                let insertionPoint = parenRange.upperBound
                content.insert(contentsOf: childEntry, at: insertionPoint)
                return
            }
        }
    }

    /// Remove file reference entries from all `PBXGroup` children arrays.
    private func removeFromGroups(fileName: String) {
        // Remove lines like: {UUID} /* FileName.swift */,
        let pattern = "\\s*[A-Fa-f0-9]{24} /\\* \(NSRegularExpression.escapedPattern(for: fileName)) \\*/,\\n"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        content = regex.stringByReplacingMatches(
            in: content,
            range: NSRange(content.startIndex..., in: content),
            withTemplate: ""
        )
    }

    // MARK: - PBXSourcesBuildPhase

    /// Insert the build file UUID into the `PBXSourcesBuildPhase` files array.
    ///
    /// For multi-target projects (app, tests, extensions), inserts into the LAST
    /// build phase found in the section, which is typically the main app target.
    private func insertIntoSourcesBuildPhase(buildFileUUID: String, fileName: String) throws {
        let fileEntry = "\t\t\t\t\(buildFileUUID) /* \(fileName) in Sources */,\n"

        // Find the PBXSourcesBuildPhase section and its files array.
        guard let sectionStart = content.range(of: "/* Begin PBXSourcesBuildPhase section */") else {
            throw PbxprojEditorError.sectionNotFound("PBXSourcesBuildPhase")
        }
        guard let sectionEnd = content.range(of: "/* End PBXSourcesBuildPhase section */") else {
            throw PbxprojEditorError.sectionNotFound("PBXSourcesBuildPhase")
        }

        // Find the LAST "files = (" within the section to target the main app target
        // (test and extension targets are typically listed first).
        var lastFilesRange: Range<String.Index>?
        var searchStart = sectionStart.lowerBound
        while let range = content.range(of: "files = (\n", range: searchStart..<sectionEnd.upperBound) {
            lastFilesRange = range
            searchStart = range.upperBound
        }

        if let filesRange = lastFilesRange {
            content.insert(contentsOf: fileEntry, at: filesRange.upperBound)
        }
    }

    /// Remove build file entries from the `PBXSourcesBuildPhase` files array.
    private func removeFromSourcesBuildPhase(fileName: String) {
        let pattern = "\\s*[A-Fa-f0-9]{24} /\\* \(NSRegularExpression.escapedPattern(for: fileName)) in Sources \\*/,\\n"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        content = regex.stringByReplacingMatches(
            in: content,
            range: NSRange(content.startIndex..., in: content),
            withTemplate: ""
        )
    }

    // MARK: - Helpers

    /// Remove all lines in a named section that contain the given file name.
    /// Uses exact comment-style matching (`/* fileName */`) to avoid false positives.
    private func removeLinesContaining(_ fileName: String, inSection sectionName: String) {
        let sectionBegin = "/* Begin \(sectionName) section */"
        let sectionEndMarker = "/* End \(sectionName) section */"

        guard let beginRange = content.range(of: sectionBegin),
              let endRange = content.range(of: sectionEndMarker) else {
            return
        }

        let sectionSubstring = String(content[beginRange.upperBound..<endRange.lowerBound])
        var filteredLines: [String] = []

        let escapedFileName = NSRegularExpression.escapedPattern(for: fileName)
        let exactPattern = "/\\* \(escapedFileName) \\*/"

        for line in sectionSubstring.components(separatedBy: "\n") {
            if line.range(of: exactPattern, options: .regularExpression) == nil {
                filteredLines.append(line)
            }
        }

        let filteredSection = filteredLines.joined(separator: "\n")
        content.replaceSubrange(beginRange.upperBound..<endRange.lowerBound, with: filteredSection)
    }
}

// MARK: - Errors

/// Errors from `PbxprojEditor` operations.
enum PbxprojEditorError: LocalizedError {
    /// The pbxproj file could not be read.
    case fileNotReadable(String)
    /// A required section was not found in the pbxproj.
    case sectionNotFound(String)

    var errorDescription: String? {
        switch self {
        case .fileNotReadable(let path):
            return "Cannot read pbxproj at: \(path)"
        case .sectionNotFound(let section):
            return "Required section not found in pbxproj: \(section)"
        }
    }
}

#endif
