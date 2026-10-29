import CoreMedia
import XCTest
@testable import RecordMac

@MainActor
final class CaptureEngineTests: XCTestCase {
    /// Records every call; each call can fail or be held until the test releases it.
    private final class FakeBackend: CaptureBackend {
        enum Call: Equatable {
            case validate
            case start(epoch: CMTime)
            case pause(CMTime)
            case resume(CMTime)
            case stop(CMTime)
        }

        var validationError: Error?
        var failing: Set<String> = []
        var held: String?
        /// Runs at the start of each pause and resume, before the backend finishes it.
        var onEntry: ((String, CaptureClock) -> Void)?
        private var release: CheckedContinuation<Void, Never>?
        private(set) var calls: [Call] = []
        private(set) var startedClock: CaptureClock?
        let tracks = [MediaTrack(kind: .microphone, segments: [], requestedFrameRate: nil, endedEarlyAt: nil)]

        struct Failure: Error {}

        func validate(_ source: CaptureSource, _ options: CaptureEngineOptions) async throws {
            calls.append(.validate)
            if let validationError { throw validationError }
        }

        func start(clock: CaptureClock) async throws {
            calls.append(.start(epoch: clock.epochHostTime))
            startedClock = clock
            try await finish("start")
        }

        func pause(atHostTime hostTime: CMTime) async throws {
            calls.append(.pause(hostTime))
            if let startedClock { onEntry?("pause", startedClock) }
            try await finish("pause")
        }

        func resume(atHostTime hostTime: CMTime) async throws {
            calls.append(.resume(hostTime))
            if let startedClock { onEntry?("resume", startedClock) }
            try await finish("resume")
        }

        func stop(atHostTime hostTime: CMTime) async throws -> [MediaTrack] {
            calls.append(.stop(hostTime))
            try await finish("stop")
            return tracks
        }

        func releaseHeld() {
            held = nil
            release?.resume()
            release = nil
        }

        private func finish(_ call: String) async throws {
            if held == call {
                await withCheckedContinuation { release = $0 }
            }
            if failing.contains(call) { throw Failure() }
        }
    }

    private final class Ticker {
        var seconds: Int64 = 100
        func next() -> CMTime {
            seconds += 1
            return CMTime(value: seconds, timescale: 1)
        }
    }

    private let source = CaptureSource(id: "display:1", kind: .display, name: "Display", subtitle: "",
        displayIndex: 1, displayID: 1, windowID: nil, area: nil, thumbnailData: nil)

    private func options(fps: Int = 60) -> CaptureEngineOptions {
        CaptureEngineOptions(microphoneDeviceID: "mic", systemAudio: true, cameraDeviceID: "cam",
            includesPointer: false, frameRate: fps, wantsAlpha: false, keepsPresenterComposite: false)
    }

    private func engine(
        _ backend: FakeBackend, refresh: RefreshRate = .hertz(120), ticker: Ticker = Ticker()
    ) -> CaptureEngine {
        CaptureEngine(makeBackend: { _ in backend }, refreshRate: { _ in refresh }, hostTimeNow: ticker.next)
    }

    private func seconds(_ value: Int64) -> CMTime { CMTime(value: value, timescale: 1) }

    private func assertRejected(
        _ call: () async throws -> Void, _ expected: CaptureEngineError,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await call()
            XCTFail("accepted", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CaptureEngineError, expected, file: file, line: line)
        }
    }

    // MARK: Offers and prepare

    func testOffersFollowTheSourceRefreshRateAndHeadroomIsNotMeasured() {
        let backend = FakeBackend()
        XCTAssertEqual(engine(backend, refresh: .hertz(60)).offers(source).frameRates, [30, 60])
        XCTAssertEqual(engine(backend, refresh: .hertz(120)).offers(source).frameRates, [30, 60, 120])
        XCTAssertEqual(engine(backend, refresh: .hertz(240)).offers(source).frameRates, [30, 60, 120, 240])
        XCTAssertEqual(engine(backend, refresh: .unknown("adaptive")).offers(source).frameRates, [30, 60])
        let offers = engine(backend, refresh: .hertz(240)).offers(source).rates
        XCTAssertTrue(offers.allSatisfy { $0.headroom == .notMeasured && $0.warning == nil })
    }

    func testARateNotOfferedIsRefusedBeforeTheBackendIsAsked() async {
        let backend = FakeBackend()
        do {
            _ = try await engine(backend, refresh: .hertz(60)).prepare(source, options(fps: 120))
            XCTFail("prepared")
        } catch {
            guard case .settingsNotProducible(let reason) = error as? CapturePrepareError else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertTrue(reason.contains("120 fps"), reason)
        }
        XCTAssertEqual(backend.calls, [])
    }

    func testTheBackendsPrepareReasonReachesTheCaller() async {
        let backend = FakeBackend()
        backend.validationError = CapturePrepareError.cameraHeldByAnotherApplication
        do {
            _ = try await engine(backend).prepare(source, options())
            XCTFail("prepared")
        } catch {
            XCTAssertEqual(error as? CapturePrepareError, .cameraHeldByAnotherApplication)
        }
    }

    // MARK: Transitions

    func testALegalSessionSharesOneClockAndOneInstantPerTransition() async throws {
        let backend = FakeBackend()
        let engine = engine(backend)
        let session = try await engine.prepare(source, options())
        XCTAssertEqual(session.phase, .prepared)

        let clock = try await engine.start(session)
        XCTAssertTrue(clock === backend.startedClock)
        XCTAssertTrue(clock === session.clock)
        XCTAssertEqual(clock.epochHostTime, seconds(101))
        try await engine.pause(session)
        XCTAssertTrue(clock.isPaused)
        try await engine.resume(session)
        XCTAssertFalse(clock.isPaused)
        let tracks = try await engine.stop(session)

        XCTAssertEqual(backend.calls, [.validate, .start(epoch: seconds(101)), .pause(seconds(102)), .resume(seconds(103)), .stop(seconds(104))])
        XCTAssertEqual(clock.sessionTime(forHostTime: seconds(104)), seconds(2), "the paused second is not session time")
        XCTAssertEqual(tracks, backend.tracks)
        XCTAssertEqual(session.phase, .stopped)
    }

    func testStopWhilePausedDoesNotResume() async throws {
        let backend = FakeBackend()
        let engine = engine(backend)
        let session = try await engine.prepare(source, options())
        let clock = try await engine.start(session)
        try await engine.pause(session)
        _ = try await engine.stop(session)
        XCTAssertEqual(backend.calls.last, .stop(seconds(103)))
        XCTAssertFalse(backend.calls.contains { if case .resume = $0 { return true } else { return false } })
        XCTAssertTrue(clock.isPaused)
    }

    func testIllegalCallsAreRejectedWithoutTouchingTheBackendOrClock() async throws {
        let backend = FakeBackend()
        let engine = engine(backend)
        let session = try await engine.prepare(source, options())
        await assertRejected({ try await engine.pause(session) }, .illegalTransition(phase: .prepared, call: "pause"))
        await assertRejected({ try await engine.resume(session) }, .illegalTransition(phase: .prepared, call: "resume"))
        await assertRejected({ _ = try await engine.stop(session) }, .illegalTransition(phase: .prepared, call: "stop"))

        let clock = try await engine.start(session)
        await assertRejected({ _ = try await engine.start(session) }, .illegalTransition(phase: .recording, call: "start"))
        await assertRejected({ try await engine.resume(session) }, .illegalTransition(phase: .recording, call: "resume"))
        try await engine.pause(session)
        await assertRejected({ try await engine.pause(session) }, .illegalTransition(phase: .paused, call: "pause"))
        _ = try await engine.stop(session)
        await assertRejected({ _ = try await engine.stop(session) }, .illegalTransition(phase: .stopped, call: "stop"))
        await assertRejected({ try await engine.resume(session) }, .illegalTransition(phase: .stopped, call: "resume"))

        XCTAssertEqual(backend.calls, [.validate, .start(epoch: seconds(101)), .pause(seconds(102)), .stop(seconds(103))])
        XCTAssertTrue(clock.isPaused)
    }

    func testAnotherEnginesSessionIsRejected() async throws {
        let backend = FakeBackend()
        let session = try await engine(backend).prepare(source, options())
        let other = engine(FakeBackend())
        await assertRejected({ _ = try await other.start(session) }, .notThisEngine)
        XCTAssertEqual(session.phase, .prepared)
        XCTAssertEqual(backend.calls, [.validate])
    }

    func testACallWhileATransitionIsUnderWayIsRejected() async throws {
        let backend = FakeBackend()
        let engine = engine(backend)
        let session = try await engine.prepare(source, options())
        _ = try await engine.start(session)
        backend.held = "pause"
        let pausing = Task { try await engine.pause(session) }
        while backend.calls.count < 3 { await Task.yield() }
        XCTAssertEqual(session.phase, .pausing)
        await assertRejected({ try await engine.pause(session) }, .illegalTransition(phase: .pausing, call: "pause"))
        await assertRejected({ _ = try await engine.stop(session) }, .illegalTransition(phase: .pausing, call: "stop"))
        backend.releaseHeld()
        try await pausing.value
        XCTAssertEqual(session.phase, .paused)
        XCTAssertEqual(backend.calls.count, 3)
    }

    // MARK: Backend failures

    func testTheClockAlreadyHasEachInstantWhileTheBackendIsInTheTransition() async throws {
        let backend = FakeBackend()
        var seen: [String: (paused: Bool, atBoundary: CMTime?)] = [:]
        backend.onEntry = { call, clock in
            let boundary = call == "pause" ? CMTime(value: 102, timescale: 1) : CMTime(value: 103, timescale: 1)
            seen[call] = (clock.isPaused, clock.sessionTime(forHostTime: boundary))
        }
        let engine = engine(backend)
        let session = try await engine.prepare(source, options())
        _ = try await engine.start(session)

        backend.held = "pause"
        let pausing = Task { try await engine.pause(session) }
        while seen["pause"] == nil { await Task.yield() }
        XCTAssertEqual(seen["pause"]?.paused, true)
        XCTAssertNil(seen["pause"]?.atBoundary, "a sample at the pause instant is already paused")
        backend.releaseHeld()
        try await pausing.value

        backend.held = "resume"
        let resuming = Task { try await engine.resume(session) }
        while seen["resume"] == nil { await Task.yield() }
        XCTAssertEqual(seen["resume"]?.paused, false)
        XCTAssertEqual(seen["resume"]?.atBoundary, seconds(1), "a sample at the resume instant already has session time")
        backend.releaseHeld()
        try await resuming.value
    }

    func testAFailedPauseKeepsTheClockPausedAndAllowsOnlyStop() async throws {
        let backend = FakeBackend()
        backend.failing = ["pause"]
        let engine = engine(backend)
        let session = try await engine.prepare(source, options())
        let clock = try await engine.start(session)
        do {
            try await engine.pause(session)
            XCTFail("paused")
        } catch {
            XCTAssertTrue(error is FakeBackend.Failure)
        }
        XCTAssertEqual(session.phase, .failed)
        XCTAssertTrue(clock.isPaused, "the clock is not rolled back")
        await assertRejected({ try await engine.resume(session) }, .illegalTransition(phase: .failed, call: "resume"))
        _ = try await engine.stop(session)
        XCTAssertEqual(session.phase, .stopped)
    }

    func testAFailedResumeKeepsTheClockRunning() async throws {
        let backend = FakeBackend()
        backend.failing = ["resume"]
        let engine = engine(backend)
        let session = try await engine.prepare(source, options())
        let clock = try await engine.start(session)
        try await engine.pause(session)
        do {
            try await engine.resume(session)
            XCTFail("resumed")
        } catch {}
        XCTAssertEqual(session.phase, .failed)
        XCTAssertFalse(clock.isPaused, "the clock is not rolled back")
    }

    func testAFailedStartGivesNoClockAndAllowsStop() async throws {
        let backend = FakeBackend()
        backend.failing = ["start"]
        let engine = engine(backend)
        let session = try await engine.prepare(source, options())
        do {
            _ = try await engine.start(session)
            XCTFail("started")
        } catch {}
        XCTAssertEqual(session.phase, .failed)
        XCTAssertNil(session.clock)
        _ = try await engine.stop(session)
        XCTAssertEqual(session.phase, .stopped)
    }

    func testAFailedStopStillEndsTheSession() async throws {
        let backend = FakeBackend()
        backend.failing = ["stop"]
        let engine = engine(backend)
        let session = try await engine.prepare(source, options())
        _ = try await engine.start(session)
        do {
            _ = try await engine.stop(session)
            XCTFail("stopped cleanly")
        } catch {}
        XCTAssertEqual(session.phase, .stopped)
        await assertRejected({ _ = try await engine.stop(session) }, .illegalTransition(phase: .stopped, call: "stop"))
    }
}
