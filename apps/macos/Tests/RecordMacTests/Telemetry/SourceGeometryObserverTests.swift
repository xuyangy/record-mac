import CoreGraphics
import CoreMedia
import XCTest
@testable import RecordMac

/// `SourceGeometryObserver` over a stand-in platform: no display callback or Accessibility
/// observer is registered, and no display or window is read. Work sent to the main thread waits
/// in a queue until the test runs it. Every expected geometry is worked out by hand.
final class SourceGeometryObserverTests: XCTestCase {
    private final class FakePlatform: SourceGeometryPlatform, @unchecked Sendable {
        final class Handle {
            let handler: @Sendable () -> Void
            init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
        }

        private let lock = NSLock()
        /// The thread standing in for the main thread while it runs, so another thread asking
        /// is told it is not on the main thread.
        private var mainThread: Thread?
        private var queued: [@Sendable () -> Void] = []
        private var time: Int64 = 100
        var trusted = true
        var displayRegistrationWorks = true
        var windowRegistrationWorks = true
        var owners: [CGWindowID: pid_t] = [7: 300]
        var attached = [ObservedDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 2)]
        var windows: [CGWindowID: CGRect] = [7: CGRect(x: 100, y: 50, width: 800, height: 600)]
        private var registeredDisplays: [Handle] = []
        private var registeredWindows: [(pid: pid_t, handle: Handle)] = []
        private(set) var reads = 0
        var displayHandles: [Handle] { lock.withLock { registeredDisplays } }
        var windowHandles: [(pid: pid_t, handle: Handle)] { lock.withLock { registeredWindows } }

        func isMainThread() -> Bool { lock.withLock { mainThread === Thread.current } }
        func onMain(_ work: @escaping @Sendable () -> Void) { lock.withLock { queued.append(work) } }

        /// Runs `work` as the main thread.
        func asMain(_ work: () -> Void) {
            lock.withLock { mainThread = Thread.current }
            work()
            lock.withLock { mainThread = nil }
        }

        func runMain() {
            while let work = lock.withLock({ queued.isEmpty ? nil : queued.removeFirst() }) { asMain(work) }
        }

        var queuedCount: Int { lock.withLock { queued.count } }

        func observeDisplayReconfiguration(_ handler: @escaping @Sendable () -> Void) -> AnyObject? {
            XCTAssertTrue(isMainThread(), "registered on the main thread")
            guard displayRegistrationWorks else { return nil }
            let handle = Handle(handler)
            lock.withLock { registeredDisplays.append(handle) }
            return handle
        }

        func stopObservingDisplayReconfiguration(_ handle: AnyObject) {
            XCTAssertTrue(isMainThread(), "removed on the main thread")
            lock.withLock { registeredDisplays.removeAll { $0 === handle } }
        }

        func isTrusted() -> Bool { trusted }
        func windowOwner(_ id: CGWindowID) -> pid_t? { owners[id] }

        func observeWindowGeometry(of pid: pid_t, _ handler: @escaping @Sendable () -> Void) -> AnyObject? {
            XCTAssertTrue(isMainThread(), "registered on the main thread")
            guard windowRegistrationWorks else { return nil }
            let handle = Handle(handler)
            lock.withLock { registeredWindows.append((pid, handle)) }
            return handle
        }

        func stopObservingWindowGeometry(_ handle: AnyObject) {
            XCTAssertTrue(isMainThread(), "removed on the main thread")
            lock.withLock { registeredWindows.removeAll { $0.handle === handle } }
        }

        /// Each call is one tick later, so a stamp taken before a read would differ from one
        /// taken after it.
        func hostTimeNow() -> CMTime {
            lock.withLock {
                time += 1
                return CMTime(value: time, timescale: 1)
            }
        }

        func displays() -> [ObservedDisplay] {
            XCTAssertTrue(isMainThread(), "read on the main thread")
            lock.withLock { reads += 1 }
            return attached
        }

        func windowBounds(_ id: CGWindowID) -> CGRect? { windows[id] }

        /// Fires every registered callback of one kind, on the main thread.
        func reconfigureDisplays() { asMain { displayHandles.forEach { $0.handler() } } }
        func moveWindow() { asMain { windowHandles.forEach { $0.handle.handler() } } }
    }

    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [SourceGeometryObservation] = []
        var all: [SourceGeometryObservation] { lock.withLock { stored } }
        var readings: [SourceGeometryObservation.Reading] { all.map(\.reading) }
        func add(_ observation: SourceGeometryObservation) { lock.withLock { stored.append(observation) } }
    }

    private let platform = FakePlatform()
    private let received = Received()
    /// Capture's frame: deliberately not the desktop size times any display's scale, so a
    /// reading that took its dimensions from the desktop would not match it.
    private let frame = CaptureFrameGeometry(pixelSize: PixelSize(width: 1000, height: 700), scaleFactor: 1.25)

    private func geometry(_ rect: CGRect, _ frame: CaptureFrameGeometry? = nil) -> SourceGeometryObservation.Reading {
        let frame = frame ?? self.frame
        return .geometry(SourceGeometry(sourceRect: rect, pixelSize: frame.pixelSize, scaleFactor: frame.scaleFactor))
    }

    private func read(_ target: SourceGeometryTarget, displays: [ObservedDisplay]? = nil,
                      window: CGRect? = nil, frame: CaptureFrameGeometry?? = .none) -> SourceGeometryObservation.Reading {
        target.read(displays: displays ?? platform.attached, windowBounds: { _ in window },
            frame: frame ?? self.frame)
    }

    private func start(_ observer: SourceGeometryObserver, _ target: SourceGeometryTarget,
                       handler: @escaping @Sendable (SourceGeometryObservation) -> Void) {
        let frame = frame
        observer.start(target, frame: { frame }, handler: handler)
    }

    private func started(_ target: SourceGeometryTarget) -> SourceGeometryObserver {
        let observer = SourceGeometryObserver(platform: platform)
        let received = received
        start(observer, target) { received.add($0) }
        platform.runMain()
        return observer
    }

    // MARK: Reading

    func testADisplayIsItsBoundsWithCapturesFrame() {
        XCTAssertEqual(read(.display(1)), geometry(CGRect(x: 0, y: 0, width: 1440, height: 900)))
    }

    /// An area keeps its place on its display: a display moved to (-1440, 200) in the
    /// arrangement moves the area by the same offset.
    func testAnAreaFollowsItsDisplayInTheArrangement() {
        let target = SourceGeometryTarget.area(1, crop: CGRect(x: 10, y: 20, width: 400, height: 300))
        var displays = platform.attached
        XCTAssertEqual(read(target, displays: displays), geometry(CGRect(x: 10, y: 20, width: 400, height: 300)))
        displays[0].bounds.origin = CGPoint(x: -1440, y: 200)
        XCTAssertEqual(read(target, displays: displays), geometry(CGRect(x: -1430, y: 220, width: 400, height: 300)))
        displays[0].bounds.size = CGSize(width: 300, height: 900)
        XCTAssertEqual(read(target, displays: displays), .unavailable(.areaOutsideDisplay))
    }

    /// The window lies mostly on a scale-1 display beside the scale-2 main display, and
    /// capture's frame says scale 1.25 at 1000 x 700: the reading takes capture's frame, not
    /// either display's scale and not the bounds times a scale.
    func testAWindowTakesCapturesFrameWhateverDisplayHoldsIt() {
        let displays = platform.attached + [ObservedDisplay(id: 2, bounds: CGRect(x: 1440, y: 0, width: 1920, height: 1080), scale: 1)]
        let window = CGRect(x: 1240, y: 100, width: 800, height: 600)
        XCTAssertEqual(read(.window(7), displays: displays, window: window), geometry(window))
    }

    /// Capture records a desktop-independent window wherever it is, so a window on no display
    /// still has geometry.
    func testAWindowOffEveryDisplayStillHasGeometry() {
        let offscreen = CGRect(x: 5000, y: 5000, width: 10, height: 10)
        XCTAssertEqual(read(.window(7), window: offscreen), geometry(offscreen))
    }

    func testAMissingSourceFrameOrExtentReadsNoGeometry() {
        XCTAssertEqual(read(.display(9)), .unavailable(.sourceGone))
        XCTAssertEqual(read(.area(9, crop: CGRect(x: 0, y: 0, width: 10, height: 10))), .unavailable(.sourceGone))
        XCTAssertEqual(read(.window(7)), .unavailable(.sourceGone))
        XCTAssertEqual(read(.display(1), frame: .some(nil)), .unavailable(.noFrame))
        XCTAssertEqual(read(.window(7), window: CGRect(x: 0, y: 0, width: 0, height: 600)), .unavailable(.invalid))
        let empty = CaptureFrameGeometry(pixelSize: PixelSize(width: 0, height: 700), scaleFactor: 2)
        XCTAssertEqual(read(.display(1), frame: .some(empty)), .unavailable(.invalid))
    }

    func testTheTargetComesFromTheResolvedLocation() {
        let whole = CaptureSourceGeometry(pixelWidth: 2880, pixelHeight: 1800, sourceRect: nil)
        let crop = CaptureSourceGeometry(pixelWidth: 800, pixelHeight: 600, sourceRect: CGRect(x: 1, y: 2, width: 400, height: 300))
        XCTAssertEqual(SourceGeometryTarget(.display(1), geometry: whole), .display(1))
        XCTAssertEqual(SourceGeometryTarget(.display(1), geometry: crop), .area(1, crop: CGRect(x: 1, y: 2, width: 400, height: 300)))
        XCTAssertEqual(SourceGeometryTarget(.window(7), geometry: whole), .window(7))
    }

    // MARK: Observing

    /// Capture's frame as the test changes it.
    private final class FrameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CaptureFrameGeometry?
        init(_ frame: CaptureFrameGeometry?) { stored = frame }
        var value: CaptureFrameGeometry? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// Started off the main thread: nothing is registered or read until the main thread runs,
    /// then one reading at the start, one per completed reconfiguration, and one per window
    /// notification, each with capture's frame at that reading. Each is stamped after its read.
    func testAWindowIsReadAtTheStartOnReconfigurationAndOnMoveOrResize() {
        let observer = SourceGeometryObserver(platform: platform)
        let received = received
        let box = FrameBox(frame)
        observer.start(.window(7), frame: { box.value }) { received.add($0) }
        XCTAssertNil(observer.coverage)
        XCTAssertEqual(platform.reads, 0)
        platform.runMain()
        XCTAssertEqual(observer.coverage, SourceGeometryCoverage(displayReconfiguration: true, windowMoveAndResize: true))
        XCTAssertEqual(platform.windowHandles.map(\.pid), [300], "the owner of the resolved window")

        platform.moveWindow()
        platform.windows[7] = CGRect(x: 0, y: 0, width: 640, height: 480)
        platform.moveWindow()
        let reconfigured = CaptureFrameGeometry(pixelSize: PixelSize(width: 640, height: 480), scaleFactor: 1)
        box.value = reconfigured
        platform.reconfigureDisplays()
        let first = geometry(CGRect(x: 100, y: 50, width: 800, height: 600))
        XCTAssertEqual(received.readings, [first, first,
            geometry(CGRect(x: 0, y: 0, width: 640, height: 480)),
            geometry(CGRect(x: 0, y: 0, width: 640, height: 480), reconfigured)])
        XCTAssertEqual(received.all.map(\.hostTime.value), [101, 102, 103, 104], "one stamp per read, in order")
        observer.stop()
        platform.runMain()
        XCTAssertTrue(platform.displayHandles.isEmpty)
        XCTAssertTrue(platform.windowHandles.isEmpty)
    }

    func testADisplayOrAreaRegistersNoWindowObserver() {
        let observer = started(.area(1, crop: CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertEqual(observer.coverage, SourceGeometryCoverage(displayReconfiguration: true, windowMoveAndResize: false))
        XCTAssertTrue(platform.windowHandles.isEmpty)
        platform.attached = []
        platform.reconfigureDisplays()
        XCTAssertEqual(received.readings.last, .unavailable(.sourceGone), "a detached display is reported, not dropped")
        observer.stop()
        platform.runMain()
    }

    /// Without trust the observer asks for nothing and still sees display reconfiguration.
    func testWithoutAccessibilityTrustOnlyReconfigurationIsSeen() {
        platform.trusted = false
        let observer = started(.window(7))
        XCTAssertEqual(observer.coverage, SourceGeometryCoverage(displayReconfiguration: true, windowMoveAndResize: false))
        XCTAssertTrue(platform.windowHandles.isEmpty)
        XCTAssertEqual(received.readings.count, 1)
        observer.stop()
        platform.runMain()
    }

    /// A failed registration leaves the other in place and is reported; stop removes only what
    /// was registered.
    func testAFailedRegistrationIsReportedAndTheRestStillWorks() {
        platform.displayRegistrationWorks = false
        let observer = started(.window(7))
        XCTAssertEqual(observer.coverage, SourceGeometryCoverage(displayReconfiguration: false, windowMoveAndResize: true))
        platform.moveWindow()
        XCTAssertEqual(received.readings.count, 2)
        observer.stop()
        platform.runMain()
        XCTAssertTrue(platform.windowHandles.isEmpty)

        platform.displayRegistrationWorks = true
        platform.windowRegistrationWorks = false
        start(observer, .window(7)) { _ in }
        platform.runMain()
        XCTAssertEqual(observer.coverage, SourceGeometryCoverage(displayReconfiguration: true, windowMoveAndResize: false))
        observer.stop()
        platform.runMain()
        XCTAssertTrue(platform.displayHandles.isEmpty)
    }

    func testAWindowThatIsGoneHasNoOwnerToObserve() {
        platform.owners = [:]
        platform.windows = [:]
        let observer = started(.window(7))
        XCTAssertEqual(observer.coverage, SourceGeometryCoverage(displayReconfiguration: true, windowMoveAndResize: false))
        XCTAssertEqual(received.readings, [.unavailable(.sourceGone)])
        observer.stop()
        platform.runMain()
    }

    /// A callback of the first registration that fires after a stop and restart, before the
    /// queued removal runs, delivers nothing to either handler.
    func testAStoppedRegistrationNeverDeliversToALaterStart() {
        let observer = started(.display(1))
        let stale = platform.displayHandles[0]
        observer.stop()
        let later = Received()
        start(observer, .display(1)) { later.add($0) }
        XCTAssertEqual(platform.queuedCount, 2, "removal and the new setup, not yet run")
        platform.asMain { stale.handler() }
        XCTAssertEqual(received.readings.count, 1, "only the first registration's start reading")
        XCTAssertEqual(later.readings.count, 0)
        platform.runMain()
        XCTAssertEqual(platform.displayHandles.count, 1, "the stale callback removed, the new one registered")
        XCTAssertEqual(later.readings.count, 1)
        observer.stop()
        platform.runMain()
    }

    /// A start replaces a running registration without a stop: the replaced one is stopped and
    /// removed, and delivers nothing more.
    func testAStartReplacesTheRunningRegistration() {
        let observer = started(.display(1))
        let stale = platform.displayHandles[0]
        let later = Received()
        start(observer, .display(1)) { later.add($0) }
        platform.asMain { stale.handler() }
        XCTAssertEqual(received.readings.count, 1)
        platform.runMain()
        XCTAssertEqual(platform.displayHandles.count, 1)
        XCTAssertFalse(platform.displayHandles[0] === stale)
        observer.stop()
        platform.runMain()
        XCTAssertTrue(platform.displayHandles.isEmpty)
    }

    /// Starts from many threads at once, then a stop: once the main thread has run, nothing is
    /// left registered, so no start was installed without the one it replaced being stopped.
    func testOverlappingStartsLeaveNoRegistrationBehind() {
        let observer = SourceGeometryObserver(platform: platform)
        let frame = frame
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            observer.start(.window(7), frame: { frame }) { _ in }
        }
        platform.runMain()
        XCTAssertEqual(platform.displayHandles.count, 1, "only the last start is set up")
        XCTAssertEqual(platform.windowHandles.count, 1)
        observer.stop()
        platform.runMain()
        XCTAssertTrue(platform.displayHandles.isEmpty)
        XCTAssertTrue(platform.windowHandles.isEmpty)
    }

    /// A stop from another thread while a reading is being delivered on the main thread returns
    /// only after that delivery, and nothing is delivered after it.
    func testAStopOffTheMainThreadWaitsForADeliveryUnderWay() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let received = received
        let observer = SourceGeometryObserver(platform: platform)
        start(observer, .display(1)) { observation in
            received.add(observation)
            guard received.all.count == 2 else { return }
            entered.signal()
            release.wait()
        }
        platform.runMain()
        let platform = platform
        DispatchQueue.global().async { platform.reconfigureDisplays() }
        entered.wait()
        DispatchQueue.global().async {
            observer.stop()
            stopped.signal()
        }
        XCTAssertEqual(stopped.wait(timeout: .now() + 0.2), .timedOut, "stop waits for the delivery")
        release.signal()
        XCTAssertEqual(stopped.wait(timeout: .now() + 5), .success)
        platform.reconfigureDisplays()
        XCTAssertEqual(received.readings.count, 2)
        platform.runMain()
        XCTAssertTrue(platform.displayHandles.isEmpty)
    }

    /// Stopped before its setup ran: nothing is registered or read.
    func testStoppedBeforeSetupRegistersNothing() {
        let observer = SourceGeometryObserver(platform: platform)
        let received = received
        start(observer, .window(7)) { received.add($0) }
        observer.stop()
        platform.runMain()
        XCTAssertTrue(platform.displayHandles.isEmpty)
        XCTAssertTrue(platform.windowHandles.isEmpty)
        XCTAssertEqual(platform.reads, 0)
        XCTAssertTrue(received.all.isEmpty)
    }

    /// Stopping from inside a delivery on the main thread neither deadlocks nor delivers again.
    func testTheHandlerMayStopTheObserver() {
        let observer = SourceGeometryObserver(platform: platform)
        let received = received
        start(observer, .display(1)) { [weak observer] in
            received.add($0)
            observer?.stop()
        }
        platform.runMain()
        platform.reconfigureDisplays()
        XCTAssertEqual(received.readings.count, 1)
        XCTAssertTrue(platform.displayHandles.isEmpty)
    }

    /// Released off the main thread while running: removal is queued with the registration, not
    /// the observer, which is gone at once.
    func testReleasedOffTheMainThreadItCleansUpWithoutKeepingTheObserver() {
        weak var released: SourceGeometryObserver?
        do {
            let observer = started(.window(7))
            released = observer
        }
        XCTAssertNil(released)
        XCTAssertFalse(platform.displayHandles.isEmpty, "removal waits for the main thread")
        platform.runMain()
        XCTAssertTrue(platform.displayHandles.isEmpty)
        XCTAssertTrue(platform.windowHandles.isEmpty)
    }

    // MARK: Feeding the recorder

    /// On a clock whose epoch is host 100 s: an unchanged reading adds nothing, a move adds a
    /// segment at its session time, a reading without geometry is held back, and an older
    /// reading is refused.
    func testTheFeedPassesOnlyGeometryAndCountsEachOutcome() throws {
        let clock = CaptureClock(epochHostTime: CMTime(value: 100, timescale: 1))
        let initial = SourceGeometry(sourceRect: CGRect(x: 100, y: 50, width: 800, height: 600),
            pixelSize: frame.pixelSize, scaleFactor: frame.scaleFactor)
        let feed = GeometryRecorderFeed(recorder: try GeometryRecorder(clock: clock, initial: initial))
        let observer = SourceGeometryObserver(platform: platform)
        start(observer, .window(7)) { feed.take($0) }
        platform.runMain()
        platform.windows[7] = CGRect(x: 0, y: 0, width: 800, height: 600)
        platform.moveWindow()
        platform.windows = [:]
        platform.moveWindow()
        observer.stop()
        platform.runMain()
        feed.take(SourceGeometryObservation(reading: .geometry(initial), hostTime: CMTime(value: 101, timescale: 1)))

        XCTAssertEqual(feed.recorder.segments, [initial.segment(at: 0),
            SourceGeometry(sourceRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                pixelSize: frame.pixelSize, scaleFactor: frame.scaleFactor).segment(at: 2)])
        XCTAssertEqual(feed.counts, GeometryFeedCounts(added: 1, unchanged: 1, noSessionTime: 0, unavailable: 1, refused: 1))
    }
}
