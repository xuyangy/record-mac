import CoreGraphics
import Foundation
@testable import RecordMac

/// A project with every track kind except the composite, gaps in the screen and microphone
/// tracks, one overlaid range, and a frame report.
func makeFixtureProject(id: UUID = UUID(uuidString: "6F1B7E52-5E0A-4C3D-9A61-2B7C1D0E9F11")!) -> RecordingProject {
    func video(_ kind: MediaTrackKind, _ index: Int, _ start: Double, _ end: Double, size: PixelSize, rate: Double)
        -> MediaSegment
    {
        MediaSegment(
            fileRef: ProjectStore.mediaFileReference(for: kind, segment: index), start: start, end: end,
            deviceID: "\(kind.rawValue)-device", nativeSize: size, frameRate: rate, hasAlpha: false)
    }
    func audio(_ kind: MediaTrackKind, _ index: Int, _ start: Double, _ end: Double, device: String) -> MediaSegment {
        MediaSegment(
            fileRef: ProjectStore.mediaFileReference(for: kind, segment: index), start: start, end: end,
            deviceID: device)
    }
    return RecordingProject(
        id: id,
        formatVersion: RecordingProject.currentFormatVersion,
        displayName: "Fixture",
        createdAt: Date(timeIntervalSince1970: 1_790_000_000.25),
        captureClock: CaptureClockReference(epochHostTimeNanoseconds: 123_456_789),
        pauses: [CaptureTimeRange(start: 4, end: 4)],
        endReason: .completed,
        overlaidRanges: [CaptureTimeRange(start: 1.5, end: 2.5)],
        frameReport: FrameReport(delivered: 600, appendRejected: 1, writerFailed: 0, written: 599),
        sourceDescription: "Display 1",
        mediaTracks: [
            MediaTrack(
                kind: .screen,
                segments: [
                    video(.screen, 1, 0, 5, size: PixelSize(width: 3456, height: 2234), rate: 120),
                    video(.screen, 2, 5.25, 10, size: PixelSize(width: 2880, height: 1800), rate: 120),
                ],
                requestedFrameRate: 120),
            MediaTrack(
                kind: .camera,
                segments: [video(.camera, 1, 0, 10, size: PixelSize(width: 1920, height: 1080), rate: 30)],
                requestedFrameRate: 30),
            MediaTrack(
                kind: .microphone,
                segments: [
                    audio(.microphone, 1, 0, 3, device: "mic-a"),
                    audio(.microphone, 2, 3.5, 10, device: "mic-a"),
                ]),
            MediaTrack(kind: .systemAudio, segments: [audio(.systemAudio, 1, 0, 10, device: "system")]),
        ])
}

func makeFixtureActivity() -> ActivityStream {
    ActivityStream(
        events: [
            ActivityEvent(timestamp: 0.1, kind: .pointerMove, location: CGPoint(x: 10, y: 20)),
            ActivityEvent(
                timestamp: 0.2, kind: .click, location: CGPoint(x: 10, y: 20), buttonOrKey: .button(0),
                target: ElementDescriptor(
                    role: "AXButton", subrole: nil, identifier: "save",
                    frame: CGRect(x: 0, y: 0, width: 80, height: 24))),
            ActivityEvent(
                timestamp: 1, kind: .keyPress,
                buttonOrKey: .key(KeyStroke(keyCode: 1, modifiers: 0x100000, characters: "s"))),
            ActivityEvent(timestamp: 2, kind: .scroll, location: CGPoint(x: 5, y: 5)),
            ActivityEvent(timestamp: 3, kind: .dragStart, location: CGPoint(x: 1, y: 1), buttonOrKey: .button(0)),
            ActivityEvent(timestamp: 3.5, kind: .dragEnd, location: CGPoint(x: 9, y: 9), buttonOrKey: .button(0)),
            ActivityEvent(
                timestamp: 6, kind: .activeWindowChange,
                window: WindowDescriptor(
                    bundleIdentifier: "com.apple.Terminal", windowID: 42,
                    frame: CGRect(x: 0, y: 0, width: 800, height: 600))),
        ],
        geometry: [
            GeometrySegment(
                start: 0, sourceRect: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                pixelSize: PixelSize(width: 3456, height: 2234), scaleFactor: 2),
            GeometrySegment(
                start: 5.25, sourceRect: CGRect(x: 0, y: 0, width: 1440, height: 900),
                pixelSize: PixelSize(width: 2880, height: 1800), scaleFactor: 2),
        ])
}

/// A per-test directory under the system temporary directory, removed by the caller.
func makeProjectTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecordMacTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Creates a project on disk with the fixture manifest, activity, a default edit document, and
/// placeholder media bytes for every segment.
func makeStoredFixtureProject(in parent: URL) throws -> ProjectStore {
    let store = try ProjectStore.create(named: "Fixture", in: parent)
    let project = makeFixtureProject()
    for segment in project.mediaTracks.flatMap(\.segments) {
        let bytes = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ segment.fileRef.count) })
        try bytes.write(to: store.url(forFileReference: segment.fileRef))
    }
    try store.writeProject(project)
    try store.writeActivity(makeFixtureActivity())
    try store.writeEdit(EditDocument(sourceDuration: project.sourceDuration))
    return store
}

struct SimulatedInterruption: Error {}
