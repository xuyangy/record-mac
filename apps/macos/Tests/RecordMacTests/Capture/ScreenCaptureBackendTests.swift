@preconcurrency import AVFoundation
import CoreMedia
@preconcurrency import ScreenCaptureKit
import XCTest
@testable import RecordMac

/// The screen backend's lifecycle against a stand-in stream that delivers synthetic buffers on
/// the queue it was given, with the real writers and encoder selection on temporary files. The
/// sync clock is the host clock; the epoch is host 1000 s. No stream, device, or permission is
/// used.
@MainActor
final class ScreenCaptureBackendTests: XCTestCase {
    private typealias FakeStream = FakeCaptureStream

    private let epoch = 1000.0
    private var directory: URL!
    private var stream: FakeStream!
    private var permitted = true
    private var microphonePermitted = true
    private var microphoneChecks = 0
    private var now = CMTime.zero

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("backend-\(UUID().uuidString)")
        stream = FakeStream()
        permitted = true
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func host(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }

    private func source(_ kind: CaptureSourceKind = .display) -> CaptureSource {
        CaptureSource(id: "display:1", kind: kind, name: "Display 1", subtitle: "", displayIndex: 1, displayID: 1,
            windowID: nil, area: nil, thumbnailData: nil)
    }

    private func options(systemAudio: Bool = false, microphone: String? = nil, rate: Int = 60) -> CaptureEngineOptions {
        CaptureEngineOptions(microphoneDeviceID: microphone, systemAudio: systemAudio, cameraDeviceID: nil,
            includesPointer: false, frameRate: rate, wantsAlpha: false, keepsPresenterComposite: false)
    }

    private func backend(
        resolve: ScreenCaptureBackend.Resolve? = nil, telemetry: BackendTelemetryFactory? = nil
    ) -> ScreenCaptureBackend {
        let stream = stream!
        return ScreenCaptureBackend(
            directory: directory,
            resolve: resolve ?? { _ in
                ResolvedCaptureSource(filter: nil, geometry: CaptureSourceGeometry(pixelWidth: 256, pixelHeight: 144, sourceRect: nil),
                    deviceID: "display:1")
            },
            makeStream: { _, _, _ in stream },
            hasPermission: { [unowned self] in permitted },
            microphonePermitted: { [unowned self] in
                microphoneChecks += 1
                return microphonePermitted
            },
            hostTimeNow: { [unowned self] in now },
            telemetry: telemetry)
    }

    private func frame(at seconds: Double, width: Int = 256, height: Int = 144) throws -> CMSampleBuffer {
        try ScreenFrameFixtures.frame(atHostSeconds: epoch + seconds, width: width, height: height)
    }

    private func audio(at seconds: Double, rate: Double, channels: AVAudioChannelCount, seed: Int) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: true))
        return try AudioFixtures.buffer(format: format, frames: Int(rate) / 10, start: epoch + seconds, seed: seed).0
    }

    /// Waits until the stream's queue has run everything delivered so far.
    private func drain() async {
        await withCheckedContinuation { continuation in backendQueue.async { continuation.resume() } }
    }

    private var backendQueue: DispatchQueue!

    private func started(_ options: CaptureEngineOptions, clock: CaptureClock) async throws -> ScreenCaptureBackend {
        let backend = backend()
        try await backend.validate(source(), options)
        try await backend.start(clock: clock)
        backendQueue = backend.sampleQueue
        return backend
    }

    // MARK: - validate

    private func assertRefused(
        _ options: CaptureEngineOptions, by backend: ScreenCaptureBackend? = nil, as check: (CapturePrepareError) -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await (backend ?? self.backend()).validate(source(), options)
            XCTFail("validate accepted", file: file, line: line)
        } catch let error as CapturePrepareError {
            XCTAssertTrue(check(error), "\(error)", file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    func testValidateRefusesWhatThisBackendCannotProduce() async {
        permitted = false
        await assertRefused(options()) { $0 == .permissionMissing("Screen Recording") }
        permitted = true
        var alpha = options()
        alpha.wantsAlpha = true
        await assertRefused(alpha) { if case .settingsNotProducible(let reason) = $0 { reason.contains("alpha") } else { false } }
        var composite = options()
        composite.keepsPresenterComposite = true
        await assertRefused(composite) { if case .settingsNotProducible(let reason) = $0 { reason.contains("composite") } else { false } }
        var camera = options()
        camera.cameraDeviceID = "camera-1"
        await assertRefused(camera) { if case .settingsNotProducible(let reason) = $0 { reason.contains("camera") } else { false } }
        await assertRefused(options(rate: 50)) { if case .settingsNotProducible(let reason) = $0 { reason.contains("50") } else { false } }
        let gone = backend(resolve: { _ in throw CapturePrepareError.sourceUnavailable("gone") })
        await assertRefused(options(), by: gone) { $0 == .sourceUnavailable("gone") }
        XCTAssertTrue(stream.outputs.isEmpty, "validate opens no stream")
    }

    func testAMicrophoneNeedsItsPermissionAndNoMicrophoneNeedsNone() async throws {
        microphonePermitted = false
        await assertRefused(options(microphone: "mic-1")) { $0 == .permissionMissing("Microphone") }
        XCTAssertEqual(microphoneChecks, 1)
        XCTAssertTrue(stream.outputs.isEmpty, "validate opens no stream")

        microphoneChecks = 0
        _ = try await started(options(systemAudio: true), clock: CaptureClock(epochHostTime: host(epoch)))
        XCTAssertEqual(microphoneChecks, 0, "no microphone, no microphone permission check")
        XCTAssertEqual(stream.outputs.map(\.type), [.screen, .audio])
    }

    func testStartBeforeValidateIsRefused() async {
        do {
            try await backend().start(clock: CaptureClock(epochHostTime: host(epoch)))
            XCTFail("start accepted")
        } catch {
            XCTAssertEqual(error as? CapturePrepareError, .settingsNotProducible("start before a successful validate"))
        }
    }

    // MARK: - Recording

    func testEverySelectedOutputSharesOneSerialQueue() async throws {
        let backend = try await started(options(systemAudio: true, microphone: "mic-1"), clock: CaptureClock(epochHostTime: host(epoch)))
        XCTAssertEqual(stream.outputs.map(\.type), [.screen, .audio, .microphone])
        XCTAssertTrue(stream.outputs.allSatisfy { $0.queue === backend.sampleQueue })
        XCTAssertTrue(stream.outputs.allSatisfy { $0.router === stream.outputs[0].router })
        XCTAssertTrue(stream.started)

        stream = FakeStream()
        _ = try await started(options(), clock: CaptureClock(epochHostTime: host(epoch)))
        XCTAssertEqual(stream.outputs.map(\.type), [.screen], "unselected audio outputs are not added")
    }

    func testARecordingReturnsItsTracksAndKeepsEveryCount() async throws {
        let clock = CaptureClock(epochHostTime: host(epoch))
        let backend = try await started(options(systemAudio: true, microphone: "mic-1"), clock: clock)
        for seconds in [0.1, 0.2, 0.3] { stream.deliver(try frame(at: seconds), .screen) }
        for index in 0..<4 {
            stream.deliver(try audio(at: Double(index) / 10, rate: 48_000, channels: 2, seed: 3), .audio)
            stream.deliver(try audio(at: Double(index) / 10, rate: 44_100, channels: 1, seed: 9), .microphone)
        }
        await drain()

        let tracks = try await backend.stop(atHostTime: host(epoch + 0.5))

        XCTAssertEqual(tracks.map(\.kind), [.screen, .systemAudio, .microphone])
        for track in tracks { XCTAssertNoThrow(try track.validate()) }
        let screen = try XCTUnwrap(tracks.first?.segments.first)
        XCTAssertEqual(screen.start, 0.1, accuracy: 1e-9)
        XCTAssertEqual(screen.end, 0.5, accuracy: 1e-9)
        XCTAssertEqual(screen.nativeSize, PixelSize(width: 256, height: 144))
        XCTAssertEqual(tracks[0].requestedFrameRate, 60)
        XCTAssertNil(tracks[0].endedEarlyAt)
        XCTAssertEqual(tracks[1].segments.map(\.fileRef), ["systemAudio.mov"])
        XCTAssertEqual(tracks[2].segments.map(\.deviceID), ["mic-1"])
        XCTAssertEqual(backend.report.frameReport, FrameReport(delivered: 3, appendRejected: 0, writerFailed: 0, written: 3))
        XCTAssertEqual(backend.report.audio[.systemAudio]?.written, .decoded(19_200))
        XCTAssertEqual(backend.report.audio[.microphone]?.written, .decoded(17_640))
        XCTAssertEqual(backend.report.audioWithoutSamples, [])
        XCTAssertEqual(backend.report.encoders.map(\.format.codec), [.hevc])
        XCTAssertEqual(stream.stopCalls, 1)
        for name in ["screen-0.mov", "systemAudio.mov", "microphone.mov"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path), name)
        }
    }

    func testASelectedMicrophoneThatSentNothingHasNoTrackAndIsReported() async throws {
        let backend = try await started(options(systemAudio: true, microphone: "mic-1"), clock: CaptureClock(epochHostTime: host(epoch)))
        stream.deliver(try frame(at: 0.1), .screen)
        stream.deliver(try audio(at: 0.1, rate: 48_000, channels: 2, seed: 3), .audio)
        await drain()

        let tracks = try await backend.stop(atHostTime: host(epoch + 0.5))

        XCTAssertEqual(tracks.map(\.kind), [.screen, .systemAudio])
        XCTAssertEqual(backend.report.audioWithoutSamples, [.microphone])
        XCTAssertEqual(backend.report.audio[.microphone]?.receivedFrames, 0)
    }

    func testStoppingWhilePausedEndsAtThePause() async throws {
        let clock = CaptureClock(epochHostTime: host(epoch))
        let backend = try await started(options(), clock: clock)
        for seconds in [0.1, 0.2] { stream.deliver(try frame(at: seconds), .screen) }
        await drain()
        XCTAssertTrue(clock.pause(atHostTime: host(epoch + 0.3)))
        try await backend.pause(atHostTime: host(epoch + 0.3))

        let tracks = try await backend.stop(atHostTime: host(epoch + 0.9))

        XCTAssertEqual(try XCTUnwrap(tracks.first?.segments.first).end, 0.3, accuracy: 1e-9)
    }

    func testAStreamThatStopsOnItsOwnEndsTheTracksThereAndSaysWhy() async throws {
        let clock = CaptureClock(epochHostTime: host(epoch))
        let backend = try await started(options(systemAudio: true), clock: clock)
        for seconds in [0.1, 0.2] { stream.deliver(try frame(at: seconds), .screen) }
        stream.deliver(try audio(at: 0, rate: 48_000, channels: 2, seed: 3), .audio)
        await drain()
        now = host(epoch + 0.25)
        backend.stopObserver.streamDidStop(reason: "the display was disconnected")

        let tracks = try await backend.stop(atHostTime: host(epoch + 0.9))

        XCTAssertEqual(tracks.map(\.kind), [.screen, .systemAudio])
        XCTAssertEqual(try XCTUnwrap(tracks[0].segments.first).end, 0.25, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(tracks[0].endedEarlyAt), 0.25, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(tracks[1].endedEarlyAt), 0.25, accuracy: 1e-9)
        XCTAssertEqual(backend.report.streamStopped?.reason, "the display was disconnected")
        XCTAssertEqual(try XCTUnwrap(backend.report.streamStopped?.at).seconds, 0.25, accuracy: 1e-9)
        XCTAssertEqual(backend.report.frameReport?.written, 2)
    }

    /// Delivers, while the stream is stopping, a frame from before the stop, a frame after it at
    /// a new size, a packet across it, and a packet after it.
    private func recordAcrossTheStop(failingStop: Bool) async throws {
        let clock = CaptureClock(epochHostTime: host(epoch))
        let backend = try await started(options(systemAudio: true), clock: clock)
        for seconds in [0.1, 0.2] { stream.deliver(try frame(at: seconds), .screen) }
        for index in 0..<4 { stream.deliver(try audio(at: Double(index) / 10, rate: 48_000, channels: 2, seed: 3), .audio) }
        let late = (
            before: try frame(at: 0.4), after: try frame(at: 0.6, width: 512, height: 288),
            across: try audio(at: 0.45, rate: 48_000, channels: 2, seed: 4), beyond: try audio(at: 0.6, rate: 48_000, channels: 2, seed: 5))
        stream.failStop = failingStop
        stream.whileStopping = { [stream] in
            stream!.deliver(late.before, .screen)
            stream!.deliver(late.after, .screen)
            stream!.deliver(late.across, .audio)
            stream!.deliver(late.beyond, .audio)
        }

        let tracks = try await backend.stop(atHostTime: host(epoch + 0.5))

        XCTAssertEqual(tracks.map(\.kind), [.screen, .systemAudio])
        let segments = try XCTUnwrap(backend.report.screen?.segments)
        XCTAssertEqual(segments.count, 1, "no segment opens after the stop")
        XCTAssertEqual(segments[0].format.width, 256)
        XCTAssertEqual(segments[0].end.seconds, 0.5, accuracy: 1e-9)
        // The frame from before the stop reaches the writer; a writer not ready for it in real
        // time sheds it and counts it as rejected.
        let frames = try XCTUnwrap(backend.report.frameReport)
        XCTAssertEqual(frames.delivered, 3, "the frame from before the stop is delivered, the one after it is not")
        XCTAssertEqual(frames.written + frames.appendRejected, 3)
        XCTAssertEqual(frames.writerFailed, 0)
        XCTAssertEqual(backend.report.router?.screen.excluded, 1)
        XCTAssertEqual(backend.report.router?.audio[.systemAudio]?.excluded, 2400 + 4800)
        XCTAssertEqual(backend.report.audio[.systemAudio]?.written, .decoded(19_200 + 2400), "only samples before the stop")
        for track in tracks { for segment in track.segments { XCTAssertLessThanOrEqual(segment.end, 0.5 + 1e-9) } }
    }

    func testNothingStampedAtOrAfterTheStopIsWritten() async throws {
        try await recordAcrossTheStop(failingStop: false)
    }

    func testNothingStampedAfterTheStopIsWrittenWhenStopCaptureFails() async throws {
        try await recordAcrossTheStop(failingStop: true)
        XCTAssertEqual(stream.stopCalls, 1)
    }

    func testAStreamWithNoClockUntilItStartsStillTimesItsFirstBuffer() async throws {
        stream.clockAfterStart = true
        XCTAssertNil(stream.synchronizationClock)
        let backend = try await started(options(), clock: CaptureClock(epochHostTime: host(epoch)))
        stream.deliver(try frame(at: 0.1), .screen)
        await drain()

        _ = try await backend.stop(atHostTime: host(epoch + 0.3))

        XCTAssertEqual(backend.report.router?.screen.failed, [:])
        XCTAssertEqual(backend.report.frameReport?.written, 1)
    }

    func testAnAudioSegmentSpansItsSamplesAndAPauseLeavesItContinuous() async throws {
        let clock = CaptureClock(epochHostTime: host(epoch))
        let backend = try await started(options(systemAudio: true), clock: clock)
        XCTAssertTrue(clock.pause(atHostTime: host(epoch + 0.2)))
        XCTAssertTrue(clock.resume(atHostTime: host(epoch + 0.3)))
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        var kept = Data()
        for (index, start) in [0.05, 0.15, 0.25, 0.35, 0.45].enumerated() {
            let (packet, bytes) = try AudioFixtures.buffer(format: format, frames: 4800, start: epoch + start, seed: index)
            stream.deliver(packet, .audio)
            switch index {
            case 1: kept.append(bytes.prefix(2400 * 8))
            case 2: kept.append(bytes.suffix(2400 * 8))
            default: kept.append(bytes)
            }
        }
        stream.deliver(try frame(at: 0.1), .screen)
        await drain()

        let tracks = try await backend.stop(atHostTime: host(epoch + 0.7))

        let segment = try XCTUnwrap(tracks.first { $0.kind == .systemAudio }?.segments.first)
        XCTAssertEqual(segment.start, 0.05, accuracy: 1e-9, "the first sample, not the session start")
        XCTAssertEqual(segment.end, 0.45, accuracy: 1e-9, "the last sample's end, not the stop")
        let file = try await AudioFixtures.read(directory.appendingPathComponent(segment.fileRef))
        XCTAssertEqual(file.firstTime, 0, accuracy: 1e-9)
        XCTAssertEqual(segment.start + Double(file.frames) / 48_000, segment.end, accuracy: 1e-9)
        let duration = try await AVURLAsset(url: directory.appendingPathComponent(segment.fileRef)).load(.duration)
        XCTAssertEqual(duration.seconds, segment.end - segment.start, accuracy: 1e-3, "the file holds no time before its first sample")
        XCTAssertEqual(file.bytes, kept, "the samples around the pause, unchanged and in order")
    }

    // MARK: - Failures

    func testAnOutputThatCannotBeAddedFailsStartAndStopStillFinalises() async throws {
        let clock = CaptureClock(epochHostTime: host(epoch))
        let backend = backend()
        stream.failingOutput = .audio
        try await backend.validate(source(), options(systemAudio: true))
        do {
            try await backend.start(clock: clock)
            XCTFail("start succeeded")
        } catch {
            XCTAssertEqual("\(error)", "output 1 refused")
        }

        let tracks = try await backend.stop(atHostTime: host(epoch + 0.5))

        XCTAssertEqual(tracks, [])
        XCTAssertEqual(backend.report.startFailure, "output 1 refused")
        XCTAssertNotNil(backend.report.router, "the router was closed")
        XCTAssertEqual(backend.report.screen?.segments.count, 0, "the screen writer was finished")
        XCTAssertEqual(backend.report.audio[.systemAudio]?.receivedFrames, 0, "the audio writers were finished")
        XCTAssertEqual(stream.stopCalls, 0, "a stream that never started is not stopped")
    }

    func testAStreamThatDoesNotStartFailsStartAndStopStillFinalises() async throws {
        let clock = CaptureClock(epochHostTime: host(epoch))
        let backend = backend()
        stream.failStart = true
        try await backend.validate(source(), options())
        do {
            try await backend.start(clock: clock)
            XCTFail("start succeeded")
        } catch {
            XCTAssertEqual("\(error)", "the stream did not start")
        }

        _ = try await backend.stop(atHostTime: host(epoch + 0.5))

        XCTAssertEqual(backend.report.startFailure, "the stream did not start")
        XCTAssertNotNil(backend.report.router)
        XCTAssertNotNil(backend.report.screen)
        XCTAssertEqual(stream.stopCalls, 0)
    }

    func testAFailedStopCaptureStillClosesTheRouterAndFinishesTheWriters() async throws {
        let clock = CaptureClock(epochHostTime: host(epoch))
        let backend = try await started(options(), clock: clock)
        stream.failStop = true
        for seconds in [0.1, 0.2] { stream.deliver(try frame(at: seconds), .screen) }
        await drain()

        let tracks = try await backend.stop(atHostTime: host(epoch + 0.5))

        XCTAssertEqual(backend.report.stopCaptureFailure, "the stream did not stop")
        XCTAssertNotNil(backend.report.router, "the router was closed")
        XCTAssertEqual(tracks.map(\.kind), [.screen])
        XCTAssertEqual(backend.report.frameReport?.written, 2)
    }

    // MARK: - Geometry and location

    func testGeometryIsTheNativePixelSizeOrRefused() throws {
        XCTAssertEqual(try CaptureSourceGeometry.whole(pointSize: CGSize(width: 1512, height: 982), scale: 2),
            CaptureSourceGeometry(pixelWidth: 3024, pixelHeight: 1964, sourceRect: nil))
        XCTAssertEqual(try CaptureSourceGeometry.whole(pointSize: CGSize(width: 800.5, height: 600), scale: 2),
            CaptureSourceGeometry(pixelWidth: 1601, pixelHeight: 1200, sourceRect: nil))
        for (size, scale) in [(CGSize(width: 800.25, height: 600), 2.0), (CGSize(width: 301, height: 200), 1.5), (CGSize(width: 0, height: 10), 2)] {
            XCTAssertThrowsError(try CaptureSourceGeometry.whole(pointSize: size, scale: CGFloat(scale)), "\(size) @\(scale)") {
                guard case .settingsNotProducible(let reason) = $0 as? CapturePrepareError else { return XCTFail("\($0)") }
                XCTAssertTrue(reason.contains("not a whole number of pixels"), reason)
            }
        }
    }

    func testAnAreaIsPlacedOnItsOwnDisplayFromTheTopLeft() throws {
        // A secondary display to the right of the main one, 200 points lower.
        let display = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
        let area = CaptureArea(x: 1612, y: -100, width: 400, height: 300, displayID: 2)

        let geometry = try CaptureSourceGeometry.area(area, displayFrame: display, scale: 2)

        XCTAssertEqual(geometry.sourceRect, CGRect(x: 100, y: 680, width: 400, height: 300))
        XCTAssertEqual(geometry.pixelWidth, 800)
        XCTAssertEqual(geometry.pixelHeight, 600)
        let outside = CaptureArea(x: 1400, y: 0, width: 400, height: 300, displayID: 2)
        XCTAssertThrowsError(try CaptureSourceGeometry.area(outside, displayFrame: display, scale: 2)) {
            guard case .settingsNotProducible = $0 as? CapturePrepareError else { return XCTFail("\($0)") }
        }
    }

    func testSourcesAreLocatedOrReportedGone() throws {
        let windows = [
            CaptureSourceLocator.Window(id: 7, bundleID: "com.other", title: "Doc", isOwnApplication: false),
            CaptureSourceLocator.Window(id: 9, bundleID: "com.editor", title: "Notes", isOwnApplication: false),
            CaptureSourceLocator.Window(id: 11, bundleID: "local.recordmac", title: "Record Mac", isOwnApplication: true),
        ]
        func window(_ id: UInt32?, bundle: String?, name: String) -> CaptureSource {
            CaptureSource(id: "w", kind: .window, name: name, subtitle: "", displayIndex: nil, displayID: nil,
                windowID: id, area: nil, thumbnailData: nil, ownerBundleID: bundle)
        }

        XCTAssertEqual(try CaptureSourceLocator.locate(source(), displays: [1, 2], windows: []), .display(1))
        XCTAssertThrowsError(try CaptureSourceLocator.locate(source(), displays: [2], windows: [])) {
            guard case .sourceUnavailable = $0 as? CapturePrepareError else { return XCTFail("\($0)") }
        }
        var area = source(.area)
        area.area = CaptureArea(x: 0, y: 0, width: 10, height: 10, displayID: 2)
        XCTAssertEqual(try CaptureSourceLocator.locate(area, displays: [1, 2], windows: []), .display(2))
        XCTAssertEqual(try CaptureSourceLocator.locate(window(9, bundle: "com.editor", name: "Notes"), displays: [], windows: windows), .window(9))
        XCTAssertEqual(try CaptureSourceLocator.locate(window(7, bundle: "com.editor", name: "Notes"), displays: [], windows: windows), .window(9),
            "a reused window ID owned by another app falls back to owner and title")
        XCTAssertThrowsError(try CaptureSourceLocator.locate(window(5, bundle: "com.gone", name: "Gone"), displays: [], windows: windows)) {
            guard case .sourceUnavailable = $0 as? CapturePrepareError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try CaptureSourceLocator.locate(window(11, bundle: nil, name: "Record Mac"), displays: [], windows: windows)) {
            guard case .settingsNotProducible = $0 as? CapturePrepareError else { return XCTFail("\($0)") }
        }
    }

    func testTheSessionEndOfAStopInsideAPauseIsThePauseStart() {
        let clock = CaptureClock(epochHostTime: host(epoch))
        XCTAssertTrue(clock.pause(atHostTime: host(epoch + 1)))
        XCTAssertTrue(clock.resume(atHostTime: host(epoch + 3)))
        XCTAssertTrue(clock.pause(atHostTime: host(epoch + 4)))
        let snapshot = clock.snapshot()
        XCTAssertNil(snapshot.sessionTime(endingAt: host(epoch - 1)))
        XCTAssertEqual(snapshot.sessionTime(endingAt: host(epoch + 2))?.seconds ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(snapshot.sessionTime(endingAt: host(epoch + 3.5))?.seconds ?? -1, 1.5, accuracy: 1e-9)
        XCTAssertEqual(snapshot.sessionTime(endingAt: host(epoch + 9))?.seconds ?? -1, 2, accuracy: 1e-9)
    }
}
