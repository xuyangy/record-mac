import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// What the router did with one route's buffers before they reached a writer. Screen counts
/// are frames; audio counts are sample frames.
struct CaptureRouteCounts: Equatable, Sendable {
    /// Left out on purpose: before the epoch or inside a pause.
    var excluded = 0
    /// Refused because they could not be put on the session clock, by reason.
    var failed: [String: Int] = [:]

    var failedTotal: Int { failed.values.reduce(0, +) }
}

/// Everything a stream's router accounted for, for the backend to merge with the writers'
/// outcomes. Frames and samples that reached a writer are counted only by that writer.
struct CaptureStreamRouterReport: Equatable, Sendable {
    /// Complete screen frames.
    var screen = CaptureRouteCounts()
    /// Screen buffers with a status other than complete, which carry no new frame, by status.
    var screenStatuses: [ScreenFrameStatus: Int] = [:]
    /// Screen buffers with no status, or one this build does not know, by reason. They are not
    /// known to carry a frame, so they are not counted as delivered.
    var screenUnknownStatuses: [String: Int] = [:]
    var audio: [AudioCaptureSource: CaptureRouteCounts] = [:]
    /// Callbacks after the router closed; none reached a writer.
    var afterClose = 0

    /// Complete frames refused before the screen writer, delivered and rejected with their
    /// reasons, to sit beside the writer's segments in `FrameReport(segments:)`; nil when none.
    var screenRejections: ScreenSegmentFrames? {
        let failed = screen.failedTotal
        guard failed > 0 else { return nil }
        return ScreenSegmentFrames(
            delivered: failed, appendRejected: failed,
            writerFailure: "not put on the session clock: "
                + screen.failed.sorted { $0.key < $1.key }.map { "\($0.value) × \($0.key)" }.joined(separator: "; "),
            written: .noFramesAppended)
    }
}

/// Routes one stream's sample buffers to their writers (contracts/capture-engine.md guarantees 7
/// and 9). Adapted from QuickRecorder's `RecordEngine.stream(_:didOutputSampleBuffer:of:)`
/// (UPSTREAM.md).
///
/// Every buffer runs on `queue`, the serial queue the backend gives each of the stream's
/// outputs, so buffers keep their order. Each is put on the session clock by `SessionRetimer`:
/// screen frames go to `screen` with their `SCFrameStatus`, system audio and microphone pieces
/// to their own writer in `audio`. A source with no writer is not recorded and its buffers are
/// ignored. A complete frame goes to the screen writer whether or not it has an image or
/// Presenter Overlay metadata; statuses other than complete carry no new frame and are only
/// counted, so an idle frame never creates a frame or a gap. A buffer with no status, or one
/// this build does not know, is counted apart and never as a delivered frame. Ending a segment when the source
/// becomes unavailable, and finishing the writers, stay with the backend.
///
/// `close` stops admission: every buffer that ran on the queue before it is routed, and none
/// after it reaches a writer.
final class CaptureStreamRouter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue: DispatchQueue

    private let retimer: SessionRetimer?
    private let missingClockReason = "the stream has no synchronization clock"
    private let screen: ScreenSegmentWriter?
    private let audio: AudioSourceWriters
    /// Read and written only on `queue`.
    private var report = CaptureStreamRouterReport()
    private var closed = false

    /// `syncClock` is the stream's synchronization clock; without one, every buffer is refused
    /// with that reason.
    init(clock: CaptureClock, syncClock: CMClock?, screen: ScreenSegmentWriter?, audio: AudioSourceWriters, queue: DispatchQueue) {
        retimer = syncClock.map { SessionRetimer(clock: clock, syncClock: $0) }
        self.screen = screen
        self.audio = audio
        self.queue = queue
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        receive(sampleBuffer, of: type)
    }

    /// Routes one buffer. Runs on `queue`.
    func receive(_ buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !closed else {
            report.afterClose += 1
            return
        }
        switch type {
        case .screen: routeScreen(buffer)
        case .audio: routeAudio(buffer, from: .systemAudio)
        case .microphone: routeAudio(buffer, from: .microphone)
        @unknown default: break
        }
    }

    /// Stops admission once every buffer already queued has been routed, and returns the report.
    /// A later call returns it again, with the callbacks refused since.
    func close() async -> CaptureStreamRouterReport {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                closed = true
                continuation.resume(returning: report)
            }
        }
    }

    private func routeScreen(_ buffer: CMSampleBuffer) {
        guard let screen else { return }
        let status: ScreenFrameStatus
        switch Self.frameStatus(of: buffer) {
        case .known(let known): status = known
        case .missing:
            report.screenUnknownStatuses["no frame status", default: 0] += 1
            return
        case .unsupported(let raw):
            report.screenUnknownStatuses["unsupported frame status \(raw)", default: 0] += 1
            return
        }
        guard status == .complete else {
            report.screenStatuses[status, default: 0] += 1
            return
        }
        guard let retimer else {
            report.screen.failed[missingClockReason, default: 0] += 1
            return
        }
        switch retimer.screenFrame(buffer) {
        case .success(let retimed?): screen.receive(retimed, status: .complete)
        case .success(nil): report.screen.excluded += 1
        case .failure(let failure): report.screen.failed[Self.describe(failure), default: 0] += 1
        }
    }

    private func routeAudio(_ buffer: CMSampleBuffer, from source: AudioCaptureSource) {
        guard let writer = audio.writer(for: source) else { return }
        let frames = CMSampleBufferGetNumSamples(buffer)
        guard let retimer else {
            report.audio[source, default: CaptureRouteCounts()].failed[missingClockReason, default: 0] += frames
            return
        }
        switch retimer.audio(buffer) {
        case .success(let retimed):
            report.audio[source, default: CaptureRouteCounts()].excluded += retimed.excludedFrames
            for piece in retimed.pieces { writer.append(piece) }
        case .failure(let failure):
            report.audio[source, default: CaptureRouteCounts()].failed[Self.describe(failure), default: 0] += frames
        }
    }

    enum FrameStatusReading: Equatable {
        case known(ScreenFrameStatus)
        case missing
        /// A raw value this build does not know.
        case unsupported(Int)
    }

    /// The `SCFrameStatus` ScreenCaptureKit attaches to a screen buffer.
    static func frameStatus(of buffer: CMSampleBuffer) -> FrameStatusReading {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int
        else { return .missing }
        switch SCFrameStatus(rawValue: raw) {
        case .complete: return .known(.complete)
        case .idle: return .known(.idle)
        case .blank: return .known(.blank)
        case .suspended: return .known(.suspended)
        case .started: return .known(.started)
        case .stopped: return .known(.stopped)
        default: return .unsupported(raw)
        }
    }

    private static func describe(_ failure: SampleRetimingFailure) -> String {
        switch failure {
        case .invalidTiming(let reason): "invalid timing: \(reason)"
        case .unsupportedFormat(let reason): "unsupported format: \(reason)"
        case .spansExcludedTime(let reason): "spans excluded time: \(reason)"
        case .copyFailed(let reason): "copy failed: \(reason)"
        }
    }
}
