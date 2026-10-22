import XCTest
@testable import RecordMac

final class ProjectMigrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try makeProjectTestDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Historical versions

    /// Format version 1 as written to disk, frozen here so a change to the current types that
    /// would stop version 1 projects opening fails this test.
    private static let version1Manifest = """
        {
          "captureClock" : { "epochHostTimeNanoseconds" : 1000 },
          "createdAt" : 1790000000,
          "displayName" : "Version 1",
          "endReason" : "completed",
          "formatVersion" : 1,
          "frameReport" : { "appendRejected" : 0, "delivered" : 300, "writerFailed" : 0, "written" : 300 },
          "id" : "0D6C0E2A-7C9B-4E0B-8F7E-3C1C2B9A4D55",
          "mediaTracks" : [
            {
              "kind" : "screen",
              "requestedFrameRate" : 60,
              "segments" : [
                {
                  "deviceID" : "display-1",
                  "end" : 5,
                  "fileRef" : "media/screen-1.mov",
                  "frameRate" : 60,
                  "hasAlpha" : false,
                  "nativeSize" : { "height" : 1117, "width" : 1728 },
                  "start" : 0
                }
              ]
            }
          ],
          "overlaidRanges" : [],
          "pauses" : [],
          "sourceDescription" : "Display 1"
        }
        """

    private static let version1Edit = """
        {
          "audioLevels" : [],
          "cameraPlacements" : [],
          "clips" : [
            { "id" : "4C1F2B6A-1E2D-4F3A-9B8C-7D6E5F4A3B2C", "order" : 0, "sourceRange" : { "end" : 5, "start" : 0 }, "speed" : 1 }
          ],
          "overlays" : [],
          "presentation" : PRESENTATION,
          "undoHistory" : { "redoStack" : [], "undoStack" : [] },
          "zoomMoves" : []
        }
        """

    private func writeVersion1Project() throws -> ProjectStore {
        let store = try ProjectStore.create(named: "Version 1", in: root)
        try Data(Self.version1Manifest.utf8).write(to: store.projectURL)
        let presentation = try String(
            data: ProjectStore.makeEncoder().encode(PresentationSettings.default), encoding: .utf8)!
        try Data(Self.version1Edit.replacingOccurrences(of: "PRESENTATION", with: presentation).utf8)
            .write(to: store.editURL)
        return store
    }

    func testVersion1ProjectOpensAtCurrentVersion() throws {
        let store = try writeVersion1Project()

        let opened = try ProjectMigrator.standard.open(store)

        XCTAssertEqual(opened.project.formatVersion, RecordingProject.currentFormatVersion)
        XCTAssertEqual(opened.project.displayName, "Version 1")
        XCTAssertEqual(opened.project.track(.screen)?.segments.first?.fileRef, "media/screen-1.mov")
        XCTAssertEqual(opened.edit.editedDuration, 5)
    }

    func testNewerFormatIsRefusedWithoutPartialRead() throws {
        let store = try writeVersion1Project()
        let manifest = Self.version1Manifest.replacingOccurrences(of: "\"formatVersion\" : 1", with: "\"formatVersion\" : 99")
        try Data(manifest.utf8).write(to: store.projectURL)
        let before = try Data(contentsOf: store.projectURL)

        XCTAssertThrowsError(try ProjectMigrator.standard.open(store)) {
            XCTAssertEqual($0 as? ProjectMigrationError, .newerFormat(found: 99, supported: RecordingProject.currentFormatVersion))
        }
        XCTAssertEqual(try Data(contentsOf: store.projectURL), before)
    }

    func testMissingMigrationIsReported() throws {
        let store = try writeVersion1Project()
        let migrator = ProjectMigrator(currentVersion: 2, migrations: [])
        XCTAssertThrowsError(try migrator.open(store)) {
            XCTAssertEqual($0 as? ProjectMigrationError, .noMigration(from: 1))
        }
    }

    // MARK: Migration commit

    /// A version 1 → 2 migration that changes both files in a way that shows whether it ran
    /// exactly once.
    private static func versionTwoMigrator() -> ProjectMigrator {
        ProjectMigrator(
            currentVersion: 2,
            migrations: [
                ProjectMigration(fromVersion: 1) { project, edit in
                    project["displayName"] = "\(project["displayName"] as? String ?? "") migrated"
                    var clips = edit["clips"] as? [[String: Any]] ?? []
                    clips.append([
                        "id": "9A8B7C6D-5E4F-4A3B-8C2D-1E0F9A8B7C6D", "order": clips.count,
                        "sourceRange": ["start": 0, "end": 1], "speed": 1,
                    ])
                    edit["clips"] = clips
                }
            ])
    }

    private func assertMigratedOnce(_ store: ProjectStore, file: StaticString = #filePath, line: UInt = #line) throws {
        let opened = try Self.versionTwoMigrator().open(store)
        XCTAssertEqual(opened.project.formatVersion, 2, file: file, line: line)
        XCTAssertEqual(opened.project.displayName, "Version 1 migrated", file: file, line: line)
        XCTAssertEqual(opened.edit.clips.count, 2, file: file, line: line)
        let fileManager = FileManager.default
        XCTAssertFalse(fileManager.fileExists(atPath: ProjectMigrator.markerURL(store).path), file: file, line: line)
        XCTAssertFalse(fileManager.fileExists(atPath: ProjectMigrator.backupURL(store.editURL).path), file: file, line: line)
        XCTAssertFalse(fileManager.fileExists(atPath: ProjectMigrator.backupURL(store.projectURL).path), file: file, line: line)
    }

    func testMigrationRunsAndCleansUp() throws {
        let store = try writeVersion1Project()
        try assertMigratedOnce(store)
        // Reopening an already migrated project changes nothing.
        try assertMigratedOnce(store)
    }

    func testInterruptionAfterEachStepRecoversToTarget() throws {
        for step in ProjectMigrationStep.allCases {
            let store = try writeVersion1Project()
            var interrupted = Self.versionTwoMigrator()
            interrupted.afterStep = { if $0 == step { throw SimulatedInterruption() } }

            XCTAssertThrowsError(try interrupted.open(store), "\(step)")
            try assertMigratedOnce(store)
            try FileManager.default.removeItem(at: store.directory)
        }
    }

    func testInterruptionBetweenTheTwoFileReplacementsNeverMixesVersions() throws {
        let store = try writeVersion1Project()
        var interrupted = Self.versionTwoMigrator()
        interrupted.afterStep = { if $0 == .editWritten { throw SimulatedInterruption() } }
        XCTAssertThrowsError(try interrupted.open(store))

        // On disk: a migrated edit.json beside a version 1 project.json, with the marker present.
        XCTAssertTrue(FileManager.default.fileExists(atPath: ProjectMigrator.markerURL(store).path))
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: store.projectURL)) as? [String: Any]
        XCTAssertEqual(manifest?["formatVersion"] as? Int, 1)

        try assertMigratedOnce(store)
    }

    func testInterruptedFileWritesDuringCommitRecover() throws {
        // Interrupt inside each atomic write of the commit, before its rename.
        for target in ["edit.json.bak", "project.json.bak", "migration.json", "edit.json", "project.json"] {
            var store = try writeVersion1Project()
            store.beforeReplace = { if $0.lastPathComponent == target { throw SimulatedInterruption() } }
            XCTAssertThrowsError(try Self.versionTwoMigrator().open(store), target)

            store.beforeReplace = nil
            try assertMigratedOnce(store)
            try FileManager.default.removeItem(at: store.directory)
        }
    }
}
