@preconcurrency import AVFoundation
import CoreMedia
import XCTest
@testable import RecordMac

/// Synthetic PCM buffers with a known value for every sample and channel, and readers that
/// return a written file's raw bytes.
enum AudioFixtures {
    /// A buffer of `frames` frames at `start` seconds; channel `c` of frame `f` holds a value
    /// derived from `seed`, `c`, and `f`, so channels and sources are told apart.
    static func buffer(format: AVAudioFormat, frames: Int, start: Double, seed: Int) throws -> (CMSampleBuffer, Data) {
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        let lists = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        let channels = Int(format.channelCount)
        for frame in 0..<frames {
            for channel in 0..<channels {
                let value = Double(((frame * 7 + channel * 101 + seed * 13) % 200) - 100) / 128.0
                let list = format.isInterleaved ? 0 : channel
                let index = format.isInterleaved ? frame * channels + channel : frame
                let data = try XCTUnwrap(lists[list].mData)
                switch format.commonFormat {
                case .pcmFormatInt16: data.assumingMemoryBound(to: Int16.self)[index] = Int16(value * 32_000)
                case .pcmFormatFloat32: data.assumingMemoryBound(to: Float.self)[index] = Float(value)
                default: XCTFail("unsupported fixture format")
                }
            }
        }
        var bytes = Data()
        for list in lists { bytes.append(Data(bytes: list.mData!, count: Int(list.mDataByteSize))) }
        let rate = Int32(format.sampleRate)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: rate),
            presentationTimeStamp: CMTime(seconds: start, preferredTimescale: rate), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: format.formatDescription, sampleCount: frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &sample)
        let result = try XCTUnwrap(sample)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(result), noErr)
        return (result, bytes)
    }

    /// The file's audio format, first sample time, frame count, and raw sample bytes in order.
    static func read(_ url: URL) async throws -> (format: AudioStreamBasicDescription, firstTime: Double, frames: Int, bytes: Data) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(try XCTUnwrap(descriptions.first))?.pointee)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var first: Double?
        var frames = 0
        var bytes = Data()
        while let sample = output.copyNextSampleBuffer() {
            if first == nil { first = sample.presentationTimeStamp.seconds }
            frames += CMSampleBufferGetNumSamples(sample)
            if let block = CMSampleBufferGetDataBuffer(sample) {
                var length = 0
                var pointer: UnsafeMutablePointer<CChar>?
                CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
                var chunk = Data(count: length)
                chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                bytes.append(chunk)
            }
        }
        return (format, try XCTUnwrap(first), frames, bytes)
    }
}

final class MicrophoneCaptureTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 48_000) }

    private func writer(start: Double = 10, pendingLimit: Double = 2) -> AudioTrackWriter {
        AudioTrackWriter(source: .microphone, url: directory.appendingPathComponent("microphone.mov"),
            start: seconds(start), pendingLimit: pendingLimit)
    }

    func testIntegerMonoIsWrittenSampleForSampleInItsOwnFormat() async throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 1, interleaved: true))
        let track = writer()
        let (first, firstBytes) = try AudioFixtures.buffer(format: format, frames: 4410, start: 10.5, seed: 1)
        let (second, secondBytes) = try AudioFixtures.buffer(format: format, frames: 4410, start: 10.6, seed: 2)
        track.append(first)
        track.append(second)
        let counts = await track.finish()

        XCTAssertEqual(counts, AudioTrackCounts(receivedFrames: 8820, appendedFrames: 8820, written: .decoded(8820)))
        let file = try await AudioFixtures.read(track.url)
        XCTAssertEqual(file.format.mSampleRate, 44_100)
        XCTAssertEqual(file.format.mChannelsPerFrame, 1)
        XCTAssertEqual(file.format.mBitsPerChannel, 16)
        XCTAssertEqual(file.format.mFormatFlags & kAudioFormatFlagIsFloat, 0, "not converted to float")
        XCTAssertEqual(file.bytes, firstBytes + secondBytes, "every sample value kept")
        // The offset from the segment's start is an empty edit before the audio.
        let asset = AVURLAsset(url: track.url)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let edits = try await XCTUnwrap(audio.first).load(.segments)
        XCTAssertEqual(edits.map(\.isEmpty), [true, false])
        XCTAssertEqual(edits.map { $0.timeMapping.target.start.seconds }, [0, 0.5])
        XCTAssertEqual(try XCTUnwrap(edits.last).timeMapping.target.duration.seconds, 0.2, accuracy: 0.001)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 0.7, accuracy: 0.001)
    }

    func testPlanarStereoFloatKeepsItsChannelsApart() async throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let track = writer()
        let (buffer, _) = try AudioFixtures.buffer(format: format, frames: 4800, start: 10, seed: 3)
        track.append(buffer)
        let counts = await track.finish()
        XCTAssertEqual(counts.written, .decoded(4800))

        let file = try await AudioFixtures.read(track.url)
        XCTAssertEqual(file.format.mChannelsPerFrame, 2)
        XCTAssertEqual(file.format.mBitsPerChannel, 32)
        XCTAssertNotEqual(file.format.mFormatFlags & kAudioFormatFlagIsFloat, 0)
        // Whatever layout the file stores, each channel's samples must be the fixture's.
        let floats = file.bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(floats.count, 9600)
        let interleaved = file.format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        for frame in [0, 1, 2399, 4799] {
            for channel in 0..<2 {
                let expected = Float(Double(((frame * 7 + channel * 101 + 3 * 13) % 200) - 100) / 128.0)
                let index = interleaved ? frame * 2 + channel : channel * 4800 + frame
                XCTAssertEqual(floats[index], expected, "frame \(frame) channel \(channel)")
            }
        }
        print("audio track: planar float stored \(interleaved ? "interleaved" : "non-interleaved")")
    }

    /// Signed 24-bit samples in 32-bit slots, as some interfaces deliver them, are kept byte
    /// for byte (see ScreenCaptureAudioTrackTests for the converter's truncation).
    func testAligned24BitSamplesAreKeptByteForByte() async throws {
        let frames = 4800
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsAlignedHigh,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
            mBitsPerChannel: 24, mReserved: 0)
        XCTAssertNil(AudioTrackWriter.outputSettings(for: asbd))
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description), noErr)
        var values = [Int32](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            values[frame * 2] = Int32((frame * 977) % 8_000_000 - 4_000_000) << 8
            values[frame * 2 + 1] = Int32((frame * 131) % 2_000_000 - 1_000_000) << 8
        }
        let bytes = values.withUnsafeBytes { Data($0) }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block)
        _ = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: $0.count) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: seconds(10), decodeTimeStamp: .invalid)
        var size = 8
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: description,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample), noErr)

        let track = writer()
        track.append(try XCTUnwrap(sample))
        let counts = await track.finish()
        XCTAssertEqual(counts.written, .decoded(frames))
        let file = try await AudioFixtures.read(track.url)
        XCTAssertEqual(file.format.mBitsPerChannel, 24)
        XCTAssertEqual(file.bytes, bytes)
    }

    /// Signed 24-bit samples in 32-bit slots with each channel in its own buffer are written as
    /// 24-bit samples, every value kept.
    func testPlanar24BitSamplesKeepEveryValue() async throws {
        let frames = 4800
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsAlignedHigh
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
            mBitsPerChannel: 24, mReserved: 0)
        let settings = try XCTUnwrap(AudioTrackWriter.outputSettings(for: asbd))
        XCTAssertEqual(settings[AVLinearPCMBitDepthKey] as? Int, 24)
        XCTAssertEqual(settings[AVLinearPCMIsFloatKey] as? Bool, false)
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description), noErr)
        // Full-scale extremes and a ramp across the 24-bit range, distinct per channel.
        func value(_ frame: Int, _ channel: Int) -> Int32 {
            switch frame {
            case 0: return channel == 0 ? 8_388_607 : -8_388_608
            case 1: return channel == 0 ? -8_388_608 : 8_388_607
            default: return Int32((frame * (channel == 0 ? 3_491 : 977)) % 16_777_216 - 8_388_608)
            }
        }
        let channels = (0..<2).map { channel in (0..<frames).map { value($0, channel) << 8 } }
        let lists = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(lists.unsafeMutablePointer) }
        let storage = channels.map { samples -> UnsafeMutableBufferPointer<Int32> in
            let pointer = UnsafeMutableBufferPointer<Int32>.allocate(capacity: samples.count)
            _ = pointer.initialize(from: samples)
            return pointer
        }
        defer { storage.forEach { $0.deallocate() } }
        for channel in 0..<2 {
            lists[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4),
                mData: UnsafeMutableRawPointer(storage[channel].baseAddress))
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: seconds(10), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: description, sampleCount: frames, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        let buffer = try XCTUnwrap(sample)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, bufferList: lists.unsafePointer), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(buffer), noErr)

        let track = writer()
        track.append(buffer)
        let counts = await track.finish()
        XCTAssertEqual(counts, AudioTrackCounts(receivedFrames: frames, appendedFrames: frames, written: .decoded(frames)))
        let file = try await AudioFixtures.read(track.url)
        XCTAssertEqual(file.format.mBitsPerChannel, 24)
        XCTAssertEqual(file.format.mChannelsPerFrame, 2)
        XCTAssertEqual(file.format.mFormatFlags & kAudioFormatFlagIsFloat, 0, "not converted to float")
        XCTAssertEqual(file.format.mFormatFlags & kAudioFormatFlagIsNonInterleaved, 0)
        XCTAssertEqual(file.format.mFormatFlags & kAudioFormatFlagIsBigEndian, 0)
        let width = Int(file.format.mBytesPerFrame) / 2
        let alignedHigh = file.format.mFormatFlags & kLinearPCMFormatFlagIsAlignedHigh != 0
        XCTAssertEqual(file.bytes.count, frames * 2 * width)
        let bytes = [UInt8](file.bytes)
        var mismatches = 0
        for frame in 0..<frames {
            for channel in 0..<2 {
                let offset = (frame * 2 + channel) * width
                var raw: UInt32 = 0
                for byte in 0..<width { raw |= UInt32(bytes[offset + byte]) << (8 * byte) }
                let stored = width == 4 && alignedHigh ? Int32(bitPattern: raw) >> 8
                    : Int32(bitPattern: raw << 8) >> 8
                if stored != value(frame, channel) { mismatches += 1 }
            }
        }
        XCTAssertEqual(mismatches, 0, "every sample value kept")
    }

    func testABufferInAnotherFormatIsRefusedAndCounted() async throws {
        let mono = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 1, interleaved: true))
        let other = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true))
        let track = writer()
        track.append(try AudioFixtures.buffer(format: mono, frames: 441, start: 10, seed: 1).0)
        track.append(try AudioFixtures.buffer(format: other, frames: 480, start: 10.01, seed: 1).0)
        let counts = await track.finish()
        XCTAssertEqual(counts.rejectedFormatFrames, 480)
        XCTAssertEqual(counts.appendedFrames, 441)
        XCTAssertEqual(counts.written, .decoded(441))
    }

    func testAudioBeyondThePendingLimitIsDroppedAndCounted() async throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 1, interleaved: true))
        let track = writer(pendingLimit: 0)
        track.append(try AudioFixtures.buffer(format: format, frames: 441, start: 10, seed: 1).0)
        let counts = await track.finish()
        XCTAssertEqual(counts.droppedOverflowFrames, 441)
        XCTAssertEqual(counts.written, .noFramesAppended, "no usable audio is reported as none")
        XCTAssertFalse(FileManager.default.fileExists(atPath: track.url.path) && counts.appendedFrames > 0)
    }

    /// A sink whose readiness and failure the test controls.
    private final class ScriptedSink: AudioSampleSink, @unchecked Sendable {
        private let lock = NSLock()
        private var ready = false
        private var failure: String?
        private(set) var appendedFrames = 0

        func set(ready: Bool) { lock.withLock { self.ready = ready } }
        func fail(_ reason: String) { lock.withLock { failure = reason } }
        var appended: Int { lock.withLock { appendedFrames } }

        var isReadyForMoreMediaData: Bool { lock.withLock { ready } }
        var terminalFailure: String? { lock.withLock { failure } }
        func append(_ buffer: CMSampleBuffer) -> Bool {
            lock.withLock { appendedFrames += CMSampleBufferGetNumSamples(buffer) }
            return true
        }
        func finish() async -> String? { terminalFailure }
        func cancel() {}
        func readBackFrames() async -> WrittenFrameCount { .decoded(appended) }
    }

    private func scriptedTrack(_ sink: ScriptedSink) -> AudioTrackWriter {
        AudioTrackWriter(source: .microphone, url: directory.appendingPathComponent("scripted.mov"),
            start: seconds(0), pendingLimit: 2) { _, _ in sink }
    }

    func testABurstAgainstAStalledWriterHoldsAtMostTheLimitAndCountsTheRest() async throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 1, interleaved: true))
        let sink = ScriptedSink()
        let track = scriptedTrack(sink)
        for packet in 0..<10 {
            track.append(try AudioFixtures.buffer(format: format, frames: 22_050, start: Double(packet) / 2, seed: packet).0)
        }
        let held = track.currentCounts
        XCTAssertEqual(held.droppedOverflowFrames, 6 * 22_050, "two seconds held, the rest dropped on arrival")
        XCTAssertEqual(held.appendedFrames, 0)
        XCTAssertEqual(sink.appended, 0)

        sink.set(ready: true)
        for _ in 0..<400 where sink.appended < 4 * 22_050 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(sink.appended, 4 * 22_050, "waiting audio drains once the writer is ready, with no new buffer")
        let counts = await track.finish()
        XCTAssertEqual(counts.receivedFrames, 10 * 22_050)
        XCTAssertEqual(counts.appendedFrames, 4 * 22_050)
        XCTAssertEqual(counts.droppedOverflowFrames, 6 * 22_050)
        XCTAssertEqual(counts.written, .decoded(4 * 22_050))
    }

    func testAWriterThatFailsWhileAudioWaitsEndsFinishAndCountsTheAudio() async throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 1, interleaved: true))
        let sink = ScriptedSink()
        let track = scriptedTrack(sink)
        track.append(try AudioFixtures.buffer(format: format, frames: 4410, start: 0, seed: 1).0)
        track.append(try AudioFixtures.buffer(format: format, frames: 4410, start: 0.1, seed: 2).0)
        _ = track.currentCounts
        sink.fail("disk full")
        let counts = await track.finish()
        XCTAssertEqual(counts.writerFailure, "disk full")
        XCTAssertEqual(counts.rejectedAppendFrames, 8820)
        XCTAssertEqual(counts.appendedFrames, 0)
        XCTAssertEqual(counts.written, .noFramesAppended)
        track.append(try AudioFixtures.buffer(format: format, frames: 4410, start: 0.2, seed: 3).0)
        let again = await track.finish()
        XCTAssertEqual(again, counts)
    }

    func testBuffersHandedOverWhileFinishingAreEitherWrittenOrCountedAndNothingChangesAfter() async throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 1, interleaved: true))
        let sink = ScriptedSink()
        sink.set(ready: true)
        let track = scriptedTrack(sink)
        let buffers = try (0..<200).map { try AudioFixtures.buffer(format: format, frames: 441, start: Double($0) / 100, seed: $0).0 }
        let batch = Batch(buffers)
        let sending = Task.detached {
            for buffer in batch.buffers { track.append(buffer) }
        }
        try await Task.sleep(nanoseconds: 1_000_000)
        let counts = await track.finish()
        await sending.value

        XCTAssertEqual(counts.appendedFrames + counts.droppedOverflowFrames + counts.rejectedAppendFrames, counts.receivedFrames,
            "every buffer taken in is written or counted")
        XCTAssertEqual(sink.appended, counts.appendedFrames)
        XCTAssertEqual(track.currentCounts, counts)
        for buffer in buffers.prefix(3) { track.append(buffer) }
        XCTAssertEqual(track.currentCounts, counts, "nothing is taken in after finish")
        let again = await track.finish()
        XCTAssertEqual(again, counts)
    }

    func testDropsAreCountedOnceAndNotAfterFinish() async throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 1, interleaved: true))
        let track = writer(pendingLimit: 0)
        track.append(try AudioFixtures.buffer(format: format, frames: 441, start: 10, seed: 1).0)
        let counts = await track.finish()
        XCTAssertEqual(counts.droppedOverflowFrames, 441)
        XCTAssertEqual(track.currentCounts, counts)
        track.append(try AudioFixtures.buffer(format: format, frames: 441, start: 11, seed: 1).0)
        XCTAssertEqual(track.currentCounts, counts)
        XCTAssertEqual(track.currentCounts.droppedOverflowFrames, 441)
    }

    func testATrackThatReceivedNothingWritesNoFile() async {
        let track = writer()
        let counts = await track.finish()
        XCTAssertEqual(counts, AudioTrackCounts(written: .noFramesAppended))
        XCTAssertFalse(FileManager.default.fileExists(atPath: track.url.path))
    }

    func testOverlappingFinishesShareOneResultAndLaterBuffersAreIgnored() async throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 1, interleaved: true))
        let track = writer()
        track.append(try AudioFixtures.buffer(format: format, frames: 441, start: 10, seed: 1).0)
        async let a = track.finish()
        async let b = track.finish()
        let (first, second) = await (a, b)
        XCTAssertEqual(first, second)
        track.append(try AudioFixtures.buffer(format: format, frames: 441, start: 11, seed: 1).0)
        let third = await track.finish()
        XCTAssertEqual(third, first)
        XCTAssertEqual(first.written, .decoded(441))
    }
}

/// Buffers handed to another thread; they are only read there.
private final class Batch: @unchecked Sendable {
    let buffers: [CMSampleBuffer]
    init(_ buffers: [CMSampleBuffer]) { self.buffers = buffers }
}
