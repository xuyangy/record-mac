import CoreMedia
import Foundation

/// How a finalised recording ended.
enum RecordingEnd: Equatable, Sendable {
    /// The owner stopped it. A stream that stopped on its own at or after that stop ends here too.
    case requested
    /// The stream stopped on its own before the owner's stop, for a reason the backend keeps only as
    /// text. Not classified: it may be a lost source, a revoked permission, a full disk, or another
    /// error.
    case streamStopped(reason: String)
}

/// What the caller says about a recording, for its project.
struct RecordingMetadata: Equatable, Sendable {
    var id: UUID
    var displayName: String
    var createdAt: Date
    var sourceDescription: String
}

enum RecordingPipelineError: Error {
    /// The call is not allowed in the pipeline's state; nothing was changed.
    case illegalCall(RecordingPipeline.State, String)
    /// The engine started no recording. `cleanup` is what the cleanup stop finalised, or its error.
    case startFailed(Error, cleanup: Result<RecordingStartCleanup, Error>)
    /// The engine's stop failed after the session left recording; nothing is left to finalise.
    case finalizeFailed(Error)
}

/// What the cleanup stop after a failed start finalised. Never a project: the recording did not start.
struct RecordingStartCleanup {
    var captureDirectory: URL
    var tracks: [MediaTrack]
    var report: ScreenCaptureBackendReport
}

enum RecordingPublishError: Error, Equatable {
    /// The clock was not ended, so the recording has no end to close its pauses at.
    case clockNotEnded
    /// The backend has no frame report, so no measured counts to write.
    case noFrameReport
    /// The stream stopped on its own and the caller gave no reason; the backend's text is kept.
    case endNotClassified(reason: String)
    /// `completed` describes only a requested stop, not a stream that stopped on its own.
    case completedIsNotAStreamStop
}

/// A recording the engine stopped: its tracks in the capture directory, the backend's report, and
/// the clock's reference, pauses, and end. Publishing it writes a project and changes none of it, so
/// a publish that fails can be tried again without stopping the capture again.
struct FinalizedRecording {
    var captureDirectory: URL
    var tracks: [MediaTrack]
    var report: ScreenCaptureBackendReport
    var clockReference: CaptureClockReference
    /// Host time the clock ended: the owner's stop, or where the stream stopped on its own.
    var endHostTime: CMTime?
    /// Paused intervals in seconds since the epoch, each ending at the clock's end at the latest;
    /// a pause that began at or after the end is left out.
    var pauses: [CaptureTimeRange]
    var end: RecordingEnd

    /// The project's end reason: `completed` for a requested stop; for a stream that stopped on its
    /// own, `streamStopReason`, which the caller must give.
    func endReason(streamStopReason: CaptureEndReason?) throws(RecordingPublishError) -> CaptureEndReason {
        switch end {
        case .requested:
            return .completed
        case .streamStopped(let reason):
            guard let streamStopReason else { throw .endNotClassified(reason: reason) }
            guard streamStopReason != .completed else { throw .completedIsNotAStreamStop }
            return streamStopReason
        }
    }

    /// Writes the project with `ProjectWriter`, which copies the media and refuses a telemetry
    /// report that is not recorded. Overlaid ranges are empty: the backend captures no Presenter
    /// Overlay composite. Throws a `RecordingPublishError` or a `ProjectWriterError`.
    func publish(
        named name: String, in parent: URL, metadata: RecordingMetadata,
        streamStopReason: CaptureEndReason? = nil,
        beforeStep: (ProjectWriter.Step) throws -> Void = { _ in }
    ) throws -> ProjectWriteResult {
        guard endHostTime != nil else { throw RecordingPublishError.clockNotEnded }
        guard let frameReport = report.frameReport else { throw RecordingPublishError.noFrameReport }
        let draft = ProjectDraft(
            id: metadata.id, displayName: metadata.displayName, createdAt: metadata.createdAt,
            captureClock: clockReference, pauses: pauses,
            endReason: try endReason(streamStopReason: streamStopReason),
            overlaidRanges: [], frameReport: frameReport, sourceDescription: metadata.sourceDescription)
        return try ProjectWriter.write(
            named: name, in: parent, draft: draft, tracks: tracks, captureDirectory: captureDirectory,
            telemetry: report.telemetry, beforeStep: beforeStep)
    }

    /// The clock's pauses, in seconds since the epoch, closed and clipped at `end`.
    static func pauses(of snapshot: CaptureClockSnapshot, endingAt end: CMTime) -> [CaptureTimeRange] {
        snapshot.pauses.compactMap { pause in
            guard pause.startHostTime < end else { return nil }
            let pauseEnd = min(pause.endHostTime ?? end, end)
            return CaptureTimeRange(
                start: (pause.startHostTime - snapshot.epochHostTime).seconds,
                end: (pauseEnd - snapshot.epochHostTime).seconds)
        }
    }
}

/// One recording on `CaptureEngine` and a `ScreenCaptureBackend` writing to `captureDirectory`, its
/// activity passing `activityFilter`: start, pause, resume, and finalise. Single use.
///
/// `finalize` stops the engine once and returns a `FinalizedRecording`, which is published
/// separately. A failed start runs the engine's cleanup stop, so nothing the backend started keeps
/// running. Each call is refused, changing nothing, in a state that does not allow it, including
/// while another call is under way.
@MainActor
final class RecordingPipeline {
    enum State: Equatable, Sendable {
        case idle
        case starting
        /// Pause, resume, and finalize are allowed; the engine refuses one its own phase does not
        /// allow.
        case recording
        case finalizing
        case finalized
        case startFailed
        case finalizeFailed
    }

    typealias MakeBackend = @MainActor (URL, ActivityEventFilter) -> ScreenCaptureBackend

    let captureDirectory: URL
    let activityFilter: ActivityEventFilter
    private(set) var state = State.idle
    private(set) var finalized: FinalizedRecording?

    private let makeBackend: MakeBackend
    private var engine: CaptureEngine!
    private var backend: ScreenCaptureBackend?
    private var session: CaptureSession?
    private var clock: CaptureClock?

    /// `makeBackend` makes the backend for the capture directory and filter; by default, a
    /// `ScreenCaptureBackend` with the system's telemetry.
    init(
        captureDirectory: URL,
        activityFilter: ActivityEventFilter,
        refreshRate: @escaping (CaptureSource) -> RefreshRate,
        hostTimeNow: @escaping () -> CMTime = CaptureClock.hostTimeNow,
        makeBackend: MakeBackend? = nil
    ) {
        self.captureDirectory = captureDirectory
        self.activityFilter = activityFilter
        self.makeBackend = makeBackend ?? { directory, filter in
            ScreenCaptureBackend(directory: directory, hostTimeNow: hostTimeNow, activityFilter: filter)
        }
        engine = CaptureEngine(
            makeBackend: { [unowned self] _ in
                let backend = self.makeBackend(self.captureDirectory, self.activityFilter)
                self.backend = backend
                return backend
            },
            refreshRate: refreshRate,
            hostTimeNow: hostTimeNow)
    }

    func offers(_ source: CaptureSource) -> CaptureOffers { engine.offers(source) }

    /// Prepares and starts the recording. A refused prepare creates nothing and leaves the pipeline
    /// idle. A failed start runs the cleanup stop and throws `startFailed` with the primary error.
    func start(_ source: CaptureSource, _ options: CaptureEngineOptions) async throws -> CaptureClock {
        guard state == .idle else { throw RecordingPipelineError.illegalCall(state, "start") }
        state = .starting
        let session: CaptureSession
        do {
            session = try await engine.prepare(source, options)
        } catch {
            backend = nil
            state = .idle
            throw error
        }
        do {
            let clock = try await engine.start(session)
            self.session = session
            self.clock = clock
            state = .recording
            return clock
        } catch {
            state = .startFailed
            let cleanup: Result<RecordingStartCleanup, Error>
            do {
                let tracks = try await engine.stop(session)
                cleanup = .success(RecordingStartCleanup(
                    captureDirectory: captureDirectory, tracks: tracks, report: backend?.report ?? ScreenCaptureBackendReport()))
            } catch let cleanupError {
                cleanup = .failure(cleanupError)
            }
            throw RecordingPipelineError.startFailed(error, cleanup: cleanup)
        }
    }

    func pause() async throws {
        guard state == .recording, let session else { throw RecordingPipelineError.illegalCall(state, "pause") }
        try await engine.pause(session)
    }

    func resume() async throws {
        guard state == .recording, let session else { throw RecordingPipelineError.illegalCall(state, "resume") }
        try await engine.resume(session)
    }

    /// Stops the engine, once, and keeps what it finalised. A stop the engine refuses while a pause
    /// or resume is under way changes nothing, and may be called again.
    func finalize() async throws -> FinalizedRecording {
        guard state == .recording, let session, let clock, let backend else {
            throw RecordingPipelineError.illegalCall(state, "finalize")
        }
        state = .finalizing
        let tracks: [MediaTrack]
        do {
            tracks = try await engine.stop(session)
        } catch let error as CaptureEngineError {
            state = .recording
            throw error
        } catch {
            state = .finalizeFailed
            throw RecordingPipelineError.finalizeFailed(error)
        }
        let snapshot = clock.snapshot()
        let report = backend.report
        let end: RecordingEnd = if let stopped = report.streamStopped, stopped.at != nil {
            .streamStopped(reason: stopped.reason)
        } else {
            .requested
        }
        let finalized = FinalizedRecording(
            captureDirectory: captureDirectory, tracks: tracks, report: report,
            clockReference: clock.reference, endHostTime: snapshot.endHostTime,
            pauses: snapshot.endHostTime.map { FinalizedRecording.pauses(of: snapshot, endingAt: $0) } ?? [],
            end: end)
        self.finalized = finalized
        state = .finalized
        return finalized
    }
}
