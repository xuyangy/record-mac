import CoreMedia
@preconcurrency import ScreenCaptureKit
import XCTest
@testable import RecordMac

/// `RecordingPipeline` on the real engine and backend over the stand-in stream, with a spy
/// telemetry or none: no desktop, tap, or hot key of the system. The epoch is host 1000 s.
@MainActor
final class RecordingPipelineTests: XCTestCase {
    /// Records each call; its outcome is empty, so a stop makes the report `recorded`.
    private final class SpyTelemetry: BackendTelemetry {
        var calls: [String] = []
        func start() throws -> TelemetryRecorderStatus {
            calls.append("start")
            return .running
        }
        func didResume(atHostTime hostTime: CMTime) { calls.append("resume \(hostTime.seconds)") }
        func stop() async throws -> TelemetryOutcome {
            calls.append("stop")
            return TelemetryOutcome(stream: ActivityStream(events: [], geometry: []), activity: .idle,
                counts: TelemetryRecorderCounts(), geometry: GeometryFeedCounts(), coverage: nil)
        }
    }

    private let epoch = 1000.0
    private var root: URL!
    private var stream: FakeCaptureStream!
    private var now = CMTime.zero
    private var permitted = true
    private var spy: SpyTelemetry?
    private var factoryClock: CaptureClock?
    private var factoryFilter: ActivityEventFilter?
    private var backends: [ScreenCaptureBackend] = []
    /// While set, the source's resolution waits here until the test resumes it.
    private var holdsResolve = false
    private var heldResolve: CheckedContinuation<Void, Never>?

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("recording-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        stream = FakeCaptureStream()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var captureDirectory: URL { root.appendingPathComponent("capture") }
    private var projects: URL { root.appendingPathComponent("Projects") }

    private func host(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }
    private func at(_ seconds: Double) { now = host(epoch + seconds) }

    private func pipeline(telemetry: Bool = true, filter: ActivityEventFilter = ActivityEventFilter()) -> RecordingPipeline {
        let stream = stream!
        let factory: BackendTelemetryFactory? = telemetry ? { [unowned self] clock, _, filter in
            factoryClock = clock
            factoryFilter = filter
            let made = SpyTelemetry()
            spy = made
            return made
        } : nil
        return RecordingPipeline(
            captureDirectory: captureDirectory, activityFilter: filter, refreshRate: { _ in .hertz(60) },
            hostTimeNow: { [unowned self] in now },
            makeBackend: { [unowned self] directory, filter in
                let backend = ScreenCaptureBackend(
                    directory: directory,
                    resolve: { [unowned self] _ in
                        if holdsResolve { await withCheckedContinuation { heldResolve = $0 } }
                        return ResolvedCaptureSource(filter: nil,
                            geometry: CaptureSourceGeometry(pixelWidth: 256, pixelHeight: 144, sourceRect: nil),
                            deviceID: "display:1", location: .display(1), pointPixelScale: 1)
                    },
                    makeStream: { _, _, _ in stream },
                    hasPermission: { [unowned self] in permitted },
                    microphonePermitted: { true },
                    hostTimeNow: { [unowned self] in now },
                    telemetry: factory,
                    activityFilter: filter)
                backends.append(backend)
                return backend
            })
    }

    private func options() -> CaptureEngineOptions {
        CaptureEngineOptions(microphoneDeviceID: nil, systemAudio: false, cameraDeviceID: nil,
            includesPointer: false, frameRate: 60, wantsAlpha: false, keepsPresenterComposite: false)
    }

    private func source() -> CaptureSource {
        CaptureSource(id: "display:1", kind: .display, name: "Display 1", subtitle: "", displayIndex: 1, displayID: 1,
            windowID: nil, area: nil, thumbnailData: nil)
    }

    private let metadata = RecordingMetadata(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!, displayName: "Demo",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000), sourceDescription: "Display 1")

    private func deliver(_ seconds: Double) async throws {
        stream.deliver(try ScreenFrameFixtures.frame(atHostSeconds: epoch + seconds), .screen)
        let queue = try XCTUnwrap(backends.last).sampleQueue
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    private func started(_ pipeline: RecordingPipeline) async throws -> CaptureClock {
        at(0)
        return try await pipeline.start(source(), options())
    }

    private func captureFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: captureDirectory.path).sorted()
    }

    // MARK: Lifecycle and publication

    /// One recording through the engine and backend, on one clock and the pipeline's filter, with
    /// its pause, published and read back.
    func testARecordingIsFinalizedAndPublishedAsAProject() async throws {
        let filter = ActivityEventFilter()
        let pipeline = pipeline(filter: filter)
        let clock = try await started(pipeline)
        XCTAssertTrue(factoryClock === clock)
        XCTAssertTrue(factoryFilter === filter)
        XCTAssertTrue(pipeline.activityFilter === filter)
        XCTAssertEqual(clock.epochHostTime, host(epoch))
        try await deliver(0.1)
        at(0.3); try await pipeline.pause()
        at(0.5); try await pipeline.resume()
        try await deliver(0.6)
        at(1.0)
        let finalized = try await pipeline.finalize()

        XCTAssertEqual(pipeline.state, .finalized)
        XCTAssertEqual(spy?.calls, ["start", "resume 1000.5", "stop"])
        XCTAssertEqual(finalized.end, .requested)
        XCTAssertEqual(finalized.endHostTime, host(epoch + 1.0))
        XCTAssertEqual(finalized.pauses, [CaptureTimeRange(start: 0.3, end: 0.5)])
        XCTAssertEqual(finalized.clockReference, clock.reference)
        XCTAssertEqual(finalized.tracks.map(\.kind), [.screen])
        XCTAssertEqual(finalized.report.telemetry.status, .recorded)

        let result = try finalized.publish(named: "Demo", in: projects, metadata: metadata)
        let project = try result.store.readProject()
        XCTAssertEqual(project.id, metadata.id)
        XCTAssertEqual(project.displayName, "Demo")
        XCTAssertEqual(project.createdAt, metadata.createdAt)
        XCTAssertEqual(project.sourceDescription, "Display 1")
        XCTAssertEqual(project.captureClock, clock.reference)
        XCTAssertEqual(project.pauses, [CaptureTimeRange(start: 0.3, end: 0.5)])
        XCTAssertEqual(project.endReason, .completed)
        XCTAssertEqual(project.overlaidRanges, [])
        XCTAssertEqual(project.frameReport, finalized.report.frameReport)
        XCTAssertEqual(project.frameReport.written, 2)
        XCTAssertEqual(project.mediaTracks.map(\.kind), [.screen])
        XCTAssertEqual(try captureFiles(), ["screen-0.mov"], "the capture is copied, not moved")
    }

    /// A pause still open at the stop ends at the stop.
    func testAStopInsideAPauseClosesItAtTheStop() async throws {
        let pipeline = pipeline()
        _ = try await started(pipeline)
        try await deliver(0.1)
        at(0.3); try await pipeline.pause()
        at(0.8)
        let finalized = try await pipeline.finalize()
        XCTAssertEqual(finalized.end, .requested)
        XCTAssertEqual(finalized.pauses, [CaptureTimeRange(start: 0.3, end: 0.8)])
        let project = try finalized.publish(named: "Demo", in: projects, metadata: metadata).store.readProject()
        XCTAssertEqual(project.pauses, [CaptureTimeRange(start: 0.3, end: 0.8)])
    }

    // MARK: A stream that stops on its own

    /// The recording ends where the stream stopped. A pause and resume after it, before the owner's
    /// stop, are left out; the end is not classified until the caller says why.
    func testAStreamThatStopsOnItsOwnEndsTheRecordingAndNeedsAReason() async throws {
        let pipeline = pipeline()
        _ = try await started(pipeline)
        try await deliver(0.1)
        at(0.2); try XCTUnwrap(backends.last).stopObserver.streamDidStop(reason: "the display was disconnected")
        at(0.3); try await pipeline.pause()
        at(0.4); try await pipeline.resume()
        at(0.6)
        let finalized = try await pipeline.finalize()

        XCTAssertEqual(finalized.endHostTime, host(epoch + 0.2))
        XCTAssertEqual(finalized.pauses, [])
        XCTAssertEqual(finalized.end, .streamStopped(reason: "the display was disconnected"))
        XCTAssertThrowsError(try finalized.publish(named: "Demo", in: projects, metadata: metadata)) {
            XCTAssertEqual($0 as? RecordingPublishError, .endNotClassified(reason: "the display was disconnected"))
        }
        XCTAssertThrowsError(try finalized.publish(named: "Demo", in: projects, metadata: metadata, streamStopReason: .completed)) {
            XCTAssertEqual($0 as? RecordingPublishError, .completedIsNotAStreamStop)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: projects.path), [], "nothing written")

        let project = try finalized.publish(named: "Demo", in: projects, metadata: metadata, streamStopReason: .sourceLost)
            .store.readProject()
        XCTAssertEqual(project.endReason, .sourceLost)
        XCTAssertEqual(project.pauses, [])
    }

    /// A pause under way when the stream stops is trimmed at that stop.
    func testAPauseCrossingAnEarlyEndIsTrimmedToIt() async throws {
        let pipeline = pipeline()
        _ = try await started(pipeline)
        try await deliver(0.05)
        at(0.1); try await pipeline.pause()
        at(0.2); try XCTUnwrap(backends.last).stopObserver.streamDidStop(reason: "the display was disconnected")
        at(0.3); try await pipeline.resume()
        at(0.6)
        let finalized = try await pipeline.finalize()
        XCTAssertEqual(finalized.pauses, [CaptureTimeRange(start: 0.1, end: 0.2)])
    }

    /// A stream that stops on its own only after the owner's stop ends nothing early.
    func testAStreamStopAfterTheStopIsARequestedEnd() async throws {
        let pipeline = pipeline()
        _ = try await started(pipeline)
        try await deliver(0.1)
        stream.whileStopping = { [unowned self] in
            backends.last?.stopObserver.streamDidStop(reason: "stopped while stopping")
        }
        at(0.5)
        let finalized = try await pipeline.finalize()
        XCTAssertEqual(finalized.end, .requested)
        XCTAssertEqual(finalized.endHostTime, host(epoch + 0.5))
    }

    // MARK: Publication failures keep the finalised recording

    /// A telemetry report that is not recorded is refused; the capture stays, and nothing is stopped
    /// again.
    func testUnrecordedTelemetryLeavesTheFinalizedRecording() async throws {
        let pipeline = pipeline(telemetry: false)
        _ = try await started(pipeline)
        try await deliver(0.1)
        at(0.5)
        let finalized = try await pipeline.finalize()
        XCTAssertThrowsError(try finalized.publish(named: "Demo", in: projects, metadata: metadata)) {
            XCTAssertEqual($0 as? ProjectWriterError, .telemetryNotRecorded(.disabled))
        }
        XCTAssertEqual(stream.stopCalls, 1)
        XCTAssertEqual(try captureFiles(), ["screen-0.mov"])
        XCTAssertEqual(finalized.tracks.map(\.kind), [.screen])
        XCTAssertEqual(pipeline.finalized?.captureDirectory.standardizedFileURL.path, captureDirectory.standardizedFileURL.path)
    }

    /// A publish that fails, at the name or while writing, is tried again from the same value.
    func testAFailedPublishIsRetriedWithoutAnotherStop() async throws {
        let pipeline = pipeline()
        _ = try await started(pipeline)
        try await deliver(0.1)
        at(0.5)
        let finalized = try await pipeline.finalize()

        try FileManager.default.createDirectory(at: projects.appendingPathComponent("Demo.recordmac"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try finalized.publish(named: "Demo", in: projects, metadata: metadata)) {
            guard case .alreadyExists = $0 as? ProjectWriterError else { return XCTFail("\($0)") }
        }
        struct Injected: Error {}
        XCTAssertThrowsError(try finalized.publish(named: "Other", in: projects, metadata: metadata) {
            if $0 == .publish { throw Injected() }
        })
        let result = try finalized.publish(named: "Other", in: projects, metadata: metadata)
        XCTAssertEqual(try result.store.readProject().frameReport.written, 1)
        XCTAssertEqual(stream.stopCalls, 1)
        XCTAssertEqual(try captureFiles(), ["screen-0.mov"])
    }

    /// Measured data that is missing is refused, never filled in.
    func testMissingMeasurementsAreNotPublished() throws {
        var finalized = FinalizedRecording(
            captureDirectory: captureDirectory, tracks: [], report: ScreenCaptureBackendReport(),
            clockReference: CaptureClockReference(epochHostTimeNanoseconds: 1), endHostTime: host(epoch + 1),
            pauses: [], end: .requested)
        XCTAssertThrowsError(try finalized.publish(named: "Demo", in: projects, metadata: metadata)) {
            XCTAssertEqual($0 as? RecordingPublishError, .noFrameReport)
        }
        finalized.endHostTime = nil
        XCTAssertThrowsError(try finalized.publish(named: "Demo", in: projects, metadata: metadata)) {
            XCTAssertEqual($0 as? RecordingPublishError, .clockNotEnded)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: projects.path), [])
    }

    // MARK: Start failures

    /// A refused prepare creates nothing and leaves the pipeline idle, so it can start later.
    func testARefusedPrepareLeavesThePipelineIdle() async throws {
        permitted = false
        let pipeline = pipeline()
        do {
            _ = try await started(pipeline)
            XCTFail("start accepted")
        } catch {
            XCTAssertEqual(error as? CapturePrepareError, .permissionMissing("Screen Recording"))
        }
        XCTAssertEqual(pipeline.state, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectory.path))

        permitted = true
        _ = try await started(pipeline)
        XCTAssertEqual(pipeline.state, .recording)
    }

    /// A start that fails runs the cleanup stop and keeps both the error and what was finalised; no
    /// stream or telemetry is left running, and the pipeline takes no further call.
    func testAFailedStartIsCleanedUp() async throws {
        stream.failStart = true
        let pipeline = pipeline()
        do {
            _ = try await started(pipeline)
            XCTFail("start accepted")
        } catch RecordingPipelineError.startFailed(let primary, let cleanup) {
            XCTAssertEqual("\(primary)", "the stream did not start")
            let finalized = try cleanup.get()
            XCTAssertEqual(finalized.report.startFailure, "the stream did not start")
            XCTAssertEqual(finalized.report.telemetry.status, .notStarted)
            XCTAssertEqual(finalized.tracks, [])
            XCTAssertEqual(finalized.captureDirectory.standardizedFileURL.path, captureDirectory.standardizedFileURL.path)
        }
        XCTAssertNil(spy, "no telemetry was made")
        XCTAssertFalse(stream.started)
        XCTAssertEqual(stream.stopCalls, 0, "a stream that never started is not stopped")
        XCTAssertEqual(pipeline.state, .startFailed)
        await assertRefused(pipeline, .startFailed)
    }

    // MARK: Refused calls

    func testCallsOutsideTheirStateAreRefused() async throws {
        let pipeline = pipeline()
        do { try await pipeline.pause(); XCTFail("pause accepted") } catch {
            guard case RecordingPipelineError.illegalCall(.idle, "pause") = error else { return XCTFail("\(error)") }
        }
        do { _ = try await pipeline.finalize(); XCTFail("finalize accepted") } catch {
            guard case RecordingPipelineError.illegalCall(.idle, "finalize") = error else { return XCTFail("\(error)") }
        }

        at(0)
        holdsResolve = true
        let (source, options) = (source(), options())
        let first = Task { try await pipeline.start(source, options) }
        while heldResolve == nil { await Task.yield() }
        do { _ = try await pipeline.start(source, options); XCTFail("second start accepted") } catch {
            guard case RecordingPipelineError.illegalCall(.starting, "start") = error else { return XCTFail("\(error)") }
        }
        do { try await pipeline.pause(); XCTFail("pause accepted") } catch {
            guard case RecordingPipelineError.illegalCall(.starting, "pause") = error else { return XCTFail("\(error)") }
        }
        heldResolve?.resume()
        _ = try await first.value
        XCTAssertEqual(pipeline.state, .recording)
        XCTAssertEqual(backends.count, 1, "one backend")

        try await deliver(0.1)
        at(0.5)
        let finalized = try await pipeline.finalize()
        await assertRefused(pipeline, .finalized)
        XCTAssertEqual(stream.stopCalls, 1)
        XCTAssertEqual(pipeline.finalized?.endHostTime, finalized.endHostTime)
        XCTAssertEqual(pipeline.finalized?.tracks, finalized.tracks)
    }

    /// Every call is refused in `state`, changing nothing.
    private func assertRefused(_ pipeline: RecordingPipeline, _ state: RecordingPipeline.State) async {
        do { _ = try await pipeline.start(source(), options()); XCTFail("start accepted") } catch {
            guard case RecordingPipelineError.illegalCall(state, "start") = error else { return XCTFail("\(error)") }
        }
        do { try await pipeline.pause(); XCTFail("pause accepted") } catch {
            guard case RecordingPipelineError.illegalCall(state, "pause") = error else { return XCTFail("\(error)") }
        }
        do { try await pipeline.resume(); XCTFail("resume accepted") } catch {
            guard case RecordingPipelineError.illegalCall(state, "resume") = error else { return XCTFail("\(error)") }
        }
        do { _ = try await pipeline.finalize(); XCTFail("finalize accepted") } catch {
            guard case RecordingPipelineError.illegalCall(state, "finalize") = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(pipeline.state, state)
    }
}
