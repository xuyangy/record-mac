import CoreMedia
import Foundation

/// What `prepare` takes (contracts/capture-engine.md).
struct CaptureEngineOptions: Equatable, Sendable {
    /// The microphone to record, or nil for none.
    var microphoneDeviceID: String?
    var systemAudio: Bool
    /// The camera to record, or nil for none.
    var cameraDeviceID: String?
    var includesPointer: Bool
    /// One of `offers(source)`.
    var frameRate: Int
    var wantsAlpha: Bool
    /// Keep the Presenter Overlay composite as an extra track.
    var keepsPresenterComposite: Bool
}

/// A warning attached to an offered rate (FR-072). Raised only from a measured headroom, which
/// does not exist yet, so no offer carries one.
enum CaptureRateWarning: Equatable, Sendable {
    case exceedsMeasuredHeadroom
}

struct CaptureRateOffer: Equatable, Sendable {
    var frameRate: Int
    var headroom: FrameRateHeadroom
    var warning: CaptureRateWarning?
}

/// The rates a source can be captured at (FR-074).
struct CaptureOffers: Equatable, Sendable {
    var rates: [CaptureRateOffer]

    var frameRates: [Int] { rates.map(\.frameRate) }
}

/// Why `prepare` refused, in terms the interface can show (FR-067, FR-072, FR-074).
enum CapturePrepareError: Error, Equatable, Sendable {
    case permissionMissing(String)
    case sourceUnavailable(String)
    case cameraHeldByAnotherApplication
    /// Includes a frame rate not in `offers(source)`.
    case settingsNotProducible(String)
}

/// A call the session's phase does not allow, rejected without changing anything.
enum CaptureEngineError: Error, Equatable, Sendable {
    case notThisEngine
    case illegalTransition(phase: CaptureSession.Phase, call: String)
}

/// One prepared recording.
@MainActor
final class CaptureSession {
    enum Phase: Equatable, Sendable {
        case prepared
        case starting
        case recording
        case pausing
        case paused
        case resuming
        case stopping
        case stopped
        /// The backend failed during a transition; its state is not known, so only `stop` is
        /// allowed.
        case failed
    }

    let source: CaptureSource
    let options: CaptureEngineOptions
    fileprivate(set) var phase = Phase.prepared
    /// The one clock every track and activity event of this session is stamped against.
    fileprivate(set) var clock: CaptureClock?
    fileprivate let backend: CaptureBackend
    fileprivate weak var engine: CaptureEngine?

    fileprivate init(source: CaptureSource, options: CaptureEngineOptions, backend: CaptureBackend, engine: CaptureEngine) {
        self.source = source
        self.options = options
        self.backend = backend
        self.engine = engine
    }
}

/// The capture work behind a session: streams, writers, and telemetry. The engine tells it each
/// transition with the host time it has already applied to the session's clock, so every part
/// pauses and resumes at the same instant, and a sample stamped while a transition is under way
/// already maps to the right session time.
@MainActor
protocol CaptureBackend: AnyObject {
    /// Checks the settings against the live source, permissions, and devices; throws a
    /// `CapturePrepareError`.
    func validate(_ source: CaptureSource, _ options: CaptureEngineOptions) async throws
    func start(clock: CaptureClock) async throws
    func pause(atHostTime hostTime: CMTime) async throws
    func resume(atHostTime hostTime: CMTime) async throws
    /// Finalises every writer and returns the tracks; called while paused without resuming.
    func stop(atHostTime hostTime: CMTime) async throws -> [MediaTrack]
}

/// The capture interface and its legal transitions (contracts/capture-engine.md, T031 part 1).
///
/// Legal: prepared → recording → paused → recording, and recording, paused, or failed → stopped.
/// Any other call, a call on another engine's session, or a call while a transition is under
/// way is rejected without touching the backend or the clock. Pause and resume apply their
/// instant to the clock before the backend is told, so the clock never lags the backend. If the
/// backend fails a transition, the session is `failed` and only `stop` is allowed; neither the
/// clock nor a partly applied backend transition is undone.
@MainActor
final class CaptureEngine {
    private let makeBackend: (CaptureSource) -> CaptureBackend
    private let refreshRate: (CaptureSource) -> RefreshRate
    private let hostTimeNow: () -> CMTime

    /// `refreshRate` resolves a source to the rate it refreshes at: for a window or region, the
    /// lowest display it spans; for an attached device, its own. There is no default backend.
    init(
        makeBackend: @escaping (CaptureSource) -> CaptureBackend,
        refreshRate: @escaping (CaptureSource) -> RefreshRate,
        hostTimeNow: @escaping () -> CMTime = CaptureClock.hostTimeNow
    ) {
        self.makeBackend = makeBackend
        self.refreshRate = refreshRate
        self.hostTimeNow = hostTimeNow
    }

    /// 30 and 60 always; 120 and 240 when the source refreshes that fast. Headroom is not
    /// measured, so no offer is warned or withheld for it.
    func offers(_ source: CaptureSource) -> CaptureOffers {
        CaptureOffers(rates: refreshRate(source).deliverableFrameRates.map {
            CaptureRateOffer(frameRate: $0, headroom: .notMeasured, warning: nil)
        })
    }

    func prepare(_ source: CaptureSource, _ options: CaptureEngineOptions) async throws -> CaptureSession {
        let offered = offers(source).frameRates
        guard offered.contains(options.frameRate) else {
            throw CapturePrepareError.settingsNotProducible(
                "\(options.frameRate) fps is not offered for this source; offered: \(offered.map(String.init).joined(separator: ", "))")
        }
        let backend = makeBackend(source)
        try await backend.validate(source, options)
        return CaptureSession(source: source, options: options, backend: backend, engine: self)
    }

    func start(_ session: CaptureSession) async throws -> CaptureClock {
        try admit(session, "start", from: [.prepared], during: .starting)
        let clock = CaptureClock(epochHostTime: hostTimeNow())
        do {
            try await session.backend.start(clock: clock)
        } catch {
            session.phase = .failed
            throw error
        }
        session.clock = clock
        session.phase = .recording
        return clock
    }

    func pause(_ session: CaptureSession) async throws {
        try admit(session, "pause", from: [.recording], during: .pausing)
        let hostTime = hostTimeNow()
        session.clock?.pause(atHostTime: hostTime)
        do {
            try await session.backend.pause(atHostTime: hostTime)
        } catch {
            session.phase = .failed
            throw error
        }
        session.phase = .paused
    }

    func resume(_ session: CaptureSession) async throws {
        try admit(session, "resume", from: [.paused], during: .resuming)
        let hostTime = hostTimeNow()
        session.clock?.resume(atHostTime: hostTime)
        do {
            try await session.backend.resume(atHostTime: hostTime)
        } catch {
            session.phase = .failed
            throw error
        }
        session.phase = .recording
    }

    /// Safe while paused, which it does not leave, and after a failed transition. The session is
    /// stopped whether or not the backend finalises.
    func stop(_ session: CaptureSession) async throws -> [MediaTrack] {
        try admit(session, "stop", from: [.recording, .paused, .failed], during: .stopping)
        defer { session.phase = .stopped }
        return try await session.backend.stop(atHostTime: hostTimeNow())
    }

    /// Checks the call is legal and marks the transition under way, before any suspension, so
    /// an overlapping call is rejected.
    private func admit(
        _ session: CaptureSession, _ call: String, from allowed: Set<CaptureSession.Phase>,
        during transition: CaptureSession.Phase
    ) throws {
        guard session.engine === self else { throw CaptureEngineError.notThisEngine }
        guard allowed.contains(session.phase) else {
            throw CaptureEngineError.illegalTransition(phase: session.phase, call: call)
        }
        session.phase = transition
    }
}
