import AVFoundation
import VideoToolbox
import XCTest
@testable import RecordMac

/// Every codec on the software path, end to end: the session with hardware disabled reports a
/// software encoder, and the samples that same session produced are written unchanged to a movie
/// and decoded with AVFoundation. A codec with no software encoder fails with its reason; it is
/// never skipped or replaced by another codec.
final class EncoderFallbackTests: XCTestCase {
    private let width = 320
    private let height = 240
    private let frameRate = 30
    private let frameCount = 10

    func testH264EncodesAndDecodesInSoftware() async throws {
        try await assertSoftwareRoundTrip(.h264)
    }

    func testHEVCEncodesAndDecodesInSoftware() async throws {
        try await assertSoftwareRoundTrip(.hevc)
    }

    func testHEVCWithAlphaEncodesAndDecodesInSoftware() async throws {
        try await assertSoftwareRoundTrip(.hevcWithAlpha)
    }

    func testProRes422EncodesAndDecodesInSoftware() async throws {
        try await assertSoftwareRoundTrip(.proRes422)
    }

    func testProRes4444EncodesAndDecodesInSoftware() async throws {
        try await assertSoftwareRoundTrip(.proRes4444)
    }

    private func assertSoftwareRoundTrip(_ codec: EncoderCodec) async throws {
        let format = EncoderFormat(codec: codec, width: width, height: height, frameRate: frameRate)
        let context = "\(codec.rawValue) \(width)x\(height) \(frameRate) fps on \(ProcessInfo.processInfo.operatingSystemVersionString)"
        let probe = VideoToolboxEncoderProbe(frameCount: frameCount)
        let (outcome, samples) = probe.encodeKeepingSamples(format, on: .software)
        guard case .encoded(let usingHardware, let encoderID) = outcome else {
            return XCTFail("no software encoder for \(context): \(outcome)")
        }
        XCTAssertFalse(usingHardware, "\(context): \(encoderID) reported hardware")
        print("encoder fallback: \(context) -> \(encoderID)")

        XCTAssertEqual(samples.count, frameCount, context)
        let formatDescription = try XCTUnwrap(samples.first?.formatDescription, context)
        assertStoredCodec(formatDescription, codec: codec, context: "\(context): encoded")

        let movie = FileManager.default.temporaryDirectory
            .appendingPathComponent("encoder-fallback-\(codec.rawValue)-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: movie) }
        try await writePassThrough(samples, hint: formatDescription, to: movie)

        let decoded = try await decode(movie, codec: codec, context: context)
        XCTAssertEqual(decoded.count, frameCount, "\(context): decoded frames")
        for (index, frame) in decoded.enumerated() {
            XCTAssertEqual(frame.time, CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate)),
                           "\(context): frame \(index) time")
            XCTAssertEqual(frame.width, width, "\(context): frame \(index) width")
            XCTAssertEqual(frame.height, height, "\(context): frame \(index) height")
            assertSignal(frame, index: index, hasAlpha: codec.hasAlpha, context: context)
        }
    }

    /// The codec on the encoded content. HEVC with alpha selects its encoder by its own codec
    /// type but is stored as HEVC flagged as containing alpha (`CMFormatDescription.h`).
    private func assertStoredCodec(_ description: CMFormatDescription, codec: EncoderCodec, context: String) {
        let containsAlpha = CMFormatDescriptionGetExtension(
            description, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel) as? Bool
        if codec == .hevcWithAlpha {
            XCTAssertEqual(description.mediaSubType.rawValue, kCMVideoCodecType_HEVC, "\(context) codec")
            XCTAssertEqual(containsAlpha, true, "\(context) alpha flag")
        } else {
            XCTAssertEqual(description.mediaSubType.rawValue, codec.codecType, "\(context) codec")
        }
    }

    /// Writes the encoded samples without processing them: an input with no output settings
    /// passes appended samples through.
    private func writePassThrough(
        _ samples: [CMSampleBuffer], hint: CMFormatDescription, to url: URL
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        input.expectsMediaDataInRealTime = false
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), "start writing: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        for (index, sample) in samples.enumerated() {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData {
                guard Date() < deadline else { throw FallbackTestError("input not ready for sample \(index)") }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard input.append(sample) else {
                throw FallbackTestError("append of sample \(index) failed: \(String(describing: writer.error))")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw FallbackTestError("writer ended \(writer.status.rawValue): \(String(describing: writer.error))")
        }
    }

    private struct DecodedFrame {
        let time: CMTime
        let width: Int
        let height: Int
        /// The blue, green, red, and alpha bytes at the centre column of each sampled row.
        let rows: [Int: [UInt8]]
    }

    private func decode(_ url: URL, codec: EncoderCodec, context: String) async throws -> [DecodedFrame] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let trackFormats = try await track.load(.formatDescriptions)
        XCTAssertEqual(trackFormats.count, 1, "\(context): stored formats")
        for description in trackFormats {
            assertStoredCodec(description, codec: codec, context: "\(context): stored")
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading(), "start reading: \(String(describing: reader.error))")
        var frames: [DecodedFrame] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let image = sample.imageBuffer else { continue }
            frames.append(read(image, time: sample.presentationTimeStamp))
        }
        guard reader.status == .completed else {
            throw FallbackTestError("reader ended \(reader.status.rawValue): \(String(describing: reader.error))")
        }
        return frames
    }

    private func read(_ image: CVPixelBuffer, time: CMTime) -> DecodedFrame {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        var rows: [Int: [UInt8]] = [:]
        if let base = CVPixelBufferGetBaseAddress(image) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(image)
            for row in stride(from: 0, to: height, by: 8) {
                let pixel = base.advanced(by: row * bytesPerRow + (width / 2) * 4)
                    .assumingMemoryBound(to: UInt8.self)
                rows[row] = (0..<4).map { pixel[$0] }
            }
        }
        return DecodedFrame(time: time, width: width, height: height, rows: rows)
    }

    /// The probe fills every byte of row `r` in frame `f` with `(r + 37 f) mod 256`. Away from the
    /// wrap, where compression smears the step, each decoded colour channel must be near that
    /// value, and so must alpha for a codec that keeps it, so blank or unrelated output fails.
    private func assertSignal(_ frame: DecodedFrame, index: Int, hasAlpha: Bool, context: String) {
        var checked = 0
        for (row, bgra) in frame.rows.sorted(by: { $0.key < $1.key }) {
            let expected = (row + index * 37) & 0xFF
            guard (24...231).contains(expected) else { continue }
            checked += 1
            for channel in 0..<(hasAlpha ? 4 : 3) {
                XCTAssertLessThanOrEqual(
                    abs(Int(bgra[channel]) - expected), 12,
                    "\(context): frame \(index) row \(row) channel \(channel) is \(bgra[channel]), expected \(expected)")
            }
        }
        XCTAssertGreaterThan(checked, 0, "\(context): frame \(index) had no rows to check")
    }
}

private extension EncoderCodec {
    var hasAlpha: Bool { self == .hevcWithAlpha || self == .proRes4444 }
}

private struct FallbackTestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
