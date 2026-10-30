import Foundation
import XCTest
@testable import RecordMac

/// AppModel's default storage closures, run against a native legacy library in temporary
/// folders.
@MainActor
final class AppModelNativeLibraryTests: XCTestCase {
    private var root: URL!
    private var library: LegacyProjectLibraryStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("app-library-\(UUID().uuidString)")
        library = LegacyProjectLibraryStore(locations: .forHome(root, storageDirectoryName: "Record Mac"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel(screenshotCapture: (@MainActor (CaptureSource, URL) throws -> Void)? = nil) -> AppModel {
        AppModel(
            screenRecordingPermission: ScreenRecordingPermission(client: ScreenRecordingPermissionClient(
                preflight: { true }, request: { true }, hasRequestedPrompt: { false }, setRequestedPrompt: { _ in })),
            captureUIHideDelayNanoseconds: 0,
            screenshotCapture: screenshotCapture,
            library: library)
    }

    private func media(_ name: String, in folder: String) throws -> URL {
        let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
        try Data("media".utf8).write(to: url)
        return url
    }

    func testRefreshLoadsPathsProjectsAndNativeHealthFromTheLibrary() async throws {
        let paths = try library.paths()
        let saved = try library.registerRecording(LegacyProjectRequest(
            path: try media("demo.mov", in: paths.recordingsDir).path, sourceName: "Display"))
        let model = makeModel()

        let refreshed = await model.refreshBackendState().value

        XCTAssertTrue(refreshed)
        XCTAssertEqual(model.paths, paths)
        XCTAssertEqual(model.projects.map(\.id), [saved.id])
        XCTAssertEqual(model.serviceHealth?.service, "Record Mac library")
        XCTAssertEqual(model.statusMessage, HealthPayload.readyMessage)
        XCTAssertTrue(paths.supportDir.hasPrefix(root.path), "the injected library, not the user's")
    }

    func testRefreshReportsADamagedLibraryAsAFailure() async throws {
        _ = try library.paths()
        try Data("corrupt".utf8).write(to: library.locations.index)
        try FileManager.default.removeItem(at: library.locations.indexBackup)
        let model = makeModel()

        let refreshed = await model.refreshBackendState().value

        XCTAssertFalse(refreshed)
        XCTAssertNotEqual(model.statusMessage, HealthPayload.readyMessage)
        XCTAssertTrue(model.statusMessage.contains("project index is unavailable"), model.statusMessage)
    }

    func testAScreenshotIsRegisteredAndRememberedInTheLibrary() async throws {
        let model = makeModel(screenshotCapture: { _, outputURL in
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("png".utf8).write(to: outputURL)
        })
        _ = await model.refreshBackendState().value
        let source = CaptureSource(id: "display:1", kind: .display, name: "Display 1", subtitle: "Built-in",
            displayIndex: 1, displayID: nil, windowID: nil, area: nil, thumbnailData: nil)
        model.setCaptureStateForTesting(HUDState(phase: .ready(.screenshot, source), presentation: .visible))

        model.takeScreenshot()
        await waitUntil { (try? self.library.listProjects().count) == 1 && (try? self.library.recentScreenshots().count) == 1 }

        let project = try XCTUnwrap(library.listProjects().first)
        let screenshot = try XCTUnwrap(project.screenshotPath)
        XCTAssertTrue(screenshot.hasPrefix(try library.paths().screenshotsDir))
        XCTAssertEqual(project.availability, .available)
        XCTAssertEqual(try library.recentScreenshots().first?.path, screenshot)
        let document = try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: URL(fileURLWithPath: project.path)))
        XCTAssertNotNil(document.editorState?.screenshot)
        await waitUntil { model.projects.contains { $0.id == project.id } }
    }

    func testImportingTheSameMediaTwiceMakesOneProjectEvenFromAFreshModel() async throws {
        let paths = try library.paths()
        let video = try media("clip.mov", in: paths.recordingsDir)
        let first = makeModel()
        await first.openEditorFile(at: video)?.value
        XCTAssertEqual(try library.listProjects().count, 1)

        let second = makeModel()
        XCTAssertEqual(second.projects, [])
        await second.openEditorFile(at: video)?.value

        let projects = try library.listProjects()
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.sourceName, "Imported Recording")
        XCTAssertEqual(projects.first?.title, "clip")
        let document = try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(projects.first).path)))
        XCTAssertNotNil(document.editorState, "the imported editor state is stored")
    }

    func testAutosaveUpdatesTheDocumentAndKeepsItsIdentity() async throws {
        let paths = try library.paths()
        let video = try media("demo.mov", in: paths.recordingsDir)
        let saved = try library.registerRecording(LegacyProjectRequest(path: video.path, sourceName: "Display"))
        let model = makeModel()

        let updated = try await model.autosaveProject(ProjectAutosaveSnapshot(
            projectPath: saved.path, title: "Demo Edited", recordingPath: video.path, screenshotPath: nil,
            sourceName: "Display", editorState: .empty, recordingSession: nil))

        XCTAssertEqual(updated.id, saved.id)
        XCTAssertEqual(updated.createdAt, saved.createdAt)
        XCTAssertEqual(updated.title, "Demo Edited")
        let document = try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: URL(fileURLWithPath: saved.path)))
        XCTAssertEqual(document.title, "Demo Edited")
        XCTAssertEqual(document.editorState, .empty)
        XCTAssertEqual(try library.listProjects().map(\.title), ["Demo Edited"])
    }

    func testAFailedImportBeforePathsLoadIsRecoveredIntoTheInjectedLibrary() async throws {
        let paths = try library.paths()
        let video = try media("unregistered.mov", in: paths.recordingsDir)
        let model = AppModel(registerImportedMedia: { _, _, _ in throw CocoaError(.fileWriteUnknown) }, library: library)
        XCTAssertNil(model.paths)

        await model.openEditorFile(at: video)?.value

        let projectPath = try XCTUnwrap(model.windowCommand?.editorSession?.projectPath)
        let projects = library.locations.projects.resolvingSymlinksInPath().path + "/"
        XCTAssertTrue(URL(fileURLWithPath: projectPath).resolvingSymlinksInPath().path.hasPrefix(projects), projectPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectPath + ".recovery"))
        XCTAssertEqual(try library.listProjects().map(\.recordingPath), [video.resolvingSymlinksInPath().standardizedFileURL.path])
    }

    func testTheDefaultLibraryInATestProcessIsATemporaryFolder() {
        let first = LegacyProjectLibraryStore.standard().locations.support.path
        let second = LegacyProjectLibraryStore.standard().locations.support.path
        XCTAssertTrue(first.hasPrefix(FileManager.default.temporaryDirectory.path), first)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.hasPrefix(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library").path))
    }

    private func waitUntil(timeout: Duration = .seconds(5), file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @escaping @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline { try? await clock.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }
}
