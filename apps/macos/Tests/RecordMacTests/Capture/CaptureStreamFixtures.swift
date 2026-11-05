@preconcurrency import AVFoundation
import CoreMedia
@preconcurrency import ScreenCaptureKit
import XCTest
@testable import RecordMac

struct FakeCaptureStreamFailure: Error, CustomStringConvertible {
    var description: String
}

/// A stand-in for a ScreenCaptureKit stream: it delivers the synthetic buffers a test gives it on
/// the queue each output was added with. Its sync clock is the host clock.
final class FakeCaptureStream: CaptureStreaming, @unchecked Sendable {
    /// Nil until capture starts when `clockAfterStart` is set, as a stream may have none before.
    var clockAfterStart = false
    var synchronizationClock: CMClock? { clockAfterStart && !started ? nil : CaptureClock.hostClock }
    /// Runs inside `stopCapture`, which returns or throws only once what it delivered has been
    /// routed: the stream still delivering while it stops.
    var whileStopping: (() throws -> Void)?
    var outputs: [(router: CaptureStreamRouter, type: SCStreamOutputType, queue: DispatchQueue)] = []
    var failingOutput: SCStreamOutputType?
    var failStart = false
    var failStop = false
    var started = false
    var stopCalls = 0

    func addOutput(_ output: CaptureStreamRouter, type: SCStreamOutputType, queue: DispatchQueue) throws {
        if type == failingOutput { throw FakeCaptureStreamFailure(description: "output \(type.rawValue) refused") }
        outputs.append((output, type, queue))
    }

    func startCapture() async throws {
        if failStart { throw FakeCaptureStreamFailure(description: "the stream did not start") }
        started = true
    }

    func stopCapture() async throws {
        stopCalls += 1
        if let whileStopping {
            try whileStopping()
            outputs.first?.queue.sync {}
        }
        if failStop { throw FakeCaptureStreamFailure(description: "the stream did not stop") }
    }

    /// As ScreenCaptureKit delivers: on the output's own queue.
    func deliver(_ buffer: CMSampleBuffer, _ type: SCStreamOutputType) {
        guard let output = outputs.first(where: { $0.type == type }) else { return }
        nonisolated(unsafe) let buffer = buffer
        output.queue.async { output.router.receive(buffer, of: type) }
    }
}

enum ScreenFrameFixtures {
    /// A complete 32BGRA screen frame stamped at `seconds` of host time.
        static func frame(atHostSeconds seconds: Double, width: Int = 256, height: Int = 144) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
        let image = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image), 90, CVPixelBufferGetDataSize(image))
        CVPixelBufferUnlockBaseAddress(image, [])
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &description)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64((seconds * 48_000).rounded()), timescale: 48_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
            formatDescription: try XCTUnwrap(description), sampleTiming: &timing, sampleBufferOut: &sample)
        let buffer = try XCTUnwrap(sample)
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true))
        unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: NSMutableDictionary.self)[SCStreamFrameInfo.status.rawValue] =
            SCFrameStatus.complete.rawValue
        return buffer
    }
}
