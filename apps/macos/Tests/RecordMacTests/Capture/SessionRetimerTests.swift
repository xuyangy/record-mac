@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import RecordMac

/// Session retiming of synthetic buffers, read on a deterministic sync clock: no device, no
/// stream.
final class SessionRetimerTests: XCTestCase {
    private let rate = 48_000.0

    private func host(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1_000_000_000) }
    private func ms(_ value: Int64) -> CMTime { CMTime(value: value, timescale: 1000) }

    /// A timebase reading `syncAtAnchor` at host time `hostAtAnchor`, running `speed` times as
    /// fast as the host clock.
    private func syncClock(syncAtAnchor: CMTime, hostAtAnchor: CMTime, speed: Double = 1) throws -> CMTimebase {
        var timebase: CMTimebase?
        XCTAssertEqual(CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: CaptureClock.hostClock, timebaseOut: &timebase), noErr)
        let created = try XCTUnwrap(timebase)
        XCTAssertEqual(CMTimebaseSetRateAndAnchorTime(created, rate: speed, anchorTime: syncAtAnchor, immediateSourceTime: hostAtAnchor), noErr)
        return created
    }

    /// The sync clock reads 900 s ahead of the host clock.
    private func offsetClock() throws -> CMTimebase {
        try syncClock(syncAtAnchor: CMTime(value: 1000, timescale: 1), hostAtAnchor: CMTime(value: 100, timescale: 1))
    }

    /// Host time `seconds` read on `offsetClock()`.
    private func offsetSync(_ seconds: Double) -> CMTime {
        CMTime(value: Int64((seconds * 1000).rounded()) + 900_000, timescale: 1000)
    }

    /// Signed 16-bit stereo, interleaved; sample i of channel c holds 2i + c + 1.
    private func pcm(frames: Int, at pts: CMTime, interleaved: Bool = true, float: Bool = false) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: float ? .pcmFormatFloat32 : .pcmFormatInt16, sampleRate: rate, channels: 2, interleaved: interleaved))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            for c in 0..<2 {
                let value = 2 * i + c + 1
                if float {
                    if interleaved { buffer.floatChannelData![0][2 * i + c] = Float(value) }
                    else { buffer.floatChannelData![c][i] = Float(value) }
                } else {
                    buffer.int16ChannelData![0][2 * i + c] = Int16(value)
                }
            }
        }
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format.formatDescription, sampleCount: frames, presentationTimeStamp: pts,
            packetDescriptions: nil, sampleBufferOut: &sample), noErr)
        let created = try XCTUnwrap(sample)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(
            created, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
            bufferList: buffer.audioBufferList), noErr)
        return created
    }

    /// Every sample value of a buffer, channel by channel.
    private func values(_ buffer: CMSampleBuffer) throws -> [[Double]] {
        let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(buffer))
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = CMSampleBufferGetNumSamples(buffer)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        XCTAssertEqual(CMSampleBufferCopyPCMDataIntoAudioBufferList(
            buffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList), noErr)
        return (0..<2).map { c in
            (0..<frames).map { i in
                switch (format.commonFormat, format.isInterleaved) {
                case (.pcmFormatFloat32, true): Double(pcm.floatChannelData![0][2 * i + c])
                case (.pcmFormatFloat32, false): Double(pcm.floatChannelData![c][i])
                default: Double(pcm.int16ChannelData![0][2 * i + c])
                }
            }
        }
    }

    /// The values `pcm` wrote for samples `range`.
    private func expected(_ range: Range<Int>) -> [[Double]] {
        (0..<2).map { c in range.map { Double(2 * $0 + c + 1) } }
    }

    private func assertPiece(
        _ piece: CMSampleBuffer, samples range: Range<Int>, session seconds: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(CMSampleBufferGetNumSamples(piece), range.count, file: file, line: line)
        XCTAssertEqual(piece.presentationTimeStamp.seconds, seconds, accuracy: 1e-9, file: file, line: line)
        XCTAssertFalse(piece.decodeTimeStamp.isValid, file: file, line: line)
        XCTAssertEqual(try values(piece), expected(range), file: file, line: line)
    }

    private func audio(_ retimer: SessionRetimer, _ buffer: CMSampleBuffer) throws -> RetimedAudio {
        try retimer.audio(buffer).get()
    }

    // MARK: - Audio split at the epoch and pauses

    func testAPacketStartingBeforeTheEpochKeepsOnlyItsLaterSamples() throws {
        let clock = CaptureClock(epochHostTime: host(100))
        let retimer = SessionRetimer(clock: clock, syncClock: try offsetClock())

        let result = try audio(retimer, try pcm(frames: 480, at: offsetSync(99.995)))

        XCTAssertEqual(result.excludedFrames, 240)
        XCTAssertEqual(result.pieces.count, 1)
        try assertPiece(result.pieces[0], samples: 240..<480, session: 0)
    }

    func testAPacketSpanningAPauseStartKeepsOnlyTheSamplesBeforeIt() throws {
        let clock = CaptureClock(epochHostTime: host(100))
        XCTAssertTrue(clock.pause(atHostTime: host(100.0025)))
        let retimer = SessionRetimer(clock: clock, syncClock: try offsetClock())

        let result = try audio(retimer, try pcm(frames: 480, at: offsetSync(100)))

        XCTAssertEqual(result.excludedFrames, 360)
        XCTAssertEqual(result.pieces.count, 1)
        try assertPiece(result.pieces[0], samples: 0..<120, session: 0)
    }

    func testAPacketSpanningAResumeKeepsTheSamplesFromItAtTheirSessionPosition() throws {
        let clock = CaptureClock(epochHostTime: host(100))
        XCTAssertTrue(clock.pause(atHostTime: host(100.001)))
        XCTAssertTrue(clock.resume(atHostTime: host(100.010)))
        let retimer = SessionRetimer(clock: clock, syncClock: try offsetClock())

        let result = try audio(retimer, try pcm(frames: 480, at: offsetSync(100.008)))

        XCTAssertEqual(result.excludedFrames, 96)
        XCTAssertEqual(result.pieces.count, 1)
        try assertPiece(result.pieces[0], samples: 96..<480, session: 0.001)
    }

    func testPausesInsideOnePacketCutItIntoPiecesWithExactBoundaries() throws {
        let clock = CaptureClock(epochHostTime: host(100))
        XCTAssertTrue(clock.pause(atHostTime: host(100.001)))
        XCTAssertTrue(clock.resume(atHostTime: host(100.002)))
        XCTAssertTrue(clock.pause(atHostTime: host(100.004)))
        XCTAssertTrue(clock.resume(atHostTime: host(100.005)))
        let retimer = SessionRetimer(clock: clock, syncClock: try offsetClock())

        let result = try audio(retimer, try pcm(frames: 480, at: offsetSync(100)))

        // Sample 48 lies exactly on the first pause's start and is left out; sample 96 lies exactly
        // on its end and is kept.
        XCTAssertEqual(result.excludedFrames, 96)
        XCTAssertEqual(result.pieces.count, 3)
        try assertPiece(result.pieces[0], samples: 0..<48, session: 0)
        try assertPiece(result.pieces[1], samples: 96..<192, session: 0.001)
        try assertPiece(result.pieces[2], samples: 240..<480, session: 0.003)
    }

    func testABoundaryBetweenTwoSamplesLeavesOutOnlyTheSamplesAfterIt() throws {
        let clock = CaptureClock(epochHostTime: host(100))
        // Between sample 47 (100.000979…) and sample 48 (100.001).
        XCTAssertTrue(clock.pause(atHostTime: CMTime(value: 100_000_990_000, timescale: 1_000_000_000)))
        let retimer = SessionRetimer(clock: clock, syncClock: CaptureClock.hostClock)

        let result = try audio(retimer, try pcm(frames: 480, at: host(100)))

        XCTAssertEqual(result.pieces.count, 1)
        try assertPiece(result.pieces[0], samples: 0..<48, session: 0)
        XCTAssertEqual(result.excludedFrames, 432)
    }

    func testAnEmptyPauseDoesNotCutAPacket() throws {
        let clock = CaptureClock(epochHostTime: host(100))
        XCTAssertTrue(clock.pause(atHostTime: host(100.002)))
        XCTAssertTrue(clock.resume(atHostTime: host(100.002)))
        let retimer = SessionRetimer(clock: clock, syncClock: try offsetClock())

        let result = try audio(retimer, try pcm(frames: 480, at: offsetSync(100)))

        XCTAssertEqual(result.excludedFrames, 0)
        XCTAssertEqual(result.pieces.count, 1)
        try assertPiece(result.pieces[0], samples: 0..<480, session: 0)
    }

    func testNonInterleavedFloatChannelsKeepTheirOwnValues() throws {
        let clock = CaptureClock(epochHostTime: host(100))
        XCTAssertTrue(clock.pause(atHostTime: host(100.001)))
        XCTAssertTrue(clock.resume(atHostTime: host(100.002)))
        let retimer = SessionRetimer(clock: clock, syncClock: try offsetClock())

        let result = try audio(retimer, try pcm(frames: 480, at: offsetSync(100), interleaved: false, float: true))

        XCTAssertEqual(result.pieces.count, 2)
        try assertPiece(result.pieces[0], samples: 0..<48, session: 0)
        try assertPiece(result.pieces[1], samples: 96..<480, session: 0.001)
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(result.pieces[1]))
        XCTAssertEqual(AVAudioFormat(cmAudioFormatDescription: format).isInterleaved, false)
        XCTAssertEqual(AVAudioFormat(cmAudioFormatDescription: format).commonFormat, .pcmFormatFloat32)
    }

    func testSampleTimesAreReadOnTheSyncClockNotAddedInHostTime() throws {
        // The sync clock runs 1.0001 times as fast as the host clock. The pause 1 ms of host time
        // in falls at sync time 1.0001 ms, after sample 48 (1 ms) and before sample 49; counting
        // samples in host time from the packet start would cut at 48. The resume falls between
        // samples 96 and 97.
        let speed = 1.0001
        let anchor = CMTime(value: 1000, timescale: 1)
        let clock = CaptureClock(epochHostTime: host(100))
        XCTAssertTrue(clock.pause(atHostTime: host(100.001)))
        XCTAssertTrue(clock.resume(atHostTime: host(100.002)))
        let retimer = SessionRetimer(
            clock: clock, syncClock: try syncClock(syncAtAnchor: anchor, hostAtAnchor: host(100), speed: speed))

        let result = try audio(retimer, try pcm(frames: 480, at: anchor))

        XCTAssertEqual(result.pieces.count, 2)
        XCTAssertEqual(result.excludedFrames, 48)
        try assertPiece(result.pieces[0], samples: 0..<49, session: 0)
        try assertPiece(result.pieces[1], samples: 97..<480, session: 97 / rate / speed - 0.001)
        // PCM samples keep their own duration; the pieces end where their samples end and meet
        // within the half-sample tolerance.
        for piece in result.pieces {
            XCTAssertEqual(piece.duration.seconds, Double(CMSampleBufferGetNumSamples(piece)) / rate, accuracy: 1e-12)
        }
        let firstEnd = result.pieces[0].presentationTimeStamp + result.pieces[0].duration
        XCTAssertGreaterThanOrEqual(
            result.pieces[1].presentationTimeStamp.seconds,
            firstEnd.seconds - SessionRetimer.pcmDurationTolerance / rate)
    }

    func testPCMIsRefusedWhenTheSyncClockDoesNotRunAtItsSampleRate() throws {
        // At twice the host clock's rate, 10 ms of samples span 5 ms of session time; keeping
        // them would need resampling.
        let anchor = CMTime(value: 1000, timescale: 1)
        let retimer = SessionRetimer(
            clock: CaptureClock(epochHostTime: host(100)),
            syncClock: try syncClock(syncAtAnchor: anchor, hostAtAnchor: host(100), speed: 2))

        XCTAssertThrowsError(try audio(retimer, try pcm(frames: 480, at: anchor + ms(10)))) {
            guard case .invalidTiming(let reason) = $0 as? SampleRetimingFailure else { return XCTFail("\($0)") }
            XCTAssertTrue(reason.contains("does not run at the sample rate"), reason)
        }
    }

    func testDurationsAndDecodeOffsetsAreConvertedToSessionTime() throws {
        let anchor = CMTime(value: 1000, timescale: 1)
        let retimer = SessionRetimer(
            clock: CaptureClock(epochHostTime: host(100)),
            syncClock: try syncClock(syncAtAnchor: anchor, hostAtAnchor: host(100), speed: 2))

        let frame = try XCTUnwrap(try retimer.screenFrame(try frame(at: anchor + ms(20), decode: anchor + ms(10))).get())
        XCTAssertEqual(frame.presentationTimeStamp.seconds, 0.010, accuracy: 1e-9)
        XCTAssertEqual(frame.duration.seconds, 1.0 / 120, accuracy: 1e-9)
        XCTAssertEqual(frame.decodeTimeStamp.seconds, 0.005, accuracy: 1e-9)

        let whole = try audio(retimer, try unsplittable(at: anchor + ms(20)))
        XCTAssertEqual(whole.pieces.count, 1)
        XCTAssertEqual(whole.pieces[0].presentationTimeStamp.seconds, 0.010, accuracy: 1e-9)
        // Each of the 441 per-sample durations is rounded to the host clock's nanosecond.
        XCTAssertEqual(whole.pieces[0].duration.seconds, 0.005, accuracy: 1e-6)
    }

    func testAClockThatCannotConvertIsAFailureNotAnExclusion() throws {
        let anchor = CMTime(value: 1000, timescale: 1)
        let retimer = SessionRetimer(
            clock: CaptureClock(epochHostTime: host(100)),
            syncClock: try syncClock(syncAtAnchor: anchor, hostAtAnchor: host(100), speed: 0))

        XCTAssertThrowsError(try retimer.screenFrame(try frame(at: anchor + ms(20))).get()) {
            guard case .invalidTiming = $0 as? SampleRetimingFailure else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try audio(retimer, try pcm(frames: 480, at: anchor + ms(20)))) {
            guard case .invalidTiming = $0 as? SampleRetimingFailure else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try audio(retimer, try unsplittable(at: anchor + ms(20)))) {
            guard case .invalidTiming = $0 as? SampleRetimingFailure else { return XCTFail("\($0)") }
        }
    }

    func testSplitPiecesKeepTheBufferAttachmentsAndOnlyTheirOwnTrims() throws {
        let clock = CaptureClock(epochHostTime: host(100))
        XCTAssertTrue(clock.pause(atHostTime: host(100.001)))
        XCTAssertTrue(clock.resume(atHostTime: host(100.002)))
        let retimer = SessionRetimer(clock: clock, syncClock: try offsetClock())
        let buffer = try pcm(frames: 480, at: offsetSync(100))
        CMSetAttachment(buffer, key: "RecordMacTest" as CFString, value: "kept" as CFString, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        CMSetAttachment(buffer, key: "RecordMacLocal" as CFString, value: "local" as CFString, attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
        _ = trimmed(buffer, start: 10, end: 10)

        let result = try audio(retimer, buffer)

        XCTAssertEqual(result.pieces.count, 2)
        for piece in result.pieces {
            XCTAssertEqual(CMGetAttachment(piece, key: "RecordMacTest" as CFString, attachmentModeOut: nil) as? String, "kept")
            var mode: CMAttachmentMode = 0
            XCTAssertEqual(CMGetAttachment(piece, key: "RecordMacLocal" as CFString, attachmentModeOut: &mode) as? String, "local")
            XCTAssertEqual(mode, kCMAttachmentMode_ShouldNotPropagate)
        }
        XCTAssertEqual(trims(result.pieces[0]), Trims(start: 10, end: nil))
        XCTAssertEqual(trims(result.pieces[1]), Trims(start: nil, end: 10))
        XCTAssertEqual(CMSampleBufferGetOutputDuration(result.pieces[0]).seconds, 38 / rate, accuracy: 1e-9)
        XCTAssertEqual(CMSampleBufferGetOutputDuration(result.pieces[1]).seconds, 374 / rate, accuracy: 1e-9)
    }

    private struct Trims: Equatable {
        var start: Int?
        var end: Int?
    }

    /// A buffer's trims, in samples.
    private func trims(_ buffer: CMSampleBuffer) -> Trims {
        func samples(_ key: CFString) -> Int? {
            guard let value = CMGetAttachment(buffer, key: key, attachmentModeOut: nil) as? NSDictionary else { return nil }
            return Int((CMTimeMakeFromDictionary(value as CFDictionary).seconds * rate).rounded())
        }
        return Trims(start: samples(kCMSampleBufferAttachmentKey_TrimDurationAtStart),
            end: samples(kCMSampleBufferAttachmentKey_TrimDurationAtEnd))
    }

    private func trimmed(_ buffer: CMSampleBuffer, start: Int? = nil, end: Int? = nil) -> CMSampleBuffer {
        for (key, samples) in [(kCMSampleBufferAttachmentKey_TrimDurationAtStart, start), (kCMSampleBufferAttachmentKey_TrimDurationAtEnd, end)] {
            guard let samples else { continue }
            CMSetAttachment(buffer, key: key, value: CMTimeCopyAsDictionary(CMTime(value: Int64(samples), timescale: 48_000), allocator: nil),
                attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        return buffer
    }

    func testAStartTrimReachingPastTheEpochKeepsItsRemainderOnTheKeptPiece() throws {
        let retimer = SessionRetimer(clock: CaptureClock(epochHostTime: host(100)), syncClock: CaptureClock.hostClock)

        let result = try audio(retimer, trimmed(try pcm(frames: 480, at: host(99.995)), start: 300))

        XCTAssertEqual(result.pieces.count, 1)
        try assertPiece(result.pieces[0], samples: 240..<480, session: 0)
        XCTAssertEqual(trims(result.pieces[0]), Trims(start: 60, end: nil))
        XCTAssertEqual(CMSampleBufferGetOutputDuration(result.pieces[0]).seconds, 0.00375, accuracy: 1e-9)
    }

    func testAnEndTrimReachingBeforeAPauseKeepsItsRemainderOnTheKeptPiece() throws {
        let clock = CaptureClock(epochHostTime: host(100))
        XCTAssertTrue(clock.pause(atHostTime: host(100.005)))
        let retimer = SessionRetimer(clock: clock, syncClock: CaptureClock.hostClock)

        let result = try audio(retimer, trimmed(try pcm(frames: 480, at: host(100)), end: 300))

        XCTAssertEqual(result.pieces.count, 1)
        try assertPiece(result.pieces[0], samples: 0..<240, session: 0)
        XCTAssertEqual(trims(result.pieces[0]), Trims(start: nil, end: 60))
        XCTAssertEqual(CMSampleBufferGetOutputDuration(result.pieces[0]).seconds, 0.00375, accuracy: 1e-9)
    }

    func testAPieceWhollyInsideATrimIsTrimmedToNothing() throws {
        let clock = CaptureClock(epochHostTime: host(100))
        XCTAssertTrue(clock.pause(atHostTime: host(100.001)))
        XCTAssertTrue(clock.resume(atHostTime: host(100.002)))
        let retimer = SessionRetimer(clock: clock, syncClock: CaptureClock.hostClock)

        // The trims overlap: samples 0..<400 and 380..<480.
        let result = try audio(retimer, trimmed(try pcm(frames: 480, at: host(100)), start: 400, end: 100))

        XCTAssertEqual(result.pieces.count, 2)
        XCTAssertEqual(trims(result.pieces[0]), Trims(start: 48, end: nil))
        XCTAssertEqual(CMSampleBufferGetOutputDuration(result.pieces[0]), .zero)
        XCTAssertEqual(trims(result.pieces[1]), Trims(start: 304, end: 80))
        XCTAssertEqual(CMSampleBufferGetOutputDuration(result.pieces[1]), .zero)
    }

    func testATrimThatIsNotAWholeNumberOfSamplesIsRefusedWhenSplitting() throws {
        let clock = CaptureClock(epochHostTime: host(100))
        XCTAssertTrue(clock.pause(atHostTime: host(100.005)))
        let retimer = SessionRetimer(clock: clock, syncClock: CaptureClock.hostClock)
        let buffer = try pcm(frames: 480, at: host(100))
        CMSetAttachment(buffer, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
            value: CMTimeCopyAsDictionary(CMTime(value: 1, timescale: 96_000), allocator: nil), attachmentMode: kCMAttachmentMode_ShouldPropagate)

        XCTAssertThrowsError(try audio(retimer, buffer)) {
            guard case .unsupportedFormat = $0 as? SampleRetimingFailure else { return XCTFail("\($0)") }
        }
    }

    func testSplitPiecesKeepTheirOwnSamplesPerSampleAttachments() throws {
        let clock = CaptureClock(epochHostTime: host(100))
        XCTAssertTrue(clock.pause(atHostTime: host(100.001)))
        XCTAssertTrue(clock.resume(atHostTime: host(100.002)))
        let retimer = SessionRetimer(clock: clock, syncClock: try offsetClock())
        let buffer = try pcm(frames: 480, at: offsetSync(100))
        let source = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true))
        let count = CFArrayGetCount(source)
        for index in 0..<count {
            let entry = unsafeBitCast(CFArrayGetValueAtIndex(source, index), to: NSMutableDictionary.self)
            entry["RecordMacSample"] = index
        }

        let result = try audio(retimer, buffer)

        XCTAssertEqual(result.pieces.count, 2)
        let samples = try result.pieces.map { piece -> [Int] in
            let array = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(piece, createIfNecessary: false)) as? [[String: Any]]
            return try XCTUnwrap(array).compactMap { $0["RecordMacSample"] as? Int }
        }
        XCTAssertEqual(count, 480, "one entry per sample")
        XCTAssertEqual(samples, [Array(0..<48), Array(96..<480)])
    }

    func testAPacketWhollyInSessionTimeIsKeptWholeWithItsAttachments() throws {
        let clock = CaptureClock(epochHostTime: host(100))
        let retimer = SessionRetimer(clock: clock, syncClock: try offsetClock())
        let buffer = try pcm(frames: 480, at: offsetSync(100.5))
        CMSetAttachment(buffer, key: "RecordMacTest" as CFString, value: "kept" as CFString, attachmentMode: kCMAttachmentMode_ShouldPropagate)

        let result = try audio(retimer, buffer)

        XCTAssertEqual(result.excludedFrames, 0)
        XCTAssertEqual(result.pieces.count, 1)
        try assertPiece(result.pieces[0], samples: 0..<480, session: 0.5)
        XCTAssertEqual(CMGetAttachment(result.pieces[0], key: "RecordMacTest" as CFString, attachmentModeOut: nil) as? String, "kept")
    }

    func testAPacketWhollyBeforeTheEpochOrInsideAPauseIsLeftOut() throws {
        let clock = CaptureClock(epochHostTime: host(100))
        XCTAssertTrue(clock.pause(atHostTime: host(101)))
        let retimer = SessionRetimer(clock: clock, syncClock: try offsetClock())

        for start in [99.5, 101, 102] {
            let result = try audio(retimer, try pcm(frames: 480, at: offsetSync(start)))
            XCTAssertEqual(result.pieces.count, 0, "\(start)")
            XCTAssertEqual(result.excludedFrames, 480, "\(start)")
        }
    }

    // MARK: - Buffers that cannot be split

    /// Retimed so each sample claims 1/44100 s in a 48 kHz format, which the split does not trust.
    private func unsplittable(at pts: CMTime) throws -> CMSampleBuffer {
        let buffer = try pcm(frames: 441, at: pts)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44_100), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &out), noErr)
        return try XCTUnwrap(out)
    }

    func testABufferThatCannotBeSplitIsKeptWholeOnlyWhenNoBoundaryFallsInIt() throws {
        let clock = CaptureClock(epochHostTime: host(100))
        XCTAssertTrue(clock.pause(atHostTime: host(100.5)))
        XCTAssertTrue(clock.resume(atHostTime: host(101)))
        let retimer = SessionRetimer(clock: clock, syncClock: try offsetClock())

        let kept = try audio(retimer, try unsplittable(at: offsetSync(100.2)))
        XCTAssertEqual(kept.pieces.count, 1)
        XCTAssertEqual(kept.pieces[0].presentationTimeStamp.seconds, 0.2, accuracy: 1e-9)
        XCTAssertEqual(CMSampleBufferGetNumSamples(kept.pieces[0]), 441)

        let afterResume = try audio(retimer, try unsplittable(at: offsetSync(101)))
        XCTAssertEqual(afterResume.pieces.first?.presentationTimeStamp.seconds ?? -1, 0.5, accuracy: 1e-9)

        let paused = try audio(retimer, try unsplittable(at: offsetSync(100.7)))
        XCTAssertEqual(paused.pieces.count, 0)
        XCTAssertEqual(paused.excludedFrames, 441)

        for start in [99.995, 100.495, 100.995] {
            XCTAssertThrowsError(try audio(retimer, try unsplittable(at: offsetSync(start))), "\(start)") {
                guard case .spansExcludedTime = $0 as? SampleRetimingFailure else { return XCTFail("\(start): \($0)") }
            }
        }
    }

    func testInvalidTimingAndNonAudioBuffersAreRefusedWithAReason() throws {
        let retimer = SessionRetimer(clock: CaptureClock(epochHostTime: host(100)), syncClock: try offsetClock())

        let valid = try pcm(frames: 480, at: offsetSync(101))
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var untimed: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: valid, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &untimed), noErr)
        XCTAssertThrowsError(try audio(retimer, try XCTUnwrap(untimed))) {
            guard case .invalidTiming = $0 as? SampleRetimingFailure else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try audio(retimer, try frame(at: offsetSync(101)))) {
            guard case .unsupportedFormat = $0 as? SampleRetimingFailure else { return XCTFail("\($0)") }
        }
    }

    // MARK: - Screen frames

    private func frame(at pts: CMTime, decode: CMTime = .invalid) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        let image = try XCTUnwrap(pixels)
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &description), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: pts, decodeTimeStamp: decode)
        var buffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: image, formatDescription: try XCTUnwrap(description), sampleTiming: &timing,
            sampleBufferOut: &buffer), noErr)
        return try XCTUnwrap(buffer)
    }

    func testScreenFramesAreStampedOnTheSessionClockAndKeepTheirImageAndAttachments() throws {
        let clock = CaptureClock(epochHostTime: host(100))
        XCTAssertTrue(clock.pause(atHostTime: host(101)))
        XCTAssertTrue(clock.resume(atHostTime: host(103)))
        let retimer = SessionRetimer(clock: clock, syncClock: try offsetClock())

        XCTAssertNil(try retimer.screenFrame(try frame(at: offsetSync(99.99))).get())
        XCTAssertNil(try retimer.screenFrame(try frame(at: offsetSync(102))).get())

        let source = try frame(at: offsetSync(103.5))
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(source, createIfNecessary: true))
        let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(first, Unmanaged.passUnretained("SCStreamUpdateFrameStatus" as CFString).toOpaque(),
            Unmanaged.passUnretained(NSNumber(value: 0)).toOpaque())
        CMSetAttachment(source, key: "RecordMacTest" as CFString, value: "kept" as CFString, attachmentMode: kCMAttachmentMode_ShouldPropagate)

        let retimed = try XCTUnwrap(try retimer.screenFrame(source).get())

        XCTAssertEqual(retimed.presentationTimeStamp.seconds, 1.5, accuracy: 1e-9)
        XCTAssertEqual(retimed.duration, CMTime(value: 1, timescale: 60))
        XCTAssertFalse(retimed.decodeTimeStamp.isValid)
        XCTAssertTrue(CMSampleBufferGetImageBuffer(retimed) === CMSampleBufferGetImageBuffer(source))
        XCTAssertEqual(CMGetAttachment(retimed, key: "RecordMacTest" as CFString, attachmentModeOut: nil) as? String, "kept")
        let copied = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(retimed, createIfNecessary: false)) as? [[String: Any]]
        XCTAssertEqual(copied?.first?["SCStreamUpdateFrameStatus"] as? Int, 0)
    }

    func testAValidDecodeTimestampKeepsItsOffset() throws {
        let retimer = SessionRetimer(clock: CaptureClock(epochHostTime: host(100)), syncClock: try offsetClock())
        let retimed = try XCTUnwrap(try retimer.screenFrame(try frame(at: offsetSync(101), decode: offsetSync(100.99))).get())
        XCTAssertEqual(retimed.presentationTimeStamp.seconds, 1, accuracy: 1e-9)
        XCTAssertEqual(retimed.decodeTimeStamp.seconds, 0.99, accuracy: 1e-9)
    }

    func testAScreenFrameWithoutATimestampIsRefused() throws {
        let retimer = SessionRetimer(clock: CaptureClock(epochHostTime: host(100)), syncClock: try offsetClock())
        XCTAssertThrowsError(try retimer.screenFrame(try frame(at: .invalid)).get()) {
            guard case .invalidTiming = $0 as? SampleRetimingFailure else { return XCTFail("\($0)") }
        }
    }

    // MARK: - Clock snapshot

    func testTheSnapshotSpansLeaveOutPausesAndEndAtAnOpenOne() {
        let clock = CaptureClock(epochHostTime: host(100))
        XCTAssertEqual(clock.snapshot().spans, [.init(start: host(100), end: nil)])
        XCTAssertTrue(clock.pause(atHostTime: host(101)))
        XCTAssertTrue(clock.resume(atHostTime: host(101)))
        XCTAssertTrue(clock.pause(atHostTime: host(102)))
        XCTAssertEqual(clock.snapshot().spans, [.init(start: host(100), end: host(102))])
        XCTAssertTrue(clock.resume(atHostTime: host(104)))
        XCTAssertEqual(clock.snapshot().spans, [.init(start: host(100), end: host(102)), .init(start: host(104), end: nil)])
    }
}
