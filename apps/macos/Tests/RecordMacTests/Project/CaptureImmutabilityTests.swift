import CoreGraphics
import CryptoKit
import XCTest
@testable import RecordMac

/// Principle I and FR-050: editing never modifies the stored capture.
final class CaptureImmutabilityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try makeProjectTestDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func captureHashes(_ store: ProjectStore) throws -> [String: String] {
        let fileManager = FileManager.default
        var files = try fileManager.contentsOfDirectory(atPath: store.mediaDirectory.path)
            .map { "media/\($0)" }
        files.append(ProjectStore.activityFileName)
        var hashes: [String: String] = [:]
        for file in files {
            let digest = SHA256.hash(data: try Data(contentsOf: store.url(forFileReference: file)))
            hashes[file] = digest.map { String(format: "%02x", $0) }.joined()
        }
        return hashes
    }

    func testFullEditingSessionLeavesMediaAndActivityUnchanged() throws {
        let store = try makeStoredFixtureProject(in: root)
        let before = try captureHashes(store)
        XCTAssertEqual(before.count, 7)

        var document = try store.readEdit()
        for step in 0..<50 {
            document.undoHistory.undoStack.append(document.state)
            document.clips = [
                Clip(sourceRange: CaptureTimeRange(start: 0, end: 4), speed: 1 + Double(step % 3) / 2, order: 0),
                Clip(sourceRange: CaptureTimeRange(start: 5.5, end: 10), order: 1),
            ]
            document.zoomMoves.append(
                ZoomMove(
                    timeRange: CaptureTimeRange(start: Double(step) / 10, end: Double(step) / 10 + 1),
                    focus: CGPoint(x: 0.5, y: 0.5), depth: 2, origin: .manual))
            document.presentation.cornerRadius = Double(step)
            document.presentation.motionBlur = Double(step % 2)
            try store.writeEdit(document)
        }
        try store.rename(to: "Renamed after editing")
        XCTAssertNoThrow(try store.writeEdit(document))

        XCTAssertEqual(try captureHashes(store), before)
        XCTAssertEqual(try store.readProject().displayName, "Renamed after editing")
    }

    func testActivityIsWriteOnce() throws {
        let store = try makeStoredFixtureProject(in: root)
        let before = try captureHashes(store)
        XCTAssertThrowsError(try store.writeActivity(makeFixtureActivity())) {
            XCTAssertEqual($0 as? ProjectStoreError, .writeOnceFileExists(store.activityURL))
        }
        XCTAssertEqual(try captureHashes(store), before)
    }
}
