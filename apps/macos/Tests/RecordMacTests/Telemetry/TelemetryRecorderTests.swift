import ApplicationServices
import CoreGraphics
import CoreMedia
import XCTest
@testable import RecordMac

final class TelemetryRecorderTests: XCTestCase {
    /// Delivers samples when the test says, never from the system.
    private final class FakeTap: PointerEventTap, @unchecked Sendable {
        var creates = true
        var disableDuringStart = false
        private(set) var onSample: (@Sendable (PointerSample) -> Void)?
        private(set) var onDisabled: (@Sendable (Bool) -> Void)?
        private(set) var stops = 0

        func start(
            onSample: @escaping @Sendable (PointerSample) -> Void,
            onDisabled: @escaping @Sendable (Bool) -> Void
        ) -> Bool {
            guard creates else { return false }
            self.onSample = onSample
            self.onDisabled = onDisabled
            if disableDuringStart { onDisabled(false) }
            return true
        }

        /// When set, `stop` waits for it, standing in for a slow shutdown.
        var holdStop: DispatchSemaphore?
        let stopEntered = DispatchSemaphore(value: 0)

        func stop() {
            stops += 1
            if let holdStop {
                stopEntered.signal()
                holdStop.wait()
            }
        }

        func send(_ samples: PointerSample...) {
            samples.forEach { onSample?($0) }
        }
    }

    /// Resolves every point to one button, fails, or waits for the test.
    private final class FakeAccessibility: AccessibilityQueries, @unchecked Sendable {
        var fails = false
        var gate: (entered: DispatchSemaphore, release: DispatchSemaphore)?
        private let element = AccessibilityElement(NSObject())

        func isTrusted() -> Bool { true }

        func element(at point: CGPoint) -> AccessibilityLookup {
            if let gate {
                self.gate = nil
                gate.entered.signal()
                gate.release.wait()
            }
            return fails ? .failed(.cannotComplete) : .element(element)
        }

        func focusedElement() -> AccessibilityLookup { .none }

        func copyAttribute(_ attribute: String, of element: AccessibilityElement) -> (AXError, CFTypeRef?) {
            attribute == kAXRoleAttribute ? (.success, "AXButton" as CFString) : (.noValue, nil)
        }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [GlobalActivityEvent] = []
        var events: [GlobalActivityEvent] { lock.withLock { stored } }
        func append(_ event: GlobalActivityEvent) { lock.withLock { stored.append(event) } }
    }

    /// Holds work the recorder schedules off the tap's thread until the test runs it.
    private final class HeldWork: @unchecked Sendable {
        private let lock = NSLock()
        private var work: [@Sendable () -> Void] = []
        func add(_ item: @escaping @Sendable () -> Void) { lock.withLock { work.append(item) } }
        func runAll() { lock.withLock { work }.forEach { $0() } }
        var count: Int { lock.withLock { work.count } }
    }

    private static let second: UInt64 = 1_000_000_000
    private let epoch = CMTime(value: 10, timescale: 1)

    private func at(_ seconds: Double, _ action: PointerSample.Action = .move, button: Int = 0,
                    point: CGPoint = CGPoint(x: -20, y: 30)) -> PointerSample {
        PointerSample(action: action, timestamp: UInt64(seconds * 1e9), location: point, button: button)
    }

    private func makeRecorder(
        tap: FakeTap = FakeTap(),
        filter: ActivityEventFilter = ActivityEventFilter(),
        accessibility: FakeAccessibility = FakeAccessibility(),
        clock: CaptureClock? = nil,
        capacity: Int = 4096,
        held: HeldWork? = nil,
        sink: (@Sendable (GlobalActivityEvent) -> Void)? = nil
    ) -> (TelemetryRecorder, Collected) {
        let collected = Collected()
        let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void =
            held.map { held in { held.add($0) } } ?? { DispatchQueue.global().async(execute: $0) }
        let recorder = TelemetryRecorder(
            clock: clock ?? CaptureClock(epochHostTime: epoch), filter: filter,
            resolver: TargetResolver(accessibility: accessibility), tap: tap, capacity: capacity,
            schedule: schedule, sink: sink ?? { collected.append($0) })
        return (recorder, collected)
    }

    private func stopAndWait(_ recorder: TelemetryRecorder) -> TelemetryRecorderCounts {
        let done = expectation(description: "stopped")
        let result = LockedCounts()
        recorder.stop { counts in
            result.value = counts
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return result.value
    }

    // MARK: Pure parts

    func testTimestampsAreNanosecondsSinceStartupAndZeroIsUnset() {
        XCTAssertEqual(PointerSample.hostTime(1_500_000_000), CMTime(value: 1_500_000_000, timescale: 1_000_000_000))
        XCTAssertNil(PointerSample.hostTime(0))
        XCTAssertNil(PointerSample.hostTime(UInt64.max))
    }

    func testSyntheticPointerEventsAreReadAndKeyEventsAreNot() throws {
        let location = CGPoint(x: -300, y: 12)
        let down = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: location, mouseButton: .right))
        down.timestamp = 42
        XCTAssertEqual(PointerSample(down), PointerSample(action: .down, timestamp: 42, location: location, button: 1))
        let drag = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDragged, mouseCursorPosition: location, mouseButton: .center))
        XCTAssertEqual(PointerSample(drag)?.action, .dragged)
        XCTAssertEqual(PointerSample(drag)?.button, 2)
        let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0))
        XCTAssertEqual(PointerSample(scroll)?.action, .scroll)
        let key = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        XCTAssertNil(PointerSample(key))
        XCTAssertFalse(PointerSample.eventTypes.contains(.keyDown))
        XCTAssertFalse(PointerSample.eventTypes.contains(.flagsChanged))
    }

    func testPressDragReleaseIsClickDragStartMovesDragEnd() {
        var translator = PointerTranslator()
        let kinds = [PointerSample.Action.down, .dragged, .dragged, .up].map {
            translator.translate(at(0, $0))
        }
        XCTAssertEqual(kinds.map { $0?.kind }, [.click, .dragStart, .pointerMove, .dragEnd])
        XCTAssertEqual(kinds.map { $0?.button }, [0, 0, nil, 0])
    }

    func testMissingTransitionsAreNotInvented() {
        var translator = PointerTranslator()
        XCTAssertEqual(translator.translate(at(0, .down))?.kind, .click)
        XCTAssertNil(translator.translate(at(0, .up)), "a click without a drag ends nothing")
        XCTAssertEqual(translator.translate(at(0, .dragged))?.kind, .pointerMove, "a drag with no press seen starts nothing")
        XCTAssertNil(translator.translate(at(0, .up)), "a release with no press seen ends nothing")

        XCTAssertEqual(translator.translate(at(0, .down, button: 1))?.kind, .click)
        XCTAssertEqual(translator.translate(at(0, .dragged, button: 1))?.kind, .dragStart)
        translator.reset()
        XCTAssertNil(translator.translate(at(0, .up, button: 1)), "after a reset the lost drag is not ended")
        XCTAssertEqual(translator.translate(at(0, .scroll))?.kind, .scroll)
    }

    // MARK: Recorder

    func testEventsArriveInOrderOnSessionTimeAcrossAPause() {
        let clock = CaptureClock(epochHostTime: epoch)
        let tap = FakeTap()
        let (recorder, collected) = makeRecorder(tap: tap, clock: clock)
        XCTAssertEqual(recorder.start(), .running)
        tap.send(at(9), at(11), at(12, .down), at(0))
        clock.pause(atHostTime: CMTime(value: 13, timescale: 1))
        tap.send(at(13.5))
        clock.resume(atHostTime: CMTime(value: 15, timescale: 1))
        tap.send(at(16, .dragged), at(17, .up))
        let counts = stopAndWait(recorder)

        XCTAssertEqual(collected.events.map(\.kind), [.pointerMove, .click, .dragStart, .dragEnd])
        XCTAssertEqual(collected.events.map(\.sessionTime.seconds), [1, 2, 4, 5])
        XCTAssertEqual(collected.events.first?.globalPoint, CGPoint(x: -20, y: 30))
        XCTAssertEqual(counts.delivered, 4)
        XCTAssertEqual(counts.droppedNoSessionTime, 3, "before the epoch, unset, and inside the pause")
    }

    func testSuspensionIsDecidedWhenTheEventArrives() {
        let filter = ActivityEventFilter()
        let tap = FakeTap()
        let (recorder, collected) = makeRecorder(tap: tap, filter: filter)
        recorder.start()
        filter.setSuspended(true)
        tap.send(at(11), at(12, .down))
        filter.setSuspended(false)
        tap.send(at(13))
        let counts = stopAndWait(recorder)
        XCTAssertEqual(collected.events.map(\.sessionTime.seconds), [3])
        XCTAssertEqual(counts.droppedSuspended, 2)
    }

    func testEventsAdmittedBeforeASuspensionAreStillDelivered() {
        let filter = ActivityEventFilter()
        let accessibility = FakeAccessibility()
        let gate = (entered: DispatchSemaphore(value: 0), release: DispatchSemaphore(value: 0))
        accessibility.gate = gate
        let tap = FakeTap()
        let (recorder, collected) = makeRecorder(tap: tap, filter: filter, accessibility: accessibility)
        recorder.start()
        tap.send(at(11))
        gate.entered.wait()
        tap.send(at(12))
        filter.setSuspended(true)
        gate.release.signal()
        _ = stopAndWait(recorder)
        XCTAssertEqual(collected.events.count, 2)
    }

    func testAFullQueueDropsTheNewestAndCountsIt() {
        let accessibility = FakeAccessibility()
        let gate = (entered: DispatchSemaphore(value: 0), release: DispatchSemaphore(value: 0))
        accessibility.gate = gate
        let tap = FakeTap()
        let (recorder, collected) = makeRecorder(tap: tap, accessibility: accessibility, capacity: 2)
        recorder.start()
        tap.send(at(11))
        gate.entered.wait()
        tap.send(at(12), at(13), at(14), at(15))
        gate.release.signal()
        let counts = stopAndWait(recorder)
        XCTAssertEqual(collected.events.map(\.sessionTime.seconds), [1, 2, 3])
        XCTAssertEqual(counts.droppedOverflow, 2)
    }

    func testAnEventIsDeliveredWhetherOrNotItsTargetResolves() {
        let accessibility = FakeAccessibility()
        let tap = FakeTap()
        let (recorder, collected) = makeRecorder(tap: tap, accessibility: accessibility)
        recorder.start()
        tap.send(at(11))
        _ = stopAndWait(recorder)
        accessibility.fails = true
        recorder.start()
        tap.send(at(12))
        _ = stopAndWait(recorder)
        XCTAssertEqual(collected.events.map(\.target?.role), ["AXButton", nil])
    }

    func testAnEarlierSessionCannotDeliverIntoALaterOne() throws {
        let tap = FakeTap()
        let (recorder, collected) = makeRecorder(tap: tap)
        recorder.start()
        let first = try XCTUnwrap(tap.onSample)
        _ = stopAndWait(recorder)
        recorder.start()
        first(at(11))
        tap.send(at(12))
        let counts = stopAndWait(recorder)
        XCTAssertEqual(collected.events.map(\.sessionTime.seconds), [2])
        XCTAssertEqual(counts.delivered, 1)
    }

    func testTheSinkCanStopTheRecorder() {
        let tap = FakeTap()
        let stopped = expectation(description: "stopped from the sink")
        let holder = RecorderHolder()
        let (recorder, _) = makeRecorder(tap: tap, sink: { _ in
            holder.recorder?.stop { _ in stopped.fulfill() }
        })
        holder.recorder = recorder
        recorder.start()
        tap.send(at(11))
        wait(for: [stopped], timeout: 5)
        XCTAssertEqual(tap.stops, 1)
        XCTAssertEqual(recorder.status, .idle)
    }

    func testATapThatCannotBeCreatedIsReported() {
        let tap = FakeTap()
        tap.creates = false
        let (recorder, _) = makeRecorder(tap: tap)
        XCTAssertEqual(recorder.start(), .tapUnavailable)
        XCTAssertEqual(recorder.status, .tapUnavailable)
    }

    func testADisabledTapIsCountedWhenReenabledAndForgetsPressedButtons() throws {
        let tap = FakeTap()
        let (recorder, collected) = makeRecorder(tap: tap)
        recorder.start()
        tap.send(at(11, .down), at(12, .dragged))
        try XCTUnwrap(tap.onDisabled)(true)
        tap.send(at(13, .up))
        let counts = stopAndWait(recorder)
        XCTAssertEqual(collected.events.map(\.kind), [.click, .dragStart])
        XCTAssertEqual(counts.tapReenabled, 1)
        XCTAssertEqual(counts.notRecorded, 1)
    }

    func testATapThatStaysDisabledStopsItsSession() throws {
        let tap = FakeTap()
        let held = HeldWork()
        let (recorder, collected) = makeRecorder(tap: tap, held: held)
        recorder.start()
        tap.send(at(11))
        try XCTUnwrap(tap.onDisabled)(false)
        XCTAssertEqual(recorder.status, .tapFailed)
        tap.send(at(12))
        held.runAll()
        XCTAssertEqual(tap.stops, 1)
        let counts = stopAndWait(recorder)
        XCTAssertEqual(collected.events.map(\.sessionTime.seconds), [1])
        XCTAssertEqual(counts.delivered, 1)
        XCTAssertEqual(recorder.status, .tapFailed)
    }

    func testAFailureDuringStartIsNotOverwrittenByRunning() {
        let tap = FakeTap()
        tap.disableDuringStart = true
        let held = HeldWork()
        let (recorder, _) = makeRecorder(tap: tap, held: held)
        XCTAssertEqual(recorder.start(), .tapFailed)
        held.runAll()
        XCTAssertEqual(recorder.status, .tapFailed)
        XCTAssertEqual(tap.stops, 1)
    }

    func testAnEarlierSessionsFailureCannotStopALaterSession() throws {
        let tap = FakeTap()
        let held = HeldWork()
        let (recorder, collected) = makeRecorder(tap: tap, held: held)
        recorder.start()
        try XCTUnwrap(tap.onDisabled)(false)
        XCTAssertEqual(held.count, 1)
        _ = stopAndWait(recorder)
        XCTAssertEqual(recorder.start(), .running)
        let stopsBefore = tap.stops
        held.runAll()
        XCTAssertEqual(recorder.status, .running)
        XCTAssertEqual(tap.stops, stopsBefore)
        tap.send(at(12))
        _ = stopAndWait(recorder)
        XCTAssertEqual(collected.events.map(\.sessionTime.seconds), [2])
    }

    func testARestartDuringADrainDeliversEverySessionsEvents() {
        let accessibility = FakeAccessibility()
        let gate = (entered: DispatchSemaphore(value: 0), release: DispatchSemaphore(value: 0))
        accessibility.gate = gate
        let tap = FakeTap()
        let (recorder, collected) = makeRecorder(tap: tap, accessibility: accessibility)
        recorder.start()
        tap.send(at(11))
        gate.entered.wait()
        tap.send(at(12))
        let firstDone = expectation(description: "first session drained")
        let firstCounts = LockedCounts()
        recorder.stop { counts in
            firstCounts.value = counts
            firstDone.fulfill()
        }
        XCTAssertEqual(recorder.start(), .running)
        tap.send(at(13))
        gate.release.signal()
        wait(for: [firstDone], timeout: 5)
        let second = stopAndWait(recorder)
        XCTAssertEqual(collected.events.map(\.sessionTime.seconds), [1, 2, 3])
        XCTAssertEqual(firstCounts.value.delivered, 2)
        XCTAssertEqual(second.delivered, 1)
    }

    func testNothingIsDeliveredAfterAStopCompletesWhileTheTapKeepsCalling() throws {
        let tap = FakeTap()
        let (recorder, collected) = makeRecorder(tap: tap)
        recorder.start()
        let send = try XCTUnwrap(tap.onSample)
        let sending = DispatchGroup()
        let keepSending = LockedFlag(true)
        DispatchQueue.global().async(group: sending) {
            var seconds = 11.0
            while keepSending.value {
                send(PointerSample(action: .move, timestamp: UInt64(seconds * 1e9), location: .zero))
                seconds += 0.001
            }
        }
        Thread.sleep(forTimeInterval: 0.02)
        let counts = stopAndWait(recorder)
        let deliveredAtCompletion = collected.events.count
        Thread.sleep(forTimeInterval: 0.05)
        keepSending.value = false
        sending.wait()
        XCTAssertGreaterThan(counts.delivered, 0)
        XCTAssertEqual(counts.delivered, deliveredAtCompletion)
        XCTAssertEqual(collected.events.count, deliveredAtCompletion, "nothing is delivered after completion")
    }

    func testADroppedTransitionForgetsPressStateInsteadOfInventingOne() {
        let filter = ActivityEventFilter()
        let accessibility = FakeAccessibility()
        let gate = (entered: DispatchSemaphore(value: 0), release: DispatchSemaphore(value: 0))
        accessibility.gate = gate
        let tap = FakeTap()
        let (recorder, collected) = makeRecorder(tap: tap, filter: filter, accessibility: accessibility, capacity: 1)
        recorder.start()
        // A release dropped while suspended: the next drag is not a drag of the stale press.
        tap.send(at(11, .down))
        gate.entered.wait()
        filter.setSuspended(true)
        tap.send(at(12, .up))
        filter.setSuspended(false)
        // A drag start dropped for a full queue: its release ends nothing.
        tap.send(at(13, .down), at(14, .dragged))
        // A drag start with no session time: its release ends nothing.
        tap.send(at(0, .dragged), at(15, .up))
        gate.release.signal()
        let counts = stopAndWait(recorder)
        XCTAssertEqual(collected.events.map(\.kind), [.click, .click])
        XCTAssertEqual(counts.droppedSuspended, 1)
        XCTAssertEqual(counts.droppedOverflow, 1)
        XCTAssertEqual(counts.droppedNoSessionTime, 1)
        XCTAssertEqual(counts.notRecorded, 1)
    }

    func testARecorderReleasedWhileRunningStopsItsTap() {
        let tap = FakeTap()
        do {
            let (recorder, _) = makeRecorder(tap: tap)
            recorder.start()
            XCTAssertEqual(tap.stops, 0)
        }
        XCTAssertEqual(tap.stops, 1)
    }

    func testCompletionWaitsForTheTapToStop() {
        let tap = FakeTap()
        let (recorder, _) = makeRecorder(tap: tap)
        recorder.start()
        tap.holdStop = DispatchSemaphore(value: 0)
        let completed = LockedFlag(false)
        let done = expectation(description: "completed")
        DispatchQueue.global().async {
            recorder.stop { _ in
                completed.value = true
                done.fulfill()
            }
        }
        tap.stopEntered.wait()
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertFalse(completed.value, "completion ran while the tap was still stopping")
        tap.holdStop?.signal()
        wait(for: [done], timeout: 5)
    }

    func testAStopWithNoSessionReportsTheLastSessionEvenAfterARestart() {
        let accessibility = FakeAccessibility()
        let gate = (entered: DispatchSemaphore(value: 0), release: DispatchSemaphore(value: 0))
        accessibility.gate = gate
        let tap = FakeTap()
        let (recorder, _) = makeRecorder(tap: tap, accessibility: accessibility)
        recorder.start()
        tap.send(at(11), at(12))
        gate.entered.wait()
        recorder.stop()
        let reported = LockedCounts()
        let done = expectation(description: "no-session stop")
        recorder.stop { counts in
            reported.value = counts
            done.fulfill()
        }
        recorder.start()
        tap.send(at(13), at(14), at(15))
        gate.release.signal()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(reported.value.delivered, 2)
        _ = stopAndWait(recorder)
    }

    func testAUserStopAfterATapFailureKeepsTheFailure() throws {
        let tap = FakeTap()
        let held = HeldWork()
        let (recorder, _) = makeRecorder(tap: tap, held: held)
        recorder.start()
        try XCTUnwrap(tap.onDisabled)(false)
        _ = stopAndWait(recorder)
        XCTAssertEqual(recorder.status, .tapFailed)
        held.runAll()
        XCTAssertEqual(recorder.status, .tapFailed)
        XCTAssertEqual(tap.stops, 1, "the held failure stop found its session already ended")
    }

    // MARK: This machine

    /// Releases a running real tap without stopping it: its thread must end. No event is posted.
    func testARealTapReleasedWithoutStopEndsItsThread() throws {
        var tap: SystemPointerEventTap? = SystemPointerEventTap()
        guard tap?.start(onSample: { _ in }, onDisabled: { _ in }) == true else {
            throw XCTSkip("the event tap is unavailable under this process's existing permissions")
        }
        let thread = try XCTUnwrap(tap?.thread)
        tap = nil
        let deadline = Date().addingTimeInterval(5)
        while !thread.isFinished, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(thread.isFinished)
    }


    /// Creates the real listen-only tap and stops it. No event is posted, and no permission is
    /// requested; without Input Monitoring or Accessibility trust the tap is unavailable.
    func testTheRealTapCanBeCreatedAndStopped() throws {
        let tap = SystemPointerEventTap()
        let created = tap.start(onSample: { _ in }, onDisabled: { _ in })
        print("telemetry recorder: real listen-only tap created \(created), Accessibility trusted \(AXIsProcessTrusted())")
        guard created else {
            throw XCTSkip("the event tap is unavailable under this process's existing permissions")
        }
        tap.stop()
        tap.stop()
    }
}

private final class LockedCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = TelemetryRecorderCounts()
    var value: TelemetryRecorderCounts {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class RecorderHolder: @unchecked Sendable {
    var recorder: TelemetryRecorder?
}
