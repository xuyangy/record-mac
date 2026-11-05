import ApplicationServices
import CoreGraphics
import CoreMedia
import XCTest
@testable import RecordMac

/// Frontmost-window changes through `TelemetryRecorder`, from a stand-in window source and tap:
/// no desktop, workspace notification, Accessibility query, or permission. The epoch is host
/// 10 s; observation times are given by the test.
final class FrontmostWindowRecorderTests: XCTestCase {
    /// Reports observations when the test says, and reads whatever window the test set.
    private final class FakeWindows: FrontmostWindowSource, @unchecked Sendable {
        private let lock = NSLock()
        private var callbacks: [@Sendable (CMTime) -> Void] = []
        private var lookup = FrontmostWindowLookup.unavailable
        private var held: (lookup: FrontmostWindowLookup, entered: DispatchSemaphore, release: DispatchSemaphore)?
        private(set) var starts = 0
        private(set) var stops = 0
        private(set) var reads = 0

        func start(onChange: @escaping @Sendable (CMTime) -> Void) -> Bool {
            lock.withLock {
                starts += 1
                callbacks.append(onChange)
            }
            return true
        }

        func stop() { lock.withLock { stops += 1 } }

        func frontmostWindow() -> FrontmostWindowLookup {
            let (lookup, held) = lock.withLock { () -> (FrontmostWindowLookup, (lookup: FrontmostWindowLookup, entered: DispatchSemaphore, release: DispatchSemaphore)?) in
                reads += 1
                defer { self.held = nil }
                return (self.lookup, self.held)
            }
            guard let held else { return lookup }
            held.entered.signal()
            held.release.wait()
            return held.lookup
        }

        /// The next read signals `entered`, waits for `release`, and returns `lookup`.
        func holdNextRead(returning lookup: FrontmostWindowLookup) -> (entered: DispatchSemaphore, release: DispatchSemaphore) {
            let gate = (entered: DispatchSemaphore(value: 0), release: DispatchSemaphore(value: 0))
            lock.withLock { held = (lookup, gate.entered, gate.release) }
            return gate
        }

        func set(_ window: WindowDescriptor?) {
            lock.withLock { lookup = window.map { .window($0) } ?? .unavailable }
        }

        /// Calls the callback of the latest start, or of an earlier one.
        func observe(atHostSeconds seconds: Double, start index: Int? = nil) {
            let callback = lock.withLock { callbacks[index ?? callbacks.count - 1] }
            callback(CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))
        }
    }

    private final class FakeTap: PointerEventTap, @unchecked Sendable {
        var creates = true
        private var onSample: (@Sendable (PointerSample) -> Void)?

        func start(onSample: @escaping @Sendable (PointerSample) -> Void, onDisabled: @escaping @Sendable (Bool) -> Void) -> Bool {
            guard creates else { return false }
            self.onSample = onSample
            return true
        }

        func stop() {}

        func move(atHostSeconds seconds: Double) {
            onSample?(PointerSample(action: .move, timestamp: UInt64((seconds * 1e9).rounded()), location: CGPoint(x: 5, y: 6)))
        }
    }

    /// Counts lookups; finds nothing.
    private final class CountingAccessibility: AccessibilityQueries, @unchecked Sendable {
        private let lock = NSLock()
        private var lookups = 0
        var count: Int { lock.withLock { lookups } }
        func isTrusted() -> Bool { true }
        func element(at point: CGPoint) -> AccessibilityLookup {
            lock.withLock { lookups += 1 }
            return .none
        }
        func focusedElement() -> AccessibilityLookup { .none }
        func copyAttribute(_ attribute: String, of element: AccessibilityElement) -> (AXError, CFTypeRef?) { (.noValue, nil) }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [GlobalActivityEvent] = []
        var events: [GlobalActivityEvent] { lock.withLock { stored } }
        func append(_ event: GlobalActivityEvent) { lock.withLock { stored.append(event) } }
    }

    private final class Counts: @unchecked Sendable {
        var value = TelemetryRecorderCounts()
    }

    private let windows = FakeWindows()
    private let tap = FakeTap()
    private let accessibility = CountingAccessibility()
    private let filter = ActivityEventFilter()
    private let collected = Collected()
    private let clock = CaptureClock(epochHostTime: CMTime(value: 10, timescale: 1))
    private lazy var recorder = TelemetryRecorder(
        clock: clock, filter: filter, resolver: TargetResolver(accessibility: accessibility), tap: tap,
        windows: windows) { [collected] in collected.append($0) }

    private let editorOne = WindowDescriptor(bundleIdentifier: "com.example.editor", windowID: 41, frame: CGRect(x: 0, y: 25, width: 800, height: 600))
    private let editorTwo = WindowDescriptor(bundleIdentifier: "com.example.editor", windowID: 42, frame: CGRect(x: 40, y: 65, width: 800, height: 600))
    private let browser = WindowDescriptor(bundleIdentifier: "com.example.browser", windowID: 7, frame: CGRect(x: 100, y: 25, width: 1200, height: 900))

    private func stopAndWait() -> TelemetryRecorderCounts {
        let done = expectation(description: "stopped")
        let counts = Counts()
        recorder.stop {
            counts.value = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return counts.value
    }

    private func windowEvents() -> [(Double, WindowDescriptor?)] {
        collected.events.filter { $0.kind == .activeWindowChange }.map { ($0.sessionTime.seconds, $0.window) }
    }

    private func assertWindows(_ expected: [(Double, WindowDescriptor)], line: UInt = #line) {
        let actual = windowEvents()
        XCTAssertEqual(actual.count, expected.count, "\(actual)", line: line)
        for ((time, window), (expectedTime, expectedWindow)) in zip(actual, expected) {
            XCTAssertEqual(time, expectedTime, accuracy: 1e-9, line: line)
            XCTAssertEqual(window, expectedWindow, line: line)
        }
    }

    func testSwitchingWindowsOfOneApplicationAndBetweenApplicationsIsRecordedOnce() {
        XCTAssertEqual(recorder.start(), .running)
        XCTAssertEqual(windows.starts, 1)
        windows.set(editorOne)
        windows.observe(atHostSeconds: 10.5)
        windows.set(editorTwo)
        windows.observe(atHostSeconds: 10.7)
        windows.set(browser)
        windows.observe(atHostSeconds: 11.0)
        windows.observe(atHostSeconds: 11.2)

        let counts = stopAndWait()

        assertWindows([(0.5, editorOne), (0.7, editorTwo), (1.0, browser)])
        XCTAssertEqual(counts.windows, .init(recorded: 3, unchanged: 1))
        XCTAssertEqual(windows.stops, 1)
        for event in collected.events {
            XCTAssertNil(event.globalPoint)
            XCTAssertNil(event.target)
            XCTAssertNil(event.button)
        }
        XCTAssertEqual(accessibility.count, 0, "a window change looks up no element")
    }

    /// No window can be read: nothing is recorded and the last window stands, so a return to it
    /// records nothing and a different window is recorded.
    func testAnUnreadableWindowRecordsNothingAndTheLastWindowStands() {
        recorder.start()
        windows.set(editorOne)
        windows.observe(atHostSeconds: 10.5)
        windows.set(nil)
        windows.observe(atHostSeconds: 10.6)
        windows.set(editorOne)
        windows.observe(atHostSeconds: 10.7)
        windows.set(nil)
        windows.observe(atHostSeconds: 10.8)
        windows.set(browser)
        windows.observe(atHostSeconds: 10.9)

        let counts = stopAndWait()

        assertWindows([(0.5, editorOne), (0.9, browser)])
        XCTAssertEqual(counts.windows, .init(recorded: 2, unchanged: 1, unavailable: 2))
    }

    /// While suspended or paused an observation is dropped before any window is read; asking
    /// again after records the window then.
    func testSuspensionAndPausesDropObservationsUntilAskedAgain() {
        recorder.start()
        windows.set(editorOne)
        windows.observe(atHostSeconds: 10.5)

        filter.setSuspended(true)
        windows.set(browser)
        windows.observe(atHostSeconds: 10.6)
        filter.setSuspended(false)
        recorder.observeWindow(atHostTime: CMTime(value: 107, timescale: 10))

        XCTAssertTrue(clock.pause(atHostTime: CMTime(value: 11, timescale: 1)))
        windows.set(editorTwo)
        windows.observe(atHostSeconds: 11.5)
        XCTAssertTrue(clock.resume(atHostTime: CMTime(value: 12, timescale: 1)))
        recorder.observeWindow(atHostTime: CMTime(value: 12, timescale: 1))
        windows.observe(atHostSeconds: 9.0)

        let counts = stopAndWait()

        // 10.7 → 0.7; 12 → 2 − the 1 s pause = 1.0.
        assertWindows([(0.5, editorOne), (0.7, browser), (1.0, editorTwo)])
        XCTAssertEqual(counts.windows, .init(recorded: 3, droppedSuspended: 1, droppedNoSessionTime: 2))
        XCTAssertEqual(windows.reads, 3, "dropped observations read no window")
    }

    /// Pointer events and window changes reach the sink in the order they were admitted.
    func testWindowChangesKeepTheirPlaceAmongPointerEvents() {
        recorder.start()
        windows.set(browser)
        tap.move(atHostSeconds: 10.1)
        windows.observe(atHostSeconds: 10.2)
        tap.move(atHostSeconds: 10.3)
        windows.set(editorOne)
        windows.observe(atHostSeconds: 10.4)

        _ = stopAndWait()

        XCTAssertEqual(collected.events.map(\.kind), [.pointerMove, .activeWindowChange, .pointerMove, .activeWindowChange])
        XCTAssertEqual(collected.events.map(\.sessionTime.seconds).map { ($0 * 10).rounded() / 10 }, [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(accessibility.count, 2, "only pointer events look up an element")
    }

    /// A window read that takes a while keeps its observation's place: a pointer event and a
    /// second observation made meanwhile are delivered after it, and the last window recorded is
    /// the second observation's.
    func testASlowWindowReadKeepsItsPlaceAmongLaterEvents() {
        recorder.start()
        let gate = windows.holdNextRead(returning: .window(editorOne))
        let firstDone = DispatchSemaphore(value: 0)
        let windows = windows
        DispatchQueue.global().async {
            windows.observe(atHostSeconds: 10.2)
            firstDone.signal()
        }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success)
        tap.move(atHostSeconds: 10.3)
        windows.set(browser)
        windows.observe(atHostSeconds: 10.4)
        gate.release.signal()
        XCTAssertEqual(firstDone.wait(timeout: .now() + 5), .success)
        windows.observe(atHostSeconds: 10.5)

        let counts = stopAndWait()

        XCTAssertEqual(collected.events.map(\.kind), [.activeWindowChange, .pointerMove, .activeWindowChange])
        XCTAssertEqual(collected.events.map(\.sessionTime.seconds).map { ($0 * 10).rounded() / 10 }, [0.2, 0.3, 0.4])
        XCTAssertEqual(collected.events.compactMap(\.window), [editorOne, browser])
        XCTAssertEqual(counts.windows, .init(recorded: 2, unchanged: 1))
    }

    /// A callback from a stopped session records nothing, in that session or the next; each new
    /// session records its first window even when it is the last one recorded before.
    func testAStoppedSessionsCallbacksRecordNothingAndANewSessionStartsAfresh() {
        recorder.start()
        windows.set(editorOne)
        windows.observe(atHostSeconds: 10.5)
        let first = stopAndWait()
        XCTAssertEqual(first.windows, .init(recorded: 1))
        XCTAssertEqual(windows.stops, 1)

        windows.observe(atHostSeconds: 10.6, start: 0)
        recorder.start()
        XCTAssertEqual(windows.starts, 2)
        windows.observe(atHostSeconds: 10.7, start: 0)
        windows.observe(atHostSeconds: 10.8)

        let second = stopAndWait()

        assertWindows([(0.5, editorOne), (0.8, editorOne)])
        XCTAssertEqual(second.windows, .init(recorded: 1))
        XCTAssertEqual(windows.stops, 2)
    }

    func testWithoutAnEventTapNoWindowIsObserved() {
        tap.creates = false
        XCTAssertEqual(recorder.start(), .tapUnavailable)
        XCTAssertEqual(windows.starts, 0)
        recorder.observeWindow(atHostTime: CMTime(value: 11, timescale: 1))
        XCTAssertEqual(stopAndWait().windows, .init())
        XCTAssertEqual(windows.reads, 0)
    }

    /// Beyond `capacity` queued events, an observation is dropped and counted, and its window is
    /// not taken as the last one recorded.
    func testChangesBeyondTheQueueAreDroppedAndCounted() {
        let held = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let collected = collected
        let recorder = TelemetryRecorder(
            clock: clock, filter: filter, resolver: TargetResolver(accessibility: accessibility), tap: tap,
            windows: windows, capacity: 2
        ) { event in
            if collected.events.isEmpty {
                entered.signal()
                held.wait()
            }
            collected.append(event)
        }
        recorder.start()
        windows.set(editorOne)
        windows.observe(atHostSeconds: 10.1)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        windows.set(editorTwo)
        windows.observe(atHostSeconds: 10.2)
        windows.observe(atHostSeconds: 10.3)
        windows.set(browser)
        windows.observe(atHostSeconds: 10.4)
        windows.set(editorOne)
        windows.observe(atHostSeconds: 10.5)
        held.signal()
        // Once the queue has drained, the dropped window is still a change.
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in collected.events.count == 2 }, object: nil)], timeout: 5)
        windows.observe(atHostSeconds: 10.6)

        let done = expectation(description: "stopped")
        let counts = Counts()
        recorder.stop {
            counts.value = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        // 10.2 and 10.3 wait behind the held delivery; 10.4 and 10.5 find the queue full.
        XCTAssertEqual(counts.value.windows, .init(recorded: 3, unchanged: 1, droppedOverflow: 2))
        XCTAssertEqual(collected.events.map(\.window), [editorOne, editorTwo, editorOne])
    }
}
