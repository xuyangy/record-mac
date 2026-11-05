import CoreMedia
import XCTest
@testable import RecordMac

/// `SystemFrontmostWindowSource`'s observers over a stand-in platform: no workspace observer,
/// Accessibility observer, or window list is registered or read. Work the source sends to the
/// main thread waits in a queue until the test runs it.
final class FrontmostWindowSourceTests: XCTestCase {
    private final class FakePlatform: FrontmostWindowPlatform, @unchecked Sendable {
        final class Token {}

        final class WindowHandle {
            let pid: pid_t
            let handler: @Sendable () -> Void
            init(pid: pid_t, handler: @escaping @Sendable () -> Void) {
                self.pid = pid
                self.handler = handler
            }
        }

        private let lock = NSLock()
        var onMainThread = false
        var trusted = true
        var frontmost: pid_t? = 100
        private var queued: [@Sendable () -> Void] = []
        private var activations: [(token: Token, handler: @Sendable (pid_t?) -> Void)] = []
        private(set) var windowHandles: [WindowHandle] = []
        private(set) var removedActivations = 0

        func isMainThread() -> Bool { lock.withLock { onMainThread } }
        func onMain(_ work: @escaping @Sendable () -> Void) { lock.withLock { queued.append(work) } }

        /// Runs the queued main-thread work in order, as the main thread would.
        func runMain() {
            while let work = lock.withLock({ queued.isEmpty ? nil : queued.removeFirst() }) {
                lock.withLock { onMainThread = true }
                work()
                lock.withLock { onMainThread = false }
            }
        }

        var queuedCount: Int { lock.withLock { queued.count } }

        func observeActivations(_ handler: @escaping @Sendable (pid_t?) -> Void) -> AnyObject {
            let token = Token()
            lock.withLock { activations.append((token, handler)) }
            return token
        }

        func stopObservingActivations(_ token: AnyObject) {
            lock.withLock {
                activations.removeAll { $0.token === token }
                removedActivations += 1
            }
        }

        /// Activates `pid`: calls every registered activation handler, on the main thread.
        func activate(_ pid: pid_t) {
            frontmost = pid
            let handlers = lock.withLock { activations.map(\.handler) }
            lock.withLock { onMainThread = true }
            handlers.forEach { $0(pid) }
            lock.withLock { onMainThread = false }
        }

        var activationCount: Int { lock.withLock { activations.count } }

        func frontmostProcess() -> pid_t? { frontmost }
        func isTrusted() -> Bool { trusted }

        func observeWindowChanges(of pid: pid_t, _ handler: @escaping @Sendable () -> Void) -> AnyObject? {
            XCTAssertTrue(isMainThread(), "set up on the main thread")
            let handle = WindowHandle(pid: pid, handler: handler)
            lock.withLock { windowHandles.append(handle) }
            return handle
        }

        func stopObservingWindowChanges(_ handle: AnyObject) {
            XCTAssertTrue(isMainThread(), "removed on the main thread")
            lock.withLock { windowHandles.removeAll { $0 === handle } }
        }

        func hostTimeNow() -> CMTime { CMTime(value: 42, timescale: 1) }
        func frontmostWindow() -> FrontmostWindowLookup { .unavailable }
    }

    private final class Observations: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        var count: Int { lock.withLock { stored } }
        func add() { lock.withLock { stored += 1 } }
    }

    private let platform = FakePlatform()
    private let observations = Observations()

    private func start(_ source: SystemFrontmostWindowSource) {
        let observations = observations
        XCTAssertTrue(source.start { _ in observations.add() })
    }

    func testStartingReportsOnceAndWatchesTheFrontmostApplicationsWindows() {
        let source = SystemFrontmostWindowSource(platform: platform)
        start(source)
        XCTAssertEqual(observations.count, 1, "the window frontmost at the start")
        XCTAssertTrue(platform.windowHandles.isEmpty, "set up on the main thread, not yet run")
        platform.runMain()
        XCTAssertEqual(platform.windowHandles.map(\.pid), [100])

        platform.windowHandles[0].handler()
        XCTAssertEqual(observations.count, 2, "a window change within the application")
        platform.activate(200)
        XCTAssertEqual(observations.count, 3, "an application switch")
        XCTAssertEqual(platform.windowHandles.map(\.pid), [200], "now watching the new application only")

        platform.onMainThread = true
        source.stop()
        platform.onMainThread = false
        XCTAssertTrue(platform.windowHandles.isEmpty)
        XCTAssertEqual(platform.activationCount, 0)
    }

    func testWithoutAccessibilityTrustOnlyApplicationSwitchesAreSeen() {
        platform.trusted = false
        let source = SystemFrontmostWindowSource(platform: platform)
        start(source)
        platform.runMain()
        platform.activate(200)
        XCTAssertEqual(observations.count, 2)
        XCTAssertTrue(platform.windowHandles.isEmpty)
        source.stop()
        platform.runMain()
    }

    /// Released off the main thread while running: cleanup is queued with the registration, not
    /// the source, which is gone at once; running the queue removes every observer.
    func testReleasedOffTheMainThreadItCleansUpWithoutKeepingTheSource() {
        weak var released: SystemFrontmostWindowSource?
        let platform = platform
        let observations = observations
        DispatchQueue.global().sync {
            let source = SystemFrontmostWindowSource(platform: platform)
            XCTAssertTrue(source.start { _ in observations.add() })
            released = source
        }
        XCTAssertNil(released, "nothing queued keeps the source")
        XCTAssertEqual(platform.activationCount, 0, "the workspace observer is removed at once")
        XCTAssertEqual(platform.queuedCount, 2, "setup, then cleanup")
        platform.runMain()
        XCTAssertTrue(platform.windowHandles.isEmpty)
        platform.activate(200)
        XCTAssertEqual(observations.count, 1, "nothing after the release")
    }

    /// A stop off the main thread queues its cleanup; a start made before it runs keeps its own
    /// observer.
    func testAStaleCleanupRemovesOnlyItsOwnObserver() {
        let source = SystemFrontmostWindowSource(platform: platform)
        start(source)
        platform.runMain()
        let first = platform.windowHandles
        XCTAssertEqual(first.count, 1)

        source.stop()
        start(source)
        platform.runMain()

        XCTAssertEqual(platform.windowHandles.count, 1)
        XCTAssertFalse(platform.windowHandles[0] === first[0], "the first start's observer is gone, the second's kept")
        XCTAssertEqual(platform.activationCount, 1)
        platform.activate(200)
        XCTAssertEqual(observations.count, 3, "each start once, then the second start's switch")
        source.stop()
        platform.runMain()
        XCTAssertTrue(platform.windowHandles.isEmpty)
    }

    /// Setup queued by a start that is stopped on the main thread before the setup runs installs
    /// nothing, and an activation after the stop does nothing.
    func testAStaleSetupInstallsNothing() {
        let source = SystemFrontmostWindowSource(platform: platform)
        start(source)
        platform.onMainThread = true
        source.stop()
        platform.onMainThread = false
        XCTAssertEqual(platform.queuedCount, 1, "only the setup")
        platform.runMain()
        XCTAssertTrue(platform.windowHandles.isEmpty)
        platform.activate(200)
        XCTAssertEqual(observations.count, 1)
        XCTAssertTrue(platform.windowHandles.isEmpty)
    }
}
