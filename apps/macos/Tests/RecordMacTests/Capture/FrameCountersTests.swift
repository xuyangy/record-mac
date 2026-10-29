import AVFoundation
import CoreMedia
import XCTest
@testable import RecordMac

final class FrameCountersTests: XCTestCase {
    /// A writer whose readiness, appends, finish, and count the test sets.
    private final class FakeWriter: ScreenSampleWriting, @unchecked Sendable {
        var ready = true
        var accepts = true
        var finishFailure: String?
        var count = WrittenFrameCount.decoded(0)
        private(set) var appended: [CMTime] = []
        private(set) var finishes = 0
        private(set) var decodes = 0
        /// When set, `finish` waits for it.
        var holdFinish: DispatchSemaphore?
        let finishEntered = DispatchSemaphore(value: 0)

        var isReadyForMoreMediaData: Bool { ready }

        func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
            guard accepts else { return false }
            appended.append(sampleBuffer.presentationTimeStamp)
            return true
        }

        func finish(endingAt endTime: CMTime) async -> String? {
            finishes += 1
            if let holdFinish {
                finishEntered.signal()
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async {
                        holdFinish.wait()
                        continuation.resume()
                    }
                }
            }
            return finishFailure
        }

        func decodedFrameCount() async -> WrittenFrameCount {
            decodes += 1
            return count
        }
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// A 64x64 BGRA frame at `seconds`, filled with `shade`.
    private func frame(at seconds: Double, shade: UInt8 = 128) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(shade), CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time(seconds), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescription: try XCTUnwrap(format),
            sampleTiming: &timing, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }

    private func realWriter() throws -> AssetScreenSampleWriter {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("frames-\(UUID().uuidString).mov")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try AssetScreenSampleWriter(url: url, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ], startTime: .zero)
    }

    /// Presentation time and duration of each sample in the file, and the file's duration.
    private func timing(of url: URL) async throws -> (samples: [(start: Double, duration: Double)], duration: Double) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [(Double, Double)] = []
        while let sample = output.copyNextSampleBuffer() {
            guard sample.numSamples > 0 else { continue }
            samples.append((sample.presentationTimeStamp.seconds, sample.duration.seconds))
        }
        let duration = try await asset.load(.duration).seconds
        return (samples, duration)
    }

    private func assertNear(_ actual: [Double], _ expected: [Double], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, "\(actual)", file: file, line: line)
        for (a, e) in zip(actual, expected) { XCTAssertEqual(a, e, accuracy: 0.01, "\(actual)", file: file, line: line) }
    }

    // MARK: Real writer

    func testAnUnchangedStretchHoldsTheFrameWithoutDuplicatingIt() async throws {
        let writer = try realWriter()
        let counter = ScreenFrameCounter(writer: writer)
        counter.receive(try frame(at: 0, shade: 40), status: .complete)
        counter.receive(try frame(at: 0.5), status: .idle)
        counter.receive(try frame(at: 0.75), status: .idle)
        counter.receive(try frame(at: 1, shade: 200), status: .complete)
        counter.receive(try frame(at: 1.5), status: .idle)
        let counts = await counter.finish(endingAt: time(2))

        XCTAssertEqual(counts, ScreenSegmentFrames(delivered: 2, appendRejected: 0, accepted: 2, writerFailure: nil, written: .decoded(2)))
        let timing = try await timing(of: writer.url)
        assertNear(timing.samples.map(\.start), [0, 1])
        assertNear(timing.samples.map(\.duration), [1, 1])
        XCTAssertEqual(timing.duration, 2, accuracy: 0.01, "the final hold lasts to the segment's end")
        XCTAssertEqual(FrameReport(segments: [counts]), FrameReport(delivered: 2, appendRejected: 0, writerFailed: 0, written: 2))
    }

    func testOneFrameThenNoChangeIsHeldToTheEnd() async throws {
        let writer = try realWriter()
        let counter = ScreenFrameCounter(writer: writer)
        counter.receive(try frame(at: 0), status: .complete)
        for second in 1...5 { counter.receive(try frame(at: Double(second) * 0.5), status: .idle) }
        let counts = await counter.finish(endingAt: time(3))
        XCTAssertEqual(counts.written, .decoded(1))
        let timing = try await timing(of: writer.url)
        assertNear(timing.samples.map(\.duration), [3])
        XCTAssertEqual(timing.duration, 3, accuracy: 0.01)
    }

    func testAStopWithoutATrailingIdleEndsAtTheGivenTime() async throws {
        let writer = try realWriter()
        let counter = ScreenFrameCounter(writer: writer)
        counter.receive(try frame(at: 0), status: .complete)
        counter.receive(try frame(at: 0.5), status: .complete)
        let counts = await counter.finish(endingAt: time(0.8))
        XCTAssertEqual(counts.written, .decoded(2))
        let timing = try await timing(of: writer.url)
        assertNear(timing.samples.map(\.duration), [0.5, 0.3])
        XCTAssertEqual(timing.duration, 0.8, accuracy: 0.01)
    }

    func testWithoutAnyCompleteFrameNoImageIsWritten() async throws {
        let writer = try realWriter()
        let counter = ScreenFrameCounter(writer: writer)
        counter.receive(try frame(at: 0), status: .idle)
        counter.receive(try frame(at: 0.5), status: .blank)
        let counts = await counter.finish(endingAt: time(1))
        XCTAssertEqual(counts.delivered, 0)
        XCTAssertEqual(counts.accepted, 0)
        XCTAssertEqual(counts.written, .noFramesAppended, "no image is invented")
        XCTAssertEqual(FrameReport(segments: [counts]), .empty)
    }

    // MARK: Counting rules

    func testOnlyCompleteFramesAreDeliveredOrWritten() async throws {
        let writer = FakeWriter()
        let counter = ScreenFrameCounter(writer: writer)
        for status in [ScreenFrameStatus.idle, .blank, .suspended, .started, .stopped] {
            counter.receive(try frame(at: 0), status: status)
        }
        counter.receive(try frame(at: 1), status: .complete)
        XCTAssertEqual(counter.counts.delivered, 1)
        XCTAssertEqual(writer.appended, [], "the frame waits for the next one or the end")
        _ = await counter.finish(endingAt: time(2))
        XCTAssertEqual(writer.appended, [time(1)])
    }

    func testAFrameTheInputIsNotReadyForIsShedAndOneItRefusesIsRejected() async throws {
        let writer = FakeWriter()
        let counter = ScreenFrameCounter(writer: writer)
        counter.receive(try frame(at: 0), status: .complete)
        writer.ready = false
        counter.receive(try frame(at: 1), status: .complete)
        writer.ready = true
        writer.accepts = false
        counter.receive(try frame(at: 2), status: .complete)
        writer.accepts = true
        writer.count = .decoded(1)
        let counts = await counter.finish(endingAt: time(3))
        XCTAssertEqual(counts, ScreenSegmentFrames(delivered: 3, appendRejected: 2, accepted: 1, written: .decoded(1)))
        XCTAssertEqual(writer.appended, [time(2)])
    }

    func testAWriterFailureCountsTheAcceptedFramesTheFileLacks() async throws {
        let writer = FakeWriter()
        writer.finishFailure = "disk full"
        writer.count = .decoded(1)
        let counter = ScreenFrameCounter(writer: writer)
        for second in 0..<3 { counter.receive(try frame(at: Double(second)), status: .complete) }
        let counts = await counter.finish(endingAt: time(3))
        XCTAssertEqual(counts.writerFailure, "disk full")
        XCTAssertEqual(counts.writerFailed, 2)
        XCTAssertNil(counts.unexplainedLoss)
        XCTAssertEqual(FrameReport(segments: [counts]), FrameReport(delivered: 3, appendRejected: 0, writerFailed: 2, written: 1))
    }

    func testAFileThatCannotBeCountedGivesNoReportButKeepsTheCounts() async throws {
        let writer = FakeWriter()
        writer.finishFailure = "finalisation failed"
        writer.count = .unavailable("no video track")
        let counter = ScreenFrameCounter(writer: writer)
        counter.receive(try frame(at: 0), status: .complete)
        let counts = await counter.finish(endingAt: time(1))
        XCTAssertEqual(counts.delivered, 1)
        XCTAssertEqual(counts.accepted, 1)
        XCTAssertEqual(counts.written, .unavailable("no video track"))
        XCTAssertNil(counts.writerFailed)
        XCTAssertNil(FrameReport(segments: [counts]), "no written count is made up")
    }

    func testALossWithoutAWriterFailureIsReportedAsUnexplained() async throws {
        let writer = FakeWriter()
        writer.count = .decoded(1)
        let counter = ScreenFrameCounter(writer: writer)
        counter.receive(try frame(at: 0), status: .complete)
        counter.receive(try frame(at: 1), status: .complete)
        let counts = await counter.finish(endingAt: time(2))
        XCTAssertEqual(counts.unexplainedLoss, 1)
        XCTAssertNil(counts.writerFailed)
        XCTAssertEqual(FrameReport(segments: [counts])?.writerFailed, 0, "the loss is not blamed on the writer")
    }

    func testFinishRunsOnceAndLaterFramesAreIgnored() async throws {
        let writer = FakeWriter()
        writer.count = .decoded(1)
        let counter = ScreenFrameCounter(writer: writer)
        counter.receive(try frame(at: 0), status: .complete)
        let first = await counter.finish(endingAt: time(1))
        counter.receive(try frame(at: 2), status: .complete)
        let second = await counter.finish(endingAt: time(3))
        XCTAssertEqual(first, second)
        XCTAssertEqual(writer.finishes, 1)
        XCTAssertEqual(second.delivered, 1)
    }

    func testAFinishCalledWhileAnotherIsUnderWayGetsTheSameFinalCounts() async throws {
        let writer = FakeWriter()
        writer.count = .decoded(1)
        writer.holdFinish = DispatchSemaphore(value: 0)
        let counter = ScreenFrameCounter(writer: writer)
        counter.receive(try frame(at: 0), status: .complete)
        let (end, laterEnd) = (time(1), time(5))
        let first = Task { await counter.finish(endingAt: end) }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                writer.finishEntered.wait()
                continuation.resume()
            }
        }
        let second = Task { await counter.finish(endingAt: laterEnd) }
        try await Task.sleep(nanoseconds: 50_000_000)
        writer.holdFinish?.signal()
        let (a, b) = await (first.value, second.value)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.written, .decoded(1))
        XCTAssertEqual(writer.finishes, 1)
        XCTAssertEqual(writer.decodes, 1)
    }

    func testAReportSumsEverySegment() {
        let segments = [
            ScreenSegmentFrames(delivered: 10, appendRejected: 1, accepted: 9, writerFailure: nil, written: .decoded(9)),
            ScreenSegmentFrames(delivered: 5, appendRejected: 0, accepted: 5, writerFailure: "failed", written: .decoded(3)),
        ]
        XCTAssertEqual(FrameReport(segments: segments), FrameReport(delivered: 15, appendRejected: 1, writerFailed: 2, written: 12))
        XCTAssertEqual(FrameReport(segments: []), .empty)
    }
}
