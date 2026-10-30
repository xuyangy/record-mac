import CoreGraphics
import CoreMedia
import CoreVideo
import XCTest
@preconcurrency import ScreenCaptureKit
@testable import RecordMac

/// The capture stream configuration, built without a stream, a device, or a permission.
final class CaptureStreamConfigurationTests: XCTestCase {
    private func settings(
        width: Int = 3024, height: Int = 1964, sourceRect: CGRect? = nil, frameRate: Int = 60,
        includesPointer: Bool = false, systemAudio: Bool = false, microphoneDeviceID: String? = nil
    ) -> CaptureStreamSettings {
        CaptureStreamSettings(pixelWidth: width, pixelHeight: height, sourceRect: sourceRect, frameRate: frameRate,
            includesPointer: includesPointer, systemAudio: systemAudio, microphoneDeviceID: microphoneDeviceID)
    }

    func testEveryOfferedRateThrottlesToOneFrameEachInterval() throws {
        XCTAssertEqual(CaptureStreamConfiguration.frameRates, [30, 60, 120, 240])
        for rate in CaptureStreamConfiguration.frameRates {
            let interval = try CaptureStreamConfiguration.make(settings(frameRate: rate)).minimumFrameInterval
            XCTAssertEqual(interval.value, 1, "\(rate) fps")
            XCTAssertEqual(interval.timescale, CMTimeScale(rate), "\(rate) fps")
            XCTAssertTrue(interval.isValid && interval.isNumeric, "\(rate) fps")
            XCTAssertEqual(interval.seconds, 1 / Double(rate), accuracy: 1e-12, "\(rate) fps")
        }
    }

    func testARateThatIsNeverOfferedIsRefused() {
        for rate in [0, -60, 24, 59, 90, 144, 480] {
            XCTAssertThrowsError(try CaptureStreamConfiguration.make(settings(frameRate: rate)), "\(rate) fps") {
                XCTAssertEqual($0 as? CaptureStreamSettingsError, .frameRateNotSupported(rate))
            }
        }
    }

    func testThePixelSizeIsUsedAsGivenEvenWhenOddOrSmall() throws {
        for (width, height) in [(873, 581), (1, 1), (6016, 3384)] {
            let configuration = try CaptureStreamConfiguration.make(settings(width: width, height: height))
            XCTAssertEqual(configuration.width, width)
            XCTAssertEqual(configuration.height, height)
        }
    }

    func testAnEmptyPixelSizeIsRefused() {
        for (width, height) in [(0, 1080), (1920, 0), (-2, 1080)] {
            XCTAssertThrowsError(try CaptureStreamConfiguration.make(settings(width: width, height: height))) {
                XCTAssertEqual($0 as? CaptureStreamSettingsError, .invalidPixelSize(width: width, height: height))
            }
        }
    }

    func testTheSourceRectIsPassedThroughUnchanged() throws {
        let rect = CGRect(x: 436.5, y: 364, width: 873, height: 581)
        let configuration = try CaptureStreamConfiguration.make(settings(width: 1746, height: 1162, sourceRect: rect))
        XCTAssertEqual(configuration.sourceRect, rect)
        XCTAssertEqual(configuration.width, 1746, "the pixel size is not derived from the rect")
        XCTAssertEqual(configuration.height, 1162)
    }

    func testWithoutASourceRectTheWholeContentIsCaptured() throws {
        let configuration = try CaptureStreamConfiguration.make(settings())
        XCTAssertEqual(configuration.sourceRect, SCStreamConfiguration().sourceRect)
    }

    func testAnEmptyOrNonFiniteSourceRectIsRefused() {
        let rects = [
            CGRect(x: 0, y: 0, width: 0, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: 0),
            CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100),
        ]
        for rect in rects {
            XCTAssertThrowsError(try CaptureStreamConfiguration.make(settings(sourceRect: rect))) {
                guard case .invalidSourceRect = $0 as? CaptureStreamSettingsError else {
                    return XCTFail("\(rect): \($0)")
                }
            }
        }
    }

    func testThePointerFollowsTheSetting() throws {
        XCTAssertTrue(try CaptureStreamConfiguration.make(settings(includesPointer: true)).showsCursor)
        XCTAssertFalse(try CaptureStreamConfiguration.make(settings(includesPointer: false)).showsCursor)
    }

    func testSystemAudioAndTheMicrophoneAreSelectedSeparately() throws {
        let neither = try CaptureStreamConfiguration.make(settings())
        XCTAssertFalse(neither.capturesAudio)
        XCTAssertFalse(neither.captureMicrophone)
        XCTAssertNil(neither.microphoneCaptureDeviceID)

        let system = try CaptureStreamConfiguration.make(settings(systemAudio: true))
        XCTAssertTrue(system.capturesAudio)
        XCTAssertFalse(system.captureMicrophone)
        XCTAssertEqual(system.sampleRate, 48_000)
        XCTAssertEqual(system.channelCount, 2)

        let microphone = try CaptureStreamConfiguration.make(settings(microphoneDeviceID: "BuiltInMicrophoneDevice"))
        XCTAssertFalse(microphone.capturesAudio)
        XCTAssertTrue(microphone.captureMicrophone)
        XCTAssertEqual(microphone.microphoneCaptureDeviceID, "BuiltInMicrophoneDevice")

        let both = try CaptureStreamConfiguration.make(settings(systemAudio: true, microphoneDeviceID: "USB-Mic"))
        XCTAssertTrue(both.capturesAudio)
        XCTAssertTrue(both.captureMicrophone)
        XCTAssertEqual(both.microphoneCaptureDeviceID, "USB-Mic")
    }

    func testAnEmptyMicrophoneIdentifierIsRefused() {
        XCTAssertThrowsError(try CaptureStreamConfiguration.make(settings(microphoneDeviceID: ""))) {
            XCTAssertEqual($0 as? CaptureStreamSettingsError, .emptyMicrophoneDeviceID)
        }
    }

    func testFramesAreDeliveredAsBGRAInSRGBWithAQueueOfEight() throws {
        let configuration = try CaptureStreamConfiguration.make(settings())
        XCTAssertEqual(configuration.pixelFormat, kCVPixelFormatType_32BGRA)
        XCTAssertEqual(configuration.colorSpaceName, CGColorSpace.sRGB)
        XCTAssertEqual(configuration.queueDepth, 8)
    }
}
