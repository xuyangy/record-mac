@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// A screen frame's ScreenCaptureKit status (`SCFrameStatus`).
enum ScreenFrameStatus: Equatable, Sendable {
    case complete
    case idle
    case blank
    case suspended
    case started
    case stopped
}

/// The frame count of a finalised file, or why it could not be counted.
enum WrittenFrameCount: Equatable, Sendable {
    case decoded(Int)
    /// No frame reached the writer, so the file holds none; it is not decoded.
    case noFramesAppended
    case unavailable(String)

    var count: Int? {
        switch self {
        case .decoded(let count): count
        case .noFramesAppended: 0
        case .unavailable: nil
        }
    }
}

/// One screen segment's frame counts (research.md R-011).
struct ScreenSegmentFrames: Equatable, Sendable {
    /// Frames delivered with status `complete`.
    var delivered = 0
    /// Complete frames the writer input refused, or shed because it was not ready.
    var appendRejected = 0
    /// Complete frames the writer input accepted.
    var accepted = 0
    /// Why the writer failed, if it did.
    var writerFailure: String?
    /// Frames in the finalised file, counted by decoding it; nil until finished.
    var written: WrittenFrameCount?

    /// Accepted frames missing from the file because the writer failed, when the file could be
    /// counted.
    var writerFailed: Int? {
        guard writerFailure != nil, let written = written?.count else { return nil }
        return max(accepted - written, 0)
    }

    /// Accepted frames missing from a file whose writer did not fail; this has no known cause and
    /// is reported as found.
    var unexplainedLoss: Int? {
        guard writerFailure == nil, let written = written?.count, written != accepted else { return nil }
        return accepted - written
    }
}

extension FrameReport {
    /// The report across a recording's screen segments, or nil when any segment's file could
    /// not be counted: a count is never made up.
    init?(segments: [ScreenSegmentFrames]) {
        var report = FrameReport.empty
        for segment in segments {
            guard let written = segment.written?.count else { return nil }
            report.delivered += segment.delivered
            report.appendRejected += segment.appendRejected
            report.writerFailed += segment.writerFailed ?? 0
            report.written += written
        }
        self = report
    }
}

/// Where a screen segment's frames go, so the counting can be tested against refusals and
/// failures the real writer rarely produces.
protocol ScreenSampleWriting: AnyObject {
    /// Whether the input takes another frame now; a frame offered when it does not is shed.
    var isReadyForMoreMediaData: Bool { get }
    func append(_ sampleBuffer: CMSampleBuffer) -> Bool
    /// Ends the session at `endTime`, so the last frame is held until then, and finalises the
    /// file. Returns why it failed, or nil.
    func finish(endingAt endTime: CMTime) async -> String?
    /// Counts the frames in the finalised file by decoding it.
    func decodedFrameCount() async -> WrittenFrameCount
}

/// Writes one screen segment's frames and counts them (FR-074, research.md R-011).
///
/// Only `complete` frames are written, each at its own presentation time. Any other status
/// writes nothing. Each frame is kept back until the next complete frame arrives, then written
/// with a duration reaching it; the last is written at `finish` with a duration reaching the
/// segment's end. An unchanged stretch, the final hold, and a recording with no change after its
/// first frame are therefore held by one frame's duration, never by a duplicated frame. Before
/// the first complete frame nothing is held, since there is no image yet. At most one frame is
/// kept back.
final class ScreenFrameCounter: @unchecked Sendable {
    private let writer: ScreenSampleWriting
    private let lock = NSLock()
    private var frames = ScreenSegmentFrames()
    private var pending: CMSampleBuffer?
    private var finished = false
    private var finishing: Task<ScreenSegmentFrames, Never>?

    init(writer: ScreenSampleWriting) {
        self.writer = writer
    }

    var counts: ScreenSegmentFrames {
        lock.withLock { frames }
    }

    /// Takes one delivered frame; frames delivered after `finish` began are ignored.
    func receive(_ sampleBuffer: CMSampleBuffer, status: ScreenFrameStatus) {
        lock.withLock {
            guard !finished, status == .complete else { return }
            frames.delivered += 1
            if let pending { write(pending, until: sampleBuffer.presentationTimeStamp) }
            pending = sampleBuffer
        }
    }

    /// Ends the segment at `endTime`, the segment's end on the session clock, then counts the
    /// finalised file. The first call does this once; every call, including one made while it is
    /// under way, returns its result.
    func finish(endingAt endTime: CMTime) async -> ScreenSegmentFrames {
        let task = lock.withLock { () -> Task<ScreenSegmentFrames, Never> in
            if let finishing { return finishing }
            finished = true
            if let pending { write(pending, until: endTime) }
            pending = nil
            let task = Task { [self] in
                let failure = await writer.finish(endingAt: endTime)
                let written = counts.accepted == 0 ? .noFramesAppended : await writer.decodedFrameCount()
                return lock.withLock {
                    frames.writerFailure = failure
                    frames.written = written
                    return frames
                }
            }
            finishing = task
            return task
        }
        return await task.value
    }
}

extension ScreenFrameCounter {
    /// Writes `sampleBuffer` lasting until `end`, counting it accepted or rejected. Called with
    /// the lock held.
    fileprivate func write(_ sampleBuffer: CMSampleBuffer, until end: CMTime) {
        let start = sampleBuffer.presentationTimeStamp
        var timing = CMSampleTimingInfo(
            duration: end > start ? end - start : .invalid, presentationTimeStamp: start, decodeTimeStamp: .invalid)
        var timed: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: sampleBuffer, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleBufferOut: &timed)
        guard status == noErr, let timed, writer.isReadyForMoreMediaData, writer.append(timed) else {
            frames.appendRejected += 1
            return
        }
        frames.accepted += 1
    }
}

/// An `AVAssetWriter` writing one screen segment to a movie file.
final class AssetScreenSampleWriter: ScreenSampleWriting, @unchecked Sendable {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput

    init(url: URL, fileType: AVFileType = .mov, outputSettings: [String: Any], startTime: CMTime) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw writer.error ?? CocoaError(.featureUnsupported)
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: startTime)
    }

    var isReadyForMoreMediaData: Bool { input.isReadyForMoreMediaData }

    func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
        input.append(sampleBuffer)
    }

    func finish(endingAt endTime: CMTime) async -> String? {
        guard writer.status == .writing else {
            return "writer \(writer.status.rawValue): \(String(describing: writer.error))"
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: endTime)
        await writer.finishWriting()
        guard writer.status == .completed else {
            return "writer \(writer.status.rawValue): \(String(describing: writer.error))"
        }
        return nil
    }

    func decodedFrameCount() async -> WrittenFrameCount {
        do {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                return .unavailable("no video track in \(url.lastPathComponent)")
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output)
            guard reader.startReading() else {
                return .unavailable("reading failed: \(String(describing: reader.error))")
            }
            var count = 0
            while let sample = output.copyNextSampleBuffer() {
                if CMSampleBufferGetImageBuffer(sample) != nil { count += 1 }
            }
            guard reader.status == .completed else {
                return .unavailable("reading ended \(reader.status.rawValue): \(String(describing: reader.error))")
            }
            return .decoded(count)
        } catch {
            return .unavailable("\(error)")
        }
    }
}
