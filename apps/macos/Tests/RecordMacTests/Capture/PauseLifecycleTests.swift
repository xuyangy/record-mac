@preconcurrency import AVFoundation
import ApplicationServices
import CoreMedia
@preconcurrency import ScreenCaptureKit
import XCTest
@testable import RecordMac

/// Pause, resume, and stop driven through `CaptureEngine`, with screen frames, system audio,
/// microphone audio, and pointer events checked together on the one clock the engine makes. The
/// backend composes the real `ScreenCaptureBackend` (router, retimer, writers, temporary files)
/// over a stand-in stream, and a real `TelemetryRecorder` over a stand-in event tap and
/// Accessibility. Host time is set by the test; the epoch is host 1000 s. No stream, device,
/// event tap, Accessibility query, or permission is used.
///
/// Every expected session time is a fixed number worked out from the schedule, never another
/// call to the clock.
@MainActor
final class PauseLifecycleTests: XCTestCase {
    /// Delivers pointer samples when the test says, on the test's thread.
    private final class FakeTap: PointerEventTap, @unchecked Sendable {
        private var onSample: (@Sendable (PointerSample) -> Void)?
        private(set) var stops = 0

        func start(
            onSample: @escaping @Sendable (PointerSample) -> Void,
            onDisabled: @escaping @Sendable (Bool) -> Void
        ) -> Bool {
            self.onSample = onSample
            return true
        }

        func stop() { stops += 1 }

        func move(atHostSeconds seconds: Double, at point: CGPoint = CGPoint(x: 10, y: 20)) {
            onSample?(PointerSample(action: .move, timestamp: UInt64((seconds * 1e9).rounded()), location: point))
        }
    }

    /// Finds no element anywhere. A lookup at `heldPoint` waits until `release` is signalled, so
    /// the event being resolved stays undelivered until the test lets it go.
    private final class HeldAccessibility: AccessibilityQueries, @unchecked Sendable {
        static let heldPoint = CGPoint(x: 77, y: 77)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        func isTrusted() -> Bool { true }
        func element(at point: CGPoint) -> AccessibilityLookup {
            if point == Self.heldPoint {
                entered.signal()
                release.wait()
            }
            return .none
        }
        func focusedElement() -> AccessibilityLookup { .none }
        func copyAttribute(_ attribute: String, of element: AccessibilityElement) -> (AXError, CFTypeRef?) { (.noValue, nil) }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [GlobalActivityEvent] = []
        private var finalCounts: TelemetryRecorderCounts?
        var events: [GlobalActivityEvent] { lock.withLock { stored } }
        /// The recorder's counts once it has stopped and delivered every event.
        var counts: TelemetryRecorderCounts? {
            get { lock.withLock { finalCounts } }
            set { lock.withLock { finalCounts = newValue } }
        }
        func append(_ event: GlobalActivityEvent) { lock.withLock { stored.append(event) } }
    }

    /// The screen backend and a telemetry recorder on the clock the engine starts it with, and
    /// every call the engine made.
    private final class Backend: CaptureBackend {
        let screen: ScreenCaptureBackend
        let tap = FakeTap()
        let accessibility = HeldAccessibility()
        let events = Collected()
        let telemetryStopped: XCTestExpectation
        private(set) var clock: CaptureClock?
        private(set) var recorder: TelemetryRecorder?
        private(set) var pauses: [CMTime] = []
        private(set) var resumes: [CMTime] = []
        private(set) var stops: [CMTime] = []

        init(screen: ScreenCaptureBackend, telemetryStopped: XCTestExpectation) {
            self.screen = screen
            self.telemetryStopped = telemetryStopped
        }

        func validate(_ source: CaptureSource, _ options: CaptureEngineOptions) async throws {
            try await screen.validate(source, options)
        }

        func start(clock: CaptureClock) async throws {
            self.clock = clock
            let events = events
            let recorder = TelemetryRecorder(clock: clock, filter: ActivityEventFilter(),
                resolver: TargetResolver(accessibility: accessibility), tap: tap) { events.append($0) }
            self.recorder = recorder
            XCTAssertEqual(recorder.start(), .running)
            try await screen.start(clock: clock)
        }

        func pause(atHostTime hostTime: CMTime) async throws {
            pauses.append(hostTime)
            try await screen.pause(atHostTime: hostTime)
        }

        func resume(atHostTime hostTime: CMTime) async throws {
            resumes.append(hostTime)
            try await screen.resume(atHostTime: hostTime)
        }

        func stop(atHostTime hostTime: CMTime) async throws -> [MediaTrack] {
            stops.append(hostTime)
            let tracks = try await screen.stop(atHostTime: hostTime)
            let (events, done) = (events, telemetryStopped)
            recorder?.stop { counts in
                events.counts = counts
                done.fulfill()
            }
            return tracks
        }
    }

    private let epoch = 1000.0
    private let systemFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
    private let microphoneFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: true)!
    private var directory: URL!
    private var stream: FakeCaptureStream!
    private var now = 1000.0
    private var backend: Backend!
    private var engine: CaptureEngine!
    /// The bytes each audio source should keep, in order.
    private var keptSystem = Data()
    private var keptMicrophone = Data()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pause-lifecycle-\(UUID().uuidString)")
        stream = FakeCaptureStream()
        now = epoch
        keptSystem = Data()
        keptMicrophone = Data()
        let stream = stream!
        backend = Backend(
            screen: ScreenCaptureBackend(
                directory: directory,
                resolve: { _ in
                    ResolvedCaptureSource(filter: nil, geometry: CaptureSourceGeometry(pixelWidth: 256, pixelHeight: 144, sourceRect: nil),
                        deviceID: "display:1")
                },
                makeStream: { _, _, _ in stream },
                hasPermission: { true },
                microphonePermitted: { true }),
            telemetryStopped: expectation(description: "telemetry stopped"))
        let backend = backend!
        engine = CaptureEngine(makeBackend: { _ in backend }, refreshRate: { _ in .hertz(60) },
            hostTimeNow: { [unowned self] in host(now) })
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Rounded to the nearest 1/48,000 s, so 1000.35 is exact.
    private func host(_ seconds: Double) -> CMTime { CMTime(value: Int64((seconds * 48_000).rounded()), timescale: 48_000) }

    private let source = CaptureSource(id: "display:1", kind: .display, name: "Display 1", subtitle: "", displayIndex: 1,
        displayID: 1, windowID: nil, area: nil, thumbnailData: nil)

    private let options = CaptureEngineOptions(microphoneDeviceID: "mic-1", systemAudio: true, cameraDeviceID: nil,
        includesPointer: false, frameRate: 60, wantsAlpha: false, keepsPresenterComposite: false)

    /// Waits until the sample queue has routed everything delivered so far.
    private func drain() async {
        await withCheckedContinuation { continuation in backend.screen.sampleQueue.async { continuation.resume() } }
    }

    private func frames(_ hostSeconds: Double...) throws {
        for seconds in hostSeconds { stream.deliver(try ScreenFrameFixtures.frame(atHostSeconds: seconds), .screen) }
    }

    private func moves(_ hostSeconds: Double...) {
        for seconds in hostSeconds { backend.tap.move(atHostSeconds: seconds) }
    }

    /// The part of an audio packet that should be written: all of it, its first half (it runs
    /// into a pause), its second half (it runs out of one), or none (inside one).
    private enum Kept { case all, firstHalf, secondHalf, none }

    /// Delivers one 0.1 s packet of each audio source starting at `hostSeconds`, and keeps the
    /// part of each that should be written.
    private func audio(_ hostSeconds: Double, seed: Int, keep: Kept) throws {
        for (format, type) in [(systemFormat, SCStreamOutputType.audio), (microphoneFormat, .microphone)] {
            let frames = Int(format.sampleRate) / 10
            let (packet, bytes) = try AudioFixtures.buffer(format: format, frames: frames, start: hostSeconds, seed: seed)
            stream.deliver(packet, type)
            let half = bytes.count / 2
            let kept: Data = switch keep {
            case .all: bytes
            case .firstHalf: bytes.prefix(half)
            case .secondHalf: bytes.suffix(half)
            case .none: Data()
            }
            if type == .audio { keptSystem.append(kept) } else { keptMicrophone.append(kept) }
        }
    }

    /// Delivers the audio packets starting at host 1000.05 + 0.1 k seconds for each `k` in
    /// `indices`, each kept as `keep(k)` says.
    private func audio(_ indices: ClosedRange<Int>, keep: (Int) -> Kept) throws {
        for index in indices { try audio(epoch + 0.05 + 0.1 * Double(index), seed: index, keep: keep(index)) }
    }

    /// Every frame's file time and duration, read back, in presentation order.
    private func screenFile(_ name: String) async throws -> [(time: Double, duration: Double)] {
        let asset = AVURLAsset(url: directory.appendingPathComponent(name))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames: [(Double, Double)] = []
        while let sample = output.copyNextSampleBuffer() {
            if sample.numSamples > 0 { frames.append((sample.presentationTimeStamp.seconds, sample.duration.seconds)) }
        }
        XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
        return frames.sorted { $0.0 < $1.0 }
    }

    /// Checks an audio file's own timeline: one edit, from the file's zero, with no empty time;
    /// buffers read back that start at zero, each where the one before ended, the last ending
    /// at `end` on the session clock, given `start`; and a duration that agrees.
    private func assertAudioTimeline(_ name: String, start: Double, end: Double, _ kind: MediaTrackKind, line: UInt = #line) async throws {
        let url = directory.appendingPathComponent(name)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let edits = try await track.load(.segments)
        XCTAssertEqual(edits.count, 1, "\(kind): one edit, so no empty time inside", line: line)
        if let edit = edits.first {
            XCTAssertFalse(edit.isEmpty, "\(kind)", line: line)
            XCTAssertEqual(edit.timeMapping.target.start.seconds, 0, accuracy: 1e-9, "\(kind)", line: line)
            XCTAssertEqual(edit.timeMapping.source.start.seconds, 0, accuracy: 1e-9, "\(kind)", line: line)
            XCTAssertEqual(edit.timeMapping.target.duration.seconds, end - start, accuracy: 1e-6, "\(kind)", line: line)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var previousEnd: CMTime?
        while let sample = output.copyNextSampleBuffer() {
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0 else { continue }
            let rate = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(try XCTUnwrap(sample.formatDescription))?.pointee).mSampleRate
            let time = sample.presentationTimeStamp
            if let previousEnd {
                XCTAssertEqual(time.seconds, previousEnd.seconds, accuracy: 1e-9, "\(kind): a buffer starts where the last ended", line: line)
            } else {
                XCTAssertEqual(time.seconds, 0, accuracy: 1e-9, "\(kind): the file starts at zero", line: line)
            }
            previousEnd = time + CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(rate))
        }
        XCTAssertEqual(reader.status, .completed, String(describing: reader.error), line: line)
        XCTAssertEqual(start + (previousEnd?.seconds ?? -1), end, accuracy: 1e-9, "\(kind): the last sample ends at \(end)", line: line)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, end - start, accuracy: 1e-3, "\(kind): the file holds no time before its first sample", line: line)
    }

    private func assertTimes(_ actual: [Double], _ expected: [Double], _ message: String, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, "\(message): \(actual)", line: line)
        for (actual, expected) in zip(actual, expected) {
            XCTAssertEqual(actual, expected, accuracy: 1e-6, "\(message): \(actual) is not \(expected)", line: line)
        }
    }

    private func assertRejected(_ call: () async throws -> Void, phase: CaptureSession.Phase, _ name: String, line: UInt = #line) async {
        do {
            try await call()
            XCTFail("\(name) was accepted", line: line)
        } catch {
            XCTAssertEqual(error as? CaptureEngineError, .illegalTransition(phase: phase, call: name), line: line)
        }
    }

    /// Two pauses: host 1000.5-1001.5 and 1002.0-1002.5, stop at 1003.0, so session time is host
    /// time less 1000 before the first pause, less 1001 between them, and less 1001.5 after.
    /// Each transition is made only after everything stamped before it has been routed, as a
    /// stream delivers in time order. Rejected calls in between change nothing.
    func testMediaAndPointerEventsShareOneTimelineAcrossTwoPauses() async throws {
        let session = try await engine.prepare(source, options)
        let clock = try await engine.start(session)
        XCTAssertTrue(backend.clock === clock, "the backend and its recorder run on the engine's clock")

        // Recording: 1000.0-1000.5.
        try frames(1000.1, 1000.3)
        moves(1000.2)
        try audio(0...3) { _ in .all }
        await drain()
        now = 1000.3
        await assertRejected({ try await self.engine.resume(session) }, phase: .recording, "resume")

        // First pause. Its start belongs to the pause; its end to the recording.
        now = 1000.5
        try await engine.pause(session)
        try frames(1000.5, 1000.9)
        moves(1000.5, 1000.7)
        try audio(4...13) { $0 == 4 ? .firstHalf : .none }
        await drain()
        now = 1001.0
        await assertRejected({ try await self.engine.pause(session) }, phase: .paused, "pause")
        now = 1001.5
        try await engine.resume(session)
        try frames(1001.5, 1001.7)
        moves(1001.5, 1001.6)
        try audio(14...18) { $0 == 14 ? .secondHalf : .all }
        await drain()

        // Second pause.
        now = 1002.0
        try await engine.pause(session)
        try frames(1002.2)
        moves(1002.3)
        try audio(19...23) { $0 == 19 ? .firstHalf : .none }
        await drain()
        now = 1002.5
        try await engine.resume(session)
        try frames(1002.8)
        moves(1002.9)
        try audio(24...28) { $0 == 24 ? .secondHalf : .all }
        await drain()

        now = 1003.0
        let tracks = try await engine.stop(session)
        await fulfillment(of: [backend.telemetryStopped], timeout: 5)

        XCTAssertEqual(session.phase, .stopped)
        XCTAssertEqual(backend.pauses, [host(1000.5), host(1002.0)], "only the accepted pauses reached the backend")
        XCTAssertEqual(backend.resumes, [host(1001.5), host(1002.5)])
        XCTAssertEqual(backend.stops, [host(1003.0)])
        let pauses = clock.pauses(closingAt: host(1003.0))
        assertTimes(pauses.flatMap { [$0.start, $0.end] }, [0.5, 1.5, 2.0, 2.5], "the clock's pauses")

        // Screen: frames at 0.1, 0.3, then 1001.5 → 0.5, 1001.7 → 0.7, 1002.8 → 1.3; the frames at
        // 1000.5, 1000.9, and 1002.2 are inside a pause. The segment ends at the stop, 1.5.
        let screen = try XCTUnwrap(tracks.first { $0.kind == .screen }?.segments.first)
        XCTAssertEqual(screen.start, 0.1, accuracy: 1e-9)
        XCTAssertEqual(screen.end, 1.5, accuracy: 1e-9)
        let written = try await screenFile(screen.fileRef)
        assertTimes(written.map { screen.start + $0.time }, [0.1, 0.3, 0.5, 0.7, 1.3], "screen frames")
        assertTimes(written.map(\.duration), [0.2, 0.2, 0.2, 0.6, 0.2], "screen frame durations")
        XCTAssertEqual(backend.screen.report.router?.screen.excluded, 3)

        // Pointer: 0.2, then 1001.5 → 0.5, 1001.6 → 0.6, 1002.9 → 1.4; three inside a pause.
        assertTimes(backend.events.events.map(\.sessionTime.seconds), [0.2, 0.5, 0.6, 1.4], "pointer events")
        XCTAssertEqual(backend.events.counts?.droppedNoSessionTime, 3)
        XCTAssertEqual(backend.events.counts?.delivered, 4)
        XCTAssertEqual(backend.tap.stops, 1)

        // Audio: packets every 0.1 s from 1000.05; the ones across a pause's start or end keep
        // the half outside it. The first sample is at 0.05 and the last ends at 1002.95 → 1.45.
        for (kind, format, kept) in [(MediaTrackKind.systemAudio, systemFormat, keptSystem), (.microphone, microphoneFormat, keptMicrophone)] {
            let segment = try XCTUnwrap(tracks.first { $0.kind == kind }?.segments.first, "\(kind)")
            XCTAssertEqual(segment.start, 0.05, accuracy: 1e-9, "\(kind)")
            XCTAssertEqual(segment.end, 1.45, accuracy: 1e-9, "\(kind)")
            let file = try await AudioFixtures.read(directory.appendingPathComponent(segment.fileRef))
            XCTAssertEqual(file.frames, Int((format.sampleRate * 1.4).rounded()), "\(kind): 12 whole packets and 4 halves")
            XCTAssertEqual(file.bytes, kept, "\(kind): the samples outside the pauses, unchanged and in order")
            XCTAssertEqual(backend.screen.report.audio[kind == .microphone ? .microphone : .systemAudio]?.discontinuities, 0,
                "\(kind): every buffer written continues the last")
            try await assertAudioTimeline(segment.fileRef, start: segment.start, end: 1.45, kind)
        }
        XCTAssertEqual(backend.screen.report.audioWithoutSamples, [])
    }

    /// Paused at host 1000.5 and stopped at 1001.0 without resuming: every track ends at the
    /// pause, 0.5; nothing stamped inside the pause is written. Media the stream delivers while
    /// it stops, after the session has ended, is written when stamped before the pause, and a
    /// pointer event admitted before the stop and still being resolved is delivered before the
    /// recorder's stop completes.
    func testStoppingWhilePausedEndsEveryTrackAtThePause() async throws {
        let session = try await engine.prepare(source, options)
        let clock = try await engine.start(session)
        try frames(1000.1)
        moves(1000.2)
        try audio(0...3) { _ in .all }
        await drain()

        now = 1000.5
        try await engine.pause(session)
        moves(1000.6, 1000.8)
        // Stamped before the pause; its delivery waits in the Accessibility lookup.
        backend.tap.move(atHostSeconds: 1000.45, at: HeldAccessibility.heldPoint)
        XCTAssertEqual(backend.accessibility.entered.wait(timeout: .now() + 5), .success)
        // Delivered by the stream inside `stopCapture`, after the session has ended; it returns
        // once they are routed.
        var deliveredWhileStopping = false
        stream.whileStopping = { [unowned self] in
            XCTAssertEqual(backend.clock?.snapshot().endHostTime, host(1001.0), "the session has ended")
            try audio(4...8) { $0 == 4 ? .firstHalf : .none }
            try frames(1000.4, 1000.7)
            deliveredWhileStopping = true
        }

        now = 1001.0
        let tracks = try await engine.stop(session)
        XCTAssertTrue(deliveredWhileStopping)
        XCTAssertNil(backend.events.counts, "the recorder's stop waits for the event being resolved")
        XCTAssertEqual(backend.events.events.count, 1)
        backend.accessibility.release.signal()
        await fulfillment(of: [backend.telemetryStopped], timeout: 5)

        XCTAssertEqual(session.phase, .stopped)
        XCTAssertEqual(backend.pauses, [host(1000.5)])
        XCTAssertEqual(backend.resumes, [], "a stop while paused never resumes")
        XCTAssertTrue(clock.isPaused)
        XCTAssertEqual(clock.snapshot().sessionTime(endingAt: host(1001.0))?.seconds ?? -1, 0.5, accuracy: 1e-9)

        let screen = try XCTUnwrap(tracks.first { $0.kind == .screen }?.segments.first)
        XCTAssertEqual(screen.end, 0.5, accuracy: 1e-9, "the recording ends at the pause")
        let written = try await screenFile(screen.fileRef)
        assertTimes(written.map { screen.start + $0.time }, [0.1, 0.4], "screen frames")
        assertTimes(written.map(\.duration), [0.3, 0.1], "the last frame lasts to the pause")

        assertTimes(backend.events.events.map(\.sessionTime.seconds), [0.2, 0.45], "pointer events")
        XCTAssertEqual(backend.events.counts?.droppedNoSessionTime, 2)

        for (kind, format, kept) in [(MediaTrackKind.systemAudio, systemFormat, keptSystem), (.microphone, microphoneFormat, keptMicrophone)] {
            let segment = try XCTUnwrap(tracks.first { $0.kind == kind }?.segments.first, "\(kind)")
            XCTAssertEqual(segment.start, 0.05, accuracy: 1e-9, "\(kind)")
            XCTAssertEqual(segment.end, 0.5, accuracy: 1e-9, "\(kind): the last packet is cut at the pause")
            let file = try await AudioFixtures.read(directory.appendingPathComponent(segment.fileRef))
            XCTAssertEqual(file.frames, Int((format.sampleRate * 0.45).rounded()), "\(kind)")
            XCTAssertEqual(file.bytes, kept, "\(kind)")
            XCTAssertEqual(backend.screen.report.audio[kind == .microphone ? .microphone : .systemAudio]?.discontinuities, 0, "\(kind)")
            try await assertAudioTimeline(segment.fileRef, start: segment.start, end: 0.5, kind)
        }

        now = 1001.2
        await assertRejected({ try await self.engine.resume(session) }, phase: .stopped, "resume")
        XCTAssertEqual(backend.resumes, [])
    }
}
