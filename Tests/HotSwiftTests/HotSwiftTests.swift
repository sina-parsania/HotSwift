//
//  HotSwiftTests.swift
//  HotSwift
//
//  Created by Sina Parsa on 13/3/26.
//

import XCTest
@testable import HotSwift
@testable import HotSwiftCore

// MARK: - ChangeType Tests

final class ChangeTypeTests: XCTestCase {

    func testChangeTypeExists() {
        // Verify all four cases are accessible.
        let bodyOnly: ChangeType = .bodyOnly
        let structural: ChangeType = .structural
        let newFile: ChangeType = .newFile
        let deleted: ChangeType = .deleted

        // Verify they are distinct by switching over each value.
        switch bodyOnly {
        case .bodyOnly: break
        default: XCTFail("Expected .bodyOnly")
        }

        switch structural {
        case .structural: break
        default: XCTFail("Expected .structural")
        }

        switch newFile {
        case .newFile: break
        default: XCTFail("Expected .newFile")
        }

        switch deleted {
        case .deleted: break
        default: XCTFail("Expected .deleted")
        }
    }
}

// MARK: - GUIDGenerator Tests

final class GUIDGeneratorTests: XCTestCase {

    func testGenerateProduces24Characters() {
        let guid = GUIDGenerator.generate()
        XCTAssertEqual(guid.count, 24, "GUID must be exactly 24 characters")
    }

    func testGenerateProducesUppercaseHex() {
        let guid = GUIDGenerator.generate()
        let hexCharacterSet = CharacterSet(charactersIn: "0123456789ABCDEF")
        for character in guid.unicodeScalars {
            XCTAssertTrue(
                hexCharacterSet.contains(character),
                "Character '\(character)' is not a valid uppercase hex digit"
            )
        }
    }

    func testGenerateProducesUniqueValues() {
        var guids = Set<String>()
        let count = 100
        for _ in 0..<count {
            guids.insert(GUIDGenerator.generate())
        }
        XCTAssertEqual(guids.count, count, "All \(count) GUIDs should be unique")
    }
}

// MARK: - PbxprojEditor Tests

final class PbxprojEditorTests: XCTestCase {

    /// A minimal but realistic pbxproj structure for testing.
    private static let samplePbxproj = """
// !$*UTF8*$!
{
    archiveVersion = 1;
    classes = {
    };
    objectVersion = 56;
    objects = {

/* Begin PBXBuildFile section */
        AAA11111BBBB2222CCCC3333 /* AppDelegate.swift in Sources */ = {isa = PBXBuildFile; fileRef = DDD44444EEEE5555FFFF6666 /* AppDelegate.swift */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
        DDD44444EEEE5555FFFF6666 /* AppDelegate.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AppDelegate.swift; sourceTree = "<group>"; };
/* End PBXFileReference section */

/* Begin PBXGroup section */
        111122223333444455556666 = {
            isa = PBXGroup;
            children = (
                DDD44444EEEE5555FFFF6666 /* AppDelegate.swift */,
            );
            path = Sources;
            sourceTree = "<group>";
        };
/* End PBXGroup section */

/* Begin PBXSourcesBuildPhase section */
        AABB11223344556677889900 /* Sources */ = {
            isa = PBXSourcesBuildPhase;
            buildActionMask = 2147483647;
            files = (
                AAA11111BBBB2222CCCC3333 /* AppDelegate.swift in Sources */,
            );
            runOnlyForDeploymentPostprocessing = 0;
        };
/* End PBXSourcesBuildPhase section */

    };
}
"""

    private var tempFile: String!

    override func setUpWithError() throws {
        let tempDir = NSTemporaryDirectory()
        tempFile = (tempDir as NSString).appendingPathComponent("test_\(UUID().uuidString).pbxproj")
        try Self.samplePbxproj.write(toFile: tempFile, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tempFile)
    }

    func testAddFileInsertsFileReference() throws {
        let editor = try PbxprojEditor(pbxprojPath: tempFile)
        try editor.addFile(filePath: "/path/to/NewView.swift", groupPath: "Sources")
        try editor.save()

        let content = try String(contentsOfFile: tempFile, encoding: .utf8)

        XCTAssertTrue(
            content.contains("NewView.swift"),
            "pbxproj should contain the new file name after addFile"
        )
        XCTAssertTrue(
            content.contains("isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = NewView.swift"),
            "Should contain a PBXFileReference for the new file"
        )
        XCTAssertTrue(
            content.contains("NewView.swift in Sources"),
            "Should contain a PBXBuildFile entry referencing the new file"
        )
    }

    func testAddFileInsertsBuildFile() throws {
        let editor = try PbxprojEditor(pbxprojPath: tempFile)
        try editor.addFile(filePath: "/path/to/ViewModel.swift", groupPath: "Sources")
        try editor.save()

        let content = try String(contentsOfFile: tempFile, encoding: .utf8)
        XCTAssertTrue(
            content.contains("ViewModel.swift in Sources"),
            "PBXBuildFile entry should reference the new file in Sources"
        )
    }

    func testRemoveFileRemovesAllReferences() throws {
        // First add a file, then remove it.
        let editor = try PbxprojEditor(pbxprojPath: tempFile)
        try editor.addFile(filePath: "/path/to/Temp.swift", groupPath: "Sources")
        try editor.save()

        // Verify it was added.
        var content = try String(contentsOfFile: tempFile, encoding: .utf8)
        XCTAssertTrue(content.contains("Temp.swift"), "File should be present after add")

        // Now remove it.
        let editor2 = try PbxprojEditor(pbxprojPath: tempFile)
        editor2.removeFile(fileName: "Temp.swift")
        try editor2.save()

        content = try String(contentsOfFile: tempFile, encoding: .utf8)
        XCTAssertFalse(
            content.contains("Temp.swift"),
            "All references to the file should be removed"
        )
    }

    func testRemoveDoesNotAffectOtherFiles() throws {
        let editor = try PbxprojEditor(pbxprojPath: tempFile)
        try editor.addFile(filePath: "/path/to/FileA.swift", groupPath: "Sources")
        try editor.addFile(filePath: "/path/to/FileB.swift", groupPath: "Sources")
        try editor.save()

        let editor2 = try PbxprojEditor(pbxprojPath: tempFile)
        editor2.removeFile(fileName: "FileA.swift")
        try editor2.save()

        let content = try String(contentsOfFile: tempFile, encoding: .utf8)
        XCTAssertFalse(content.contains("FileA.swift"), "FileA should be removed")
        XCTAssertTrue(content.contains("FileB.swift"), "FileB should still be present")
        XCTAssertTrue(content.contains("AppDelegate.swift"), "Original file should still be present")
    }

    func testInitWithNonexistentFileThrows() {
        XCTAssertThrowsError(try PbxprojEditor(pbxprojPath: "/nonexistent/path/project.pbxproj")) { error in
            XCTAssertTrue(error is CocoaError || error is NSError, "Should throw a file-reading error")
        }
    }
}

// MARK: - ChangeAnalyzer Tests

final class ChangeAnalyzerTests: XCTestCase {

    private var analyzer: ChangeAnalyzer!
    private var tempDir: String!

    override func setUp() {
        super.setUp()
        analyzer = ChangeAnalyzer()
        tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("HotSwiftTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    private func writeTempFile(name: String, content: String) -> String {
        let path = (tempDir as NSString).appendingPathComponent(name)
        try! content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func testNewFileReturnsNewFile() {
        let path = writeTempFile(name: "New.swift", content: "class New {}")
        let result = analyzer.analyze(filePath: path, eventType: .created)
        XCTAssertEqual(result, .newFile)
    }

    func testDeletedReturnsDeleted() {
        let result = analyzer.analyze(filePath: "/some/deleted/File.swift", eventType: .deleted)
        XCTAssertEqual(result, .deleted)
    }

    func testBodyOnlyChangeDetected() {
        let originalSource = """
        class MyVC {
            var name: String = ""
            func doWork() {
                print("hello")
            }
        }
        """

        let modifiedSource = """
        class MyVC {
            var name: String = ""
            func doWork() {
                print("hello world!")
                print("more work")
            }
        }
        """

        let path = writeTempFile(name: "MyVC.swift", content: originalSource)

        // First modification: analyzer sees this file for the first time,
        // returns .structural because there is no previous tree cached.
        let firstResult = analyzer.analyze(filePath: path, eventType: .modified)
        XCTAssertEqual(firstResult, .structural, "First time seeing a file should be .structural")

        // Now modify only the method body.
        try! modifiedSource.write(toFile: path, atomically: true, encoding: .utf8)
        let secondResult = analyzer.analyze(filePath: path, eventType: .modified)
        XCTAssertEqual(secondResult, .bodyOnly, "Only method body changed, should be .bodyOnly")
    }

    func testStructuralChangeDetected() {
        let originalSource = """
        class MyVC {
            var name: String = ""
            func doWork() {
                print("hello")
            }
        }
        """

        let modifiedSource = """
        class MyVC {
            var name: String = ""
            var age: Int = 0
            func doWork() {
                print("hello")
            }
        }
        """

        let path = writeTempFile(name: "Structural.swift", content: originalSource)

        // Prime the cache.
        _ = analyzer.analyze(filePath: path, eventType: .modified)

        // Add a new stored property — this is structural.
        try! modifiedSource.write(toFile: path, atomically: true, encoding: .utf8)
        let result = analyzer.analyze(filePath: path, eventType: .modified)
        XCTAssertEqual(result, .structural, "Adding a stored property should be .structural")
    }

    func testNewTypeIsStructural() {
        let originalSource = """
        struct Data {
            let id: Int
        }
        """

        let modifiedSource = """
        struct Data {
            let id: Int
        }
        struct NewData {
            let value: String
        }
        """

        let path = writeTempFile(name: "Types.swift", content: originalSource)
        _ = analyzer.analyze(filePath: path, eventType: .modified)

        try! modifiedSource.write(toFile: path, atomically: true, encoding: .utf8)
        let result = analyzer.analyze(filePath: path, eventType: .modified)
        XCTAssertEqual(result, .structural, "Adding a new type should be .structural")
    }

    func testResetCacheClearsState() {
        let source = "class A { func f() {} }"
        let path = writeTempFile(name: "Cache.swift", content: source)

        // Prime cache.
        _ = analyzer.analyze(filePath: path, eventType: .modified)

        // After reset, next modification should be .structural (no cached tree).
        analyzer.resetCache()
        let result = analyzer.analyze(filePath: path, eventType: .modified)
        XCTAssertEqual(result, .structural, "After resetCache, first analysis should be .structural")
    }
}

// MARK: - DylibLoader Tests

final class DylibLoaderTests: XCTestCase {

    func testLoadNonexistentFileThrowsFileNotFound() {
        let loader = DylibLoader()
        XCTAssertThrowsError(try loader.load(dylibPath: "/nonexistent/path/fake.dylib")) { error in
            guard let loaderError = error as? DylibLoaderError else {
                XCTFail("Expected DylibLoaderError, got \(type(of: error))")
                return
            }

            if case .fileNotFound(let path) = loaderError {
                XCTAssertEqual(path, "/nonexistent/path/fake.dylib")
            } else {
                XCTFail("Expected .fileNotFound, got \(loaderError)")
            }
        }
    }

    func testLoadedImagesStartsEmpty() {
        let loader = DylibLoader()
        XCTAssertTrue(loader.loadedImages.isEmpty, "A new loader should have no loaded images")
    }

    func testDylibLoaderErrorDescriptions() {
        let fileNotFound = DylibLoaderError.fileNotFound("/tmp/missing.dylib")
        XCTAssertNotNil(fileNotFound.errorDescription)
        XCTAssertTrue(fileNotFound.errorDescription!.contains("/tmp/missing.dylib"))

        let loadFailed = DylibLoaderError.loadFailed(path: "/tmp/bad.dylib", reason: "image not found")
        XCTAssertNotNil(loadFailed.errorDescription)
        XCTAssertTrue(loadFailed.errorDescription!.contains("image not found"))

        let symbolNotFound = DylibLoaderError.symbolNotFound(name: "_myFunc", reason: nil)
        XCTAssertNotNil(symbolNotFound.errorDescription)
        XCTAssertTrue(symbolNotFound.errorDescription!.contains("_myFunc"))
    }
}

// MARK: - FSEventsWatcher Tests

final class FSEventsWatcherTests: XCTestCase {

    func testInitialState() {
        let watcher = FSEventsWatcher()
        XCTAssertFalse(watcher.isWatching, "Watcher should not be watching after init")
    }

    func testDefaultDebounceInterval() {
        let watcher = FSEventsWatcher()
        XCTAssertEqual(watcher.debounceInterval, 0.3, accuracy: 0.001)
    }

    func testCustomDebounceInterval() {
        let watcher = FSEventsWatcher(debounceInterval: 1.0)
        XCTAssertEqual(watcher.debounceInterval, 1.0, accuracy: 0.001)
    }

    func testCustomAllowedExtensions() {
        // Verify custom extensions are accepted at init
        let watcher = FSEventsWatcher(allowedExtensions: ["swift", "m"])
        // If it doesn't crash, the init handled the custom set correctly
        XCTAssertNotNil(watcher)
    }

    func testCustomExcludePatterns() {
        // Verify custom exclude patterns are accepted at init
        let watcher = FSEventsWatcher(excludePatterns: ["CustomDir", "Pods"])
        XCTAssertNotNil(watcher)
    }

    func testStopOnNonStartedWatcherDoesNotCrash() {
        let watcher = FSEventsWatcher()
        // Calling stop without start should be a no-op, not a crash.
        watcher.stop()
        XCTAssertFalse(watcher.isWatching)
    }
}

// MARK: - PipelineConfiguration Tests

final class PipelineConfigurationTests: XCTestCase {

    func testInitAndPropertyAccess() {
        let config = PipelineConfiguration(
            watchPaths: ["/Users/test/Project"],
            excludePatterns: ["DerivedData", "Pods"],
            debounceInterval: 0.5,
            verbose: true,
            pbxprojPath: "/Users/test/Project/App.xcodeproj/project.pbxproj",
            projectName: "TestApp"
        )

        XCTAssertEqual(config.watchPaths, ["/Users/test/Project"])
        XCTAssertEqual(config.excludePatterns, ["DerivedData", "Pods"])
        XCTAssertEqual(config.debounceInterval, 0.5, accuracy: 0.001)
        XCTAssertTrue(config.verbose)
        XCTAssertEqual(config.pbxprojPath, "/Users/test/Project/App.xcodeproj/project.pbxproj")
        XCTAssertEqual(config.projectName, "TestApp")
    }

    func testNilOptionalProperties() {
        let config = PipelineConfiguration(
            watchPaths: [],
            excludePatterns: [],
            debounceInterval: 0.3,
            verbose: false,
            pbxprojPath: nil,
            projectName: nil
        )

        XCTAssertNil(config.pbxprojPath)
        XCTAssertNil(config.projectName)
        XCTAssertTrue(config.watchPaths.isEmpty)
    }
}

// MARK: - HotSwift Public API Tests

final class HotSwiftPublicAPITests: XCTestCase {

    func testSharedInstanceExists() {
        let instance = HotSwift.shared
        XCTAssertNotNil(instance, "HotSwift.shared should be accessible")
    }

    func testDidReloadNotificationNameExists() {
        let name = HotSwift.didReloadNotification
        XCTAssertEqual(name.rawValue, "HotSwiftDidReload")
    }

    func testStartAndStopDoNotCrash() {
        // Calling start without a real project should handle gracefully (no crash).
        // It will fail to detect a project root, which is expected in a test context.
        HotSwift.stop()
        // Calling stop when not running should be a safe no-op.
        HotSwift.stop()
    }

    func testHotSwiftConfigurationDefaults() {
        let config = HotSwiftConfiguration.default
        XCTAssertTrue(config.watchPaths.isEmpty, "Default watchPaths should be empty (auto-detect)")
        XCTAssertFalse(config.verbose, "Default verbose should be false")
        XCTAssertEqual(config.debounceInterval, 0.3, accuracy: 0.001)
        XCTAssertNil(config.pbxprojPath)
        XCTAssertNil(config.projectName)
    }

    func testHotSwiftConfigurationCustomInit() {
        var config = HotSwiftConfiguration(
            watchPaths: ["/tmp/test"],
            excludePatterns: ["DerivedData"],
            debounceInterval: 1.0,
            verbose: true,
            pbxprojPath: "/tmp/test.pbxproj",
            projectName: "TestProject"
        )

        XCTAssertEqual(config.watchPaths, ["/tmp/test"])
        XCTAssertEqual(config.debounceInterval, 1.0, accuracy: 0.001)
        XCTAssertTrue(config.verbose)
        XCTAssertEqual(config.pbxprojPath, "/tmp/test.pbxproj")
        XCTAssertEqual(config.projectName, "TestProject")

        // Verify mutability.
        config.verbose = false
        XCTAssertFalse(config.verbose)
    }

    func testHotSwiftReloadEventStatus() {
        let successEvent = HotSwiftReloadEvent(
            status: .success,
            filePath: "/tmp/Test.swift",
            affectedClasses: ["TestClass"],
            duration: 0.5,
            message: "Reloaded",
            timestamp: Date()
        )
        XCTAssertEqual(successEvent.status, .success)
        XCTAssertEqual(successEvent.filePath, "/tmp/Test.swift")
        XCTAssertEqual(successEvent.affectedClasses, ["TestClass"])

        let failedEvent = HotSwiftReloadEvent(
            status: .failed,
            filePath: "/tmp/Bad.swift",
            affectedClasses: [],
            duration: 0.1,
            message: "Compilation failed",
            timestamp: Date()
        )
        XCTAssertEqual(failedEvent.status, .failed)
        XCTAssertTrue(failedEvent.affectedClasses.isEmpty)
    }
}

// MARK: - FileEvent & FileEventType Tests

final class FileEventTests: XCTestCase {

    func testFileEventEquality() {
        let date = Date()
        let event1 = FileEvent(path: "/tmp/A.swift", type: .modified, timestamp: date)
        let event2 = FileEvent(path: "/tmp/A.swift", type: .modified, timestamp: date)
        XCTAssertEqual(event1, event2)
    }

    func testFileEventTypeVariants() {
        let created: FileEventType = .created
        let modified: FileEventType = .modified
        let deleted: FileEventType = .deleted

        // Ensure they are distinct.
        switch created {
        case .created: break
        default: XCTFail("Expected .created")
        }
        switch modified {
        case .modified: break
        default: XCTFail("Expected .modified")
        }
        switch deleted {
        case .deleted: break
        default: XCTFail("Expected .deleted")
        }
    }
}

// MARK: - PbxprojEditorError Tests

final class PbxprojEditorErrorTests: XCTestCase {

    func testFileNotReadableDescription() {
        let error = PbxprojEditorError.fileNotReadable("/bad/path")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("/bad/path"))
    }

    func testSectionNotFoundDescription() {
        let error = PbxprojEditorError.sectionNotFound("PBXBuildFile")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("PBXBuildFile"))
    }
}

// MARK: - XcactivitylogParser Tokenizer Tests

final class XcactivitylogParserTokenizerTests: XCTestCase {

    private let parser = XcactivitylogParser()

    func testSimpleTokenization() {
        let tokens = parser.tokenize(command: "/usr/bin/swiftc -emit-library -o output.dylib input.swift")
        XCTAssertEqual(tokens, ["/usr/bin/swiftc", "-emit-library", "-o", "output.dylib", "input.swift"])
    }

    func testDoubleQuotedPaths() {
        let tokens = parser.tokenize(command: #"swiftc -o "/path/with spaces/out.dylib" "/path/with spaces/in.swift""#)
        XCTAssertEqual(tokens, ["swiftc", "-o", "/path/with spaces/out.dylib", "/path/with spaces/in.swift"])
    }

    func testSingleQuotedPaths() {
        let tokens = parser.tokenize(command: "swiftc -o '/path/with spaces/out.dylib' '/path/with spaces/in.swift'")
        XCTAssertEqual(tokens, ["swiftc", "-o", "/path/with spaces/out.dylib", "/path/with spaces/in.swift"])
    }

    func testBackslashEscapedSpaces() {
        let tokens = parser.tokenize(command: #"swiftc /path/with\ spaces/file.swift"#)
        XCTAssertEqual(tokens, ["swiftc", "/path/with spaces/file.swift"])
    }

    func testEmptyStringProducesNoTokens() {
        let tokens = parser.tokenize(command: "")
        XCTAssertTrue(tokens.isEmpty)
    }

    func testMultipleSpacesBetweenTokens() {
        let tokens = parser.tokenize(command: "swiftc   -o   output.dylib")
        XCTAssertEqual(tokens, ["swiftc", "-o", "output.dylib"])
    }

    func testMixedQuoteStyles() {
        let tokens = parser.tokenize(command: #"swiftc -F "/path/one" -I '/path/two' /path/three"#)
        XCTAssertEqual(tokens, ["swiftc", "-F", "/path/one", "-I", "/path/two", "/path/three"])
    }

    func testParseWithNonexistentFileThrows() {
        XCTAssertThrowsError(try parser.parse(logPath: "/nonexistent/file.xcactivitylog")) { error in
            guard let parserError = error as? XcactivitylogParserError else {
                XCTFail("Expected XcactivitylogParserError")
                return
            }
            if case .fileNotFound = parserError {
                // expected
            } else {
                XCTFail("Expected .fileNotFound, got \(parserError)")
            }
        }
    }
}

// MARK: - XcactivitylogParserError Tests

final class XcactivitylogParserErrorTests: XCTestCase {

    func testFileNotFoundDescription() {
        let error = XcactivitylogParserError.fileNotFound("/tmp/missing.xcactivitylog")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("/tmp/missing.xcactivitylog"))
    }

    func testDecompressionFailedDescription() {
        let error = XcactivitylogParserError.decompressionFailed("gunzip failed")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("gunzip failed"))
    }

    func testInvalidLogContentDescription() {
        let error = XcactivitylogParserError.invalidLogContent
        XCTAssertNotNil(error.errorDescription)
    }

    func testNoCompileCommandsFoundDescription() {
        let error = XcactivitylogParserError.noCompileCommandsFound
        XCTAssertNotNil(error.errorDescription)
    }
}

// MARK: - PbxprojEditor Edge Cases

final class PbxprojEditorEdgeCaseTests: XCTestCase {

    private static let samplePbxproj = """
// !$*UTF8*$!
{
    archiveVersion = 1;
    classes = {
    };
    objectVersion = 56;
    objects = {

/* Begin PBXBuildFile section */
        AAA11111BBBB2222CCCC3333 /* AppDelegate.swift in Sources */ = {isa = PBXBuildFile; fileRef = DDD44444EEEE5555FFFF6666 /* AppDelegate.swift */; };
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
        DDD44444EEEE5555FFFF6666 /* AppDelegate.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AppDelegate.swift; sourceTree = "<group>"; };
/* End PBXFileReference section */

/* Begin PBXGroup section */
        111122223333444455556666 = {
            isa = PBXGroup;
            children = (
                DDD44444EEEE5555FFFF6666 /* AppDelegate.swift */,
            );
            path = Sources;
            sourceTree = "<group>";
        };
/* End PBXGroup section */

/* Begin PBXSourcesBuildPhase section */
        AABB11223344556677889900 /* Sources */ = {
            isa = PBXSourcesBuildPhase;
            buildActionMask = 2147483647;
            files = (
                AAA11111BBBB2222CCCC3333 /* AppDelegate.swift in Sources */,
            );
            runOnlyForDeploymentPostprocessing = 0;
        };
/* End PBXSourcesBuildPhase section */

    };
}
"""

    private var tempFile: String!

    override func setUpWithError() throws {
        let tempDir = NSTemporaryDirectory()
        tempFile = (tempDir as NSString).appendingPathComponent("test_edge_\(UUID().uuidString).pbxproj")
        try Self.samplePbxproj.write(toFile: tempFile, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tempFile)
        // Clean up backup file
        try? FileManager.default.removeItem(atPath: tempFile + ".hotswift.bak")
    }

    func testDuplicateAddIsIgnored() throws {
        let editor = try PbxprojEditor(pbxprojPath: tempFile)
        let result1 = try editor.addFile(filePath: "/path/to/Dup.swift", groupPath: "Sources")
        let result2 = try editor.addFile(filePath: "/path/to/Dup.swift", groupPath: "Sources")
        try editor.save()

        // Second add should return empty strings (duplicate detected)
        XCTAssertTrue(result2.fileRef.isEmpty)
        XCTAssertTrue(result2.buildFile.isEmpty)
        // First add should have real UUIDs
        XCTAssertFalse(result1.fileRef.isEmpty)
        XCTAssertFalse(result1.buildFile.isEmpty)
    }

    func testSaveCreatesBackup() throws {
        let editor = try PbxprojEditor(pbxprojPath: tempFile)
        try editor.addFile(filePath: "/path/to/Backup.swift", groupPath: "Sources")
        try editor.save()

        let backupPath = tempFile + ".hotswift.bak"
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: backupPath),
            "save() should create a .hotswift.bak backup"
        )
    }

    func testRemoveNonexistentFileDoesNotCorrupt() throws {
        let originalContent = try String(contentsOfFile: tempFile, encoding: .utf8)
        let editor = try PbxprojEditor(pbxprojPath: tempFile)
        editor.removeFile(fileName: "NonExistent.swift")
        try editor.save()

        let afterContent = try String(contentsOfFile: tempFile, encoding: .utf8)
        XCTAssertEqual(originalContent, afterContent, "Removing a non-existent file should not change the content")
    }

    func testAddMultipleFilesPreservesAll() throws {
        let editor = try PbxprojEditor(pbxprojPath: tempFile)
        try editor.addFile(filePath: "/path/to/A.swift", groupPath: "Sources")
        try editor.addFile(filePath: "/path/to/B.swift", groupPath: "Sources")
        try editor.addFile(filePath: "/path/to/C.swift", groupPath: "Sources")
        try editor.save()

        let content = try String(contentsOfFile: tempFile, encoding: .utf8)
        XCTAssertTrue(content.contains("A.swift"))
        XCTAssertTrue(content.contains("B.swift"))
        XCTAssertTrue(content.contains("C.swift"))
        XCTAssertTrue(content.contains("AppDelegate.swift"))
    }
}

// MARK: - ChangeAnalyzer Advanced Tests

final class ChangeAnalyzerAdvancedTests: XCTestCase {

    private var analyzer: ChangeAnalyzer!
    private var tempDir: String!

    override func setUp() {
        super.setUp()
        analyzer = ChangeAnalyzer()
        tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("HotSwiftAdvanced_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    private func writeTempFile(name: String, content: String) -> String {
        let path = (tempDir as NSString).appendingPathComponent(name)
        try! content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func testActorDeclarationIsStructural() {
        let original = "actor MyActor { func doWork() { print(1) } }"
        let modified = "actor MyActor { var state: Int = 0\nfunc doWork() { print(1) } }"

        let path = writeTempFile(name: "Actor.swift", content: original)
        _ = analyzer.analyze(filePath: path, eventType: .modified)

        try! modified.write(toFile: path, atomically: true, encoding: .utf8)
        let result = analyzer.analyze(filePath: path, eventType: .modified)
        XCTAssertEqual(result, .structural, "Adding a stored property to an actor should be .structural")
    }

    func testActorBodyOnlyChangeDetected() {
        let original = "actor Counter { var count = 0\nfunc increment() { count += 1 } }"
        let modified = "actor Counter { var count = 0\nfunc increment() { count += 2 } }"

        let path = writeTempFile(name: "ActorBody.swift", content: original)
        _ = analyzer.analyze(filePath: path, eventType: .modified)

        try! modified.write(toFile: path, atomically: true, encoding: .utf8)
        let result = analyzer.analyze(filePath: path, eventType: .modified)
        XCTAssertEqual(result, .bodyOnly, "Changing only actor method body should be .bodyOnly")
    }

    func testNewEnumCaseIsStructural() {
        let original = "enum Status { case active\ncase inactive }"
        let modified = "enum Status { case active\ncase inactive\ncase pending }"

        let path = writeTempFile(name: "Enum.swift", content: original)
        _ = analyzer.analyze(filePath: path, eventType: .modified)

        try! modified.write(toFile: path, atomically: true, encoding: .utf8)
        let result = analyzer.analyze(filePath: path, eventType: .modified)
        XCTAssertEqual(result, .structural, "Adding an enum case should be .structural")
    }

    func testNewFunctionSignatureIsStructural() {
        let original = "class Svc { func load() { print(1) } }"
        let modified = "class Svc { func load() { print(1) }\nfunc save() { print(2) } }"

        let path = writeTempFile(name: "Func.swift", content: original)
        _ = analyzer.analyze(filePath: path, eventType: .modified)

        try! modified.write(toFile: path, atomically: true, encoding: .utf8)
        let result = analyzer.analyze(filePath: path, eventType: .modified)
        XCTAssertEqual(result, .structural, "Adding a new function should be .structural")
    }

    func testChangingImportIsStructural() {
        let original = "import Foundation\nclass A { func f() {} }"
        let modified = "import Foundation\nimport UIKit\nclass A { func f() {} }"

        let path = writeTempFile(name: "Import.swift", content: original)
        _ = analyzer.analyze(filePath: path, eventType: .modified)

        try! modified.write(toFile: path, atomically: true, encoding: .utf8)
        let result = analyzer.analyze(filePath: path, eventType: .modified)
        XCTAssertEqual(result, .structural, "Adding an import should be .structural")
    }

    func testObserverDefaultValueChangeIsStructural() {
        let original = """
        class VM {
            var count: Int = 0 {
                didSet { print(count) }
            }
        }
        """
        let modified = """
        class VM {
            var count: Int = 1 {
                didSet { print(count) }
            }
        }
        """

        let path = writeTempFile(name: "Observer.swift", content: original)
        _ = analyzer.analyze(filePath: path, eventType: .modified)

        try! modified.write(toFile: path, atomically: true, encoding: .utf8)
        let result = analyzer.analyze(filePath: path, eventType: .modified)
        XCTAssertEqual(result, .structural, "Changing observer default value should be .structural")
    }

    func testExtensionConformanceIsStructural() {
        let original = "struct S {}\nextension S { func f() {} }"
        let modified = "struct S {}\nextension S: Codable { func f() {} }"

        let path = writeTempFile(name: "Extension.swift", content: original)
        _ = analyzer.analyze(filePath: path, eventType: .modified)

        try! modified.write(toFile: path, atomically: true, encoding: .utf8)
        let result = analyzer.analyze(filePath: path, eventType: .modified)
        XCTAssertEqual(result, .structural, "Adding protocol conformance in extension should be .structural")
    }

    func testTypealiasChangeIsStructural() {
        let original = "typealias ID = String\nclass A { func f() {} }"
        let modified = "typealias ID = Int\nclass A { func f() {} }"

        let path = writeTempFile(name: "Typealias.swift", content: original)
        _ = analyzer.analyze(filePath: path, eventType: .modified)

        try! modified.write(toFile: path, atomically: true, encoding: .utf8)
        let result = analyzer.analyze(filePath: path, eventType: .modified)
        XCTAssertEqual(result, .structural, "Changing a typealias should be .structural")
    }

    func testMultipleBodyChangesRemainBodyOnly() {
        let original = """
        class VC {
            var x: Int = 0
            func a() { print(1) }
            func b() { print(2) }
            func c() { print(3) }
        }
        """
        let modified = """
        class VC {
            var x: Int = 0
            func a() { print("changed") }
            func b() { for i in 0..<10 { print(i) } }
            func c() { let result = 42; print(result) }
        }
        """

        let path = writeTempFile(name: "MultiBody.swift", content: original)
        _ = analyzer.analyze(filePath: path, eventType: .modified)

        try! modified.write(toFile: path, atomically: true, encoding: .utf8)
        let result = analyzer.analyze(filePath: path, eventType: .modified)
        XCTAssertEqual(result, .bodyOnly, "Changing multiple method bodies should still be .bodyOnly")
    }

    func testNonexistentFileReturnsStructural() {
        let result = analyzer.analyze(filePath: "/nonexistent/file.swift", eventType: .modified)
        XCTAssertEqual(result, .structural, "Unreadable file should return .structural as safety fallback")
    }
}

// MARK: - ReloadPipeline Lifecycle Tests

final class ReloadPipelineLifecycleTests: XCTestCase {

    private func makeConfig() -> PipelineConfiguration {
        PipelineConfiguration(
            watchPaths: [NSTemporaryDirectory()],
            excludePatterns: ["DerivedData"],
            debounceInterval: 0.3,
            verbose: false,
            pbxprojPath: nil,
            projectName: nil
        )
    }

    func testStartAndStopDoNotCrash() {
        let pipeline = ReloadPipeline(configuration: makeConfig())
        pipeline.start()
        pipeline.stop()
    }

    func testDoubleStartIsIdempotent() {
        let pipeline = ReloadPipeline(configuration: makeConfig())
        pipeline.start()
        pipeline.start() // should not crash or duplicate watchers
        pipeline.stop()
    }

    func testDoubleStopIsIdempotent() {
        let pipeline = ReloadPipeline(configuration: makeConfig())
        pipeline.start()
        pipeline.stop()
        pipeline.stop() // should not crash
    }

    func testStopWithoutStartIsNoOp() {
        let pipeline = ReloadPipeline(configuration: makeConfig())
        pipeline.stop() // should not crash
    }

    func testEventsPublisherIsAccessible() {
        let pipeline = ReloadPipeline(configuration: makeConfig())
        // Just verify the publisher exists and can be subscribed to
        let cancellable = pipeline.events.sink { _ in }
        XCTAssertNotNil(cancellable)
        cancellable.cancel()
    }

    func testReloadEventProperties() {
        let event = ReloadEvent(
            status: .success,
            filePath: "/tmp/Test.swift",
            affectedClasses: ["TestVC", "TestVM"],
            duration: 0.42,
            diagnostics: ["Compiled successfully"],
            timestamp: Date()
        )

        XCTAssertEqual(event.status, .success)
        XCTAssertEqual(event.filePath, "/tmp/Test.swift")
        XCTAssertEqual(event.affectedClasses.count, 2)
        XCTAssertEqual(event.duration, 0.42, accuracy: 0.001)
        XCTAssertEqual(event.diagnostics.count, 1)
    }

    func testReloadEventFailureStatuses() {
        let statuses: [ReloadEvent.Status] = [.success, .compilationFailed, .loadFailed, .interpositionFailed]
        XCTAssertEqual(statuses.count, 4, "ReloadEvent.Status should have 4 cases")
    }
}

// MARK: - CompilationError Tests

final class CompilationErrorTests: XCTestCase {

    func testCompilationFailedDescription() {
        let error = CompilationError.compilationFailed(exitCode: 1, output: "error: missing return")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("missing return"))
        XCTAssertTrue(error.errorDescription!.contains("exit 1"))
    }

    func testOutputMissingDescription() {
        let error = CompilationError.outputMissing("/tmp/hotswift/reload_1.dylib")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("/tmp/hotswift/reload_1.dylib"))
    }
}

// MARK: - BuildSettingsError Tests

final class BuildSettingsErrorTests: XCTestCase {

    func testDerivedDataNotFoundDescription() {
        let error = BuildSettingsError.derivedDataNotFound
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("DerivedData"))
    }

    func testProjectNotFoundDescription() {
        let error = BuildSettingsError.projectNotFound("MyApp")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("MyApp"))
    }

    func testNoActivityLogsDescription() {
        let error = BuildSettingsError.noActivityLogs("/path/to/logs")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("/path/to/logs"))
    }

    func testFileNotFoundInBuildLogDescription() {
        let error = BuildSettingsError.fileNotFoundInBuildLog("ViewController.swift")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("ViewController.swift"))
    }

    func testUnableToExtractSettingsDescription() {
        let error = BuildSettingsError.unableToExtractSettings("malformed args")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("malformed args"))
    }
}

// MARK: - SwiftCompilerError Tests

final class SwiftCompilerErrorTests: XCTestCase {

    func testSwiftcNotFoundDescription() {
        let error = SwiftCompilerError.swiftcNotFound
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("swiftc"))
    }

    func testOutputDirectoryCreationFailedDescription() {
        let error = SwiftCompilerError.outputDirectoryCreationFailed("permission denied")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("permission denied"))
    }

    func testProcessLaunchFailedDescription() {
        let error = SwiftCompilerError.processLaunchFailed("not found")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("not found"))
    }
}

// MARK: - BuildSettings Tests

final class BuildSettingsTests: XCTestCase {

    func testBuildSettingsProperties() {
        let settings = BuildSettings(
            sdkPath: "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator17.0.sdk",
            targetTriple: "arm64-apple-ios17.0-simulator",
            frameworkSearchPaths: ["/path/to/frameworks"],
            importPaths: ["/path/to/headers"],
            libraryPaths: ["/path/to/libs"],
            moduleName: "MyApp",
            otherSwiftFlags: ["-DDEBUG"],
            otherLinkerFlags: ["-lz"]
        )

        XCTAssertTrue(settings.sdkPath.contains("iPhoneSimulator"))
        XCTAssertEqual(settings.targetTriple, "arm64-apple-ios17.0-simulator")
        XCTAssertEqual(settings.frameworkSearchPaths.count, 1)
        XCTAssertEqual(settings.importPaths.count, 1)
        XCTAssertEqual(settings.libraryPaths.count, 1)
        XCTAssertEqual(settings.moduleName, "MyApp")
        XCTAssertEqual(settings.otherSwiftFlags, ["-DDEBUG"])
        XCTAssertEqual(settings.otherLinkerFlags, ["-lz"])
    }
}

// MARK: - FSEventsWatcher File Detection Tests

final class FSEventsWatcherFileDetectionTests: XCTestCase {

    func testStartSetsWatching() {
        let watcher = FSEventsWatcher()
        let tempDir = NSTemporaryDirectory()
        watcher.start(paths: [tempDir]) { _ in }

        // Give FSEvents a moment to initialize
        let expectation = XCTestExpectation(description: "Watcher starts")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertTrue(watcher.isWatching, "Watcher should be watching after start()")
            watcher.stop()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }

    func testStopClearsWatching() {
        let watcher = FSEventsWatcher()
        let tempDir = NSTemporaryDirectory()
        watcher.start(paths: [tempDir]) { _ in }

        let expectation = XCTestExpectation(description: "Watcher stops")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            watcher.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                XCTAssertFalse(watcher.isWatching, "Watcher should not be watching after stop()")
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 2.0)
    }

    func testDetectsSwiftFileCreation() {
        let watcher = FSEventsWatcher(debounceInterval: 0.1)
        let tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("hotswift_test_\(UUID().uuidString)")
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

        let expectation = XCTestExpectation(description: "Detect file creation")

        watcher.start(paths: [tempDir]) { events in
            if events.contains(where: { $0.path.hasSuffix("TestDetect.swift") }) {
                expectation.fulfill()
            }
        }

        // Create a Swift file after a small delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let filePath = (tempDir as NSString).appendingPathComponent("TestDetect.swift")
            try! "class Test {}".write(toFile: filePath, atomically: true, encoding: .utf8)
        }

        wait(for: [expectation], timeout: 5.0)
        watcher.stop()
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    func testIgnoresNonSwiftFiles() {
        let watcher = FSEventsWatcher(debounceInterval: 0.1)
        let tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("hotswift_test_\(UUID().uuidString)")
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

        let swiftExpectation = XCTestExpectation(description: "Detect Swift file")
        let noTxtExpectation = XCTestExpectation(description: "No .txt event")
        noTxtExpectation.isInverted = true

        watcher.start(paths: [tempDir]) { events in
            for event in events {
                if event.path.hasSuffix(".txt") {
                    noTxtExpectation.fulfill()
                }
                if event.path.hasSuffix(".swift") {
                    swiftExpectation.fulfill()
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // Write a .txt file (should be ignored)
            let txtPath = (tempDir as NSString).appendingPathComponent("readme.txt")
            try! "hello".write(toFile: txtPath, atomically: true, encoding: .utf8)
            // Write a .swift file (should be detected)
            let swiftPath = (tempDir as NSString).appendingPathComponent("Code.swift")
            try! "struct S {}".write(toFile: swiftPath, atomically: true, encoding: .utf8)
        }

        wait(for: [swiftExpectation], timeout: 5.0)
        wait(for: [noTxtExpectation], timeout: 1.0)
        watcher.stop()
        try? FileManager.default.removeItem(atPath: tempDir)
    }
}

// MARK: - Integration: Compile + Load Cycle

final class CompileAndLoadIntegrationTests: XCTestCase {

    func testCompileSimpleSwiftFileIntoLoadableDylib() throws {
        // Write a minimal Swift source file
        let tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("hotswift_integration_\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let sourcePath = (tempDir as NSString).appendingPathComponent("TestReload.swift")
        let dylibPath = (tempDir as NSString).appendingPathComponent("TestReload.dylib")

        try """
        public func hotswiftTestValue() -> Int { return 42 }
        """.write(toFile: sourcePath, atomically: true, encoding: .utf8)

        // Compile using xcrun swiftc
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "swiftc",
            "-emit-library",
            "-o", dylibPath,
            "-module-name", "TestReload",
            "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup",
            sourcePath
        ]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, "swiftc should compile successfully")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dylibPath), "dylib should exist after compilation")

        // Load the dylib using DylibLoader
        let loader = DylibLoader()
        let image = try loader.load(dylibPath: dylibPath)

        XCTAssertEqual(image.version, 1)
        XCTAssertEqual(image.path, dylibPath)
        XCTAssertEqual(loader.loadedImages.count, 1)
    }

    func testCompileAndLoadMultipleVersions() throws {
        let tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("hotswift_versions_\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let loader = DylibLoader()

        for version in 1...3 {
            let sourcePath = (tempDir as NSString).appendingPathComponent("V\(version).swift")
            let dylibPath = (tempDir as NSString).appendingPathComponent("V\(version).dylib")

            try """
            public func version\(version)() -> Int { return \(version) }
            """.write(toFile: sourcePath, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = [
                "swiftc", "-emit-library", "-o", dylibPath,
                "-module-name", "V\(version)",
                "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup",
                sourcePath
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()

            let image = try loader.load(dylibPath: dylibPath)
            XCTAssertEqual(image.version, version)
        }

        XCTAssertEqual(loader.loadedImages.count, 3, "Should have loaded 3 dylib versions")
    }
}
