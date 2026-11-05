import CoreGraphics
import CoreMedia
import Foundation

/// Pointer activity in global screen points (top-left origin of the main display), and
/// frontmost-window changes, before they are converted to capture coordinates. It is not an
/// `ActivityEvent`, whose location is in capture coordinates; that conversion needs the
/// recording's geometry.
struct GlobalActivityEvent: Equatable, Sendable {
    /// Session time on the capture clock.
    var sessionTime: CMTime
    var kind: ActivityEventKind
    /// For pointer kinds.
    var globalPoint: CGPoint?
    /// The mouse button, for click and drag kinds.
    var button: Int?
    /// The element at `globalPoint` when the event was delivered, which can differ from the
    /// element there when the event happened.
    var target: ElementDescriptor?
    /// `activeWindowChange` only: the window frontmost when the change was observed.
    var window: WindowDescriptor?
}

/// The fields of a pointer CGEvent the recorder reads. Key events are never read.
struct PointerSample: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case move
        case down
        case dragged
        case up
        case scroll
    }

    var action: Action
    /// The CGEvent timestamp: nanoseconds since startup (`CGEventTypes.h`).
    var timestamp: UInt64
    var location: CGPoint
    var button: Int

    static let eventTypes: [CGEventType] = [
        .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .scrollWheel,
    ]

    init(action: Action, timestamp: UInt64, location: CGPoint, button: Int = 0) {
        self.action = action
        self.timestamp = timestamp
        self.location = location
        self.button = button
    }

    /// The sample for a pointer event, or nil for any other type.
    init?(_ event: CGEvent) {
        let action: Action
        switch event.type {
        case .mouseMoved: action = .move
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: action = .down
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: action = .dragged
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: action = .up
        case .scrollWheel: action = .scroll
        default: return nil
        }
        self.init(
            action: action, timestamp: event.timestamp, location: event.location,
            button: Int(event.getIntegerValueField(.mouseEventButtonNumber)))
    }

    /// The host time of a CGEvent timestamp. The host clock counts nanoseconds since startup on
    /// the same base, so the conversion is a change of units. A zero timestamp is unset.
    static func hostTime(_ timestamp: UInt64) -> CMTime? {
        guard timestamp > 0, let value = Int64(exactly: timestamp) else { return nil }
        return CMTime(value: value, timescale: 1_000_000_000)
    }
}

/// Turns pointer samples into activity kinds. A press is a click. The first drag after a press
/// starts a drag, later drags are pointer moves, and the release ends it. A drag with no press
/// seen is a pointer move, and a release with no drag seen ends nothing: missing transitions
/// are never invented. `reset()` forgets every pressed button, for when events may have been
/// lost.
struct PointerTranslator: Sendable {
    private var pressed: Set<Int> = []
    private var dragging: Set<Int> = []

    mutating func translate(_ sample: PointerSample) -> (kind: ActivityEventKind, button: Int?)? {
        switch sample.action {
        case .move:
            return (.pointerMove, nil)
        case .scroll:
            return (.scroll, nil)
        case .down:
            pressed.insert(sample.button)
            dragging.remove(sample.button)
            return (.click, sample.button)
        case .dragged:
            guard pressed.contains(sample.button), !dragging.contains(sample.button) else {
                return (.pointerMove, nil)
            }
            dragging.insert(sample.button)
            return (.dragStart, sample.button)
        case .up:
            pressed.remove(sample.button)
            guard dragging.remove(sample.button) != nil else { return nil }
            return (.dragEnd, sample.button)
        }
    }

    mutating func reset() {
        pressed = []
        dragging = []
    }
}

/// What a session counted. Every pointer event the tap delivered to the session while it was
/// admitting is in exactly one count.
struct TelemetryRecorderCounts: Equatable, Sendable {
    /// What became of the frontmost-window observations the session admitted or refused. Each
    /// observation the source reported while the session was admitting is in exactly one count.
    struct Windows: Equatable, Sendable {
        /// A window other than the last one recorded: an `activeWindowChange` was delivered.
        var recorded = 0
        /// The window last recorded is still frontmost.
        var unchanged = 0
        /// No window could be read; the last one recorded stands.
        var unavailable = 0
        var droppedSuspended = 0
        /// Before the epoch, inside a pause, or after the end.
        var droppedNoSessionTime = 0
        var droppedOverflow = 0
    }

    var delivered = 0
    var droppedSuspended = 0
    /// Before the epoch, inside a pause, or with an unset timestamp.
    var droppedNoSessionTime = 0
    var droppedOverflow = 0
    /// A release that ended no drag carries nothing new.
    var notRecorded = 0
    var tapReenabled = 0
    var windows = Windows()
}

enum TelemetryRecorderStatus: Equatable, Sendable {
    case idle
    case running
    /// The event tap could not be created, for example without Input Monitoring or
    /// Accessibility trust.
    case tapUnavailable
    /// The system disabled the tap and it could not be enabled again; the recorder stopped.
    case tapFailed
}

/// The source of pointer samples, so the recorder can be tested without a real tap.
protocol PointerEventTap: AnyObject, Sendable {
    /// Starts delivering samples on one thread, in order, and reports each time the system
    /// disabled the tap with whether enabling it again worked. Returns false if no tap could be
    /// created.
    func start(
        onSample: @escaping @Sendable (PointerSample) -> Void,
        onDisabled: @escaping @Sendable (_ reenabled: Bool) -> Void
    ) -> Bool
    func stop()
}

/// Records pointer activity from a listen-only event tap, and frontmost-window changes from a
/// `FrontmostWindowSource` (T041).
///
/// On the tap's thread, each event is checked against suspension at the moment it arrives, then
/// stamped on the capture clock and queued, all under one lock; the tap never waits on
/// Accessibility or the sink. A serial queue resolves each event's target and hands it to the
/// sink in arrival order, whether or not a target resolves. At most `capacity` events wait;
/// beyond that the newest is dropped and counted.
///
/// A frontmost-window observation is stamped with the host time the source observed it and
/// admitted like a pointer event, taking its place on the serial queue under the lock. Only then
/// is the window frontmost read, on the source's thread, outside the lock; the queue waits at
/// that place for the reading, so later pointer events and observations stay behind it, while
/// the tap is never held. On the queue the window is delivered as an `activeWindowChange` only
/// if it differs from the last window the session recorded; the first window read in a session
/// is always recorded. When no window can be read, nothing is delivered and the last window
/// recorded stands, so a return to it records nothing new. An observation dropped while
/// suspended or paused reads no window and records nothing; `observeWindow(atHostTime:)` asks
/// for a fresh one, for example on resume.
///
/// Each start begins a session. Stopping a session closes its admission under the lock that
/// admits and queues events, stops the tap, then queues the session's end, so every event it
/// admitted is delivered before its completion runs, even if a new session has started
/// meanwhile, and nothing is admitted after. `stop` does not wait for the queue to drain, so the
/// sink may call it. Starts, stops, and a failed tap's stop are serialised, and a stop acts only
/// on the session it was made for.
final class TelemetryRecorder: @unchecked Sendable {
    /// Its state is read and written only under the recorder's `lock`.
    private final class Session: @unchecked Sendable {
        var admitting = true
        var failed = false
        var counts = TelemetryRecorderCounts()
        /// The window last delivered. Read and written only on the serial queue.
        var lastWindow: WindowDescriptor?
    }

    let capacity: Int

    private let clock: CaptureClock
    private let filter: ActivityEventFilter
    private let resolver: TargetResolver
    private let tap: PointerEventTap
    private let windows: FrontmostWindowSource?
    private let sink: @Sendable (GlobalActivityEvent) -> Void
    private let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let worker = DispatchQueue(label: "local.recordmac.telemetry-recorder")

    /// Held across a whole start or stop.
    private let lifecycle = NSLock()
    /// Held for admission, counting, and session state; never while calling the tap or the sink.
    private let lock = NSLock()
    private var current: Session?
    private var lastStatus = TelemetryRecorderStatus.idle
    private var lastSession: Session?
    private var translator = PointerTranslator()
    private var pending = 0

    /// `schedule` runs work off the tap's thread; tests replace it to force an interleaving.
    /// With no `windows` source, no window changes are recorded.
    init(
        clock: CaptureClock,
        filter: ActivityEventFilter,
        resolver: TargetResolver = TargetResolver(),
        tap: PointerEventTap = SystemPointerEventTap(),
        windows: FrontmostWindowSource? = nil,
        capacity: Int = 4096,
        schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.global().async(execute: $0) },
        sink: @escaping @Sendable (GlobalActivityEvent) -> Void
    ) {
        self.clock = clock
        self.filter = filter
        self.resolver = resolver
        self.tap = tap
        self.windows = windows
        self.capacity = capacity
        self.schedule = schedule
        self.sink = sink
    }

    /// A recorder released while running stops its tap. It does not wait, so a release on the
    /// tap's own thread cannot deadlock.
    deinit {
        if lock.withLock({ current }) != nil {
            tap.stop()
            windows?.stop()
        }
    }

    var status: TelemetryRecorderStatus {
        lock.withLock {
            guard let current else { return lastStatus }
            return current.failed ? .tapFailed : .running
        }
    }

    /// The counts of the running session, or of the last one.
    var counts: TelemetryRecorderCounts {
        lock.withLock { (current ?? lastSession)?.counts ?? TelemetryRecorderCounts() }
    }

    @discardableResult
    func start() -> TelemetryRecorderStatus {
        lifecycle.withLock {
            let session: Session? = lock.withLock {
                guard current == nil else { return nil }
                let session = Session()
                current = session
                translator.reset()
                return session
            }
            guard let session else { return status }
            let started = tap.start(
                onSample: { [weak self, weak session] sample in
                    guard let self, let session else { return }
                    self.receive(sample, in: session)
                },
                onDisabled: { [weak self, weak session] reenabled in
                    guard let self, let session else { return }
                    self.tapDisabled(reenabled: reenabled, in: session)
                })
            if !started {
                lock.withLock {
                    current = nil
                    lastStatus = .tapUnavailable
                    lastSession = session
                }
            } else {
                _ = windows?.start { [weak self, weak session] hostTime in
                    guard let self, let session else { return }
                    self.observeWindow(atHostTime: hostTime, in: session)
                }
            }
            return status
        }
    }

    /// Stops the running session: closes its admission, stops the tap, delivers every event it
    /// admitted (including any admitted before a suspension), then calls `completion` with its
    /// final counts. With no session running, `completion` gets the last session's counts. A
    /// session whose tap failed ends as `.tapFailed`, otherwise as `.idle`.
    func stop(completion: @escaping @Sendable (TelemetryRecorderCounts) -> Void = { _ in }) {
        lifecycle.withLock {
            let (session, previous) = lock.withLock { (current, lastSession) }
            guard let session else {
                // Queued after the previous session's end, so its counts are final.
                worker.async { [self] in
                    completion(lock.withLock { previous?.counts ?? TelemetryRecorderCounts() })
                }
                return
            }
            // A session whose tap failed keeps reporting the failure.
            end(session, status: lock.withLock { session.failed } ? .tapFailed : .idle, completion: completion)
        }
    }

    /// Runs on the tap's thread.
    private func receive(_ sample: PointerSample, in session: Session) {
        let suspended = filter.isSuspended
        lock.withLock {
            guard session.admitting else { return }
            guard !suspended else { return drop(sample, &session.counts.droppedSuspended) }
            guard let host = PointerSample.hostTime(sample.timestamp),
                let sessionTime = clock.sessionTime(forHostTime: host)
            else { return drop(sample, &session.counts.droppedNoSessionTime) }

            var next = translator
            guard let (kind, button) = next.translate(sample) else {
                translator = next
                session.counts.notRecorded += 1
                return
            }
            guard pending < capacity else { return drop(sample, &session.counts.droppedOverflow) }
            translator = next
            pending += 1
            let event = GlobalActivityEvent(sessionTime: sessionTime, kind: kind, globalPoint: sample.location, button: button)
            // Queued under the lock, so it precedes any end of this session queued after it.
            worker.async { [self] in deliver(event, in: session) }
        }
    }

    /// Asks for the frontmost window as of `hostTime` in the running session, as if the source had
    /// observed a change then.
    func observeWindow(atHostTime hostTime: CMTime) {
        guard let session = lock.withLock({ current }) else { return }
        observeWindow(atHostTime: hostTime, in: session)
    }

    /// The window an admitted observation read, handed from the source's thread to the queue.
    private final class WindowReading: @unchecked Sendable {
        private let ready = DispatchSemaphore(value: 0)
        private var lookup = FrontmostWindowLookup.unavailable

        func fill(_ lookup: FrontmostWindowLookup) {
            self.lookup = lookup
            ready.signal()
        }

        func wait() -> FrontmostWindowLookup {
            ready.wait()
            return lookup
        }
    }

    /// Runs on the source's thread.
    private func observeWindow(atHostTime hostTime: CMTime, in session: Session) {
        let suspended = filter.isSuspended
        let reading: WindowReading? = lock.withLock {
            guard session.admitting else { return nil }
            guard !suspended else {
                session.counts.windows.droppedSuspended += 1
                return nil
            }
            guard let sessionTime = clock.sessionTime(forHostTime: hostTime) else {
                session.counts.windows.droppedNoSessionTime += 1
                return nil
            }
            guard pending < capacity else {
                session.counts.windows.droppedOverflow += 1
                return nil
            }
            pending += 1
            let reading = WindowReading()
            // Queued under the lock, so it keeps its place among pointer events and precedes any
            // end of this session queued after it.
            worker.async { [self] in deliverWindow(reading.wait(), at: sessionTime, in: session) }
            return reading
        }
        // Every admitted observation fills its reading, so the queue never waits past it.
        reading?.fill(windows?.frontmostWindow() ?? .unavailable)
    }

    private func deliverWindow(_ lookup: FrontmostWindowLookup, at sessionTime: CMTime, in session: Session) {
        lock.withLock { pending -= 1 }
        guard case .window(let window) = lookup else {
            lock.withLock { session.counts.windows.unavailable += 1 }
            return
        }
        guard window != session.lastWindow else {
            lock.withLock { session.counts.windows.unchanged += 1 }
            return
        }
        session.lastWindow = window
        lock.withLock { session.counts.windows.recorded += 1 }
        sink(GlobalActivityEvent(sessionTime: sessionTime, kind: .activeWindowChange, window: window))
    }

    /// A dropped press, drag, or release loses a transition, so press state is forgotten rather
    /// than completed from a guess. Called with the lock held.
    private func drop(_ sample: PointerSample, _ count: inout Int) {
        count += 1
        if sample.action != .move, sample.action != .scroll { translator.reset() }
    }

    private func tapDisabled(reenabled: Bool, in session: Session) {
        let failed: Bool = lock.withLock {
            guard session.admitting else { return false }
            // Events were lost while the tap was off, so no press state can be trusted.
            translator.reset()
            if reenabled {
                session.counts.tapReenabled += 1
                return false
            }
            session.failed = true
            session.admitting = false
            return true
        }
        guard failed else { return }
        schedule { [weak self, weak session] in
            guard let self, let session else { return }
            self.lifecycle.withLock {
                guard self.lock.withLock({ self.current === session }) else { return }
                self.end(session, status: .tapFailed) { _ in }
            }
        }
    }

    /// Called with `lifecycle` held, for the current session. Admission closes first, so the end
    /// queued after the tap has stopped still follows every event the session admitted, and the
    /// completion cannot run before the tap has stopped.
    private func end(
        _ session: Session, status: TelemetryRecorderStatus,
        completion: @escaping @Sendable (TelemetryRecorderCounts) -> Void
    ) {
        lock.withLock {
            session.admitting = false
            current = nil
            lastStatus = status
            lastSession = session
            translator.reset()
        }
        tap.stop()
        windows?.stop()
        worker.async { [self] in
            completion(lock.withLock { session.counts })
        }
    }

    private func deliver(_ event: GlobalActivityEvent, in session: Session) {
        lock.withLock { pending -= 1 }
        var event = event
        event.target = event.globalPoint.flatMap { resolver.target(at: $0) }
        lock.withLock { session.counts.delivered += 1 }
        sink(event)
    }
}

/// A listen-only session event tap for pointer events, run on its own thread. It never alters or
/// withholds an event.
final class SystemPointerEventTap: PointerEventTap, @unchecked Sendable {
    private final class Context {
        let onSample: @Sendable (PointerSample) -> Void
        let onDisabled: @Sendable (Bool) -> Void
        var port: CFMachPort?

        init(onSample: @escaping @Sendable (PointerSample) -> Void, onDisabled: @escaping @Sendable (Bool) -> Void) {
            self.onSample = onSample
            self.onDisabled = onDisabled
        }
    }

    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var port: CFMachPort?
    private var runningThread: Thread?

    /// The thread running the current tap, if any.
    var thread: Thread? { lock.withLock { runningThread } }

    /// Released while running, the tap is disabled and its thread's run loop stopped, without
    /// waiting for the thread.
    deinit {
        stop()
    }

    func start(
        onSample: @escaping @Sendable (PointerSample) -> Void,
        onDisabled: @escaping @Sendable (Bool) -> Void
    ) -> Bool {
        stop()
        let context = Context(onSample: onSample, onDisabled: onDisabled)
        let mask = PointerSample.eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: pointerTapCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque())
        else { return false }
        context.port = port

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            let runLoop = CFRunLoopGetCurrent()!
            CFRunLoopAddSource(runLoop, source, .commonModes)
            self?.lock.withLock { self?.runLoop = runLoop }
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            // The context stays alive until the run loop that calls back with it has ended.
            withExtendedLifetime(context) {}
        }
        thread.name = "local.recordmac.pointer-tap"
        lock.withLock {
            self.port = port
            self.runningThread = thread
        }
        thread.start()
        ready.wait()
        return true
    }

    func stop() {
        let (port, runLoop) = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            defer {
                self.port = nil
                self.runLoop = nil
                self.runningThread = nil
            }
            return (self.port, self.runLoop)
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    fileprivate static func handle(
        _ type: CGEventType, _ event: CGEvent, _ userInfo: UnsafeMutableRawPointer?
    ) {
        guard let userInfo else { return }
        let context = Unmanaged<Context>.fromOpaque(userInfo).takeUnretainedValue()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            guard let port = context.port else { return }
            CGEvent.tapEnable(tap: port, enable: true)
            context.onDisabled(CGEvent.tapIsEnabled(tap: port))
        default:
            if let sample = PointerSample(event) { context.onSample(sample) }
        }
    }
}

private let pointerTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    SystemPointerEventTap.handle(type, event, userInfo)
    return Unmanaged.passUnretained(event)
}
