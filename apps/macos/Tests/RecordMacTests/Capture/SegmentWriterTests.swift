import AVFoundation
import CoreMedia
import XCTest
@testable import RecordMac

final class SegmentWriterTests: XCTestCase {
    private static let bgra = kCVPixelFormatType_32BGRA
    private static let yuv = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    /// Opens real H.264 files at each segment's native size in a temporary directory.
    private final class MovieFactory: ScreenSegmentFileFactory, @unchecked Sendable {
        let directory: URL
        var failingFormats: Set<ScreenFrameFormat> = []
        private(set) var opened: [(index: Int, format: ScreenFrameFormat, start: CMTime)] = []

        init(directory: URL) { self.directory = directory }

        func makeFile(index: Int, format: ScreenFrameFormat, start: CMTime) throws -> ScreenSegmentFile {
            opened.append((index, format, start))
            if failingFormats.contains(format) { throw CocoaError(.fileWriteNoPermission) }
            let fileRef = "screen-\(index).mov"
            let writer = try AssetScreenSampleWriter(
                url: directory.appendingPathComponent(fileRef),
                outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: format.width, AVVideoHeightKey: format.height],
                startTime: start)
            return ScreenSegmentFile(writer: writer, fileRef: fileRef, hasAlpha: false)
        }
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("segments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

    private func frame(at seconds: Double, width: Int = 64, height: Int = 64, format: OSType = bgra) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        if CVPixelBufferIsPlanar(buffer) {
            for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
                memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), 128,
                    CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
            }
        } else {
            memset(CVPixelBufferGetBaseAddress(buffer), 128, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &description)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time(seconds), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
            formatDescription: try XCTUnwrap(description), sampleTiming: &timing, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }

    private func makeWriter(_ factory: ScreenSegmentFileFactory) -> ScreenSegmentWriter {
        ScreenSegmentWriter(factory: factory, deviceID: "display:1", frameRate: 60)
    }

    /// The file's duration, its first sample's presentation time, and its frame size.
    private func describe(_ fileRef: String) async throws -> (duration: Double, firstTime: Double, size: CGSize) {
        let asset = AVURLAsset(url: directory.appendingPathComponent(fileRef))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var first: Double?
        while let sample = output.copyNextSampleBuffer() {
            guard sample.numSamples > 0 else { continue }
            if first == nil { first = sample.presentationTimeStamp.seconds }
        }
        let duration = try await asset.load(.duration).seconds
        return (duration, try XCTUnwrap(first), size)
    }

    // MARK: Format changes

    func testASizeChangeStartsANewSegmentAtTheNewNativeSize() async throws {
        let factory = MovieFactory(directory: directory)
        let writer = makeWriter(factory)
        writer.receive(try frame(at: 0), status: .complete)
        writer.receive(try frame(at: 1), status: .complete)
        writer.receive(try frame(at: 2, width: 96, height: 48), status: .complete)
        writer.receive(try frame(at: 2.5, width: 96, height: 48), status: .idle)
        let outcomes = await writer.finish(at: time(3)).segments

        XCTAssertEqual(outcomes.map(\.start.seconds), [0, 2])
        XCTAssertEqual(outcomes.map(\.end.seconds), [2, 3])
        XCTAssertEqual(outcomes.map { $0.segment?.nativeSize }, [PixelSize(width: 64, height: 64), PixelSize(width: 96, height: 48)])
        XCTAssertEqual(outcomes.map(\.frames.written), [.decoded(2), .decoded(1)])
        XCTAssertEqual(outcomes.map { $0.segment?.frameRate }, [60, 60])

        let first = try await describe("screen-0.mov")
        XCTAssertEqual(first.duration, 2, accuracy: 0.01)
        XCTAssertEqual(first.size, CGSize(width: 64, height: 64))
        let second = try await describe("screen-1.mov")
        XCTAssertEqual(second.duration, 1, accuracy: 0.01, "the file lasts the segment's start to end")
        XCTAssertEqual(second.firstTime, 0, accuracy: 0.01, "the file's own timeline starts at its segment's start")
        XCTAssertEqual(try XCTUnwrap(outcomes[1].segment?.start) + second.firstTime, 2, accuracy: 0.01,
            "the segment's start places the file on the session clock")
        XCTAssertEqual(second.size, CGSize(width: 96, height: 48), "not scaled to the first segment's size")

        let track = MediaTrack(screenSegments: outcomes, requestedFrameRate: 60)
        XCTAssertNoThrow(try track.validate())
        XCTAssertEqual(FrameReport(segments: outcomes.map(\.frames)), FrameReport(delivered: 3, appendRejected: 0, writerFailed: 0, written: 3))
    }

    func testAPixelFormatChangeAloneStartsANewSegment() async throws {
        let factory = MovieFactory(directory: directory)
        let writer = makeWriter(factory)
        writer.receive(try frame(at: 0, format: Self.bgra), status: .complete)
        writer.receive(try frame(at: 1, format: Self.yuv), status: .complete)
        let outcomes = await writer.finish(at: time(2)).segments
        XCTAssertEqual(factory.opened.map(\.format.pixelFormat), [Self.bgra, Self.yuv])
        XCTAssertEqual(outcomes.map(\.end.seconds), [1, 2])
        XCTAssertEqual(outcomes.map(\.frames.written), [.decoded(1), .decoded(1)])
    }

    // MARK: Gaps

    func testAnUnavailableSourceLeavesAGapAndTheFrameIsNotHeldAcrossIt() async throws {
        let writer = makeWriter(MovieFactory(directory: directory))
        writer.receive(try frame(at: 0), status: .complete)
        writer.sourceUnavailable(at: time(1.5))
        writer.receive(try frame(at: 2.5), status: .complete)
        let outcomes = await writer.finish(at: time(3)).segments

        XCTAssertEqual(outcomes.map(\.start.seconds), [0, 2.5])
        XCTAssertEqual(outcomes.map(\.end.seconds), [1.5, 3], "the gap from 1.5 to 2.5 s belongs to no segment")
        let first = try await describe("screen-0.mov")
        XCTAssertEqual(first.duration, 1.5, accuracy: 0.01)
        XCTAssertNoThrow(try MediaTrack(screenSegments: outcomes, requestedFrameRate: 60).validate())
    }

    func testASourceThatDisappearsEndsItsSegmentThere() async throws {
        let writer = makeWriter(MovieFactory(directory: directory))
        writer.receive(try frame(at: 0), status: .complete)
        writer.sourceUnavailable(at: time(1))
        let outcomes = await writer.finish(at: time(3)).segments
        XCTAssertEqual(outcomes.map(\.end.seconds), [1])
    }

    func testALongUnchangedStretchIsNotAGap() async throws {
        let writer = makeWriter(MovieFactory(directory: directory))
        writer.receive(try frame(at: 0), status: .complete)
        for second in 1...4 { writer.receive(try frame(at: Double(second)), status: .idle) }
        writer.receive(try frame(at: 5), status: .complete)
        let outcomes = await writer.finish(at: time(6)).segments
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.frames.written, .decoded(2))
    }

    // MARK: Failures and order

    func testAFormatWithNoWriterIsCountedAsRejectedWithItsReason() async throws {
        let factory = MovieFactory(directory: directory)
        factory.failingFormats = [ScreenFrameFormat(width: 96, height: 48, pixelFormat: Self.bgra)]
        let writer = makeWriter(factory)
        writer.receive(try frame(at: 0), status: .complete)
        writer.receive(try frame(at: 1, width: 96, height: 48), status: .complete)
        writer.receive(try frame(at: 1.5, width: 96, height: 48), status: .complete)
        writer.receive(try frame(at: 2), status: .complete)
        let outcomes = await writer.finish(at: time(3)).segments

        XCTAssertEqual(outcomes.count, 3)
        XCTAssertNil(outcomes[1].segment)
        XCTAssertEqual(outcomes[1].frames.delivered, 2)
        XCTAssertEqual(outcomes[1].frames.appendRejected, 2)
        XCTAssertTrue(outcomes[1].frames.writerFailure?.contains("96x48") == true)
        XCTAssertEqual(MediaTrack(screenSegments: outcomes, requestedFrameRate: 60).segments.count, 2)
        XCTAssertEqual(FrameReport(segments: outcomes.map(\.frames)), FrameReport(delivered: 4, appendRejected: 2, writerFailed: 0, written: 2))
    }

    /// A writer whose finish waits until the test releases it.
    private final class HeldWriter: ScreenSampleWriting, @unchecked Sendable {
        let release = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        var isReadyForMoreMediaData: Bool { true }
        func append(_ sampleBuffer: CMSampleBuffer) -> Bool { true }
        func finish(endingAt endTime: CMTime) async -> String? {
            entered.signal()
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async { [release] in
                    release.wait()
                    continuation.resume()
                }
            }
            return nil
        }
        func decodedFrameCount() async -> WrittenFrameCount { .decoded(1) }
    }

    private final class HeldFactory: ScreenSegmentFileFactory, @unchecked Sendable {
        let first = HeldWriter()
        func makeFile(index: Int, format: ScreenFrameFormat, start: CMTime) throws -> ScreenSegmentFile {
            ScreenSegmentFile(writer: index == 0 ? first : HeldWriterReleased(), fileRef: "screen-\(index).mov", hasAlpha: false)
        }
    }

    private final class HeldWriterReleased: ScreenSampleWriting, @unchecked Sendable {
        var isReadyForMoreMediaData: Bool { true }
        func append(_ sampleBuffer: CMSampleBuffer) -> Bool { true }
        func finish(endingAt endTime: CMTime) async -> String? { nil }
        func decodedFrameCount() async -> WrittenFrameCount { .decoded(1) }
    }

    func testFinishWaitsForASlowerEarlierSegmentAndKeepsTheOrder() async throws {
        let factory = HeldFactory()
        let writer = makeWriter(factory)
        writer.receive(try frame(at: 0), status: .complete)
        writer.receive(try frame(at: 1, width: 96, height: 48), status: .complete)
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [entered = factory.first.entered] in
                entered.wait()
                continuation.resume()
            }
        }
        let end = time(2)
        let finishing = Task { await writer.finish(at: end).segments }
        try await Task.sleep(nanoseconds: 50_000_000)
        factory.first.release.signal()
        let outcomes = await finishing.value
        XCTAssertEqual(outcomes.map(\.start.seconds), [0, 1])
        XCTAssertEqual(outcomes.map(\.frames.written), [.decoded(1), .decoded(1)])
    }

    /// A complete frame with no image, as a malformed delivery would be.
    private func imageless(at seconds: Double) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time(seconds), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: nil, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }

    func testCompleteFramesWithoutAnImageAreCountedEvenWithNoSegmentOpen() async throws {
        let factory = MovieFactory(directory: directory)
        let writer = makeWriter(factory)
        writer.receive(try imageless(at: 0), status: .complete)
        writer.receive(try frame(at: 1), status: .complete)
        writer.receive(try imageless(at: 1.5), status: .complete)
        writer.sourceUnavailable(at: time(2))
        writer.receive(try imageless(at: 2.5), status: .complete)
        let result = await writer.finish(at: time(3))

        XCTAssertEqual(factory.opened.count, 1, "no file for a frame with no image")
        XCTAssertEqual(result.unassigned.delivered, 2)
        XCTAssertEqual(result.unassigned.appendRejected, 2)
        XCTAssertEqual(result.segments.first?.frames.delivered, 2)
        XCTAssertEqual(result.segments.first?.frames.appendRejected, 1)
        XCTAssertEqual(FrameReport(segments: result.frames), FrameReport(delivered: 4, appendRejected: 3, writerFailed: 0, written: 1))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, ["screen-0.mov"])
    }

    /// Every writer's finish is held until the test releases them all.
    private final class AllHeldFactory: ScreenSegmentFileFactory, @unchecked Sendable {
        let release = DispatchSemaphore(value: 0)
        private(set) var opened: [(index: Int, start: CMTime)] = []
        func makeFile(index: Int, format: ScreenFrameFormat, start: CMTime) throws -> ScreenSegmentFile {
            opened.append((index, start))
            return ScreenSegmentFile(writer: GatedWriter(gate: release), fileRef: "screen-\(index).mov", hasAlpha: false)
        }
    }

    private final class GatedWriter: ScreenSampleWriting, @unchecked Sendable {
        let gate: DispatchSemaphore
        init(gate: DispatchSemaphore) { self.gate = gate }
        var isReadyForMoreMediaData: Bool { true }
        func append(_ sampleBuffer: CMSampleBuffer) -> Bool { true }
        func finish(endingAt endTime: CMTime) async -> String? {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async { [gate] in
                    gate.wait()
                    continuation.resume()
                }
            }
            return nil
        }
        func decodedFrameCount() async -> WrittenFrameCount { .decoded(1) }
    }

    func testRapidFormatChangesNeverOpenMoreFilesThanTheLimit() async throws {
        let factory = AllHeldFactory()
        let writer = ScreenSegmentWriter(factory: factory, deviceID: "display:1", frameRate: 60, maxOpenFiles: 2)
        writer.receive(try frame(at: 0, width: 64), status: .complete)
        writer.receive(try frame(at: 1, width: 80), status: .complete)
        XCTAssertEqual(writer.openFiles, 2)
        writer.receive(try frame(at: 2, width: 96), status: .complete)
        writer.receive(try frame(at: 3, width: 112), status: .complete)
        writer.receive(try frame(at: 3.5, width: 112), status: .complete)
        XCTAssertEqual(factory.opened.count, 2, "no third file while two are open")
        XCTAssertLessThanOrEqual(writer.openFiles, 2)

        factory.release.signal()
        while writer.openFiles > 1 { try await Task.sleep(nanoseconds: 5_000_000) }
        writer.receive(try frame(at: 4, width: 112), status: .complete)
        XCTAssertEqual(factory.opened.map(\.start.seconds), [0, 1, 4], "a file opens again once one has finalised")
        for _ in 0..<3 { factory.release.signal() }
        let result = await writer.finish(at: time(5))

        XCTAssertEqual(result.segments.map(\.start.seconds), [0, 1, 2, 3, 4])
        XCTAssertEqual(result.segments.map(\.end.seconds), [1, 2, 3, 4, 5])
        XCTAssertEqual(result.segments.map { $0.segment == nil }, [false, false, true, true, false])
        let saturated = result.segments[2...3]
        XCTAssertTrue(saturated.allSatisfy { $0.frames.writerFailure?.contains("still open") == true })
        XCTAssertEqual(saturated.map(\.frames.delivered), [1, 2])
        XCTAssertEqual(saturated.map(\.frames.appendRejected), [1, 2])
        for _ in 0..<5 { factory.release.signal() }
    }

    func testFramesAfterFinishAreIgnoredAndNonCompleteFramesOpenNothing() async throws {
        let factory = MovieFactory(directory: directory)
        let writer = makeWriter(factory)
        writer.receive(try frame(at: 0), status: .idle)
        writer.receive(try frame(at: 0.5), status: .blank)
        XCTAssertTrue(factory.opened.isEmpty)
        writer.receive(try frame(at: 1), status: .complete)
        let outcomes = await writer.finish(at: time(2)).segments
        writer.receive(try frame(at: 3, width: 96, height: 48), status: .complete)
        XCTAssertEqual(factory.opened.count, 1)
        XCTAssertEqual(outcomes.map(\.start.seconds), [1])
        let again = await writer.finish(at: time(5)).segments
        XCTAssertEqual(again, outcomes)
    }
}
