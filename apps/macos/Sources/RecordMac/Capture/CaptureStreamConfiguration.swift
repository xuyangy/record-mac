import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import ScreenCaptureKit

/// What one capture stream is asked for. Adapted from the stream configuration in QuickRecorder's
/// `RecordEngine.record(filter:fastStart:)` (UPSTREAM.md); every input is explicit, nothing is
/// read from preferences or from the attached displays.
struct CaptureStreamSettings: Equatable, Sendable {
    /// The native pixel size of the captured area. Used as given: never raised to a minimum,
    /// rounded to even, or scaled.
    var pixelWidth: Int
    var pixelHeight: Int
    /// The captured part of the filter's content, in ScreenCaptureKit's coordinate space for that
    /// filter (points, origin at the top left). Nil captures the whole content.
    var sourceRect: CGRect?
    /// One of `CaptureStreamConfiguration.frameRates`.
    var frameRate: Int
    var includesPointer: Bool
    var systemAudio: Bool
    /// The microphone to capture, or nil for none.
    var microphoneDeviceID: String?
}

enum CaptureStreamSettingsError: Error, Equatable, Sendable {
    case frameRateNotSupported(Int)
    case invalidPixelSize(width: Int, height: Int)
    case invalidSourceRect(CGRect)
    case emptyMicrophoneDeviceID
}

/// Builds the `SCStreamConfiguration` for a capture stream. It creates no stream, opens no
/// device, and asks for no permission.
enum CaptureStreamConfiguration {
    /// Every rate the engine can offer (FR-074). Which of them a source gets is
    /// `CaptureEngine.offers`.
    static let frameRates = [30, 60, 120, 240]
    static let queueDepth = 8
    static let audioSampleRate = 48_000
    static let audioChannelCount = 2

    static func make(_ settings: CaptureStreamSettings) throws -> SCStreamConfiguration {
        guard frameRates.contains(settings.frameRate) else {
            throw CaptureStreamSettingsError.frameRateNotSupported(settings.frameRate)
        }
        guard settings.pixelWidth > 0, settings.pixelHeight > 0 else {
            throw CaptureStreamSettingsError.invalidPixelSize(width: settings.pixelWidth, height: settings.pixelHeight)
        }
        if let rect = settings.sourceRect {
            guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite,
                  rect.width > 0, rect.height > 0 else {
                throw CaptureStreamSettingsError.invalidSourceRect(rect)
            }
        }
        if settings.microphoneDeviceID?.isEmpty == true {
            throw CaptureStreamSettingsError.emptyMicrophoneDeviceID
        }

        let configuration = SCStreamConfiguration()
        configuration.width = settings.pixelWidth
        configuration.height = settings.pixelHeight
        if let rect = settings.sourceRect {
            configuration.sourceRect = rect
        }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
        configuration.queueDepth = queueDepth
        configuration.showsCursor = settings.includesPointer
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.capturesAudio = settings.systemAudio
        configuration.sampleRate = audioSampleRate
        configuration.channelCount = audioChannelCount
        configuration.captureMicrophone = settings.microphoneDeviceID != nil
        configuration.microphoneCaptureDeviceID = settings.microphoneDeviceID
        return configuration
    }
}
