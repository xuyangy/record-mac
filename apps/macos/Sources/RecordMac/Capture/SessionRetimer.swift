@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Why a buffer could not be put on the session clock. Distinct from a buffer left out on
/// purpose because it lies before the epoch or inside a pause.
enum SampleRetimingFailure: Error, Equatable, Sendable {
    /// Includes a timestamp the sync clock could not convert.
    case invalidTiming(String)
    case unsupportedFormat(String)
    /// A buffer that cannot be split lies partly in session time and partly outside it.
    case spansExcludedTime(String)
    case copyFailed(String)
}

/// What became of one audio buffer.
struct RetimedAudio {
    /// The parts in session time, in order, each with the source's own format and sample values.
    var pieces: [CMSampleBuffer]
    /// Sample frames left out because they lie before the epoch or inside a pause.
    var excludedFrames: Int
}

/// Puts stream buffers on the session clock (contracts/capture-engine.md guarantee 7).
///
/// A buffer's time is its own presentation timestamp, read on `syncClock`, the stream's
/// synchronization clock, and mapped through one `CaptureClock` snapshot per buffer. Arrival
/// time and the first frame are never used. Session timing replaces the buffer's timing; its
/// media data, format, and attachments are kept. Durations and decode timestamp offsets are
/// converted to session time like the presentation timestamp. A decode timestamp stays invalid
/// when it was invalid. A timestamp the sync clock cannot convert is a failure, never an
/// exclusion.
struct SessionRetimer {
    let clock: CaptureClock
    let syncClock: CMClockOrTimebase

    /// How far, in samples, the host time a run of PCM samples spans may differ from the samples'
    /// own duration. Beyond it the sync clock does not run at the sample rate, the samples would
    /// need resampling, and the buffer is refused.
    static let pcmDurationTolerance = 0.5

    /// A screen frame in session time, or nil when it lies before the epoch or inside a pause.
    func screenFrame(_ buffer: CMSampleBuffer) -> Result<CMSampleBuffer?, SampleRetimingFailure> {
        Result { () throws(SampleRetimingFailure) -> CMSampleBuffer? in
            let snapshot = clock.snapshot()
            var retimed: [CMSampleTimingInfo] = []
            for entry in try timingEntries(buffer) {
                guard entry.presentationTimeStamp.isNumeric else {
                    throw .invalidTiming("the presentation timestamp is not numeric")
                }
                guard let session = snapshot.sessionTime(forHostTime: try hostTime(entry.presentationTimeStamp)) else {
                    return nil
                }
                retimed.append(try retime(entry, at: session, convertingDuration: true))
            }
            return try copy(buffer, timing: retimed)
        }
    }

    /// The parts of an audio buffer in session time.
    ///
    /// Linear PCM with one frame per packet and a uniform duration of one sample is split at the
    /// epoch and at every pause start and end that falls inside it: a sample is kept when its
    /// own time has session time. Its samples keep their duration of one sample. Any other
    /// buffer is kept whole when all of it has session time without a break, left out whole when
    /// none of it has, and otherwise refused.
    func audio(_ buffer: CMSampleBuffer) -> Result<RetimedAudio, SampleRetimingFailure> {
        Result { () throws(SampleRetimingFailure) -> RetimedAudio in
            let snapshot = clock.snapshot()
            let frames = CMSampleBufferGetNumSamples(buffer)
            guard frames > 0 else { throw .invalidTiming("the buffer holds no samples") }
            guard let description = CMSampleBufferGetFormatDescription(buffer),
                  CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                  asbd.mSampleRate > 0
            else { throw .unsupportedFormat("the buffer has no audio format") }
            let start = CMSampleBufferGetPresentationTimeStamp(buffer)
            guard start.isNumeric else { throw .invalidTiming("the presentation timestamp is not numeric") }

            if let sample = splittableSampleDuration(buffer, asbd) {
                return try splitPCM(buffer, asbd: asbd, description: description, start: start, sample: sample,
                    frames: frames, snapshot: snapshot)
            }
            return try wholeBuffer(buffer, start: start, frames: frames, snapshot: snapshot)
        }
    }

    // MARK: - Linear PCM

    private func splittableSampleDuration(_ buffer: CMSampleBuffer, _ asbd: AudioStreamBasicDescription) -> CMTime? {
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFramesPerPacket == 1, asbd.mBytesPerFrame > 0,
              asbd.mSampleRate == asbd.mSampleRate.rounded(), asbd.mSampleRate <= Double(Int32.max),
              let entries = try? timingEntries(buffer), entries.count == 1
        else { return nil }
        let sample = CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate))
        return entries[0].duration == sample ? sample : nil
    }

    private func splitPCM(
        _ buffer: CMSampleBuffer, asbd: AudioStreamBasicDescription, description: CMFormatDescription,
        start: CMTime, sample: CMTime, frames: Int, snapshot: CaptureClockSnapshot
    ) throws(SampleRetimingFailure) -> RetimedAudio {
        _ = try hostTime(start)
        // Each span's boundaries, read on the sync clock, become sample indices: the first sample
        // at or after the boundary.
        var ranges: [(span: CaptureClockSnapshot.Span, first: Int, end: Int)] = []
        for span in snapshot.spans {
            let first = firstSample(atOrAfter: try syncTime(span.start), start: start, sample: sample, frames: frames)
            let end = try span.end.map { (end) throws(SampleRetimingFailure) in
                firstSample(atOrAfter: try syncTime(end), start: start, sample: sample, frames: frames)
            } ?? frames
            if end > first { ranges.append((span, first, end)) }
        }
        let kept = ranges.reduce(0) { $0 + $1.end - $1.first }
        var pieces: [CMSampleBuffer] = []
        for range in ranges {
            let count = range.end - range.first
            let firstTime = start + CMTimeMultiply(sample, multiplier: Int32(range.first))
            let firstHost = try hostTime(firstTime)
            let spanned = try hostTime(firstTime + CMTimeMultiply(sample, multiplier: Int32(count))) - firstHost
            guard abs(spanned.seconds - Double(count) * sample.seconds) <= Self.pcmDurationTolerance * sample.seconds else {
                throw .invalidTiming(
                    "\(count) samples span \(spanned.seconds) s on the session clock; the sync clock does not run at the sample rate")
            }
            guard let session = snapshot.sessionTime(forHostTime: max(firstHost, range.span.start)) else {
                throw .invalidTiming("a kept sample has no session time")
            }
            if count == frames {
                let entry = try timingEntries(buffer)[0]
                pieces.append(try copy(buffer, timing: [try retime(entry, at: session, convertingDuration: false)]))
            } else {
                let piece = try pcmPiece(buffer, asbd: asbd, description: description, first: range.first,
                    count: count, at: session)
                try copyAttachments(from: buffer, to: piece, first: range.first, count: count, frames: frames, sample: sample)
                pieces.append(piece)
            }
        }
        return RetimedAudio(pieces: pieces, excludedFrames: frames - kept)
    }

    /// The index of the first sample at or after `boundary`, clamped to the buffer.
    private func firstSample(atOrAfter boundary: CMTime, start: CMTime, sample: CMTime, frames: Int) -> Int {
        let offset = boundary - start
        guard offset > .zero else { return 0 }
        guard offset < CMTimeMultiply(sample, multiplier: Int32(clamping: frames)) else { return frames }
        // offset / sample, rounded up, exactly: offset.value / offset.timescale * sample.timescale.
        let (numerator, overflow) = offset.value.multipliedReportingOverflow(by: Int64(sample.timescale))
        guard !overflow else { return Int((offset.seconds / sample.seconds).rounded(.up)) }
        let denominator = Int64(offset.timescale) * sample.value
        let quotient = numerator / denominator
        return Int(numerator % denominator == 0 ? quotient : quotient + 1)
    }

    private func pcmPiece(
        _ buffer: CMSampleBuffer, asbd: AudioStreamBasicDescription, description: CMFormatDescription,
        first: Int, count: Int, at session: CMTime
    ) throws(SampleRetimingFailure) -> CMSampleBuffer {
        var listSize = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard status == noErr, listSize > 0 else { throw .copyFailed("audio buffer list size: \(status)") }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: listSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard status == noErr else { throw .copyFailed("audio buffer list: \(status)") }

        let source = UnsafeMutableAudioBufferListPointer(list)
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let pieceStorage = AudioBufferList.allocate(maximumBuffers: source.count)
        defer { free(pieceStorage.unsafeMutablePointer) }
        for (index, audioBuffer) in source.enumerated() {
            guard let data = audioBuffer.mData, Int(audioBuffer.mDataByteSize) >= (first + count) * bytesPerFrame else {
                throw .copyFailed("audio buffer \(index) is shorter than its samples")
            }
            pieceStorage[index] = AudioBuffer(
                mNumberChannels: audioBuffer.mNumberChannels, mDataByteSize: UInt32(count * bytesPerFrame),
                mData: data + first * bytesPerFrame)
        }

        var piece: CMSampleBuffer?
        status = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: description, sampleCount: count, presentationTimeStamp: session,
            packetDescriptions: nil, sampleBufferOut: &piece)
        guard status == noErr, let piece else { throw .copyFailed("audio piece: \(status)") }
        // Copies the samples, so the piece does not depend on the source buffer.
        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            piece, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
            bufferList: pieceStorage.unsafePointer)
        guard status == noErr else { throw .copyFailed("audio piece data: \(status)") }
        return piece
    }

    /// Gives a piece the buffer's attachments in both propagation modes, and the per-sample
    /// attachments of its own samples.
    ///
    /// The trims at the start and end mark samples to remove after decoding. Each is taken as a
    /// run of whole samples at its end of the buffer, and the piece gets the part of that run
    /// that falls inside it, measured from its own start or end, in the trim's original mode. A
    /// piece wholly inside the trimmed samples is trimmed to nothing. A trim that is not a whole
    /// number of samples is refused rather than moved.
    private func copyAttachments(
        from buffer: CMSampleBuffer, to piece: CMSampleBuffer, first: Int, count: Int, frames: Int, sample: CMTime
    ) throws(SampleRetimingFailure) {
        let trimKeys = [kCMSampleBufferAttachmentKey_TrimDurationAtStart, kCMSampleBufferAttachmentKey_TrimDurationAtEnd]
        for mode in [kCMAttachmentMode_ShouldPropagate, kCMAttachmentMode_ShouldNotPropagate] {
            guard let attachments = CMCopyDictionaryOfAttachments(allocator: nil, target: buffer, attachmentMode: mode)
            else { continue }
            let kept = NSMutableDictionary(dictionary: attachments as NSDictionary)
            kept.removeObjects(forKeys: trimKeys)
            CMSetAttachments(piece, attachments: kept as CFDictionary, attachmentMode: mode)
        }

        // Trimmed samples of the buffer: 0..<atStart and (frames - atEnd)..<frames.
        let atStart = try trimmedSamples(buffer, kCMSampleBufferAttachmentKey_TrimDurationAtStart, sample: sample, frames: frames)
        let atEnd = try trimmedSamples(buffer, kCMSampleBufferAttachmentKey_TrimDurationAtEnd, sample: sample, frames: frames)
        let pieceAtStart = atStart.map { min(max($0.samples - first, 0), count) }
        let pieceAtEnd = atEnd.map { min(max(first + count - (frames - $0.samples), 0), count - (pieceAtStart ?? 0)) }
        for (key, trim, original) in [
            (kCMSampleBufferAttachmentKey_TrimDurationAtStart, pieceAtStart, atStart?.mode),
            (kCMSampleBufferAttachmentKey_TrimDurationAtEnd, pieceAtEnd, atEnd?.mode),
        ] {
            guard let trim, let original, trim > 0 else { continue }
            let duration = CMTimeMultiply(sample, multiplier: Int32(trim))
            CMSetAttachment(piece, key: key, value: CMTimeCopyAsDictionary(duration, allocator: nil), attachmentMode: original)
        }

        guard let source = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false),
              CFArrayGetCount(source) > 0
        else { return }
        guard let target = CMSampleBufferGetSampleAttachmentsArray(piece, createIfNecessary: true) else {
            throw .copyFailed("the piece has no per-sample attachments")
        }
        let sourceCount = CFArrayGetCount(source)
        let targetCount = CFArrayGetCount(target)
        let offset: Int
        switch (sourceCount, targetCount) {
        case (frames, count): offset = first
        case (1, 1): offset = 0
        default: throw .copyFailed("\(sourceCount) per-sample attachments do not match \(frames) samples")
        }
        for index in 0..<targetCount {
            let from = unsafeBitCast(CFArrayGetValueAtIndex(source, offset + index), to: NSDictionary.self)
            let to = unsafeBitCast(CFArrayGetValueAtIndex(target, index), to: NSMutableDictionary.self)
            to.addEntries(from: from as? [AnyHashable: Any] ?? [:])
        }
    }

    /// A trim attachment as a whole number of samples, at most the buffer's, with its mode; nil
    /// when the buffer has none.
    private func trimmedSamples(
        _ buffer: CMSampleBuffer, _ key: CFString, sample: CMTime, frames: Int
    ) throws(SampleRetimingFailure) -> (samples: Int, mode: CMAttachmentMode)? {
        var mode: CMAttachmentMode = 0
        guard let value = CMGetAttachment(buffer, key: key, attachmentModeOut: &mode) else { return nil }
        let trim = (value as? NSDictionary).map { CMTimeMakeFromDictionary($0 as CFDictionary) } ?? .invalid
        guard trim.isNumeric, trim >= .zero else { throw .invalidTiming("\(key) is not a duration") }
        // trim / sample = trim.value * sample.timescale / (trim.timescale * sample.value), whole.
        let (numerator, overflow) = trim.value.multipliedReportingOverflow(by: Int64(sample.timescale))
        let denominator = Int64(trim.timescale) * sample.value
        guard !overflow, numerator % denominator == 0 else {
            throw .unsupportedFormat("\(key) of \(trim.seconds) s is not a whole number of samples")
        }
        return (min(Int(numerator / denominator), frames), mode)
    }

    // MARK: - Whole buffers

    private func wholeBuffer(
        _ buffer: CMSampleBuffer, start: CMTime, frames: Int, snapshot: CaptureClockSnapshot
    ) throws(SampleRetimingFailure) -> RetimedAudio {
        let duration = CMSampleBufferGetDuration(buffer)
        guard duration.isNumeric, duration > .zero else {
            throw .invalidTiming("the buffer has no duration, so its extent is unknown")
        }
        let first = try hostTime(start)
        let end = try hostTime(start + duration)
        let overlapping = snapshot.spans.filter { $0.start < end && ($0.end.map { $0 > first } ?? true) }
        if overlapping.isEmpty { return RetimedAudio(pieces: [], excludedFrames: frames) }
        guard overlapping.count == 1, overlapping[0].start <= first, overlapping[0].end.map({ end <= $0 }) ?? true else {
            throw .spansExcludedTime("a buffer that cannot be split lies partly before the epoch or inside a pause")
        }
        var retimed: [CMSampleTimingInfo] = []
        for entry in try timingEntries(buffer) {
            let pts = entry.presentationTimeStamp.isNumeric ? entry.presentationTimeStamp : start
            guard let session = snapshot.sessionTime(forHostTime: max(try hostTime(pts), overlapping[0].start)) else {
                throw .invalidTiming("a kept sample has no session time")
            }
            retimed.append(try retime(entry, at: session, convertingDuration: true))
        }
        return RetimedAudio(pieces: [try copy(buffer, timing: retimed)], excludedFrames: 0)
    }

    // MARK: - Timing

    private func hostTime(_ time: CMTime) throws(SampleRetimingFailure) -> CMTime {
        try convert(time, from: syncClock, to: CaptureClock.hostClock)
    }

    private func syncTime(_ hostTime: CMTime) throws(SampleRetimingFailure) -> CMTime {
        try convert(hostTime, from: CaptureClock.hostClock, to: syncClock)
    }

    private func convert(
        _ time: CMTime, from source: CMClockOrTimebase, to target: CMClockOrTimebase
    ) throws(SampleRetimingFailure) -> CMTime {
        let rate = CMSyncGetRelativeRate(source, relativeTo: target)
        guard rate.isFinite, rate > 0 else {
            throw .invalidTiming("the sync clock runs at \(rate) times the host clock, so its times cannot be converted")
        }
        let converted = CMSyncConvertTime(time, from: source, to: target)
        guard converted.isNumeric else { throw .invalidTiming("the sync clock could not convert \(time.seconds) s") }
        return converted
    }

    private func timingEntries(_ buffer: CMSampleBuffer) throws(SampleRetimingFailure) -> [CMSampleTimingInfo] {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0
        else { throw .invalidTiming("the buffer has no timing") }
        var entries = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &entries, entriesNeededOut: nil) == noErr else {
            throw .invalidTiming("the buffer's timing could not be read")
        }
        return entries
    }

    /// The entry at `session`. With `convertingDuration`, a numeric duration becomes the host
    /// time it spans; PCM samples keep theirs. A valid decode timestamp keeps its offset from the
    /// presentation timestamp, converted to host time.
    private func retime(
        _ entry: CMSampleTimingInfo, at session: CMTime, convertingDuration: Bool
    ) throws(SampleRetimingFailure) -> CMSampleTimingInfo {
        let pts = entry.presentationTimeStamp
        var duration = entry.duration
        if convertingDuration, duration.isNumeric {
            duration = try hostTime(pts + duration) - hostTime(pts)
        }
        var decode = CMTime.invalid
        if entry.decodeTimeStamp.isNumeric {
            decode = session + (try hostTime(entry.decodeTimeStamp) - hostTime(pts))
        }
        return CMSampleTimingInfo(duration: duration, presentationTimeStamp: session, decodeTimeStamp: decode)
    }

    private func copy(_ buffer: CMSampleBuffer, timing: [CMSampleTimingInfo]) throws(SampleRetimingFailure) -> CMSampleBuffer {
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: timing.count, sampleTimingArray: timing,
            sampleBufferOut: &out)
        guard status == noErr, let out else { throw .copyFailed("retimed copy: \(status)") }
        return out
    }
}
