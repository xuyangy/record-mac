import VideoToolbox
import XCTest
@testable import RecordMac

final class EncoderSelectionTests: XCTestCase {
    private let format = EncoderFormat(codec: .hevc, width: 1920, height: 1080, frameRate: 60)

    /// Answers each path with a fixed outcome and records the paths asked for.
    private final class ScriptedProbe: EncoderProbe, @unchecked Sendable {
        let hardware: EncoderProbeOutcome
        let software: EncoderProbeOutcome
        private(set) var requests: [EncoderPath] = []

        init(hardware: EncoderProbeOutcome, software: EncoderProbeOutcome) {
            self.hardware = hardware
            self.software = software
        }

        func encode(_ format: EncoderFormat, on path: EncoderPath) -> EncoderProbeOutcome {
            requests.append(path)
            return path == .hardware ? hardware : software
        }
    }

    private func selector(_ probe: ScriptedProbe) -> EncoderSelector {
        EncoderSelector(probe: probe, operatingSystemVersion: "test OS")
    }

    // MARK: Policy

    func testHardwareIsSelectedWhenItEncodesOnHardware() throws {
        let probe = ScriptedProbe(
            hardware: .encoded(usingHardware: true, encoderID: "hw.hevc"),
            software: .failed("not asked"))
        let selection = try selector(probe).select(format)
        XCTAssertEqual(selection.path, .hardware)
        XCTAssertEqual(selection.encoderID, "hw.hevc")
        XCTAssertEqual(selection.operatingSystemVersion, "test OS")
        XCTAssertNil(selection.reduction)
        XCTAssertEqual(probe.requests, [.hardware])
    }

    func testSoftwareIsSelectedAndTheReductionNamedWhenHardwareFails() throws {
        let probe = ScriptedProbe(
            hardware: .failed("compression session creation failed (-12908)"),
            software: .encoded(usingHardware: false, encoderID: "sw.hevc"))
        let selection = try selector(probe).select(format)
        XCTAssertEqual(selection.path, .software)
        XCTAssertEqual(selection.encoderID, "sw.hevc")
        let reduction = try XCTUnwrap(selection.reduction)
        XCTAssertTrue(reduction.contains("hevc"))
        XCTAssertTrue(reduction.contains("1920x1080 60 fps"))
        XCTAssertTrue(reduction.contains("-12908"))
        XCTAssertEqual(probe.requests, [.hardware, .software])
    }

    func testAHardwareRequestThatRanWithoutHardwareCountsAsAHardwareFailure() throws {
        let probe = ScriptedProbe(
            hardware: .encoded(usingHardware: false, encoderID: "sw.hevc"),
            software: .encoded(usingHardware: false, encoderID: "sw.hevc"))
        let selection = try selector(probe).select(format)
        XCTAssertEqual(selection.path, .software)
        XCTAssertTrue(try XCTUnwrap(selection.reduction).contains("without hardware"))
    }

    func testFailureOnBothPathsIsAnErrorCarryingBothReasons() {
        let probe = ScriptedProbe(hardware: .failed("hw reason"), software: .failed("sw reason"))
        XCTAssertThrowsError(try selector(probe).select(format)) { error in
            XCTAssertEqual(
                error as? EncoderSelectionError,
                .noEncoder(format, hardwareFailure: "hw reason", softwareFailure: "sw reason"))
        }
    }

    func testASoftwareRequestThatRanOnHardwareIsAnError() {
        let probe = ScriptedProbe(
            hardware: .failed("hw reason"),
            software: .encoded(usingHardware: true, encoderID: "hw.hevc"))
        XCTAssertThrowsError(try selector(probe).select(format)) { error in
            guard case .noEncoder(_, _, let softwareFailure) = error as? EncoderSelectionError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(softwareFailure.contains("used hardware although hardware was disabled"))
        }
    }

    // MARK: Probe evidence

    private typealias Read = VideoToolboxEncoderProbe.PropertyRead

    func testObservedHardwareStatusAndEncoderIDAreEncoded() {
        XCTAssertEqual(
            VideoToolboxEncoderProbe.outcome(
                usingHardware: Read(status: noErr, value: false),
                encoderID: Read(status: noErr, value: "sw.h264")),
            .encoded(usingHardware: false, encoderID: "sw.h264"))
    }

    /// The SDK documents the hardware property as false when an encoder does not support it.
    func testAnEncoderWithoutTheHardwarePropertyIsNotUsingHardware() {
        XCTAssertEqual(
            VideoToolboxEncoderProbe.outcome(
                usingHardware: Read(status: kVTPropertyNotSupportedErr, value: nil),
                encoderID: Read(status: noErr, value: "sw.h264")),
            .encoded(usingHardware: false, encoderID: "sw.h264"))
    }

    func testUnreadableOrMissingEvidenceIsAFailureNotASoftwareEncode() {
        let id = Read(status: noErr, value: "sw.h264")
        let cases: [(Read, Read, String)] = [
            (Read(status: kVTPropertyReadOnlyErr, value: nil), id, "\(kVTPropertyReadOnlyErr)"),
            (Read(status: noErr, value: nil), id, "missing"),
            (Read(status: noErr, value: "yes"), id, "not a Boolean"),
            (Read(status: noErr, value: false), Read(status: kVTPropertyNotSupportedErr, value: nil), "\(kVTPropertyNotSupportedErr)"),
            (Read(status: noErr, value: false), Read(status: noErr, value: nil), "missing"),
            (Read(status: noErr, value: false), Read(status: noErr, value: ""), "not a string"),
        ]
        for (hardware, encoderID, expected) in cases {
            guard case .failed(let reason) = VideoToolboxEncoderProbe.outcome(
                usingHardware: hardware, encoderID: encoderID)
            else {
                XCTFail("accepted \(hardware) \(encoderID)")
                continue
            }
            XCTAssertTrue(reason.contains(expected), reason)
        }
    }

    func testARejectedSettingIsAFailureNamingItsKey() {
        var applied: [CFString] = []
        let outcome = VideoToolboxEncoderProbe.apply(
            [(kVTCompressionPropertyKey_ExpectedFrameRate, 60 as CFNumber),
             (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)]
        ) { key, _ in
            applied.append(key)
            return key == kVTCompressionPropertyKey_RealTime ? -12900 : noErr
        }
        guard case .failed(let reason) = outcome else { return XCTFail("rejection accepted") }
        XCTAssertTrue(reason.contains(kVTCompressionPropertyKey_RealTime as String), reason)
        XCTAssertTrue(reason.contains("-12900"), reason)
        XCTAssertEqual(applied.count, 2)
    }

    func testAcceptedSettingsAreNotAFailure() {
        XCTAssertNil(VideoToolboxEncoderProbe.apply(
            [(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)]) { _, _ in noErr })
    }

    func testFormatsVideoToolboxCannotTakeFailWithoutReachingIt() {
        let probe = VideoToolboxEncoderProbe()
        for format in [
            EncoderFormat(codec: .h264, width: 0, height: 1080, frameRate: 60),
            EncoderFormat(codec: .h264, width: 1920, height: 1080, frameRate: 0),
            EncoderFormat(codec: .h264, width: Int(Int32.max) + 1, height: 1080, frameRate: 60),
        ] {
            guard case .failed = probe.encode(format, on: .hardware) else {
                return XCTFail("accepted \(format)")
            }
        }
    }

    // MARK: VideoToolbox

    private func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    /// Acceptance on the reference machine only, which has a hardware encoder for every codec
    /// (research.md R-006). Elsewhere software fallback is a supported result, so the test skips.
    func testEveryCodecSelectsHardwareOnTheReferenceMachine() throws {
        let model = hardwareModel()
        guard model == "Mac17,8" else {
            throw XCTSkip("reference-machine acceptance; this host is \(model)")
        }
        let selector = EncoderSelector()
        for codec in EncoderCodec.allCases {
            let selection = try selector.select(
                EncoderFormat(codec: codec, width: 1920, height: 1080, frameRate: 60))
            XCTAssertEqual(selection.path, .hardware, "\(codec)")
            XCTAssertNil(selection.reduction, "\(codec)")
            XCTAssertNotEqual(selection.encoderID, "unknown", "\(codec)")
            print("encoder selection: \(codec.rawValue) 1920x1080 60 fps -> \(selection.path.rawValue) \(selection.encoderID)")
        }
    }

    func testTheSoftwarePathEncodesWithoutHardware() {
        let outcome = VideoToolboxEncoderProbe().encode(
            EncoderFormat(codec: .h264, width: 1280, height: 720, frameRate: 30), on: .software)
        guard case .encoded(let usingHardware, let encoderID) = outcome else {
            return XCTFail("software encode failed: \(outcome)")
        }
        XCTAssertFalse(usingHardware)
        print("encoder probe: h264 1280x720 30 fps software -> \(encoderID)")
    }

    func testAFormatNoEncoderAcceptsFailsOnBothPaths() {
        let selector = EncoderSelector()
        let impossible = EncoderFormat(codec: .h264, width: 32768, height: 32768, frameRate: 60)
        XCTAssertThrowsError(try selector.select(impossible)) { error in
            guard case .noEncoder = error as? EncoderSelectionError else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }
}
