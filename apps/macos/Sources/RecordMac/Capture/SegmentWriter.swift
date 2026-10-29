import CoreMedia
import CoreVideo
import Foundation

/// A screen frame's native format, read from its own image buffer.
struct ScreenFrameFormat: Hashable, Sendable {
    var width: Int
    var height: Int
    var pixelFormat: OSType

    init(width: Int, height: Int, pixelFormat: OSType) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
    }

    init?(_ sampleBuffer: CMSampleBuffer) {
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        self.init(
            width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image),
            pixelFormat: CVPixelBufferGetPixelFormatType(image))
    }
}

/// A file opened for one screen segment.
struct ScreenSegmentFile {
    var writer: ScreenSampleWriting
    /// Path relative to the project directory.
    var fileRef: String
    var hasAlpha: Bool
}

/// Opens a writer for a segment at its native format, never a scaled one. `start` is the
/// segment's start on the session clock.
protocol ScreenSegmentFileFactory: AnyObject {
    func makeFile(index: Int, format: ScreenFrameFormat, start: CMTime) throws -> ScreenSegmentFile
}

/// One finished screen segment: its project entry when a file was written, and its counts.
struct ScreenSegmentOutcome: Equatable, Sendable {
    var format: ScreenFrameFormat
    /// Session time of the segment's first complete frame.
    var start: CMTime
    /// Session time the segment ended: the next format's first frame, a source-unavailable
    /// boundary, or the end of the recording.
    var end: CMTime
    /// Nil when no file could be opened for the format.
    var segment: MediaSegment?
    var frames: ScreenSegmentFrames
}

/// Every screen segment of a recording, in order, and the complete frames no segment could take.
struct ScreenTrackOutcome: Equatable, Sendable {
    var segments: [ScreenSegmentOutcome]
    /// Complete frames without an image that arrived while no segment was open: delivered and
    /// rejected, with no format or file.
    var unassigned: ScreenSegmentFrames

    /// Every count, for `FrameReport(segments:)`.
    var frames: [ScreenSegmentFrames] {
        segments.map(\.frames) + (unassigned.delivered > 0 ? [unassigned] : [])
    }
}

/// Splits the screen track into native segments (contracts/capture-engine.md guarantee 9,
/// T035 part 1).
///
/// Frames arrive in order, stamped on the session clock, with their `SCFrameStatus`. A complete
/// frame whose native size or pixel format differs from the current segment's ends that segment
/// at the frame's time and starts a new one there, in a new file at the new format; frames are
/// never rescaled. `sourceUnavailable(at:)` ends the current segment at that time; the next
/// complete frame starts a new segment at its own time, so the span between is a gap, and the
/// old frame is never held across it. Idle frames are unchanged content, never a gap, and a long
/// interval between frames alone is not treated as one.
///
/// A segment that ends is finalised in the background while frames go on to the next; `finish`
/// waits for every segment in order. At most `maxOpenFiles` files are open at once, counting the
/// ones still finalising. When a new format would exceed that, its segment opens no file and
/// its complete frames are counted as delivered and rejected, with the reason; the first
/// complete frame after a file has finished finalising ends that segment and opens a file from
/// that frame on. The same counting, with the reason, applies when no file can be opened for a
/// format. A complete frame without an image is counted as delivered and rejected in the open
/// segment, or as unassigned when none is open.
///
/// Each segment's file has its own timeline, starting at zero at the segment's start; its
/// `MediaSegment.start` places it on the session clock. Each outcome's start is also a geometry
/// boundary; producing the `GeometrySegment`s is the
/// engine's work. `frameRate` is the rate the capture stream delivers at, supplied by its
/// backend; it is not measured here.
final class ScreenSegmentWriter: @unchecked Sendable {
    private struct Current {
        var index: Int
        var format: ScreenFrameFormat
        var start: CMTime
        var file: ScreenSegmentFile?
        var counter: ScreenFrameCounter?
        var failure: ScreenSegmentFrames
        /// Opened no file because too many were open.
        var saturated = false
    }

    let maxOpenFiles: Int

    private let factory: ScreenSegmentFileFactory
    private let deviceID: String
    private let frameRate: Double
    private let lock = NSLock()
    private var current: Current?
    private var nextIndex = 0
    private var finalizing = 0
    private var unassigned = ScreenSegmentFrames(written: .noFramesAppended)
    private var ended: [Task<ScreenSegmentOutcome, Never>] = []
    private var finished = false

    init(factory: ScreenSegmentFileFactory, deviceID: String, frameRate: Double, maxOpenFiles: Int = 3) {
        self.factory = factory
        self.deviceID = deviceID
        self.frameRate = frameRate
        self.maxOpenFiles = max(maxOpenFiles, 1)
    }

    /// Takes one frame stamped on the session clock; frames after `finish` began are ignored.
    func receive(_ sampleBuffer: CMSampleBuffer, status: ScreenFrameStatus) {
        lock.withLock {
            guard !finished, status == .complete else { return }
            guard let format = ScreenFrameFormat(sampleBuffer) else {
                if current == nil {
                    unassigned.delivered += 1
                    unassigned.appendRejected += 1
                } else {
                    current?.failure.delivered += 1
                    current?.failure.appendRejected += 1
                }
                return
            }
            let time = sampleBuffer.presentationTimeStamp
            if let open = current, open.format != format || (open.saturated && finalizing < maxOpenFiles) {
                endCurrent(at: time)
            }
            if current == nil { open(format, at: time) }
            if let counter = current?.counter {
                counter.receive(sampleBuffer, status: .complete)
            } else {
                current?.failure.delivered += 1
                current?.failure.appendRejected += 1
            }
        }
    }

    /// Ends the current segment at `time`, when the source stops delivering, for example while
    /// it is reconfigured or after it disappears.
    func sourceUnavailable(at time: CMTime) {
        lock.withLock {
            guard !finished else { return }
            endCurrent(at: time)
        }
    }

    /// Ends the recording at `time` and returns every segment in order once each is finalised.
    func finish(at time: CMTime) async -> ScreenTrackOutcome {
        let tasks = lock.withLock { () -> [Task<ScreenSegmentOutcome, Never>] in
            if !finished {
                finished = true
                endCurrent(at: time)
            }
            return ended
        }
        var outcomes: [ScreenSegmentOutcome] = []
        for task in tasks { outcomes.append(await task.value) }
        return ScreenTrackOutcome(segments: outcomes, unassigned: lock.withLock { unassigned })
    }

    /// Files open now, counting those still finalising.
    var openFiles: Int {
        lock.withLock { finalizing + (current?.file == nil ? 0 : 1) }
    }

    /// Called with the lock held.
    private func open(_ format: ScreenFrameFormat, at time: CMTime) {
        let index = nextIndex
        nextIndex += 1
        var segment = Current(index: index, format: format, start: time, failure: ScreenSegmentFrames())
        guard finalizing < maxOpenFiles else {
            segment.saturated = true
            segment.failure.writerFailure = "\(maxOpenFiles) segment files were still open; no file for \(format.width)x\(format.height) \(fourCC(format.pixelFormat)) from \(time.seconds) s"
            segment.failure.written = .noFramesAppended
            current = segment
            return
        }
        do {
            let file = try factory.makeFile(index: index, format: format, start: time)
            segment.file = file
            segment.counter = ScreenFrameCounter(writer: file.writer)
        } catch {
            segment.failure.writerFailure = "could not open a writer for \(format.width)x\(format.height) \(fourCC(format.pixelFormat)): \(error)"
            segment.failure.written = .noFramesAppended
        }
        current = segment
    }

    /// Called with the lock held.
    private func endCurrent(at time: CMTime) {
        guard let segment = current else { return }
        current = nil
        let deviceID = deviceID
        let frameRate = frameRate
        let end = max(time, segment.start)
        guard let counter = segment.counter, let file = segment.file else {
            let outcome = ScreenSegmentOutcome(
                format: segment.format, start: segment.start, end: end, segment: nil, frames: segment.failure)
            ended.append(Task { outcome })
            return
        }
        finalizing += 1
        ended.append(Task { [self] in
            var frames = await counter.finish(endingAt: end)
            lock.withLock { finalizing -= 1 }
            frames.delivered += segment.failure.delivered
            frames.appendRejected += segment.failure.appendRejected
            return ScreenSegmentOutcome(
                format: segment.format, start: segment.start, end: end,
                segment: MediaSegment(
                    fileRef: file.fileRef, start: segment.start.seconds, end: end.seconds, deviceID: deviceID,
                    nativeSize: PixelSize(width: segment.format.width, height: segment.format.height),
                    frameRate: frameRate, hasAlpha: file.hasAlpha),
                frames: frames)
        })
    }
}

extension MediaTrack {
    /// The screen track for a recording's segment outcomes; failed segments have no entry.
    init(screenSegments outcomes: [ScreenSegmentOutcome], requestedFrameRate: Int) {
        self.init(
            kind: .screen, segments: outcomes.compactMap(\.segment),
            requestedFrameRate: requestedFrameRate, endedEarlyAt: nil)
    }
}

private func fourCC(_ code: OSType) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
    return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
}
