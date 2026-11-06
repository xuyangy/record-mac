import ApplicationServices
import CoreGraphics
import CoreMedia
import XCTest
@testable import RecordMac

/// `TelemetrySession` over stand-ins for the tap, the frontmost-window source, Accessibility, and
/// the geometry platform: nothing of the desktop is read or registered. The clock's epoch is host
/// 10 s. The recorded display is 1440 x 900 points at the origin, captured at 2880 x 1800, so a
/// point maps to capture coordinates at twice its offset from the display's origin. Every expected
/// time and coordinate is worked out by hand.
@MainActor
final class TelemetrySessionTests: XCTestCase {
    private final class FakeTap: PointerEventTap, @unchecked Sendable {
        var creates = true
        private let lock = NSLock()
        private var onSample: (@Sendable (PointerSample) -> Void)?
        private var onDisabled: (@Sendable (Bool) -> Void)?

        func start(onSample: @escaping @Sendable (PointerSample) -> Void, onDisabled: @escaping @Sendable (Bool) -> Void) -> Bool {
            guard creates else { return false }
            lock.withLock {
                self.onSample = onSample
                self.onDisabled = onDisabled
            }
            return true
        }

        /// The system disables the tap and enabling it again fails.
        func fail() {
            let onDisabled = lock.withLock { self.onDisabled }
            onDisabled?(false)
        }

        func stop() {}

        func move(atHostSeconds seconds: Double, to point: CGPoint) {
            let onSample = lock.withLock { self.onSample }
            onSample?(PointerSample(action: .move, timestamp: UInt64((seconds * 1e9).rounded()), location: point))
        }
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

        func frontmostWindow() -> FrontmostWindowLookup {
            lock.withLock { window.map { .window($0) } ?? .unavailable }
        }

        func observe(atHostSeconds seconds: Double) {
            let onChange = lock.withLock { self.onChange }
            onChange?(CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))
        }
    }

    /// Finds nothing, or holds one lookup until the test releases it.
    private final class FakeAccessibility: AccessibilityQueries, @unchecked Sendable {
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

    /// One display; main-thread work waits in a queue until the test runs it; the host time of a
    /// reading is whatever the test set.
    private final class FakePlatform: SourceGeometryPlatform, @unchecked Sendable {
        private let lock = NSLock()
        private var mainThread: Thread?
        private var queued: [@Sendable () -> Void] = []
        private var handlers: [@Sendable () -> Void] = []
        var now = CMTime(value: 10, timescale: 1)
        var attached = [ObservedDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)]

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

        /// Moves the display to `origin` at host `seconds` and fires the reconfiguration.
        func reconfigure(atHostSeconds seconds: Double, origin: CGPoint? = nil, detached: Bool = false) {
            lock.withLock {
                now = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
                if let origin { attached[0].bounds.origin = origin }
                if detached { attached = [] }
            }
            let handlers = lock.withLock { self.handlers }
            asMain { handlers.forEach { $0() } }
        }

        func setNow(_ seconds: Double) {
            lock.withLock { now = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000) }
        }
    }

    private let tap = FakeTap()
    private let windows = FakeWindows()
    private let accessibility = FakeAccessibility()
    private let platform = FakePlatform()
    private let clock = CaptureClock(epochHostTime: CMTime(value: 10, timescale: 1))
    private let frame = CaptureFrameGeometry(pixelSize: PixelSize(width: 2880, height: 1800), scaleFactor: 2)
    private let window = WindowDescriptor(bundleIdentifier: "com.example.editor", windowID: 7, frame: CGRect(x: 0, y: 0, width: 800, height: 600))

    private var initial: SourceGeometry {
        SourceGeometry(sourceRect: CGRect(x: 0, y: 0, width: 1440, height: 900), pixelSize: frame.pixelSize, scaleFactor: 2)
    }

    private func host(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1_000_000_000) }

    private func session(initial: SourceGeometry? = nil, filter: ActivityEventFilter = ActivityEventFilter()) throws -> TelemetrySession {
        let frame = frame
        return try TelemetrySession(
            clock: clock, target: .display(1), initial: initial ?? self.initial, frame: { frame }, filter: filter,
            resolver: TargetResolver(accessibility: accessibility), tap: tap, windows: windows,
            observer: SourceGeometryObserver(platform: platform))
    }

    private func moves(_ stream: ActivityStream) -> [(TimeInterval, CGPoint?)] {
        stream.events.filter { $0.kind == .pointerMove }.map { ($0.timestamp, $0.location) }
    }

    private func assertMoves(_ stream: ActivityStream, _ expected: [(TimeInterval, CGPoint)],
                             file: StaticString = #filePath, line: UInt = #line) {
        let actual = moves(stream)
        XCTAssertEqual(actual.count, expected.count, "pointer moves", file: file, line: line)
        for (got, want) in zip(actual, expected) {
            XCTAssertEqual(got.0, want.0, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(got.1, want.1, file: file, line: line)
        }
    }

    /// Blocks until `semaphore` is signalled; a synchronous wait is not allowed directly in an
    /// async test.
    private nonisolated static func wait(for semaphore: DispatchSemaphore) {
        semaphore.wait()
    }

    // MARK: Recording

    /// The initial geometry, the first window, and a pointer move at host 11 s at (720, 450),
    /// which maps to (1440, 900).
    func testItFreezesTheInitialGeometryWindowAndEvents() async throws {
        let session = try session()
        windows.window = window
        XCTAssertEqual(try session.start(), .running)
        platform.runMain()
        windows.observe(atHostSeconds: 10.5)
        tap.move(atHostSeconds: 11, to: CGPoint(x: 720, y: 450))
        let outcome = try await session.stop()

        XCTAssertEqual(outcome.stream.geometry, [initial.segment(at: 0)])
        XCTAssertEqual(outcome.stream.events.first?.kind, .activeWindowChange)
        XCTAssertEqual(outcome.stream.events.first?.timestamp ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(outcome.stream.events.first?.window, window)
        assertMoves(outcome.stream, [(1, CGPoint(x: 1440, y: 900))])
        XCTAssertEqual(outcome.activity, .idle)
        XCTAssertEqual(outcome.counts.delivered, 1)
        XCTAssertEqual(outcome.geometry.unchanged, 1, "the start reading matches the initial geometry")
        XCTAssertEqual(outcome.coverage, SourceGeometryCoverage(displayReconfiguration: true, windowMoveAndResize: false))
    }

    /// The display moves to x 100 at host 12 s. A move at 11.5 s delivered after that still maps
    /// with the old geometry, (720, 450) to (1440, 900); a move at 12.5 s at (820, 450) maps with
    /// the new one, to ((820 - 100) x 2, 900) = (1440, 900).
    func testEachEventMapsWithTheGeometryOfItsOwnTime() async throws {
        let session = try session()
        try session.start()
        platform.runMain()
        platform.reconfigure(atHostSeconds: 12, origin: CGPoint(x: 100, y: 0))
        tap.move(atHostSeconds: 11.5, to: CGPoint(x: 720, y: 450))
        tap.move(atHostSeconds: 12.5, to: CGPoint(x: 820, y: 450))
        let outcome = try await session.stop()

        var moved = initial
        moved.sourceRect.origin.x = 100
        XCTAssertEqual(outcome.stream.geometry, [initial.segment(at: 0), moved.segment(at: 2)])
        assertMoves(outcome.stream, [(1.5, CGPoint(x: 1440, y: 900)), (2.5, CGPoint(x: 1440, y: 900))])
    }

    /// An event still resolving its target when the stop is asked for is delivered before the
    /// stream freezes.
    func testAnEventStillResolvingIsInTheStream() async throws {
        let session = try session()
        try session.start()
        platform.runMain()
        let gate = accessibility.hold()
        tap.move(atHostSeconds: 11, to: CGPoint(x: 10, y: 20))
        Self.wait(for: gate.entered)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { gate.release.signal() }
        let outcome = try await session.stop()
        assertMoves(outcome.stream, [(1, CGPoint(x: 20, y: 40))])
    }

    /// A source change while the stop waits for an event still resolving does not enter the
    /// stream: geometry observation stops at the stop request.
    func testASourceChangeWhileTheStopDrainsIsNotRecorded() async throws {
        let session = try session()
        try session.start()
        platform.runMain()
        let gate = accessibility.hold()
        tap.move(atHostSeconds: 11, to: CGPoint(x: 10, y: 20))
        Self.wait(for: gate.entered)
        let platform = platform
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            platform.reconfigure(atHostSeconds: 12, origin: CGPoint(x: 100, y: 0))
            gate.release.signal()
        }
        let outcome = try await session.stop()
        XCTAssertEqual(outcome.stream.geometry, [initial.segment(at: 0)])
        XCTAssertEqual(outcome.geometry, GeometryFeedCounts(unchanged: 1))
        assertMoves(outcome.stream, [(1, CGPoint(x: 20, y: 40))])
    }

    /// Paused at host 12 s, resumed at 13 s, so session time is host - 10 before the pause and
    /// host - 11 after it. A move at 11.9 s delivered after the pause keeps its time, 1.9. The
    /// display moves during the pause, and that reading has no session time, so it adds nothing;
    /// a move inside the pause is dropped. At the resume the window is read as of 2.0, and the
    /// geometry is read at host 13.2 s (session 2.2), not backdated to the resume. A move at 13.1 s
    /// (session 2.1) still maps with the old geometry; one at 13.3 s (2.3) with the new.
    func testAPauseAddsNothingAndTheResumeReadsAfresh() async throws {
        let session = try session()
        try session.start()
        platform.runMain()
        windows.window = window
        windows.observe(atHostSeconds: 10.5)

        XCTAssertTrue(clock.pause(atHostTime: host(12)))
        tap.move(atHostSeconds: 11.9, to: CGPoint(x: 720, y: 450))
        platform.reconfigure(atHostSeconds: 12.5, origin: CGPoint(x: 100, y: 0))
        tap.move(atHostSeconds: 12.6, to: CGPoint(x: 720, y: 450))
        XCTAssertTrue(clock.resume(atHostTime: host(13)))
        var moved = window
        moved.windowID = 8
        windows.window = moved
        platform.setNow(13.2)
        session.didResume(atHostTime: host(13))
        tap.move(atHostSeconds: 13.1, to: CGPoint(x: 720, y: 450))
        platform.runMain()
        tap.move(atHostSeconds: 13.3, to: CGPoint(x: 820, y: 450))
        let outcome = try await session.stop()

        var shifted = initial
        shifted.sourceRect.origin.x = 100
        XCTAssertEqual(outcome.stream.geometry.count, 2)
        XCTAssertEqual(outcome.stream.geometry.first?.start, 0)
        XCTAssertEqual(outcome.stream.geometry.last?.start ?? -1, 2.2, accuracy: 1e-9)
        XCTAssertEqual(outcome.stream.geometry.last?.sourceRect, shifted.sourceRect)
        assertMoves(outcome.stream, [(1.9, CGPoint(x: 1440, y: 900)), (2.1, CGPoint(x: 1440, y: 900)), (2.3, CGPoint(x: 1440, y: 900))])
        let windowEvents = outcome.stream.events.filter { $0.kind == .activeWindowChange }
        XCTAssertEqual(windowEvents.map(\.window?.windowID), [7, 8])
        XCTAssertEqual(windowEvents.last?.timestamp ?? -1, 2, accuracy: 1e-9)
        XCTAssertEqual(outcome.counts.droppedNoSessionTime, 1)
        XCTAssertEqual(outcome.geometry.noSessionTime, 1)
        XCTAssertEqual(outcome.geometry.added, 1)
    }

    /// Stopped while paused: what came before the pause is kept.
    func testItStopsWhilePaused() async throws {
        let session = try session()
        try session.start()
        platform.runMain()
        tap.move(atHostSeconds: 11, to: CGPoint(x: 1, y: 1))
        XCTAssertTrue(clock.pause(atHostTime: host(12)))
        let outcome = try await session.stop()
        assertMoves(outcome.stream, [(1, CGPoint(x: 2, y: 2))])
    }

    /// Suspended activity recording drops pointer events but geometry is still recorded.
    func testSuspendingActivityStillRecordsGeometry() async throws {
        let filter = ActivityEventFilter()
        filter.setSuspended(true)
        let session = try session(filter: filter)
        try session.start()
        platform.runMain()
        tap.move(atHostSeconds: 11, to: CGPoint(x: 1, y: 1))
        platform.reconfigure(atHostSeconds: 12, origin: CGPoint(x: 100, y: 0))
        let outcome = try await session.stop()
        XCTAssertTrue(outcome.stream.events.isEmpty)
        XCTAssertEqual(outcome.stream.geometry.count, 2)
        XCTAssertEqual(outcome.counts.droppedSuspended, 1)
    }

    // MARK: Failures and lifecycle

    /// Without a tap, geometry is still observed, and the outcome says activity was unavailable.
    func testWithoutATapGeometryIsStillRecordedAndTheOutcomeSaysSo() async throws {
        tap.creates = false
        let session = try session()
        XCTAssertEqual(try session.start(), .tapUnavailable)
        platform.runMain()
        platform.reconfigure(atHostSeconds: 12, origin: CGPoint(x: 100, y: 0))
        let outcome = try await session.stop()
        XCTAssertEqual(outcome.activity, .tapUnavailable)
        XCTAssertTrue(outcome.stream.events.isEmpty)
        XCTAssertEqual(outcome.stream.geometry.count, 2)
    }

    /// The system disables the tap for good after one move: that move is drained into the
    /// stream, geometry is still recorded, and the outcome says the tap failed.
    func testAfterATapFailureAdmittedEventsAndGeometryAreKept() async throws {
        let session = try session()
        try session.start()
        platform.runMain()
        tap.move(atHostSeconds: 11, to: CGPoint(x: 10, y: 20))
        tap.fail()
        tap.move(atHostSeconds: 11.5, to: CGPoint(x: 30, y: 40))
        platform.reconfigure(atHostSeconds: 12, origin: CGPoint(x: 100, y: 0))
        let outcome = try await session.stop()
        XCTAssertEqual(outcome.activity, .tapFailed)
        assertMoves(outcome.stream, [(1, CGPoint(x: 20, y: 40))])
        XCTAssertEqual(outcome.stream.geometry.count, 2)
        XCTAssertEqual(outcome.counts.delivered, 1)
    }

    /// A detached display is counted, and the geometry in force stands.
    func testAnUnavailableSourceKeepsTheGeometryInForce() async throws {
        let session = try session()
        try session.start()
        platform.runMain()
        platform.reconfigure(atHostSeconds: 12, detached: true)
        tap.move(atHostSeconds: 12.5, to: CGPoint(x: 10, y: 10))
        let outcome = try await session.stop()
        XCTAssertEqual(outcome.stream.geometry, [initial.segment(at: 0)])
        XCTAssertEqual(outcome.geometry.unavailable, 1)
        assertMoves(outcome.stream, [(2.5, CGPoint(x: 20, y: 20))])
    }

    func testAnInvalidInitialGeometryIsRefused() {
        var empty = initial
        empty.sourceRect.size.width = 0
        XCTAssertThrowsError(try session(initial: empty)) {
            XCTAssertEqual($0 as? GeometryRecorderError, .invalidGeometry)
        }
    }

    /// Calls out of phase throw and change nothing; callbacks after the stop reach nothing.
    func testCallsOutOfPhaseThrowAndLateCallbacksAreIgnored() async throws {
        let session = try session()
        do {
            _ = try await session.stop()
            XCTFail("a stop before start")
        } catch {
            XCTAssertEqual(error as? TelemetrySessionError, .notStarted)
        }
        try session.start()
        XCTAssertThrowsError(try session.start()) { XCTAssertEqual($0 as? TelemetrySessionError, .alreadyStarted) }
        platform.runMain()
        let outcome = try await session.stop()

        tap.move(atHostSeconds: 11, to: CGPoint(x: 1, y: 1))
        platform.reconfigure(atHostSeconds: 12, origin: CGPoint(x: 100, y: 0))
        session.didResume(atHostTime: host(12))
        platform.runMain()
        XCTAssertTrue(outcome.stream.events.isEmpty)
        XCTAssertEqual(outcome.stream.geometry.count, 1)
        do {
            _ = try await session.stop()
            XCTFail("a second stop")
        } catch {
            XCTAssertEqual(error as? TelemetrySessionError, .alreadyStopped)
        }
        XCTAssertThrowsError(try session.start()) { XCTAssertEqual($0 as? TelemetrySessionError, .alreadyStopped) }
    }
}
