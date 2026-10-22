import XCTest
@testable import RecordMac

final class AutosaveAtomicityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try makeProjectTestDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func leftoverTemporaryFiles(in store: ProjectStore) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.directory.path).filter { $0.hasSuffix(".tmp") }
    }

    func testInterruptedEditWriteLeavesPreviousEditIntact() throws {
        var store = try makeStoredFixtureProject(in: root)
        let before = try Data(contentsOf: store.editURL)
        var changed = try store.readEdit()
        changed.clips[0].speed = 2

        store.beforeReplace = { _ in throw SimulatedInterruption() }
        XCTAssertThrowsError(try store.writeEdit(changed))

        XCTAssertEqual(try Data(contentsOf: store.editURL), before)
        XCTAssertEqual(try store.readEdit().clips[0].speed, 1)
        XCTAssertEqual(try leftoverTemporaryFiles(in: store), [])
    }

    func testInterruptedManifestWriteLeavesPreviousManifestIntact() throws {
        var store = try makeStoredFixtureProject(in: root)
        let before = try Data(contentsOf: store.projectURL)

        store.beforeReplace = { _ in throw SimulatedInterruption() }
        XCTAssertThrowsError(try store.rename(to: "Renamed"))

        XCTAssertEqual(try Data(contentsOf: store.projectURL), before)
        XCTAssertEqual(try store.readProject().displayName, "Fixture")
        XCTAssertEqual(try leftoverTemporaryFiles(in: store), [])
    }

    func testCompletedWriteReplacesTheFile() throws {
        let store = try makeStoredFixtureProject(in: root)
        var changed = try store.readEdit()
        changed.clips[0].speed = 1.5
        try store.writeEdit(changed)
        XCTAssertEqual(try store.readEdit().clips[0].speed, 1.5)
        XCTAssertEqual(try leftoverTemporaryFiles(in: store), [])
    }
}
