import CoreMedia
import Foundation

/// A call the session's phase does not allow; nothing changes.
enum TelemetrySessionError: Error, Equatable {
    case alreadyStarted
    case notStarted
    /// A stop is under way or done.
    case alreadyStopped
}

/// What one recording's activity telemetry produced.
struct TelemetryOutcome: Equatable, Sendable {
    /// The frozen stream: every event the recorder admitted, with the geometry in force at each.
    var stream: ActivityStream
    /// How activity recording ended: `.idle` when it ran to the stop, `.tapUnavailable` when no
    /// event tap could be created (the stream then holds no pointer events), `.tapFailed` when the
    /// system disabled the tap for good partway through.
    var activity: TelemetryRecorderStatus
    var counts: TelemetryRecorderCounts
    var geometry: GeometryFeedCounts
    /// What the geometry observer could see; nil if it was never set up.
    var coverage: SourceGeometryCoverage?
}

/// The activity telemetry of one recording (T041): pointer activity and frontmost-window changes
/// from a `TelemetryRecorder`, the source's geometry from a `SourceGeometryObserver` through a
/// `GeometryRecorder`, frozen together into an `ActivityStream` at the stop. Each recording uses a
/// new session, so nothing of one recording reaches another.
///
/// The session never pauses, resumes, or ends the shared `CaptureClock`; its owner does, and
/// tells the session of a resume after applying it. A pause needs no call: both recorders already
/// drop anything stamped inside a pause. Suspending activity recording (`ActivityEventFilter`)
/// stops pointer and window events but not geometry, which still says where the source is.
///
/// Every call is made on the main actor. Events arrive from the recorder's worker thread into a
/// locked collection; geometry readings arrive on the main thread.
@MainActor
final class TelemetrySession {
    private enum Phase {
        case idle
        case running
        case stopping
        case stopped
    }

    /// The recorder's events, collected from its worker thread.
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [GlobalActivityEvent] = []
        func add(_ event: GlobalActivityEvent) { lock.withLock { stored.append(event) } }
        var all: [GlobalActivityEvent] { lock.withLock { stored } }
    }

    private let target: SourceGeometryTarget
    private let frame: @Sendable () -> CaptureFrameGeometry?
    private let recorder: TelemetryRecorder
    private let feed: GeometryRecorderFeed
    private let observer: SourceGeometryObserver
    private let events = Events()
    private var phase = Phase.idle

    /// `initial` is the source's geometry at the clock's epoch, as capture prepared it; throws
    /// `GeometryRecorderError.invalidGeometry` if it is not valid. `frame` is read at each
    /// geometry reading for the frame capture produces.
    init(
        clock: CaptureClock,
        target: SourceGeometryTarget,
        initial: SourceGeometry,
        frame: @escaping @Sendable () -> CaptureFrameGeometry?,
        filter: ActivityEventFilter,
        resolver: TargetResolver = TargetResolver(),
        tap: PointerEventTap = SystemPointerEventTap(),
        windows: FrontmostWindowSource? = SystemFrontmostWindowSource(),
        observer: SourceGeometryObserver = SourceGeometryObserver()
    ) throws {
        self.target = target
        self.frame = frame
        self.observer = observer
        feed = GeometryRecorderFeed(recorder: try GeometryRecorder(clock: clock, initial: initial))
        let events = events
        recorder = TelemetryRecorder(
            clock: clock, filter: filter, resolver: resolver, tap: tap, windows: windows,
            sink: { events.add($0) })
    }

    /// Starts activity recording and geometry observation. Returns the recorder's status: a tap
    /// that cannot be created leaves geometry observed and the session running, so the stop
    /// still freezes a stream, and reports `.tapUnavailable` there.
    @discardableResult
    func start() throws -> TelemetryRecorderStatus {
        guard phase == .idle else { throw phase == .running ? TelemetrySessionError.alreadyStarted : .alreadyStopped }
        phase = .running
        let feed = feed
        observer.start(target, frame: frame) { feed.take($0) }
        return recorder.start()
    }

    /// Called by the clock's owner once it has applied a resume at `hostTime`. Takes a fresh
    /// geometry reading, stamped when it is read, and asks for the frontmost window as of the
    /// resume. Events admitted between the resume and that reading map with the geometry in force
    /// before the pause; the reading does not repair them.
    func didResume(atHostTime hostTime: CMTime) {
        guard phase == .running else { return }
        observer.refresh()
        recorder.observeWindow(atHostTime: hostTime)
    }

    /// Stops geometry observation first, so no source change after the stop request enters the
    /// stream, then closes activity admission and waits until every admitted event has been
    /// delivered, then freezes. Safe while paused and after a tap failure. A second stop, or a
    /// stop before start, throws and changes nothing; the outcome of the first is unaffected by
    /// anything after it.
    func stop() async throws -> TelemetryOutcome {
        switch phase {
        case .idle: throw TelemetrySessionError.notStarted
        case .stopping, .stopped: throw TelemetrySessionError.alreadyStopped
        case .running: break
        }
        phase = .stopping
        defer { phase = .stopped }
        let coverage = observer.coverage
        observer.stop()
        let counts = await withCheckedContinuation { continuation in
            recorder.stop { continuation.resume(returning: $0) }
        }
        var builder = ActivityStreamBuilder()
        for segment in feed.recorder.segments { try builder.add(segment) }
        for event in events.all { builder.add(event) }
        return TelemetryOutcome(
            stream: try builder.freeze(), activity: recorder.status, counts: counts,
            geometry: feed.counts, coverage: coverage)
    }
}
