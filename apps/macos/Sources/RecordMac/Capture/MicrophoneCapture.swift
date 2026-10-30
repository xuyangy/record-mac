@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// The audio sources a recording keeps apart (FR-015, FR-017).
enum AudioCaptureSource: String, CaseIterable, Sendable {
    case microphone
    case systemAudio
}

/// What an audio track writer did with its buffers, in sample frames.
struct AudioTrackCounts: Equatable, Sendable {
    var receivedFrames = 0
    var appendedFrames = 0
    /// Frames dropped because more than the pending limit was waiting for the writer.
    var droppedOverflowFrames = 0
    /// Frames in a format other than the track's first, refused: a format change needs a new
    /// segment (T061).
    var rejectedFormatFrames = 0
    /// Frames the writer input refused.
    var rejectedAppendFrames = 0
    var writerFailure: String?
    /// Frames in the finalised file, read back; nil until finished.
    var written: WrittenFrameCount?
}

/// Where an audio track's buffers go: an `AVAssetWriter` input in production, a scripted one in
/// tests of backpressure and failure.
protocol AudioSampleSink: AnyObject {
    var isReadyForMoreMediaData: Bool { get }
    /// Why the writer can take nothing more, once it has failed or been cancelled.
    var terminalFailure: String? { get }
    func append(_ buffer: CMSampleBuffer) -> Bool
    /// Finalises the file; returns why it failed, or nil.
    func finish() async -> String?
    func cancel()
    func readBackFrames() async -> WrittenFrameCount
}

/// Writes one audio source to its own file in the source's own format: linear PCM keeps its
/// rate, channel count and order, bit depth, and sample type, so every sample value is kept, and
/// nothing is mixed (FR-017, Principle I).
///
/// Buffers arrive stamped on the session clock. The file's timeline starts at zero at `start`,
/// the segment's start on the session clock, so the first buffer sits at its offset from it.
/// The first buffer's format is the track's; a buffer in any other format is refused and counted.
///
/// At most `pendingLimit` seconds of audio are held at once, counted when `append` is called and
/// covering buffers both queued and waiting for the writer; beyond that the newest buffer is
/// dropped and counted at once. Waiting buffers are retried every few milliseconds until the
/// writer takes them, without needing another buffer. A writer that fails or is cancelled stops
/// the track: every waiting buffer is counted as rejected. `finish` drains every waiting buffer,
/// finalises once, and gives every caller the same result. A track that received no audio
/// writes no file.
final class AudioTrackWriter: @unchecked Sendable {
    let source: AudioCaptureSource
    let url: URL
    let start: CMTime
    let pendingLimit: Double

    private let makeSink: (CMFormatDescription, AudioStreamBasicDescription) throws -> AudioSampleSink
    private let queue: DispatchQueue
    /// Guards admission: frames held, frames dropped on admission, and whether admission has
    /// closed. A buffer is admitted and queued under it, so closing it orders every admitted
    /// buffer ahead of the close on the queue.
    private let admission = NSLock()
    private var heldFrames = 0
    private var droppedAtAdmission = 0
    private var admissionClosed = false
    private var sink: AudioSampleSink?
    private var format: AudioStreamBasicDescription?
    private var pending: [CMSampleBuffer] = []
    private var retryScheduled = false
    private var counts = AudioTrackCounts()
    private var finishing: Task<AudioTrackCounts, Never>?
    private let finishLock = NSLock()

    init(
        source: AudioCaptureSource, url: URL, start: CMTime, pendingLimit: Double = 2,
        makeSink: ((CMFormatDescription, AudioStreamBasicDescription) throws -> AudioSampleSink)? = nil
    ) {
        self.source = source
        self.url = url
        self.start = start
        self.pendingLimit = pendingLimit
        self.makeSink = makeSink ?? { description, asbd in
            try AssetAudioSampleSink(url: url, start: start, description: description, asbd: asbd)
        }
        queue = DispatchQueue(label: "local.recordmac.audio-track.\(source.rawValue)")
    }

    /// The writer input this track writes through, once its first buffer has arrived.
    var writerInput: AVAssetWriterInput? {
        queue.sync { (sink as? AssetAudioSampleSink)?.input }
    }

    var currentCounts: AudioTrackCounts {
        queue.sync { merged() }
    }

    /// Admits a buffer if the audio already held leaves room for it, otherwise counts it dropped.
    /// A buffer with no audio format or no frames is ignored here; after `finish` began, every
    /// buffer is.
    func append(_ buffer: CMSampleBuffer) {
        let frames = CMSampleBufferGetNumSamples(buffer)
        guard frames > 0, let description = CMSampleBufferGetFormatDescription(buffer),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
            asbd.mSampleRate > 0
        else { return }
        admission.withLock {
            guard !admissionClosed else { return }
            guard Double(heldFrames + frames) <= pendingLimit * asbd.mSampleRate else {
                droppedAtAdmission += frames
                return
            }
            heldFrames += frames
            queue.async { [self] in receive(buffer) }
        }
    }

    /// Drains every waiting buffer, finalises the file, and reads it back. Runs once.
    func finish() async -> AudioTrackCounts {
        let task = finishLock.withLock { () -> Task<AudioTrackCounts, Never> in
            if let finishing { return finishing }
            let task = Task { await finalise() }
            finishing = task
            return task
        }
        return await task.value
    }

    // MARK: On the queue

    private func release(_ frames: Int) {
        admission.withLock { heldFrames -= frames }
    }

    /// Counts and the drops made on admission, which stop changing once admission has closed.
    private func merged() -> AudioTrackCounts {
        var result = counts
        let dropped = admission.withLock { droppedAtAdmission }
        result.receivedFrames += dropped
        result.droppedOverflowFrames += dropped
        return result
    }

    private func receive(_ buffer: CMSampleBuffer) {
        let frames = CMSampleBufferGetNumSamples(buffer)
        guard buffer.isValid, CMSampleBufferDataIsReady(buffer), frames > 0,
            buffer.presentationTimeStamp.isNumeric,
            let description = CMSampleBufferGetFormatDescription(buffer),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
            asbd.mSampleRate > 0
        else {
            release(frames)
            return
        }
        counts.receivedFrames += frames
        if let format {
            guard Self.sameFormat(format, asbd) else {
                counts.rejectedFormatFrames += frames
                release(frames)
                return
            }
        } else {
            format = asbd
            do {
                sink = try makeSink(description, asbd)
            } catch {
                counts.writerFailure = "\(error)"
            }
        }
        guard counts.writerFailure == nil, sink != nil else {
            counts.rejectedAppendFrames += frames
            release(frames)
            return
        }
        pending.append(buffer)
        drain()
    }

    private func drain() {
        guard let sink else { return }
        while let buffer = pending.first {
            if let failure = sink.terminalFailure {
                stop(with: failure)
                return
            }
            guard sink.isReadyForMoreMediaData else { break }
            pending.removeFirst()
            let frames = CMSampleBufferGetNumSamples(buffer)
            release(frames)
            if sink.append(buffer) {
                counts.appendedFrames += frames
            } else {
                counts.rejectedAppendFrames += frames
            }
        }
        if let failure = sink.terminalFailure, !pending.isEmpty {
            stop(with: failure)
        } else if !pending.isEmpty, !retryScheduled {
            retryScheduled = true
            queue.asyncAfter(deadline: .now() + .milliseconds(5)) { [self] in
                retryScheduled = false
                drain()
            }
        }
    }

    /// Counts every waiting buffer as rejected because the writer can take nothing more.
    private func stop(with failure: String) {
        if counts.writerFailure == nil { counts.writerFailure = failure }
        for buffer in pending {
            let frames = CMSampleBufferGetNumSamples(buffer)
            counts.rejectedAppendFrames += frames
            release(frames)
        }
        pending.removeAll()
    }

    private func finalise() async -> AudioTrackCounts {
        // Every buffer admitted before admission closes is already on the queue ahead of this.
        admission.withLock { admissionClosed = true }
        while queue.sync(execute: { drain(); return !pending.isEmpty }) {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let (sink, appended) = queue.sync { (self.sink, counts.appendedFrames) }
        var failure: String?
        var written = WrittenFrameCount.noFramesAppended
        if let sink, appended > 0 {
            failure = await sink.finish()
            written = await sink.readBackFrames()
        } else {
            sink?.cancel()
        }
        return queue.sync {
            if let failure, counts.writerFailure == nil { counts.writerFailure = failure }
            counts.written = written
            return merged()
        }
    }

    /// Linear PCM at the source's rate, channel count, bit depth, and sample type, interleaved as
    /// QuickTime stores it, so every sample value is kept. Interleaved signed 24-bit samples in
    /// 32-bit slots are passed through untouched instead: a float conversion truncates them.
    /// The writer cannot pass the same samples through with each channel in its own buffer
    /// (-12780), so those go through these settings, which interleave them as 24-bit integers.
    static func outputSettings(for asbd: AudioStreamBasicDescription) -> [String: Any]? {
        let aligned24In32 = asbd.mBitsPerChannel == 24 && asbd.mBytesPerFrame == asbd.mChannelsPerFrame * 4
            && asbd.mFormatFlags & kAudioFormatFlagIsPacked == 0
        if aligned24In32 || asbd.mFormatID != kAudioFormatLinearPCM { return nil }
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: asbd.mSampleRate,
            AVNumberOfChannelsKey: Int(asbd.mChannelsPerFrame),
            AVLinearPCMBitDepthKey: Int(asbd.mBitsPerChannel),
            AVLinearPCMIsFloatKey: asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            AVLinearPCMIsBigEndianKey: asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    private static func sameFormat(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags
            && a.mBytesPerPacket == b.mBytesPerPacket && a.mFramesPerPacket == b.mFramesPerPacket
            && a.mBytesPerFrame == b.mBytesPerFrame && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBitsPerChannel == b.mBitsPerChannel
    }
}

/// An `AVAssetWriter` with one audio input, writing a QuickTime file.
final class AssetAudioSampleSink: AudioSampleSink {
    let url: URL
    let writer: AVAssetWriter
    let input: AVAssetWriterInput

    init(url: URL, start: CMTime, description: CMFormatDescription, asbd: AudioStreamBasicDescription) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(
            mediaType: .audio, outputSettings: AudioTrackWriter.outputSettings(for: asbd), sourceFormatHint: description)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "cannot add an audio input for this format"])
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: start)
    }

    var isReadyForMoreMediaData: Bool { input.isReadyForMoreMediaData }

    var terminalFailure: String? {
        switch writer.status {
        case .failed, .cancelled: "writer \(writer.status.rawValue): \(String(describing: writer.error))"
        default: nil
        }
    }

    func append(_ buffer: CMSampleBuffer) -> Bool { input.append(buffer) }

    func finish() async -> String? {
        if writer.status == .writing {
            input.markAsFinished()
            await writer.finishWriting()
        }
        return writer.status == .completed ? nil : "writer \(writer.status.rawValue): \(String(describing: writer.error))"
    }

    func cancel() { writer.cancelWriting() }

    func readBackFrames() async -> WrittenFrameCount {
        do {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                return .unavailable("no audio track in \(url.lastPathComponent)")
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            guard reader.startReading() else {
                return .unavailable("reading failed: \(String(describing: reader.error))")
            }
            var frames = 0
            while let sample = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(sample) }
            guard reader.status == .completed else {
                return .unavailable("reading ended \(reader.status.rawValue): \(String(describing: reader.error))")
            }
            return .decoded(frames)
        } catch {
            return .unavailable("\(error)")
        }
    }
}

/// Routes each source's buffers to that source's own writer and input. There is no path that
/// combines two sources (FR-017).
final class AudioSourceWriters: @unchecked Sendable {
    private let writers: [AudioCaptureSource: AudioTrackWriter]

    /// `makeURL` gives each source its own file.
    init(sources: Set<AudioCaptureSource>, start: CMTime, makeURL: (AudioCaptureSource) -> URL) {
        var writers: [AudioCaptureSource: AudioTrackWriter] = [:]
        for source in sources {
            writers[source] = AudioTrackWriter(source: source, url: makeURL(source), start: start)
        }
        self.writers = writers
    }

    func writer(for source: AudioCaptureSource) -> AudioTrackWriter? {
        writers[source]
    }

    /// Buffers from a source that is not being recorded are ignored.
    func append(_ buffer: CMSampleBuffer, from source: AudioCaptureSource) {
        writers[source]?.append(buffer)
    }

    func finish() async -> [AudioCaptureSource: AudioTrackCounts] {
        var results: [AudioCaptureSource: AudioTrackCounts] = [:]
        for (source, writer) in writers { results[source] = await writer.finish() }
        return results
    }
}
