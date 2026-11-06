import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreMedia
@preconcurrency import ScreenCaptureKit
import XCTest
@testable import RecordMac

/// Activity telemetry inside `ScreenCaptureBackend`, against the stand-in stream, a spy telemetry,
/// or a real `TelemetrySession` on stand-in tap, Accessibility, and geometry platform: no tap,
/// observer, or desktop of the system. The epoch is host 1000 s; the prepared frame is 256 x 144
/// on a display of 256 x 144 points at the origin, scale 1, so a point maps to itself.
@MainActor
final class BackendTelemetryTests: XCTestCase {
    /// Records each call, and the stream's state at it.
    private final class SpyTelemetry: BackendTelemetry {
        var calls: [String] = []
        var failStop = false
        let stream: FakeCaptureStream
        init(stream: FakeCaptureStream) { self.stream = stream }

        func start() throws -> TelemetryRecorderStatus {
            calls.append("start streamStarted=\(stream.started)")
            return .running
        }

        func didResume(atHostTime hostTime: CMTime) { calls.append("resume \(hostTime.seconds)") }

        func stop() async throws -> TelemetryOutcome {
            calls.append("stop stopCalls=\(stream.stopCalls)")
            if failStop { throw TelemetrySessionError.alreadyStopped }
            return TelemetryOutcome(stream: ActivityStream(events: [], geometry: []), activity: .idle,
                counts: TelemetryRecorderCounts(), geometry: GeometryFeedCounts(), coverage: nil)
        }
    }

    private final class FakeTap: PointerEventTap, @unchecked Sendable {
        private let lock = NSLock()
        private var onSample: (@Sendable (PointerSample) -> Void)?

        func start(onSample: @escaping @Sendable (PointerSample) -> Void, onDisabled: @escaping @Sendable (Bool) -> Void) -> Bool {
            lock.withLock { self.onSample = onSample }
            return true
        }

        func stop() {}

        func move(atHostSeconds seconds: Double, to point: CGPoint) {
            let onSample = lock.withLock { self.onSample }
            onSample?(PointerSample(action: .move, timestamp: UInt64((seconds * 1e9).rounded()), location: point))
        }
    }

    /// Finds nothing, or holds one lookup until the test releases it.
    private final class NoAccessibility: AccessibilityQueries, @unchecked Sendable {
        private let lock = NSLock()
        private var gate: (entered: DispatchSemaphore, release: DispatchSemaphore)?

        func hold() -> (entered: DispatchSemaphore, release: DispatchSemaphore) {
            let gate = (entered: DispatchSemaphore(value: 0), release: DispatchSemaphore(value: 0))
            lock.withLock { self.gate = gate }
            return gate
        }

        func isTrusted() -> Bool { true }
        func element(at point: CGPoint) -> AccessibilityLookup {
            if let gate = lock.withLock({ () -> (entered: DispatchSemaphore, release: DispatchSemaphore)? in
                defer { gate = nil }
                return gate
            }) {
                gate.entered.signal()
                gate.release.wait()
            }
            return .none
        }
        func focusedElement() -> AccessibilityLookup { .none }
        func copyAttribute(_ attribute: String, of element: AccessibilityElement) -> (AXError, CFTypeRef?) { (.noValue, nil) }
    }

    private final class FakeWindows: FrontmostWindowSource, @unchecked Sendable {
        private let lock = NSLock()
        private var onChange: (@Sendable (CMTime) -> Void)?
        var window: WindowDescriptor?

        func start(onChange: @escaping @Sendable (CMTime) -> Void) -> Bool {
            lock.withLock { self.onChange = onChange }
            return true
        }

        func stop() {}
        func frontmostWindow() -> FrontmostWindowLookup { lock.withLock { window.map { .window($0) } ?? .unavailable } }

        func observe(atHostSeconds seconds: Double) {
            let onChange = lock.withLock { self.onChange }
            onChange?(CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))
        }
    }

    /// Carbon stand-in: one handler, every registration accepted.
    private final class FakeHotKeySystem: HotKeySystem {
        private(set) var dispatch: ((EventHotKeyID, Bool) -> Bool)?
        private(set) var ids: [EventHotKeyID] = []

        func installHandler(_ dispatch: @escaping (EventHotKeyID, Bool) -> Bool) -> OSStatus {
            self.dispatch = dispatch
            return noErr
        }

        func removeHandler() { dispatch = nil }

        func register(_ combination: ShortcutCombination, id: EventHotKeyID) -> (OSStatus, EventHotKeyRef?) {
            ids.append(id)
            return (noErr, EventHotKeyRef(bitPattern: ids.count))
        }

        func unregister(_ reference: EventHotKeyRef) {}

        /// Presses and releases the last registered hot key, as the user would.
        func pressAndRelease() {
            guard let id = ids.last else { return }
            _ = dispatch?(id, false)
            _ = dispatch?(id, true)
        }
    }

    private final class FakePlatform: SourceGeometryPlatform, @unchecked Sendable {
        private let lock = NSLock()
        private var mainThread: Thread?
        private var queued: [@Sendable () -> Void] = []
        private var handlers: [@Sendable () -> Void] = []
        private var now = CMTime.zero
        private var attached = [ObservedDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 256, height: 144), scale: 1)]

        func isMainThread() -> Bool { lock.withLock { mainThread === Thread.current } }
        func onMain(_ work: @escaping @Sendable () -> Void) { lock.withLock { queued.append(work) } }

        func asMain(_ work: () -> Void) {
            lock.withLock { mainThread = Thread.current }
            work()
            lock.withLock { mainThread = nil }
        }

        func runMain() {
            while let work = lock.withLock({ queued.isEmpty ? nil : queued.removeFirst() }) { asMain(work) }
        }

        func observeDisplayReconfiguration(_ handler: @escaping @Sendable () -> Void) -> AnyObject? {
            lock.withLock { handlers.append(handler) }
            return NSObject()
        }

        func stopObservingDisplayReconfiguration(_ handle: AnyObject) {}
        func isTrusted() -> Bool { false }
        func windowOwner(_ id: CGWindowID) -> pid_t? { nil }
        func observeWindowGeometry(of pid: pid_t, _ handler: @escaping @Sendable () -> Void) -> AnyObject? { nil }
        func stopObservingWindowGeometry(_ handle: AnyObject) {}
        func hostTimeNow() -> CMTime { lock.withLock { now } }
        func displays() -> [ObservedDisplay] { lock.withLock { attached } }
        func windowBounds(_ id: CGWindowID) -> CGRect? { nil }

        /// Moves the display to x 100 at host `seconds` and fires the reconfiguration there.
        func moveDisplay(atHostSeconds seconds: Double) {
            lock.withLock {
                now = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
                attached[0].bounds.origin.x = 100
            }
            let handlers = lock.withLock { self.handlers }
            asMain { handlers.forEach { $0() } }
        }
    }

    private let epoch = 1000.0
    private var directory: URL!
    private var stream: FakeCaptureStream!
    private var now = CMTime.zero
    private let tap = FakeTap()
    private let platform = FakePlatform()
    private let windows = FakeWindows()
    private let accessibility = NoAccessibility()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("backend-telemetry-\(UUID().uuidString)")
        stream = FakeCaptureStream()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func host(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }

    private let initial = SourceGeometry(sourceRect: CGRect(x: 0, y: 0, width: 256, height: 144),
        pixelSize: PixelSize(width: 256, height: 144), scaleFactor: 1)

    private func backend(
        telemetry: BackendTelemetryFactory?, activityFilter: ActivityEventFilter = ActivityEventFilter()
    ) -> ScreenCaptureBackend {
        let stream = stream!
        return ScreenCaptureBackend(
            directory: directory,
            resolve: { _ in
                ResolvedCaptureSource(filter: nil, geometry: CaptureSourceGeometry(pixelWidth: 256, pixelHeight: 144, sourceRect: nil),
                    deviceID: "display:1", location: .display(1), pointPixelScale: 1)
            },
            makeStream: { _, _, _ in stream },
            hasPermission: { true },
            microphonePermitted: { true },
            hostTimeNow: { [unowned self] in now },
            telemetry: telemetry,
            activityFilter: activityFilter)
    }

    /// A real session on the stand-ins, from the resolved source's target and prepared frame.
    private func sessionFactory(
        made: ((CaptureClock) -> Void)? = nil, filterGiven: ((ActivityEventFilter) -> Void)? = nil
    ) -> BackendTelemetryFactory {
        let (tap, platform, initial, windows, accessibility) = (tap, platform, initial, windows, accessibility)
        return { clock, resolved, filter in
            made?(clock)
            filterGiven?(filter)
            let frame = resolved.preparedFrame!
            return try TelemetrySession(
                clock: clock, target: SourceGeometryTarget(resolved.location!, geometry: resolved.geometry),
                initial: initial, frame: { frame }, filter: filter,
                resolver: TargetResolver(accessibility: accessibility), tap: tap, windows: windows,
                observer: SourceGeometryObserver(platform: platform))
        }
    }

    private func options() -> CaptureEngineOptions {
        CaptureEngineOptions(microphoneDeviceID: nil, systemAudio: false, cameraDeviceID: nil,
            includesPointer: false, frameRate: 60, wantsAlpha: false, keepsPresenterComposite: false)
    }

    private func source() -> CaptureSource {
        CaptureSource(id: "display:1", kind: .display, name: "Display 1", subtitle: "", displayIndex: 1, displayID: 1,
            windowID: nil, area: nil, thumbnailData: nil)
    }

    private func started(_ backend: ScreenCaptureBackend, clock: CaptureClock) async throws {
        try await backend.validate(source(), options())
        try await backend.start(clock: clock)
    }

    private func drain(_ backend: ScreenCaptureBackend) async {
        await withCheckedContinuation { continuation in backend.sampleQueue.async { continuation.resume() } }
    }

    private func frame(at seconds: Double, width: Int = 256, height: Int = 144) throws -> CMSampleBuffer {
        try ScreenFrameFixtures.frame(atHostSeconds: epoch + seconds, width: width, height: height)
    }

    // MARK: Lifecycle

    /// Telemetry is made on the recording's own clock once the stream has started, is told of a
    /// resume with its host time, and is stopped before the stream is.
    func testTelemetryFollowsTheStreamOnTheSameClock() async throws {
        let clock = CaptureClock(epochHostTime: host(epoch))
        var spy: SpyTelemetry?
        var madeWith: CaptureClock?
        let stream = stream!
        now = host(epoch + 0.05)
        let backend = backend(telemetry: { clock, _, _ in
            madeWith = clock
            let made = SpyTelemetry(stream: stream)
            spy = made
            return made
        })
        try await started(backend, clock: clock)
        XCTAssertTrue(madeWith === clock)
        XCTAssertEqual(backend.report.telemetry.status, .running)
        XCTAssertEqual(backend.report.telemetry.startedAt, host(epoch + 0.05), "collected from the start, not the epoch")
        try await backend.resume(atHostTime: host(epoch + 1))
        _ = try await backend.stop(atHostTime: host(epoch + 2))

        XCTAssertEqual(spy?.calls, ["start streamStarted=true", "resume 1001.0", "stop stopCalls=0"])
        XCTAssertEqual(backend.report.telemetry.status, .recorded)
    }

    func testAStreamThatDoesNotStartLeavesNoTelemetry() async throws {
        stream.failStart = true
        var made = 0
        let backend = backend(telemetry: sessionFactory(made: { _ in made += 1 }))
        do {
            try await started(backend, clock: CaptureClock(epochHostTime: host(epoch)))
            XCTFail("start accepted")
        } catch {}
        _ = try await backend.stop(atHostTime: host(epoch + 1))
        XCTAssertEqual(made, 0)
        XCTAssertEqual(backend.report.telemetry.status, .notStarted)
    }

    func testTelemetryTurnedOffIsReportedAsDisabled() async throws {
        let backend = backend(telemetry: nil)
        try await started(backend, clock: CaptureClock(epochHostTime: host(epoch)))
        _ = try await backend.stop(atHostTime: host(epoch + 1))
        XCTAssertEqual(backend.report.telemetry.status, .disabled)
        XCTAssertNil(backend.report.telemetry.outcome)
    }

    /// A telemetry that cannot be made, or fails at its stop, is reported; the media are recorded
    /// and finalised all the same.
    func testATelemetryFailureNeverFailsTheMedia() async throws {
        let refused = backend(telemetry: { _, _, _ in throw BackendTelemetryError.sourceNotLocated })
        try await started(refused, clock: CaptureClock(epochHostTime: host(epoch)))
        stream.deliver(try frame(at: 0.1), .screen)
        await drain(refused)
        let tracks = try await refused.stop(atHostTime: host(epoch + 0.5))
        XCTAssertEqual(tracks.map(\.kind), [.screen])
        XCTAssertEqual(refused.report.telemetry.status, .failed("start: \(BackendTelemetryError.sourceNotLocated)"))

        // A second recording, in its own directory: the first one's files are still there.
        try? FileManager.default.removeItem(at: directory)
        directory = directory.appendingPathExtension("second")
        stream = FakeCaptureStream()
        let stream = stream!
        let failing = backend(telemetry: { _, _, _ in
            let spy = SpyTelemetry(stream: stream)
            spy.failStop = true
            return spy
        })
        try await started(failing, clock: CaptureClock(epochHostTime: host(epoch)))
        stream.deliver(try frame(at: 0.1), .screen)
        await drain(failing)
        let kept = try await failing.stop(atHostTime: host(epoch + 0.5))
        XCTAssertEqual(kept.map(\.kind), [.screen])
        XCTAssertEqual(stream.stopCalls, 1)
        XCTAssertEqual(failing.report.frameReport?.written, 1)
        XCTAssertEqual(failing.report.telemetry.status, .failed("stop: \(TelemetrySessionError.alreadyStopped)"))
    }

    // MARK: Suspension

    private nonisolated static func wait(for semaphore: DispatchSemaphore) { semaphore.wait() }

    private let window = WindowDescriptor(bundleIdentifier: "com.example.editor", windowID: 7, frame: CGRect(x: 0, y: 0, width: 100, height: 100))

    /// The shortcut and the recording share one filter. A move still resolving when the shortcut
    /// suspends is kept; while suspended a move and a window observation are dropped, but a display
    /// move is recorded; after the shortcut resumes, a move and a fresh window observation are
    /// recorded. The window is only known again from that fresh observation, not from the toggle.
    func testTheSuspensionShortcutSuspendsTheRecordingsActivity() async throws {
        let filter = ActivityEventFilter()
        let system = FakeHotKeySystem()
        let shortcut = ActivitySuspensionShortcut(registrar: GlobalShortcutRegistrar(system: system), filter: filter)
        shortcut.bind(ShortcutCombination(keyCode: UInt32(kVK_F17), modifiers: UInt32(cmdKey | optionKey)))
        var given: ActivityEventFilter?
        let backend = backend(telemetry: sessionFactory(filterGiven: { given = $0 }), activityFilter: filter)
        try await started(backend, clock: CaptureClock(epochHostTime: host(epoch)))
        platform.runMain()
        XCTAssertTrue(given === filter, "the factory gets the backend's filter")
        XCTAssertEqual(backend.report.telemetry.suspendedAtStart, false)

        let gate = accessibility.hold()
        tap.move(atHostSeconds: epoch + 0.1, to: CGPoint(x: 10, y: 10))
        Self.wait(for: gate.entered)
        system.pressAndRelease()
        XCTAssertTrue(filter.isSuspended)
        gate.release.signal()
        windows.window = window
        tap.move(atHostSeconds: epoch + 0.2, to: CGPoint(x: 20, y: 20))
        windows.observe(atHostSeconds: epoch + 0.25)
        platform.moveDisplay(atHostSeconds: epoch + 0.3)
        system.pressAndRelease()
        XCTAssertFalse(filter.isSuspended)
        tap.move(atHostSeconds: epoch + 0.4, to: CGPoint(x: 40, y: 40))
        windows.observe(atHostSeconds: epoch + 0.45)
        _ = try await backend.stop(atHostTime: host(epoch + 0.9))

        let outcome = try XCTUnwrap(backend.report.telemetry.outcome)
        XCTAssertEqual(outcome.stream.events.map(\.kind), [.pointerMove, .pointerMove, .activeWindowChange])
        XCTAssertEqual(outcome.stream.events.map(\.timestamp).map { ($0 * 100).rounded() / 100 }, [0.1, 0.4, 0.45])
        XCTAssertEqual(outcome.stream.geometry.count, 2, "geometry goes on while suspended")
        XCTAssertEqual(outcome.counts.droppedSuspended, 1)
        XCTAssertEqual(outcome.counts.windows.droppedSuspended, 1)
        XCTAssertEqual(backend.report.telemetry.status, .recorded, "suspension is not a failure")
        XCTAssertEqual(backend.report.telemetry.suspendedAtStart, false, "the snapshot is of the start only")
    }

    /// A filter suspended before the first recording stays suspended through a pause and resume
    /// and into a later recording of another backend, until its owner changes it.
    func testASuspendedFilterStaysSuspendedUntilItsOwnerChangesIt() async throws {
        let filter = ActivityEventFilter()
        filter.setSuspended(true)
        let clock = CaptureClock(epochHostTime: host(epoch))
        let first = backend(telemetry: sessionFactory(), activityFilter: filter)
        try await started(first, clock: clock)
        platform.runMain()
        XCTAssertEqual(first.report.telemetry.suspendedAtStart, true)
        XCTAssertTrue(clock.pause(atHostTime: host(epoch + 0.2)))
        XCTAssertTrue(clock.resume(atHostTime: host(epoch + 0.3)))
        try await first.resume(atHostTime: host(epoch + 0.3))
        platform.runMain()
        XCTAssertTrue(filter.isSuspended, "a capture resume does not lift it")
        tap.move(atHostSeconds: epoch + 0.4, to: CGPoint(x: 1, y: 1))
        _ = try await first.stop(atHostTime: host(epoch + 0.9))
        XCTAssertTrue(filter.isSuspended, "nor does the stop")
        XCTAssertEqual(first.report.telemetry.outcome?.stream.events, [])

        try? FileManager.default.removeItem(at: directory)
        directory = directory.appendingPathExtension("second")
        stream = FakeCaptureStream()
        let second = backend(telemetry: sessionFactory(), activityFilter: filter)
        try await started(second, clock: CaptureClock(epochHostTime: host(epoch)))
        platform.runMain()
        XCTAssertEqual(second.report.telemetry.suspendedAtStart, true)
        tap.move(atHostSeconds: epoch + 0.1, to: CGPoint(x: 1, y: 1))
        filter.setSuspended(false)
        tap.move(atHostSeconds: epoch + 0.2, to: CGPoint(x: 2, y: 2))
        _ = try await second.stop(atHostTime: host(epoch + 0.9))
        XCTAssertEqual(second.report.telemetry.outcome?.stream.events.map(\.location), [CGPoint(x: 2, y: 2)])
    }

    /// Telemetry that never started has no snapshot.
    func testNoSnapshotWithoutTelemetry() async throws {
        let filter = ActivityEventFilter()
        filter.setSuspended(true)
        let disabled = backend(telemetry: nil, activityFilter: filter)
        try await started(disabled, clock: CaptureClock(epochHostTime: host(epoch)))
        _ = try await disabled.stop(atHostTime: host(epoch + 0.5))
        XCTAssertNil(disabled.report.telemetry.suspendedAtStart)
        XCTAssertTrue(filter.isSuspended)
    }

    // MARK: Bounds of the recording

    /// The stream stops on its own at 0.25 s. A move at 0.3 s and a display move at 0.3 s are
    /// collected before the stop ends the clock; both are left out, the move at 0.1 s is kept.
    func testActivityAfterAnEarlySourceLossIsLeftOut() async throws {
        let clock = CaptureClock(epochHostTime: host(epoch))
        let backend = backend(telemetry: sessionFactory())
        try await started(backend, clock: clock)
        platform.runMain()
        tap.move(atHostSeconds: epoch + 0.1, to: CGPoint(x: 10, y: 10))
        now = host(epoch + 0.25)
        backend.stopObserver.streamDidStop(reason: "the display was disconnected")
        tap.move(atHostSeconds: epoch + 0.3, to: CGPoint(x: 20, y: 20))
        platform.moveDisplay(atHostSeconds: epoch + 0.3)

        _ = try await backend.stop(atHostTime: host(epoch + 0.9))

        let outcome = try XCTUnwrap(backend.report.telemetry.outcome)
        XCTAssertEqual(outcome.stream.events.map(\.timestamp), [0.1].map { $0 })
        XCTAssertEqual(outcome.stream.events.first?.location, CGPoint(x: 10, y: 10))
        XCTAssertEqual(outcome.stream.geometry, [initial.segment(at: 0)])
        XCTAssertEqual(backend.report.telemetry.removedAfterEnd, .init(events: 1, geometry: 1))
        XCTAssertEqual(backend.report.telemetry.status, .recorded)
    }

    /// While the stream stops, a move and a display move from before the stop arrive: telemetry
    /// has already stopped, so neither enters the outcome.
    func testNothingIsCollectedWhileTheMediaShutDown() async throws {
        let clock = CaptureClock(epochHostTime: host(epoch))
        let backend = backend(telemetry: sessionFactory())
        try await started(backend, clock: clock)
        platform.runMain()
        tap.move(atHostSeconds: epoch + 0.1, to: CGPoint(x: 10, y: 10))
        let (tap, platform, epoch) = (tap, platform, epoch)
        stream.whileStopping = {
            tap.move(atHostSeconds: epoch + 0.45, to: CGPoint(x: 20, y: 20))
            platform.moveDisplay(atHostSeconds: epoch + 0.45)
        }

        _ = try await backend.stop(atHostTime: host(epoch + 0.5))

        let outcome = try XCTUnwrap(backend.report.telemetry.outcome)
        XCTAssertEqual(outcome.stream.events.count, 1)
        XCTAssertEqual(outcome.stream.geometry, [initial.segment(at: 0)])
        XCTAssertEqual(backend.report.telemetry.removedAfterEnd, .init())
    }

    // MARK: Frame size

    /// The screen switches to 512 x 288 mid-recording: the prepared 256 x 144 frame every geometry
    /// segment assumes no longer holds, so the outcome is incomplete.
    func testAFrameSizeOtherThanThePreparedOneMakesTelemetryIncomplete() async throws {
        let clock = CaptureClock(epochHostTime: host(epoch))
        let backend = backend(telemetry: sessionFactory())
        try await started(backend, clock: clock)
        platform.runMain()
        stream.deliver(try frame(at: 0.1), .screen)
        stream.deliver(try frame(at: 0.2, width: 512, height: 288), .screen)
        stream.deliver(try frame(at: 0.3, width: 512, height: 288), .screen)
        await drain(backend)
        _ = try await backend.stop(atHostTime: host(epoch + 0.5))
        XCTAssertEqual(backend.report.telemetry.status, .incomplete([
            .frameSizeChanged(prepared: PixelSize(width: 256, height: 144), seen: [PixelSize(width: 512, height: 288)]),
        ]))
        XCTAssertNotNil(backend.report.telemetry.outcome)
    }

    /// Every size seen counts, including a segment that wrote no file, and only a recorded
    /// outcome is marked.
    func testTheFrameSizeCheckCountsEverySizeSeen() {
        let prepared = PixelSize(width: 256, height: 144)
        let other = PixelSize(width: 512, height: 288)
        var report = BackendTelemetryReport()
        report.status = .recorded
        report.checkFrameSizes(prepared: prepared, seen: [prepared, prepared])
        XCTAssertEqual(report.status, .recorded)
        report.checkFrameSizes(prepared: prepared, seen: [prepared, other, other])
        XCTAssertEqual(report.status, .incomplete([.frameSizeChanged(prepared: prepared, seen: [other])]))
        var failed = BackendTelemetryReport()
        failed.status = .failed("stop")
        failed.checkFrameSizes(prepared: prepared, seen: [other])
        XCTAssertEqual(failed.status, .failed("stop"))
    }

    // MARK: Geometry construction

    /// An area on a display left of and above the main one: the area given in AppKit's global
    /// space becomes a display-local crop, which telemetry places at the display's global
    /// top-left origin. Main display 1440 x 900; the other is 1920 x 1080 with CG bounds at
    /// (-1920, -300), so its AppKit frame is at (-1920, 900 - (-300 + 1080)) = (-1920, 120). The
    /// area 400 x 300 at AppKit (-1900, 870) lies 20 points in and 1200 - 870 - 300 = 30 down, so
    /// its global top-left rect is (-1900, -270).
    func testAnAreaOnAnotherDisplayIsPlacedInGlobalTopLeftPoints() throws {
        let area = CaptureArea(x: -1900, y: 870, width: 400, height: 300, displayID: 2)
        let prepared = try CaptureSourceGeometry.area(area, displayFrame: CGRect(x: -1920, y: 120, width: 1920, height: 1080), scale: 2)
        XCTAssertEqual(prepared.sourceRect, CGRect(x: 20, y: 30, width: 400, height: 300))
        let resolved = ResolvedCaptureSource(filter: nil, geometry: prepared, deviceID: "display:2",
            location: .display(2), pointPixelScale: 2)
        let target = SourceGeometryTarget(try XCTUnwrap(resolved.location), geometry: resolved.geometry)
        let displays = [
            ObservedDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2),
            ObservedDisplay(id: 2, bounds: CGRect(x: -1920, y: -300, width: 1920, height: 1080), scale: 2),
        ]
        XCTAssertEqual(target.read(displays: displays, windowBounds: { _ in nil }, frame: resolved.preparedFrame),
            .geometry(SourceGeometry(sourceRect: CGRect(x: -1900, y: -270, width: 400, height: 300),
                pixelSize: PixelSize(width: 800, height: 600), scaleFactor: 2)))
    }

    func testASourceWithoutLocationOrScaleHasNoTelemetry() throws {
        let resolved = ResolvedCaptureSource(filter: nil, geometry: CaptureSourceGeometry(pixelWidth: 256, pixelHeight: 144, sourceRect: nil),
            deviceID: "display:1")
        XCTAssertNil(resolved.preparedFrame)
        XCTAssertThrowsError(try ScreenCaptureBackend.systemTelemetry(CaptureClock(epochHostTime: host(epoch)), resolved, ActivityEventFilter())) {
            XCTAssertEqual($0 as? BackendTelemetryError, .sourceNotLocated)
        }
    }
}
