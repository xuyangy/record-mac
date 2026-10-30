@preconcurrency import AVFoundation
import CoreMedia
@preconcurrency import ScreenCaptureKit
import XCTest
@testable import RecordMac

/// The stream router with synthetic buffers and the real writers on temporary files. The sync
/// clock is the host clock, so a buffer's timestamp is its host time; the epoch is host 1000 s.
/// No stream, device, or permission is used.
final class CaptureStreamRouterTests: XCTestCase {
    private final class MovieFactory: ScreenSegmentFileFactory, @unchecked Sendable {
        let directory: URL
        init(directory: URL) { self.directory = directory }

        func makeFile(index: Int, format: ScreenFrameFormat, start: CMTime) throws -> ScreenSegmentFile {
            let fileRef = "screen-\(index).mov"
            let writer = try AssetScreenSampleWriter(
                url: directory.appendingPathComponent(fileRef),
                outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: format.width, AVVideoHeightKey: format.height],
                startTime: start)
            return ScreenSegmentFile(writer: writer, fileRef: fileRef, hasAlpha: false)
        }
    }

    private let epoch = 1000.0
    private var directory: URL!
    private var clock: CaptureClock!
    private var screen: ScreenSegmentWriter!
    private var queue: DispatchQueue!

    private let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 1, interleaved: true)!
    private let systemFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("router-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        clock = CaptureClock(epochHostTime: host(epoch))
        screen = ScreenSegmentWriter(factory: MovieFactory(directory: directory), deviceID: "display:1", frameRate: 60)
        queue = DispatchQueue(label: "router-test.samples")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func host(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }

    private func writers(_ sources: Set<AudioCaptureSource>) -> AudioSourceWriters {
        AudioSourceWriters(sources: sources, start: .zero) { self.directory.appendingPathComponent("\($0.rawValue).mov") }
    }

    private func router(_ audio: AudioSourceWriters, syncClock: CMClock? = CaptureClock.hostClock) -> CaptureStreamRouter {
        CaptureStreamRouter(clock: clock, syncClock: { syncClock }, screen: screen, audio: audio, queue: queue)
    }

    /// As ScreenCaptureKit calls the output: on the sample queue, in order.
    private func deliver(_ router: CaptureStreamRouter, _ buffer: CMSampleBuffer, _ type: SCStreamOutputType) {
        nonisolated(unsafe) let buffer = buffer
        queue.async { router.receive(buffer, of: type) }
    }

    // MARK: - Buffers

    private func setStatus(_ status: SCFrameStatus, overlay: CGRect? = nil, on buffer: CMSampleBuffer) throws {
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true))
        let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)
        first[SCStreamFrameInfo.status.rawValue] = status.rawValue
        if let overlay {
            first[SCStreamFrameInfo.presenterOverlayContentRect.rawValue] = overlay.dictionaryRepresentation
        }
    }

    private func frame(at seconds: Double, width: Int = 64, height: Int = 64, status: SCFrameStatus = .complete,
                       overlay: CGRect? = nil) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
        let image = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image), 128, CVPixelBufferGetDataSize(image))
        CVPixelBufferUnlockBaseAddress(image, [])
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &description)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: host(seconds), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
            formatDescription: try XCTUnwrap(description), sampleTiming: &timing, sampleBufferOut: &sample)
        let buffer = try XCTUnwrap(sample)
        try setStatus(status, overlay: overlay, on: buffer)
        return buffer
    }

    /// A screen buffer with timing and a status but no image, as ScreenCaptureKit sends for idle
    /// frames.
    private func imageless(at time: CMTime, status: SCFrameStatus) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: nil, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        let buffer = try XCTUnwrap(sample)
        try setStatus(status, on: buffer)
        return buffer
    }

    /// A tenth of a second of audio starting at host `seconds`.
    private func packet(_ format: AVAudioFormat, at seconds: Double, seed: Int) throws -> (CMSampleBuffer, Data) {
        try AudioFixtures.buffer(format: format, frames: Int(format.sampleRate) / 10, start: seconds, seed: seed)
    }

    // MARK: - Routes

    func testEachRouteWritesItsOwnSourceOnTheSessionClockAndAudioBeforeTheFirstFrameIsKept() async throws {
        let audio = writers([.microphone, .systemAudio])
        let router = router(audio)
        var micBytes = Data()
        var systemBytes = Data()
        for index in 0..<3 {
            let start = epoch + Double(index) / 10
            let (mic, micData) = try packet(micFormat, at: start, seed: 11)
            let (system, systemData) = try packet(systemFormat, at: start, seed: 57)
            deliver(router, mic, .microphone)
            deliver(router, system, .audio)
            micBytes.append(micData)
            systemBytes.append(systemData)
            if index > 0 { deliver(router, try frame(at: start), .screen) }
        }

        let report = await router.close()
        let screenOutcome = await screen.finish(at: CMTime(seconds: 0.3, preferredTimescale: 600))
        let audioOutcome = await audio.finish()

        XCTAssertEqual(report, CaptureStreamRouterReport(audio: [.microphone: .init(), .systemAudio: .init()]))
        XCTAssertEqual(screenOutcome.segments.count, 1)
        XCTAssertEqual(screenOutcome.segments[0].start.seconds, 0.1, accuracy: 1e-9, "the screen starts at its own first frame")
        XCTAssertEqual(screenOutcome.segments[0].frames.written, .decoded(2))
        let mic = try await AudioFixtures.read(try XCTUnwrap(audio.writer(for: .microphone)).url)
        let system = try await AudioFixtures.read(try XCTUnwrap(audio.writer(for: .systemAudio)).url)
        XCTAssertEqual(mic.firstTime, 0, accuracy: 1e-9, "audio before the first screen frame keeps its offset")
        XCTAssertEqual(mic.format.mSampleRate, 44_100)
        XCTAssertEqual(mic.bytes, micBytes, "only microphone samples, unchanged")
        XCTAssertEqual(system.format.mChannelsPerFrame, 2)
        XCTAssertEqual(system.bytes, systemBytes, "only system audio samples, unchanged")
        XCTAssertEqual(audioOutcome[.microphone]?.written, .decoded(13_230))
        XCTAssertEqual(audioOutcome[.systemAudio]?.written, .decoded(14_400))
    }

    func testAPauseLeavesOutScreenAndAudioInsideItAcrossPacketEdges() async throws {
        XCTAssertTrue(clock.pause(atHostTime: host(epoch + 0.25)))
        XCTAssertTrue(clock.resume(atHostTime: host(epoch + 0.45)))
        let audio = writers([.systemAudio])
        let router = router(audio)
        var kept = Data()
        let half = 2400 * 8
        for index in 0..<6 {
            let (system, data) = try packet(systemFormat, at: epoch + Double(index) / 10, seed: 57)
            deliver(router, system, .audio)
            switch index {
            case 2: kept.append(data.prefix(half))
            case 3: break
            case 4: kept.append(data.suffix(half))
            default: kept.append(data)
            }
        }
        for seconds in [0.1, 0.3, 0.5] { deliver(router, try frame(at: epoch + seconds), .screen) }

        let report = await router.close()
        let screenOutcome = await screen.finish(at: CMTime(seconds: 0.4, preferredTimescale: 600))
        let audioOutcome = await audio.finish()

        XCTAssertEqual(report.screen.excluded, 1)
        XCTAssertEqual(report.audio[.systemAudio]?.excluded, 9600)
        XCTAssertEqual(report.audio[.systemAudio]?.failed, [:])
        XCTAssertEqual(screenOutcome.segments.first?.frames.written, .decoded(2))
        XCTAssertEqual(audioOutcome[.systemAudio]?.written, .decoded(19_200))
        let system = try await AudioFixtures.read(try XCTUnwrap(audio.writer(for: .systemAudio)).url)
        XCTAssertEqual(system.bytes, kept, "samples inside the pause are absent; the rest are unchanged")
    }

    func testAFormatChangeStartsASegmentAndIdleFramesAddNothing() async throws {
        let router = router(writers([]))
        deliver(router, try frame(at: epoch + 0.1), .screen)
        deliver(router, try imageless(at: host(epoch + 0.2), status: .idle), .screen)
        deliver(router, try frame(at: epoch + 0.3), .screen)
        deliver(router, try frame(at: epoch + 0.4, width: 128), .screen)
        deliver(router, try imageless(at: host(epoch + 0.5), status: .idle), .screen)

        let report = await router.close()
        let outcome = await screen.finish(at: CMTime(seconds: 0.6, preferredTimescale: 600))

        XCTAssertEqual(report.screenStatuses, [.idle: 2])
        XCTAssertEqual(outcome.segments.map(\.format.width), [64, 128])
        XCTAssertEqual(outcome.segments.map(\.start.seconds), [0.1, 0.4])
        XCTAssertEqual(outcome.segments.map(\.end.seconds), [0.4, 0.6], "the last frame is held to the end")
        XCTAssertEqual(outcome.segments.map(\.frames.written), [.decoded(2), .decoded(1)])
        XCTAssertEqual(FrameReport(segments: outcome.frames), FrameReport(delivered: 3, appendRejected: 0, writerFailed: 0, written: 3))
    }

    func testCompleteFramesWithOverlayMetadataOrNoImageReachTheScreenWriter() async throws {
        let router = router(writers([]))
        deliver(router, try frame(at: epoch + 0.1), .screen)
        deliver(router, try frame(at: epoch + 0.2, overlay: CGRect(x: 10, y: 10, width: 20, height: 20)), .screen)
        deliver(router, try imageless(at: host(epoch + 0.3), status: .complete), .screen)

        let report = await router.close()
        let outcome = await screen.finish(at: CMTime(seconds: 0.4, preferredTimescale: 600))

        XCTAssertEqual(report, CaptureStreamRouterReport())
        XCTAssertEqual(outcome.segments.first?.frames.delivered, 3)
        XCTAssertEqual(outcome.segments.first?.frames.appendRejected, 1, "the frame without an image is counted by the writer")
        XCTAssertEqual(outcome.segments.first?.frames.written, .decoded(2))
    }

    // MARK: - Failures and accounting

    func testRetimingFailuresAreCountedPerRouteWithReasonsAndReachNoWriter() async throws {
        let audio = writers([.microphone])
        let router = router(audio)
        deliver(router, try imageless(at: .invalid, status: .complete), .screen)
        let (mic, _) = try packet(micFormat, at: epoch, seed: 11)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44_100), presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var untimed: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: mic, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &untimed), noErr)
        deliver(router, try XCTUnwrap(untimed), .microphone)
        let (system, _) = try packet(systemFormat, at: epoch, seed: 57)
        deliver(router, system, .audio)

        let report = await router.close()
        let outcome = await screen.finish(at: CMTime(seconds: 0.1, preferredTimescale: 600))
        let audioOutcome = await audio.finish()

        XCTAssertEqual(report.screen.failed, ["invalid timing: the presentation timestamp is not numeric": 1])
        XCTAssertEqual(report.audio[.microphone]?.failed, ["invalid timing: the presentation timestamp is not numeric": 4410])
        XCTAssertNil(report.audio[.systemAudio], "an unselected source is ignored, not failed")
        XCTAssertEqual(outcome.segments.count, 0)
        XCTAssertEqual(audioOutcome[.microphone]?.receivedFrames, 0)
        let rejections = try XCTUnwrap(report.screenRejections)
        XCTAssertEqual(FrameReport(segments: outcome.frames + [rejections]),
            FrameReport(delivered: 1, appendRejected: 1, writerFailed: 0, written: 0))
    }

    func testWithoutASyncClockEveryBufferIsRefusedWithThatReason() async throws {
        let audio = writers([.systemAudio])
        let router = router(audio, syncClock: nil)
        deliver(router, try frame(at: epoch + 0.1), .screen)
        let (system, _) = try packet(systemFormat, at: epoch, seed: 57)
        deliver(router, system, .audio)

        let report = await router.close()

        XCTAssertEqual(report.screen.failed, ["the stream has no synchronization clock": 1])
        XCTAssertEqual(report.audio[.systemAudio]?.failed, ["the stream has no synchronization clock": 4800])
        _ = await screen.finish(at: .zero)
        _ = await audio.finish()
    }

    func testCloseRoutesEveryQueuedBufferInOrderAndNothingAfterIt() async throws {
        let audio = writers([.systemAudio])
        let router = router(audio)
        queue.suspend()
        for seconds in [0.1, 0.2, 0.3] { deliver(router, try frame(at: epoch + seconds), .screen) }
        let (system, _) = try packet(systemFormat, at: epoch, seed: 57)
        deliver(router, system, .audio)
        // Both closes are queued behind the buffers while the queue is held.
        async let first = router.close()
        async let second = router.close()
        try await Task.sleep(for: .milliseconds(50))
        queue.resume()
        let reports = await [first, second]
        deliver(router, try frame(at: epoch + 0.4), .screen)
        let (late, _) = try packet(systemFormat, at: epoch + 0.1, seed: 57)
        deliver(router, late, .audio)
        let afterLate = await router.close()

        XCTAssertEqual(reports[0], reports[1])
        XCTAssertEqual(reports[0].afterClose, 0)
        XCTAssertEqual(afterLate.afterClose, 2)
        let outcome = await screen.finish(at: CMTime(seconds: 0.5, preferredTimescale: 600))
        let audioOutcome = await audio.finish()
        XCTAssertEqual(outcome.segments.first?.frames.delivered, 3)
        XCTAssertEqual(outcome.segments.first?.frames.written, .decoded(3))
        XCTAssertEqual(outcome.segments.first?.end.seconds ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(audioOutcome[.systemAudio]?.written, .decoded(4800), "the late packet reached no writer")
    }

    func testTheFrameStatusIsReadFromScreenCaptureKitsAttachment() throws {
        XCTAssertEqual(CaptureStreamRouter.frameStatus(of: try frame(at: epoch, status: .complete)), .known(.complete))
        XCTAssertEqual(CaptureStreamRouter.frameStatus(of: try imageless(at: host(epoch), status: .idle)), .known(.idle))
        XCTAssertEqual(CaptureStreamRouter.frameStatus(of: try imageless(at: host(epoch), status: .suspended)), .known(.suspended))
        let (system, _) = try packet(systemFormat, at: epoch, seed: 57)
        XCTAssertEqual(CaptureStreamRouter.frameStatus(of: system), .missing)
    }

    func testAMissingOrUnknownStatusIsReportedApartAndNeverAsADeliveredFrame() async throws {
        let router = router(writers([]))
        let missing = try frame(at: epoch + 0.1)
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(missing, createIfNecessary: false))
        unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self).removeAllObjects()
        let unknown = try frame(at: epoch + 0.2)
        let unknownAttachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(unknown, createIfNecessary: false))
        unsafeBitCast(CFArrayGetValueAtIndex(unknownAttachments, 0), to: NSMutableDictionary.self)[SCStreamFrameInfo.status.rawValue] = 99
        deliver(router, missing, .screen)
        deliver(router, unknown, .screen)
        deliver(router, try imageless(at: .invalid, status: .complete), .screen)
        deliver(router, try imageless(at: host(epoch + 0.3), status: .blank), .screen)

        let report = await router.close()
        let outcome = await screen.finish(at: CMTime(seconds: 0.4, preferredTimescale: 600))

        XCTAssertEqual(report.screenUnknownStatuses, ["no frame status": 1, "unsupported frame status 99": 1])
        XCTAssertEqual(report.screenStatuses, [.blank: 1])
        XCTAssertEqual(report.screen.failedTotal, 1, "only the known complete frame")
        XCTAssertEqual(FrameReport(segments: outcome.frames + [try XCTUnwrap(report.screenRejections)]),
            FrameReport(delivered: 1, appendRejected: 1, writerFailed: 0, written: 0))
    }
}
