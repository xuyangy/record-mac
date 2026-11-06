import CoreGraphics
import CryptoKit
import XCTest
@testable import RecordMac

/// `ProjectWriter` on stand-in capture files in a temporary directory: no capture, encoder, or
/// real media. Files are compared by their bytes' SHA-256.
final class ProjectWriterTests: XCTestCase {
    private var root: URL!
    private var capture: URL!
    private var parent: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("project-writer-\(UUID().uuidString)")
        capture = root.appendingPathComponent("capture")
        parent = root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func put(_ name: String, _ bytes: [UInt8]) throws {
        try Data(bytes).write(to: capture.appendingPathComponent(name))
    }

    private func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private let draft = ProjectDraft(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!, displayName: "Demo",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        captureClock: CaptureClockReference(epochHostTimeNanoseconds: 1_000_000_000_000),
        pauses: [CaptureTimeRange(start: 1, end: 1)], endReason: .completed, overlaidRanges: [],
        frameReport: FrameReport(delivered: 3, appendRejected: 0, writerFailed: 0, written: 3),
        sourceDescription: "Display 1")

    private func video(_ ref: String, _ start: Double, _ end: Double, width: Int = 256) -> MediaSegment {
        MediaSegment(fileRef: ref, start: start, end: end, deviceID: "display:1",
            nativeSize: PixelSize(width: width, height: 144), frameRate: 60, hasAlpha: false)
    }

    /// Two screen segments, as the backend names them, and a system-audio file.
    private func tracks() throws -> [MediaTrack] {
        try put("screen-0.mov", [1, 2, 3, 4])
        try put("screen-1.mov", [5, 6, 7])
        try put("systemAudio.mov", [8, 9])
        return [
            MediaTrack(kind: .screen, segments: [video("screen-0.mov", 0, 1), video("screen-1.mov", 1, 2.5, width: 512)],
                requestedFrameRate: 60),
            MediaTrack(kind: .systemAudio, segments: [MediaSegment(fileRef: "systemAudio.mov", start: 0, end: 2.5, deviceID: "system-audio")]),
        ]
    }

    private let stream = ActivityStream(
        events: [ActivityEvent(timestamp: 0.5, kind: .pointerMove, location: CGPoint(x: 20, y: 40))],
        geometry: [GeometrySegment(start: 0, sourceRect: CGRect(x: 0, y: 0, width: 256, height: 144),
            pixelSize: PixelSize(width: 256, height: 144), scaleFactor: 1)])

    private func recorded() -> BackendTelemetryReport {
        var report = BackendTelemetryReport()
        report.take(TelemetryOutcome(stream: stream, activity: .idle, counts: TelemetryRecorderCounts(),
            geometry: GeometryFeedCounts(), coverage: nil), endingAt: 10)
        return report
    }

    private func write(
        _ tracks: [MediaTrack], telemetry: BackendTelemetryReport? = nil, beforeStep: (ProjectWriter.Step) throws -> Void = { _ in }
    ) throws -> ProjectWriteResult {
        try ProjectWriter.write(named: "Demo", in: parent, draft: draft, tracks: tracks, captureDirectory: capture,
            telemetry: telemetry ?? recorded(), beforeStep: beforeStep)
    }

    /// Everything in `parent`, hidden entries included.
    private func listing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted()
    }

    private func captureHashes() throws -> [String: String] {
        var hashes: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: capture.path) {
            hashes[name] = try hash(capture.appendingPathComponent(name))
        }
        return hashes
    }

    // MARK: Writing

    func testItWritesAProjectThatReadsBack() throws {
        let tracks = try tracks()
        let before = try captureHashes()
        let result = try write(tracks)

        XCTAssertEqual(result.store.directory.lastPathComponent, "Demo.recordmac")
        XCTAssertEqual(try listing(), ["Demo.recordmac"], "no staging left behind")
        let project = try result.store.readProject()
        XCTAssertEqual(project, result.project)
        XCTAssertEqual(project.id, draft.id)
        XCTAssertEqual(project.pauses, draft.pauses)
        XCTAssertEqual(project.frameReport, draft.frameReport)
        XCTAssertEqual(project.endReason, .completed)
        XCTAssertEqual(project.mediaTracks.map { $0.segments.map(\.fileRef) },
            [["media/screen-1.mov", "media/screen-2.mov"], ["media/system-1.mov"]], "the container is kept")
        XCTAssertEqual(project.track(.screen)?.segments.map(\.nativeSize), tracks[0].segments.map(\.nativeSize))
        XCTAssertEqual(try result.store.readActivity(), stream)
        let edit = try result.store.readEdit()
        XCTAssertEqual(edit.clips.map(\.sourceRange), [CaptureTimeRange(start: 0, end: 2.5)], "the default document")
        XCTAssertTrue(edit.zoomMoves.isEmpty)

        for (track, original) in zip(project.mediaTracks, tracks) {
            for (segment, source) in zip(track.segments, original.segments) {
                XCTAssertEqual(try hash(result.store.url(forFileReference: segment.fileRef)),
                    before[source.fileRef], segment.fileRef)
            }
        }
        XCTAssertEqual(try captureHashes(), before, "the capture files are kept as they were")
    }

    // MARK: Refusals before any write

    func testEveryTelemetryStatusButRecordedIsRefusedBeforeAnyWrite() throws {
        let tracks = try tracks()
        var withoutOutcome = BackendTelemetryReport()
        withoutOutcome.status = .recorded
        var incomplete = recorded()
        incomplete.status = .incomplete([.frameSizeChanged(prepared: PixelSize(width: 256, height: 144), seen: [PixelSize(width: 512, height: 144)])])
        let statuses: [BackendTelemetryReport.Status] = [.notStarted, .disabled, .running, .failed("stop")]
        var reports = statuses.map { status -> BackendTelemetryReport in
            var report = BackendTelemetryReport()
            report.status = status
            return report
        }
        reports += [incomplete, withoutOutcome]
        for report in reports {
            XCTAssertThrowsError(try write(tracks, telemetry: report)) {
                XCTAssertEqual($0 as? ProjectWriterError, .telemetryNotRecorded(report.status))
            }
        }
        XCTAssertEqual(try listing(), [])
    }

    func testMissingInvalidOrRepeatedMediaIsRefusedBeforeAnyWrite() throws {
        var tracks = try tracks()
        try FileManager.default.removeItem(at: capture.appendingPathComponent("screen-1.mov"))
        XCTAssertThrowsError(try write(tracks)) { XCTAssertEqual($0 as? ProjectWriterError, .missingMedia("screen-1.mov")) }

        try put("screen-1.mov", [5, 6, 7])
        tracks[1].segments[0].fileRef = "../outside.mov"
        XCTAssertThrowsError(try write(tracks)) { XCTAssertEqual($0 as? ProjectWriterError, .invalidMediaReference("../outside.mov")) }

        tracks[1].segments[0].fileRef = "screen-0.mov"
        XCTAssertThrowsError(try write(tracks)) { XCTAssertEqual($0 as? ProjectWriterError, .duplicateMedia("screen-0.mov")) }

        try FileManager.default.createDirectory(at: capture.appendingPathComponent("folder.mov"), withIntermediateDirectories: false)
        tracks[1].segments[0].fileRef = "folder.mov"
        XCTAssertThrowsError(try write(tracks)) { XCTAssertEqual($0 as? ProjectWriterError, .missingMedia("folder.mov")) }
        XCTAssertEqual(try listing(), [])
    }

    /// A file reached through a linked folder that points outside the capture directory, a named
    /// pipe, and a link as the file itself are refused; nothing is written and the outside file is
    /// unchanged.
    func testMediaOutsideTheCaptureOrNotARegularFileIsRefused() throws {
        var tracks = try tracks()
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try Data([7, 7]).write(to: outside.appendingPathComponent("outside.mov"))
        try FileManager.default.createSymbolicLink(at: capture.appendingPathComponent("linked"), withDestinationURL: outside)
        tracks[1].segments[0].fileRef = "linked/outside.mov"
        XCTAssertThrowsError(try write(tracks)) {
            XCTAssertEqual($0 as? ProjectWriterError, .mediaOutsideCapture("linked/outside.mov"))
        }

        XCTAssertEqual(mkfifo(capture.appendingPathComponent("pipe.mov").path, 0o600), 0)
        tracks[1].segments[0].fileRef = "pipe.mov"
        XCTAssertThrowsError(try write(tracks)) { XCTAssertEqual($0 as? ProjectWriterError, .missingMedia("pipe.mov")) }

        try FileManager.default.createSymbolicLink(at: capture.appendingPathComponent("alias.mov"),
            withDestinationURL: capture.appendingPathComponent("systemAudio.mov"))
        tracks[1].segments[0].fileRef = "alias.mov"
        XCTAssertThrowsError(try write(tracks)) { XCTAssertEqual($0 as? ProjectWriterError, .missingMedia("alias.mov")) }

        XCTAssertEqual(try listing(), [])
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("outside.mov")), Data([7, 7]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["outside.mov"])
    }

    /// A name that is not one visible file name is refused before anything is written, in `parent`
    /// or around it.
    func testANameThatIsNotOneFileNameIsRefused() throws {
        let tracks = try tracks()
        let around = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        for name in ["", "/tmp/Demo", "nested/Demo", "..", "../Demo", ".hidden", "a\0b"] {
            XCTAssertThrowsError(try ProjectWriter.write(named: name, in: parent, draft: draft, tracks: tracks,
                captureDirectory: capture, telemetry: recorded())) {
                XCTAssertEqual($0 as? ProjectWriterError, .invalidName(name))
            }
        }
        XCTAssertEqual(try listing(), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), around)
    }

    /// The name on disk and the manifest's display name are separate.
    func testTheDisplayNameIsNotTheFileName() throws {
        var draft = draft
        draft.displayName = "Q3 / review"
        let result = try ProjectWriter.write(named: "Q3 review", in: parent, draft: draft, tracks: try tracks(),
            captureDirectory: capture, telemetry: recorded())
        XCTAssertEqual(result.store.directory.lastPathComponent, "Q3 review.recordmac")
        XCTAssertEqual(try result.store.readProject().displayName, "Q3 / review")
    }

    func testAnInvalidManifestIsRefusedBeforeAnyWrite() throws {
        var tracks = try tracks()
        tracks[0].segments[0].nativeSize = nil
        XCTAssertThrowsError(try write(tracks)) {
            XCTAssertEqual($0 as? ProjectValidationError, .missingVideoFields(.screen))
        }
        XCTAssertEqual(try listing(), [])
    }

    /// An existing project of that name is refused and left exactly as it was.
    func testAnExistingProjectIsRefusedAndUntouched() throws {
        let tracks = try tracks()
        let existing = parent.appendingPathComponent("Demo.recordmac")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        try Data([42]).write(to: existing.appendingPathComponent("keep"))
        XCTAssertThrowsError(try write(tracks)) {
            guard case .alreadyExists(let url) = $0 as? ProjectWriterError else { return XCTFail("\($0)") }
            XCTAssertEqual(url.standardizedFileURL.path, existing.standardizedFileURL.path)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: existing.path), ["keep"])
        XCTAssertEqual(try Data(contentsOf: existing.appendingPathComponent("keep")), Data([42]))
        XCTAssertEqual(try listing(), ["Demo.recordmac"])
    }

    // MARK: Failures while writing

    /// A failure at any step leaves no project and no staging, and the capture files as they were.
    func testAFailureAtAnyStepLeavesNothingAndKeepsTheCapture() throws {
        struct Interrupted: Error {}
        let tracks = try tracks()
        let before = try captureHashes()
        for step in [ProjectWriter.Step.media, .activity, .edit, .manifest, .publish] {
            XCTAssertThrowsError(try write(tracks) { if $0 == step { throw Interrupted() } }, "\(step)") {
                XCTAssertTrue($0 is Interrupted)
            }
            XCTAssertEqual(try listing(), [], "\(step)")
        }
        XCTAssertEqual(try captureHashes(), before)
    }

    /// A project appearing at the destination after the checks is never replaced: the publish
    /// fails, the staging is removed, and that project is untouched.
    func testAProjectAppearingBeforePublishIsNotReplaced() throws {
        let tracks = try tracks()
        let existing = parent.appendingPathComponent("Demo.recordmac")
        XCTAssertThrowsError(try write(tracks) { step in
            guard step == .publish else { return }
            try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
            try Data([42]).write(to: existing.appendingPathComponent("keep"))
        }) {
            guard case .cannotPublish(let url, _) = $0 as? ProjectWriterError else { return XCTFail("\($0)") }
            XCTAssertEqual(url.standardizedFileURL.path, existing.standardizedFileURL.path)
        }
        XCTAssertEqual(try listing(), ["Demo.recordmac"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: existing.path), ["keep"])
    }
}
