import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// The video codecs an export preset or capture writer can ask for (data-model.md ExportPreset).
enum EncoderCodec: String, CaseIterable, Codable, Sendable {
    case h264
    case hevc
    case hevcWithAlpha
    case proRes422
    case proRes4444

    var codecType: CMVideoCodecType {
        switch self {
        case .h264: kCMVideoCodecType_H264
        case .hevc: kCMVideoCodecType_HEVC
        case .hevcWithAlpha: kCMVideoCodecType_HEVCWithAlpha
        case .proRes422: kCMVideoCodecType_AppleProRes422
        case .proRes4444: kCMVideoCodecType_AppleProRes4444
        }
    }
}

/// One exact output format: an encoder that works at one size or rate is not assumed to work at
/// another (research.md R-006).
struct EncoderFormat: Hashable, Sendable {
    var codec: EncoderCodec
    var width: Int
    var height: Int
    var frameRate: Int
    /// The pixel format of the frames handed to the encoder.
    var sourcePixelFormat: OSType = kCVPixelFormatType_32BGRA
}

enum EncoderPath: String, Codable, Sendable {
    case hardware
    case software
}

/// The encoder chosen for a format, with the evidence that it encoded.
struct EncoderSelection: Equatable, Sendable {
    let format: EncoderFormat
    let path: EncoderPath
    /// The ID VideoToolbox reports for the encoder that ran.
    let encoderID: String
    let operatingSystemVersion: String
    /// Why hardware was not used, when the software encoder was chosen; the reduced capability
    /// reported to the creator (FR-071).
    let reduction: String?
}

enum EncoderSelectionError: Error, Equatable {
    /// Neither path encoded the format. Both reasons are kept so the failure is not silent.
    case noEncoder(EncoderFormat, hardwareFailure: String, softwareFailure: String)
}

/// The result of encoding a few frames of a format on one path.
enum EncoderProbeOutcome: Equatable, Sendable {
    case encoded(usingHardware: Bool, encoderID: String)
    case failed(String)
}

/// Encodes synthetic frames of an exact format on the hardware or the software path. The
/// selector depends on this seam so its policy can be tested without the encoders' behaviour.
protocol EncoderProbe: Sendable {
    func encode(_ format: EncoderFormat, on path: EncoderPath) -> EncoderProbeOutcome
}

/// Chooses an encoder per exact format: hardware when an encode with hardware required succeeds
/// and reports a hardware encoder, otherwise the software encoder selected explicitly, with the
/// reduction named (Principle III, FR-071, contracts/capture-engine.md guarantee 6).
struct EncoderSelector: Sendable {
    let probe: any EncoderProbe
    let operatingSystemVersion: String

    init(
        probe: any EncoderProbe = VideoToolboxEncoderProbe(),
        operatingSystemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) {
        self.probe = probe
        self.operatingSystemVersion = operatingSystemVersion
    }

    func select(_ format: EncoderFormat) throws -> EncoderSelection {
        let hardwareFailure: String
        switch probe.encode(format, on: .hardware) {
        case .encoded(usingHardware: true, let encoderID):
            return EncoderSelection(
                format: format, path: .hardware, encoderID: encoderID,
                operatingSystemVersion: operatingSystemVersion, reduction: nil)
        case .encoded(usingHardware: false, let encoderID):
            hardwareFailure = "encoder \(encoderID) ran without hardware although hardware was required"
        case .failed(let reason):
            hardwareFailure = reason
        }

        switch probe.encode(format, on: .software) {
        case .encoded(usingHardware: false, let encoderID):
            return EncoderSelection(
                format: format, path: .software, encoderID: encoderID,
                operatingSystemVersion: operatingSystemVersion,
                reduction: "hardware \(format.codec.rawValue) encode unavailable at \(format.width)x\(format.height) \(format.frameRate) fps: \(hardwareFailure)")
        case .encoded(usingHardware: true, let encoderID):
            throw EncoderSelectionError.noEncoder(
                format, hardwareFailure: hardwareFailure,
                softwareFailure: "encoder \(encoderID) used hardware although hardware was disabled")
        case .failed(let reason):
            throw EncoderSelectionError.noEncoder(
                format, hardwareFailure: hardwareFailure, softwareFailure: reason)
        }
    }
}

/// Probes with a VTCompressionSession: hardware required through
/// `RequireHardwareAcceleratedVideoEncoder`, or hardware disabled through
/// `EnableHardwareAcceleratedVideoEncoder = false`, with the expected frame rate and real-time
/// encoding hinted. A probe succeeds only when the session accepts every setting, every submitted
/// frame comes back encoded, and the session reports which encoder ran and whether it was
/// hardware. The evidence covers these settings only; a writer that sets a profile, bit rate, or
/// other compression property needs a probe with the same settings.
struct VideoToolboxEncoderProbe: EncoderProbe {
    /// A property read from a compression session: its status and, on success, its value.
    struct PropertyRead {
        let status: OSStatus
        let value: Any?
    }

    var frameCount = 3

    /// Why a format cannot be handed to VideoToolbox, which takes 32-bit sizes and timescales.
    static func invalidFormatReason(_ format: EncoderFormat) -> String? {
        guard format.width > 0, format.height > 0, format.frameRate > 0 else {
            return "size \(format.width)x\(format.height) and rate \(format.frameRate) must be positive"
        }
        guard Int32(exactly: format.width) != nil, Int32(exactly: format.height) != nil,
            Int32(exactly: format.frameRate) != nil
        else {
            return "size \(format.width)x\(format.height) or rate \(format.frameRate) exceeds 32 bits"
        }
        return nil
    }

    /// A compression property the probe sets. A hint only tunes how the encoder runs, so an
    /// encoder that does not support it (`kVTPropertyNotSupportedErr`) still encodes the format.
    struct Setting {
        let key: CFString
        let value: CFTypeRef
        let isHint: Bool
    }

    /// Applies each setting in order; the first one the session rejects is a failure naming its
    /// key and status, since an encode with that setting ignored would not test the format asked
    /// for. The one exception is a hint the encoder does not support.
    static func apply(
        _ settings: [Setting], using set: (CFString, CFTypeRef) -> OSStatus
    ) -> EncoderProbeOutcome? {
        for setting in settings {
            let status = set(setting.key, setting.value)
            if status == noErr || (setting.isHint && status == kVTPropertyNotSupportedErr) { continue }
            return .failed("setting \(setting.key) rejected (\(status))")
        }
        return nil
    }

    /// Whether hardware ran and the encoder ID are both required evidence: a read that fails, is
    /// missing, or has the wrong type is a failure. The one exception is the SDK's documented
    /// default: an encoder that does not support `UsingHardwareAcceleratedVideoEncoder`
    /// (`kVTPropertyNotSupportedErr`) is not using hardware, as `VTCompressionProperties.h`
    /// states the property is "assumed false by default". The software encoders on the
    /// reference machine report it that way.
    static func outcome(usingHardware: PropertyRead, encoderID: PropertyRead) -> EncoderProbeOutcome {
        let hardwareKey = kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder
        let isHardware: Bool
        switch usingHardware.status {
        case noErr:
            guard let value = usingHardware.value as? Bool else {
                return .failed("\(hardwareKey) is missing or not a Boolean")
            }
            isHardware = value
        case kVTPropertyNotSupportedErr:
            isHardware = false
        default:
            return .failed("reading \(hardwareKey) failed (\(usingHardware.status))")
        }
        guard encoderID.status == noErr else {
            return .failed("reading \(kVTCompressionPropertyKey_EncoderID) failed (\(encoderID.status))")
        }
        guard let identifier = encoderID.value as? String, !identifier.isEmpty else {
            return .failed("\(kVTCompressionPropertyKey_EncoderID) is missing or not a string")
        }
        return .encoded(usingHardware: isHardware, encoderID: identifier)
    }

    func encode(_ format: EncoderFormat, on path: EncoderPath) -> EncoderProbeOutcome {
        run(format, on: path, keepingSamples: false).outcome
    }

    /// Encodes as `encode(_:on:)` does and also returns the encoded samples in output order, so
    /// the media the session produced can be decoded and tied to the encoder it reported.
    func encodeKeepingSamples(
        _ format: EncoderFormat, on path: EncoderPath
    ) -> (outcome: EncoderProbeOutcome, samples: [CMSampleBuffer]) {
        run(format, on: path, keepingSamples: true)
    }

    private func run(
        _ format: EncoderFormat, on path: EncoderPath, keepingSamples: Bool
    ) -> (outcome: EncoderProbeOutcome, samples: [CMSampleBuffer]) {
        let tally = EncodeTally(keepsSamples: keepingSamples)
        return (session(format, on: path, tally: tally), tally.snapshot().samples)
    }

    private func session(
        _ format: EncoderFormat, on path: EncoderPath, tally: EncodeTally
    ) -> EncoderProbeOutcome {
        if let reason = Self.invalidFormatReason(format) { return .failed(reason) }
        let specification: [CFString: Any] =
            switch path {
            case .hardware: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
            case .software: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: false]
            }
        let sourceAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: format.sourcePixelFormat,
            kCVPixelBufferWidthKey: format.width,
            kCVPixelBufferHeightKey: format.height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        ]

        var createdSession: VTCompressionSession?
        let createStatus = VTCompressionSessionCreate(
            allocator: nil, width: Int32(format.width), height: Int32(format.height),
            codecType: format.codec.codecType,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: sourceAttributes as CFDictionary, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &createdSession)
        guard createStatus == noErr, let session = createdSession else {
            return .failed("compression session creation failed (\(createStatus))")
        }
        defer { VTCompressionSessionInvalidate(session) }

        let settings = [
            Setting(key: kVTCompressionPropertyKey_ExpectedFrameRate, value: format.frameRate as CFNumber, isHint: true),
            Setting(key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue, isHint: true),
        ]
        if let rejected = Self.apply(settings, using: { key, value in
            VTSessionSetProperty(session, key: key, value: value)
        }) {
            return rejected
        }
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepareStatus == noErr else {
            return .failed("prepare to encode failed (\(prepareStatus))")
        }

        guard let pool = VTCompressionSessionGetPixelBufferPool(session) else {
            return .failed("compression session has no pixel buffer pool")
        }
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(format.frameRate))
        for index in 0..<frameCount {
            var pixelBuffer: CVPixelBuffer?
            let poolStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard poolStatus == kCVReturnSuccess, let pixelBuffer else {
                return .failed("pixel buffer creation failed (\(poolStatus))")
            }
            fill(pixelBuffer, frame: index)
            let encodeStatus = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixelBuffer,
                presentationTimeStamp: CMTimeMultiply(frameDuration, multiplier: Int32(index)),
                duration: frameDuration, frameProperties: nil, infoFlagsOut: nil
            ) { status, _, sampleBuffer in
                tally.record(status: status, sampleBuffer: sampleBuffer)
            }
            guard encodeStatus == noErr else {
                return .failed("encode of frame \(index) failed (\(encodeStatus))")
            }
        }
        let completeStatus = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard completeStatus == noErr else {
            return .failed("completing frames failed (\(completeStatus))")
        }
        let result = tally.snapshot()
        if let failure = result.firstFailure {
            return .failed("encoder output failed (\(failure))")
        }
        guard result.encoded == frameCount else {
            return .failed("\(result.encoded) of \(frameCount) frames encoded")
        }

        return Self.outcome(
            usingHardware: copyProperty(
                session, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder),
            encoderID: copyProperty(session, kVTCompressionPropertyKey_EncoderID))
    }

    /// VTSessionCopyProperty returns a retained value, released here once read.
    private func copyProperty(_ session: VTSession, _ key: CFString) -> PropertyRead {
        var value: Unmanaged<CFTypeRef>?
        let status = withUnsafeMutablePointer(to: &value) {
            VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: $0)
        }
        return PropertyRead(status: status, value: status == noErr ? value?.takeRetainedValue() : nil)
    }

    /// Fills each row with a value that depends on the row and the frame, so rows and
    /// consecutive frames differ. A planar buffer has no single base address and is left as the
    /// pool gave it.
    private func fill(_ pixelBuffer: CVPixelBuffer, frame: Int) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for row in 0..<CVPixelBufferGetHeight(pixelBuffer) {
            memset(base + row * bytesPerRow, Int32((row &+ frame &* 37) & 0xFF), bytesPerRow)
        }
    }
}

/// Collects the encoder's per-frame results, which arrive on VideoToolbox's own thread, and the
/// encoded samples when asked to keep them.
private final class EncodeTally: @unchecked Sendable {
    struct Result {
        var encoded = 0
        var firstFailure: OSStatus?
        var samples: [CMSampleBuffer] = []
    }

    private let keepsSamples: Bool
    private let lock = NSLock()
    private var result = Result()

    init(keepsSamples: Bool) {
        self.keepsSamples = keepsSamples
    }

    func record(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        lock.lock()
        defer { lock.unlock() }
        if status != noErr {
            if result.firstFailure == nil { result.firstFailure = status }
        } else if let sampleBuffer {
            result.encoded += 1
            if keepsSamples { result.samples.append(sampleBuffer) }
        }
    }

    func snapshot() -> Result {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
