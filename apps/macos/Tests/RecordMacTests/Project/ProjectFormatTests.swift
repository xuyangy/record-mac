import CoreGraphics
import XCTest
@testable import RecordMac

final class ProjectFormatTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try makeProjectTestDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testManifestRoundTripKeepsEveryField() throws {
        let store = try ProjectStore.create(named: "Round Trip", in: root)
        let project = makeFixtureProject()

        try store.writeProject(project)
        let read = try store.readProject()

        XCTAssertEqual(read, project)
        XCTAssertEqual(read.overlaidRanges, [CaptureTimeRange(start: 1.5, end: 2.5)])
        XCTAssertEqual(read.frameReport, FrameReport(delivered: 600, appendRejected: 1, writerFailed: 0, written: 599))
        XCTAssertEqual(read.createdAt, project.createdAt)
    }

    func testSegmentsAndGapsSurviveRoundTrip() throws {
        let store = try ProjectStore.create(named: "Gaps", in: root)
        try store.writeProject(makeFixtureProject())
        let read = try store.readProject()

        let screen = try XCTUnwrap(read.track(.screen))
        XCTAssertEqual(screen.segments.map(\.fileRef), ["media/screen-1.mov", "media/screen-2.mov"])
        XCTAssertEqual(screen.segments.map(\.nativeSize), [PixelSize(width: 3456, height: 2234), PixelSize(width: 2880, height: 1800)])
        XCTAssertEqual(screen.gaps, [CaptureTimeRange(start: 5, end: 5.25)])
        XCTAssertEqual(read.track(.microphone)?.gaps, [CaptureTimeRange(start: 3, end: 3.5)])
        XCTAssertEqual(read.track(.systemAudio)?.gaps, [])
    }

    func testManifestListsEveryMediaFileWithItsTimes() throws {
        let store = try ProjectStore.create(named: "Listing", in: root)
        try store.writeProject(makeFixtureProject())

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.projectURL)) as? [String: Any]
        let tracks = try XCTUnwrap(json?["mediaTracks"] as? [[String: Any]])
        let segments = tracks.flatMap { ($0["segments"] as? [[String: Any]]) ?? [] }
        XCTAssertEqual(segments.count, 6)
        for segment in segments {
            XCTAssertNotNil(segment["fileRef"] as? String)
            XCTAssertNotNil(segment["start"] as? Double)
            XCTAssertNotNil(segment["end"] as? Double)
        }
    }

    func testSourceDurationIgnoresPresenterComposite() {
        var project = makeFixtureProject()
        XCTAssertEqual(project.sourceDuration, 10)
        project.mediaTracks.append(
            MediaTrack(
                kind: .presenterComposite,
                segments: [
                    MediaSegment(
                        fileRef: "media/presenter-composite-1.mov", start: 2, end: 30, deviceID: "overlay",
                        nativeSize: PixelSize(width: 1920, height: 1080), frameRate: 60, hasAlpha: false)
                ],
                requestedFrameRate: 60))
        XCTAssertEqual(project.sourceDuration, 10)
    }

    func testLayoutFileNames() throws {
        XCTAssertEqual(ProjectStore.mediaFileReference(for: .screen, segment: 1), "media/screen-1.mov")
        XCTAssertEqual(ProjectStore.mediaFileReference(for: .camera, segment: 2), "media/camera-2.mov")
        XCTAssertEqual(ProjectStore.mediaFileReference(for: .microphone, segment: 1), "media/microphone-1.m4a")
        XCTAssertEqual(ProjectStore.mediaFileReference(for: .systemAudio, segment: 3), "media/system-3.m4a")
        XCTAssertEqual(
            ProjectStore.mediaFileReference(for: .presenterComposite, segment: 1),
            "media/presenter-composite-1.mov")

        let store = try ProjectStore.create(named: "Layout", in: root)
        XCTAssertEqual(store.directory.lastPathComponent, "Layout.recordmac")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.mediaDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertThrowsError(try ProjectStore.create(named: "Layout", in: root))
    }

    func testEditDocumentRoundTripAndEditedDuration() throws {
        let store = try ProjectStore.create(named: "Edit", in: root)
        var document = EditDocument(sourceDuration: 10)
        document.clips = [
            Clip(sourceRange: CaptureTimeRange(start: 0, end: 4), speed: 1, order: 0),
            Clip(sourceRange: CaptureTimeRange(start: 6, end: 10), speed: 2, order: 1),
        ]
        document.zoomMoves = [
            ZoomMove(
                timeRange: CaptureTimeRange(start: 1, end: 2), focus: CGPoint(x: 0.25, y: 0.75), depth: 2,
                origin: .generated)
        ]
        document.overlays = [
            try OverlayElement(
                sourceEventRefs: [ActivityEventRef(index: 2)], kind: .keystrokeBadge,
                timeRange: CaptureTimeRange(start: 1, end: 1.8),
                appearance: .init(position: CGPoint(x: 0.5, y: 0.9), scale: 1, duration: 0.8))
        ]
        document.audioLevels = [AudioLevelCurve(track: .microphone, points: [.init(time: 0, gain: 0.8)])]
        document.cameraPlacements = [
            CameraPlacement(
                timeRange: CaptureTimeRange(start: 0, end: 10), anchor: .bottomRight, size: 0.25, borderWidth: 2,
                borderColor: SerializableColor(hex: "#FFFFFF"), cornerRadius: 12, isVisible: true)
        ]
        document.undoHistory.undoStack = [EditDocument(sourceDuration: 10).state]

        try store.writeEdit(document)
        let read = try store.readEdit()

        XCTAssertEqual(read, document)
        XCTAssertEqual(read.editedDuration, 6)
        let json = try String(contentsOf: store.editURL, encoding: .utf8)
        XCTAssertFalse(json.contains("editedDuration"))
    }

    func testDefaultPresentationHasBackgroundCornersShadowAndSmoothing() {
        let presentation = EditDocument(sourceDuration: 1).presentation
        XCTAssertGreaterThan(presentation.cornerRadius, 0)
        XCTAssertGreaterThan(presentation.shadow, 0)
        XCTAssertGreaterThan(presentation.padding, 0)
        XCTAssertGreaterThan(presentation.cursor.smoothing, 0)
    }

    func testOverlayElementRequiresASourceEvent() throws {
        XCTAssertThrowsError(
            try OverlayElement(
                sourceEventRefs: [], kind: .clickRipple, timeRange: CaptureTimeRange(start: 0, end: 1),
                appearance: .init(position: .zero, scale: 1, duration: 0.5)))
        let json = #"{"id":"6F1B7E52-5E0A-4C3D-9A61-2B7C1D0E9F11","sourceEventRefs":[],"kind":"clickRipple","timeRange":{"start":0,"end":1},"appearance":{"position":[0,0],"scale":1,"duration":0.5},"suppressed":false}"#
        XCTAssertThrowsError(try JSONDecoder().decode(OverlayElement.self, from: Data(json.utf8)))
    }

    func testZoomDepthIsCappedByMaximum() {
        let move = ZoomMove(
            timeRange: CaptureTimeRange(start: 0, end: 1), focus: .zero, depth: 4, origin: .manual)
        XCTAssertEqual(move.capped(at: 2.5).depth, 2.5)
        XCTAssertEqual(move.capped(at: 8).depth, 4)
    }

    // MARK: Invariants

    func testRejectsOverlappingSegments() {
        var project = makeFixtureProject()
        project.mediaTracks[0].segments[1].start = 4.5
        XCTAssertThrowsError(try project.validate()) {
            XCTAssertEqual($0 as? ProjectValidationError, .segmentsOverlap(.screen))
        }
    }

    func testRejectsSegmentsOutOfOrder() {
        var project = makeFixtureProject()
        project.mediaTracks[2].segments.reverse()
        XCTAssertThrowsError(try project.validate()) {
            XCTAssertEqual($0 as? ProjectValidationError, .segmentsOutOfOrder(.microphone))
        }
    }

    func testRejectsTwoTracksOfOneKind() {
        var project = makeFixtureProject()
        project.mediaTracks.append(project.mediaTracks[3])
        XCTAssertThrowsError(try project.validate()) {
            XCTAssertEqual($0 as? ProjectValidationError, .duplicateTrackKind(.systemAudio))
        }
    }

    func testRejectsOverlaidRangeOutsideScreenTrack() {
        var project = makeFixtureProject()
        project.overlaidRanges = [CaptureTimeRange(start: 4.9, end: 5.1)]
        XCTAssertThrowsError(try project.validate()) {
            XCTAssertEqual(
                $0 as? ProjectValidationError,
                .overlaidRangeOutsideScreenTrack(CaptureTimeRange(start: 4.9, end: 5.1)))
        }
    }

    func testRejectsInvalidRequestedFrameRate() {
        var project = makeFixtureProject()
        project.mediaTracks[0].requestedFrameRate = 90
        XCTAssertThrowsError(try project.validate()) {
            XCTAssertEqual($0 as? ProjectValidationError, .invalidRequestedFrameRate(.screen, 90))
        }
    }

    func testRejectsVideoFieldsOnAudioTrack() {
        var project = makeFixtureProject()
        project.mediaTracks[2].segments[0].frameRate = 30
        XCTAssertThrowsError(try project.validate()) {
            XCTAssertEqual($0 as? ProjectValidationError, .videoFieldsOnAudioTrack(.microphone))
        }
    }

    func testRejectsFileReferencesOutsideTheProject() {
        for reference in ["/tmp/screen-1.mov", "../screen-1.mov", "media/../../x.mov", ""] {
            var project = makeFixtureProject()
            project.mediaTracks[0].segments[0].fileRef = reference
            XCTAssertThrowsError(try project.validate(), reference)
        }
    }

    func testWriteRefusesAnInvalidProject() throws {
        let store = try ProjectStore.create(named: "Invalid", in: root)
        var project = makeFixtureProject()
        project.mediaTracks[0].segments[1].start = 1
        XCTAssertThrowsError(try store.writeProject(project))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.projectURL.path))
    }
}
