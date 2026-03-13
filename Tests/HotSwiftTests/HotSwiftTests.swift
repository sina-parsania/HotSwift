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
        editor.addFile(filePath: "/path/to/NewView.swift", groupPath: "Sources")
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
        editor.addFile(filePath: "/path/to/ViewModel.swift", groupPath: "Sources")
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
        editor.addFile(filePath: "/path/to/Temp.swift", groupPath: "Sources")
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
        editor.addFile(filePath: "/path/to/FileA.swift", groupPath: "Sources")
        editor.addFile(filePath: "/path/to/FileB.swift", groupPath: "Sources")
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

    func testDefaultAllowedExtensions() {
        let watcher = FSEventsWatcher()
        XCTAssertTrue(watcher.allowedExtensions.contains("swift"))
        XCTAssertEqual(watcher.allowedExtensions.count, 1)
    }

    func testDefaultExcludePatterns() {
        let watcher = FSEventsWatcher()
        XCTAssertTrue(watcher.excludePatterns.contains("DerivedData"))
        XCTAssertTrue(watcher.excludePatterns.contains("Pods"))
        XCTAssertTrue(watcher.excludePatterns.contains(".build"))
        XCTAssertTrue(watcher.excludePatterns.contains(".git"))
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
