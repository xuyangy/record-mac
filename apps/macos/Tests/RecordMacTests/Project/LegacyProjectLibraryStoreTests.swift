import Foundation
import XCTest
@testable import RecordMac

/// The native legacy project library, checked against the behaviour of open-recorder's Rust
/// service (`apps/rust-service/src/main.rs` at `afa3176`) on temporary folders.
final class LegacyProjectLibraryStoreTests: XCTestCase {
    private var root: URL!
    private var store: LegacyProjectLibraryStore!
    private var locations: LegacyLibraryLocations { store.locations }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-library-\(UUID().uuidString)")
        store = LegacyProjectLibraryStore(locations: LegacyLibraryLocations(
            recordings: root.appendingPathComponent("Recordings"),
            screenshots: root.appendingPathComponent("Screenshots"),
            projects: root.appendingPathComponent("Projects"),
            support: root.appendingPathComponent("Support")))
        _ = try store.paths()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    private func media(_ name: String, in folder: URL? = nil) throws -> String {
        let url = (folder ?? locations.recordings).appendingPathComponent(name)
        try Data("media".utf8).write(to: url)
        return url.path
    }

    private func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }

    private func object(at path: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
    }

    private func indexed() throws -> [ProjectSummary] {
        try JSONDecoder().decode([ProjectSummary].self, from: Data(contentsOf: locations.index))
    }

    private func writeDocument(_ name: String, _ document: [String: Any]) throws -> URL {
        let url = locations.projects.appendingPathComponent(name)
        try JSONSerialization.data(withJSONObject: document).write(to: url)
        return url
    }

    private func document(title: String, recordingPath: String?, createdAt: String = "100") -> [String: Any] {
        ["schemaVersion": 2, "title": title, "recordingPath": recordingPath ?? NSNull(), "sourceName": "Display",
         "createdAt": createdAt, "updatedAt": createdAt, "editorState": ["timelineEdits": [String: Any]()]]
    }

    private func register(_ title: String) throws -> ProjectSummary {
        try store.saveProject(LegacyProjectRequest(title: title, recordingPath: try media("\(title).mp4"), sourceName: "Display"))
    }

    private func corrupt(_ url: URL) throws {
        try Data("corrupt".utf8).write(to: url)
    }

    // MARK: Locations

    func testProductionAndNightlyLibrariesAreSeparateAndNamedForThisApp() {
        let home = URL(fileURLWithPath: "/test/home")
        let production = LegacyLibraryLocations.forHome(home, storageDirectoryName: "Record Mac")
        let nightly = LegacyLibraryLocations.forHome(home, storageDirectoryName: "RecordMacNightly")
        XCTAssertEqual(production.support.path, "/test/home/Library/Application Support/Record Mac")
        XCTAssertEqual(production.projects.path, "/test/home/Library/Application Support/Record Mac/Projects")
        XCTAssertEqual(production.recordings.path, "/test/home/Movies/Record Mac")
        XCTAssertEqual(nightly.screenshots.path, "/test/home/Pictures/RecordMacNightly")
        XCTAssertNotEqual(production.index, nightly.index)
        XCTAssertNotEqual(production.forgottenProjects, nightly.forgottenProjects)
        XCTAssertEqual(LegacyLibraryLocations.forHome(home).support.lastPathComponent, AppVariant.storageDirectoryName)
    }

    func testPathsCreateTheFoldersAndAnEmptyIndex() throws {
        let paths = try store.paths()
        XCTAssertEqual(paths.projectsDir, locations.projects.path)
        for path in [paths.recordingsDir, paths.screenshotsDir, paths.projectsDir, paths.supportDir] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }
        XCTAssertEqual(try indexed(), [])
    }

    func testPreparedRecordingFilesAreSanitisedIntoTheRecordingsFolder() throws {
        XCTAssertEqual(try store.prepareRecordingFile(fileName: "Demo: Screen/Window.mov").path,
            locations.recordings.appendingPathComponent("Demo-Screen-Window.mov").path)
        let generated = try store.prepareRecordingFile(fileName: nil).path
        XCTAssertTrue(URL(fileURLWithPath: generated).lastPathComponent.hasPrefix("recording-"))
        XCTAssertEqual(sanitizedFileName("Product Demo: Screen/Window.mov"), "Product-Demo-Screen-Window.mov")
        XCTAssertEqual(sanitizedFileName("Clip\tTitle\nFinal.mov"), "Clip-Title-Final.mov")
        XCTAssertEqual(sanitizedFileName("..."), "open-recorder-file")
        XCTAssertEqual(sanitizedFileName("Café"), "Caf")
    }

    // MARK: Requests

    func testRequestFieldsCountOnlyWhenTheyAreStrings() throws {
        let request = try LegacyProjectRequest(params: json(["path": "/tmp/demo.mov", "title": 2, "editorState": NSNull()]))
        XCTAssertEqual(request.path, "/tmp/demo.mov")
        XCTAssertNil(request.title)
        XCTAssertEqual(request.editorState, Data("null".utf8))
        XCTAssertNil(request.recordingSession)
        XCTAssertThrowsError(try LegacyProjectRequest(params: Data("[1]".utf8)))
    }

    func testRegistrationRequiresAPath() {
        XCTAssertThrowsError(try store.registerRecording(LegacyProjectRequest())) {
            XCTAssertEqual($0 as? LegacyLibraryError, .missingParameter("registerRecording requires path"))
        }
        XCTAssertThrowsError(try store.updateProject(LegacyProjectRequest()))
    }

    // MARK: Saving and updating

    func testARegisteredRecordingKeepsItsEditorStateAndSessionAsGiven() throws {
        let path = try media("demo.mp4")
        let session: [String: Any] = [
            "screenVideoPath": path, "facecamOffsetMs": -375, "showCursorOverlay": true,
            "futureField": ["nested": [1, 2.5, "x"]],
        ]
        let state: [String: Any] = ["timelineEdits": ["clipSplitTimes": [Any]()], "unknownPanel": ["width": 320]]
        let summary = try store.registerRecording(LegacyProjectRequest(
            path: path, sourceName: "Display 1", editorState: json(state), recordingSession: json(session)))

        XCTAssertEqual(summary.title, "demo")
        XCTAssertTrue(summary.id.hasPrefix("project-"))
        XCTAssertEqual(summary.availability, .available)
        XCTAssertEqual(summary.createdAt, summary.updatedAt)
        XCTAssertNotNil(Int(summary.createdAt), "seconds as a string")
        XCTAssertTrue(summary.path.hasSuffix(".openrecorder"))
        let saved = try object(at: summary.path)
        XCTAssertEqual(saved["schemaVersion"] as? Int, 2)
        XCTAssertEqual(saved["recordingPath"] as? String, path)
        XCTAssertTrue(saved["screenshotPath"] is NSNull)
        XCTAssertEqual(saved["editorState"] as? NSDictionary, state as NSDictionary)
        XCTAssertEqual(saved["recordingSession"] as? NSDictionary, session as NSDictionary)
        XCTAssertEqual(try indexed().map(\.id), [summary.id])

        let updated = try store.updateProject(LegacyProjectRequest(
            path: summary.path, title: "Demo Edited",
            editorState: json(["timelineEdits": ["clipSplitTimes": [1.5]]])))
        let resaved = try object(at: summary.path)
        XCTAssertEqual(updated.id, summary.id)
        XCTAssertEqual(resaved["recordingSession"] as? NSDictionary, session as NSDictionary, "kept when left out")
        XCTAssertEqual(((resaved["editorState"] as? [String: Any])?["timelineEdits"] as? [String: Any])?["clipSplitTimes"] as? [Double], [1.5])
        XCTAssertEqual(resaved["recordingPath"] as? String, path)
    }

    func testARegistrationWithoutEditorStateGetsTheDefaultTimeline() throws {
        let summary = try store.registerRecording(LegacyProjectRequest(path: try media("plain.mp4")))
        XCTAssertEqual(try object(at: summary.path)["editorState"] as? NSDictionary,
            LegacyProjectLibraryStore.defaultTimelineEditorState as NSDictionary)
        XCTAssertTrue(try object(at: summary.path)["recordingSession"] is NSNull)
    }

    func testUpdateKeepsCreationTimeIdentityAndLastOpenedAndDoesNotDuplicate() throws {
        let recording = try media("demo.mp4")
        let project = try writeDocument("demo.openrecorder", document(title: "Demo", recordingPath: recording))
        let existing = ProjectSummary(
            id: "project-existing", title: "Demo", path: project.path, recordingPath: recording,
            sourceName: "Display", createdAt: "100", updatedAt: "100", lastOpenedAt: "150", missing: false)
        try JSONEncoder().encode([existing]).write(to: locations.index)

        for index in 0..<2 {
            let updated = try store.updateProject(LegacyProjectRequest(path: project.path, title: "Demo \(index)"))
            XCTAssertEqual(updated.id, "project-existing")
            XCTAssertEqual(updated.createdAt, "100")
            XCTAssertEqual(updated.lastOpenedAt, "150")
        }
        let saved = try object(at: project.path)
        XCTAssertEqual(saved["title"] as? String, "Demo 1")
        XCTAssertEqual(saved["createdAt"] as? String, "100")
        XCTAssertNotEqual(saved["updatedAt"] as? String, "100")
        XCTAssertEqual(try indexed().filter { $0.path == project.path }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.path + ".recovery"), "an indexed project is not marked")
    }

    func testUpdateKeepsAScreenshotPathAndReplacesItsState() throws {
        let shot = try media("shot.png", in: locations.screenshots)
        var original = document(title: "Shot", recordingPath: nil)
        original["screenshotPath"] = shot
        original["editorState"] = ["screenshot": ["padding": 56]]
        let project = try writeDocument("shot.openrecorder", original)

        let updated = try store.updateProject(LegacyProjectRequest(
            path: project.path, title: "Shot Edited", editorState: json(["screenshot": ["padding": 96]])))
        XCTAssertEqual(updated.screenshotPath, shot)
        XCTAssertNil(updated.recordingPath)
        XCTAssertEqual(((try object(at: project.path)["editorState"] as? [String: Any])?["screenshot"] as? [String: Any])?["padding"] as? Int, 96)
    }

    func testUpdateChangesNothingWhenTheIndexIsDamaged() throws {
        let project = try writeDocument("demo.openrecorder", document(title: "Before", recordingPath: try media("demo.mp4")))
        let before = try Data(contentsOf: project)
        try corrupt(locations.index)

        XCTAssertThrowsError(try store.updateProject(LegacyProjectRequest(path: project.path, title: "After")))
        XCTAssertEqual(try Data(contentsOf: project), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.path + ".recovery"))
    }

    func testUpdateRestoresTheDocumentWhenTheIndexCannotBeWritten() throws {
        let saved = try register("Demo")
        let project = URL(fileURLWithPath: saved.path)
        let before = try Data(contentsOf: project)
        // An immutable index can be read but not replaced.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locations.index.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locations.index.path) }

        XCTAssertThrowsError(try store.updateProject(LegacyProjectRequest(path: saved.path, title: "After")))
        XCTAssertEqual(try Data(contentsOf: project), before)
        XCTAssertEqual(try indexed().map(\.title), ["Demo"])
    }

    func testUpdateOfAnUnindexedDocumentLeavesNoMarkerWhenTheIndexCannotBeWritten() throws {
        let project = try writeDocument("loose.openrecorder", document(title: "Loose", recordingPath: try media("loose.mp4")))
        let before = try Data(contentsOf: project)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locations.index.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locations.index.path) }

        XCTAssertThrowsError(try store.updateProject(LegacyProjectRequest(path: project.path, title: "After")))
        XCTAssertEqual(try Data(contentsOf: project), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.path + ".recovery"))
    }

    func testAFailedUpdateKeepsAnExistingMarkerSoTheDocumentIsStillFound() throws {
        for blocked in ["document", "index"] {
            let project = try writeDocument("fallback-\(blocked).openrecorder",
                document(title: "Fallback \(blocked)", recordingPath: try media("fallback-\(blocked).mp4")))
            let marker = LegacyProjectLibraryStore.recoveryMarker(for: project)
            try Data().write(to: marker)
            let before = try Data(contentsOf: project)
            let target = blocked == "document" ? project.path : locations.index.path
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: target)
            XCTAssertThrowsError(try store.updateProject(LegacyProjectRequest(path: project.path, title: "After")))
            try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: target)

            XCTAssertEqual(try Data(contentsOf: project), before, blocked)
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), blocked)
            XCTAssertTrue(try store.listProjects().contains { $0.path == project.path }, blocked)
        }
    }

    func testAFailedIndexWriteRemovesTheNewDocument() throws {
        try FileManager.default.removeItem(at: locations.index)
        try FileManager.default.createDirectory(at: locations.index.appendingPathComponent("occupied"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try register("Recording"))
        let documents = try FileManager.default.contentsOfDirectory(atPath: locations.projects.path)
            .filter { $0.hasSuffix(".openrecorder") }
        XCTAssertEqual(documents, [])
    }

    func testConcurrentRegistrationsFromSeparateStoresKeepEveryEntryWithUniqueIDs() throws {
        let count = 24
        let recordings = try (0..<count).map { try media("recording-\($0).mp4") }
        let results = ResultBox(count: count)
        let locations = locations
        DispatchQueue.concurrentPerform(iterations: count) { index in
            // A store per caller, so the index lock is taken on separate file descriptions.
            let store = LegacyProjectLibraryStore(locations: locations)
            results.set(index, Result {
                try store.registerRecording(LegacyProjectRequest(path: recordings[index], title: "Recording \(index)"))
            })
        }
        let summaries = try results.values.map { try XCTUnwrap($0).get() }
        let index = try indexed()
        XCTAssertEqual(index.count, count)
        XCTAssertEqual(Set(summaries.map(\.id)).count, count)
        XCTAssertEqual(Set(index.map(\.path)).count, count)
        XCTAssertEqual(Set(index.map(\.id)), Set(summaries.map(\.id)))
    }

    // MARK: Availability

    func testAvailabilityTellsMissingProjectsFromMissingMediaAndUnusableFiles() throws {
        let recording = try media("other-media.mp4")
        let saved = try register("Recording")
        XCTAssertEqual(try store.listProjects().first?.availability, .available)

        try FileManager.default.removeItem(atPath: try XCTUnwrap(saved.recordingPath))
        XCTAssertEqual(try store.listProjects().first?.availability, .missingMedia)
        try FileManager.default.removeItem(atPath: saved.path)
        XCTAssertEqual(try store.listProjects().first?.availability, .missingProjectAndMedia)
        XCTAssertEqual(try store.listProjects().first?.missing, true)

        let corrupted = try store.saveProject(LegacyProjectRequest(title: "Corrupt", recordingPath: recording))
        try corrupt(URL(fileURLWithPath: corrupted.path))
        XCTAssertEqual(try store.listProjects().first { $0.id == corrupted.id }?.availability, .unavailable)

        let folderMedia = locations.recordings.appendingPathComponent("folder.mp4")
        try FileManager.default.createDirectory(at: folderMedia, withIntermediateDirectories: true)
        let directory = try store.saveProject(LegacyProjectRequest(title: "Folder", recordingPath: folderMedia.path))
        XCTAssertEqual(directory.availability, .unavailable)
        let noMedia = try store.saveProject(LegacyProjectRequest(title: "Nothing"))
        XCTAssertEqual(noMedia.availability, .unavailable)

        try FileManager.default.removeItem(atPath: recording)
        let missingProject = try store.saveProject(LegacyProjectRequest(title: "Gone", recordingPath: try media("kept.mp4")))
        try FileManager.default.removeItem(atPath: missingProject.path)
        XCTAssertEqual(try store.listProjects().first { $0.id == missingProject.id }?.availability, .missingProject)
    }

    // MARK: Forgetting and recovery

    func testForgettingRemovesTheEntryAndItsMarkerButKeepsTheDocument() throws {
        let saved = try register("Recording")
        let marker = saved.path + ".recovery"
        try Data().write(to: URL(fileURLWithPath: marker))
        try store.forgetProject(path: saved.path)
        XCTAssertEqual(try store.listProjects(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testForgettingChangesNothingWhenTombstonesCannotBeRead() throws {
        let saved = try register("Recording")
        try corrupt(locations.forgottenProjects)
        XCTAssertThrowsError(try store.forgetProject(path: saved.path))
        XCTAssertEqual(try indexed().map(\.id), [saved.id])
    }

    func testAnUnmarkedUnindexedDocumentIsNotAddedToAHealthyIndex() throws {
        let project = try writeDocument("intentionally-forgotten.openrecorder", document(title: "Forgotten", recordingPath: nil))
        XCTAssertEqual(try store.listProjects(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path))
    }

    func testAMarkedDocumentIsRecoveredOnceAndKeepsItsMarker() throws {
        let recording = try media("recovered.mp4")
        let project = try writeDocument("recovered-local.openrecorder",
            document(title: "Recovered Recording", recordingPath: recording, createdAt: "2026-07-11T01:00:00Z"))
        try Data().write(to: LegacyProjectLibraryStore.recoveryMarker(for: project))
        try corrupt(locations.index)

        let first = try store.listProjects()
        let second = try store.listProjects()
        XCTAssertEqual(first.map(\.title), ["Recovered Recording"])
        XCTAssertEqual(first.first?.path, project.path)
        XCTAssertEqual(first.first?.id, "project-recovered-recovered-local")
        XCTAssertEqual(first.first?.availability, .available)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(try indexed().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path + ".recovery"))
    }

    func testAMarkedDocumentIsNotDuplicatedWhenIndexedThroughAnotherSpellingOfItsPath() throws {
        let saved = try register("Recording")
        try Data().write(to: URL(fileURLWithPath: saved.path + ".recovery"))
        var entries = try indexed()
        entries[0].path = locations.projects.appendingPathComponent("../Projects")
            .appendingPathComponent(URL(fileURLWithPath: saved.path).lastPathComponent).path
        try JSONEncoder().encode(entries).write(to: locations.index)
        XCTAssertEqual(try store.listProjects().count, 1)
    }

    func testAReadoptedForgottenDocumentIsMarkedAndSurvivesALostIndex() throws {
        let project = try writeDocument("readopted.openrecorder", document(title: "Readopted", recordingPath: try media("r.mp4")))
        try JSONSerialization.data(withJSONObject: [LegacyProjectLibraryStore.identity(project)])
            .write(to: locations.forgottenProjects)
        _ = try store.updateProject(LegacyProjectRequest(path: project.path, title: "Readopted Again"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path + ".recovery"))
        try corrupt(locations.index)
        try corrupt(locations.indexBackup)

        XCTAssertEqual(try store.listProjects().map(\.title), ["Readopted Again"])
    }

    func testSalvageWithoutAnyIndexHonoursTombstones() throws {
        let kept = try register("Kept")
        let forgotten = try register("Forgotten")
        try Data().write(to: URL(fileURLWithPath: forgotten.path + ".recovery"))
        try store.forgetProject(path: forgotten.path)
        try corrupt(locations.index)
        try corrupt(locations.indexBackup)

        let salvaged = try store.listProjects()
        XCTAssertEqual(salvaged.map(\.path), [kept.path])
        XCTAssertEqual(salvaged.first?.id, "project-recovered-\(URL(fileURLWithPath: kept.path).deletingPathExtension().lastPathComponent)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: forgotten.path))
        XCTAssertEqual(try indexed().map(\.path), [kept.path])
    }

    func testAOnlyForgottenLibrarySalvagesToAnEmptyIndex() throws {
        let forgotten = try register("Forgotten")
        try store.forgetProject(path: forgotten.path)
        try corrupt(locations.index)
        try corrupt(locations.indexBackup)
        XCTAssertEqual(try store.listProjects(), [])
        XCTAssertEqual(try indexed(), [])
    }

    func testAStaleBackupIsCompletedFromDocumentsAndDoesNotBringBackForgottenProjects() throws {
        let staleEmpty = try Data(contentsOf: locations.indexBackup)
        let added = try register("Added")
        try staleEmpty.write(to: locations.indexBackup)
        try corrupt(locations.index)
        XCTAssertEqual(try store.listProjects().map(\.path), [added.path])

        let staleWithAdded = try Data(contentsOf: locations.indexBackup)
        try store.forgetProject(path: added.path)
        try staleWithAdded.write(to: locations.indexBackup)
        try corrupt(locations.index)
        XCTAssertEqual(try store.listProjects(), [])
        XCTAssertEqual(try indexed(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: added.path))
    }

    func testACorruptIndexIsRepairedFromAFreshBackupKeepingIDs() throws {
        let saved = try register("Recording")
        try FileManager.default.removeItem(at: locations.indexBackup)
        XCTAssertEqual(try store.listProjects().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations.indexBackup.path), "listing refreshes the backup")
        try corrupt(locations.index)

        XCTAssertEqual(try store.listProjects().map(\.id), [saved.id])
        XCTAssertEqual(try indexed().map(\.id), [saved.id])
    }

    func testAnIndexRemovedFromAnExistingLibraryIsRecoveredNotReplacedWithAnEmptyOne() throws {
        let saved = try register("Recording")
        try FileManager.default.removeItem(at: locations.index)
        XCTAssertThrowsError(try register("Blocked"), "a change waits for recovery")
        XCTAssertEqual(try store.listProjects().map(\.id), [saved.id])
        let next = try register("After")
        XCTAssertEqual(try indexed().map(\.id), [next.id, saved.id])
    }

    func testAnUnreadableIndexWithNothingToRecoverIsAnError() throws {
        try corrupt(locations.index)
        XCTAssertEqual(try store.listProjects(), [], "the empty backup is a recovery")
        try corrupt(locations.index)
        try FileManager.default.removeItem(at: locations.indexBackup)
        XCTAssertThrowsError(try store.listProjects())
    }

    func testIndexEntriesWithoutAvailabilityStillDecode() throws {
        let data = Data("""
            [{"id":"project-legacy","title":"Legacy","path":"/tmp/legacy.openrecorder","recordingPath":"/tmp/legacy.mp4",
              "screenshotPath":null,"sourceName":null,"createdAt":"100","updatedAt":"100","lastOpenedAt":"100","missing":true}]
            """.utf8)
        try data.write(to: locations.index)
        let listed = try store.listProjects()
        XCTAssertEqual(listed.map(\.id), ["project-legacy"])
        XCTAssertEqual(listed.first?.availability, .missingProjectAndMedia)
    }

    // MARK: Screenshots

    func testAScreenshotProjectIsRememberedAndKeepsItsState() throws {
        let shot = try media("shot.png", in: locations.screenshots)
        let summary = try store.registerScreenshot(LegacyProjectRequest(
            path: shot, sourceName: "Display 1", editorState: json(["screenshot": ["padding": 72]])))
        XCTAssertNil(summary.recordingPath)
        XCTAssertEqual(summary.screenshotPath, shot)
        XCTAssertEqual(summary.title, "shot")
        let saved = try object(at: summary.path)
        XCTAssertEqual(saved["screenshotPath"] as? String, shot)
        XCTAssertEqual(((saved["editorState"] as? [String: Any])?["screenshot"] as? [String: Any])?["padding"] as? Int, 72)
        XCTAssertEqual(try store.recentScreenshots().first?.path, shot)

        let defaulted = try store.registerScreenshot(LegacyProjectRequest(path: try media("other.png", in: locations.screenshots)))
        XCTAssertNotNil((try object(at: defaulted.path)["editorState"] as? [String: Any])?["screenshot"])
    }

    func testRecentScreenshotsReadNewestFirstWithStableIDsAndSkipEntriesWithoutPaths() throws {
        XCTAssertEqual(try store.recentScreenshots(), [])
        try json([
            ["createdAt": "200"],
            ["path": "/tmp/older shot.png", "createdAt": "9"],
            ["path": "/tmp/newer:shot.png", "createdAt": "10"],
        ]).write(to: locations.screenshotIndex)
        let recent = try store.recentScreenshots()
        XCTAssertEqual(recent.map(\.path), ["/tmp/newer:shot.png", "/tmp/older shot.png"])
        XCTAssertEqual(recent.map(\.id), ["screenshot-10-tmp-newer-shot.png", "screenshot-9-tmp-older-shot.png"])
    }

    func testTheRecentScreenshotListKeepsTheLatestHundred() throws {
        for index in 0..<105 { try store.rememberScreenshot(path: "/tmp/shot-\(index).png") }
        let recent = try store.recentScreenshots()
        XCTAssertEqual(recent.count, 100)
        XCTAssertEqual(recent.first?.path, "/tmp/shot-104.png")
        XCTAssertEqual(recent.last?.path, "/tmp/shot-5.png")
        try store.rememberScreenshot(path: "/tmp/shot-50.png")
        XCTAssertEqual(try store.recentScreenshots().first?.path, "/tmp/shot-50.png")
        XCTAssertEqual(try store.recentScreenshots().filter { $0.path == "/tmp/shot-50.png" }.count, 1)
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Result<ProjectSummary, Error>?]

    init(count: Int) { storage = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ value: Result<ProjectSummary, Error>) { lock.withLock { storage[index] = value } }
    var values: [Result<ProjectSummary, Error>?] { lock.withLock { storage } }
}
