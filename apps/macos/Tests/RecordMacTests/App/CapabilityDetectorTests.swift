import CoreGraphics
import XCTest
@testable import RecordMac

final class CapabilityDetectorTests: XCTestCase {
    private let hevc = EncoderFormat(codec: .hevc, width: 1920, height: 1080, frameRate: 60)
    private let proRes = EncoderFormat(codec: .proRes4444, width: 1920, height: 1080, frameRate: 60)

    /// Answers by codec and path, and records every request.
    private final class ScriptedProbe: EncoderProbe, @unchecked Sendable {
        var outcomes: [EncoderCodec: [EncoderPath: EncoderProbeOutcome]] = [:]
        private(set) var requests: [(EncoderCodec, EncoderPath)] = []

        func encode(_ format: EncoderFormat, on path: EncoderPath) -> EncoderProbeOutcome {
            requests.append((format.codec, path))
            return outcomes[format.codec]?[path] ?? .failed("not scripted")
        }
    }

    private struct FixedDisplays: DisplayRefreshSource {
        let rates: [CGDirectDisplayID: RefreshRate]
        func activeDisplays() -> [CGDirectDisplayID] { rates.keys.sorted() }
        func refreshRate(of display: CGDirectDisplayID) -> RefreshRate { rates[display] ?? .unknown("absent") }
    }

    private func hardwareEverywhere() -> ScriptedProbe {
        let probe = ScriptedProbe()
        for codec in EncoderCodec.allCases {
            probe.outcomes[codec] = [
                .hardware: .encoded(usingHardware: true, encoderID: "hw.\(codec.rawValue)"),
                .software: .encoded(usingHardware: false, encoderID: "sw.\(codec.rawValue)"),
            ]
        }
        return probe
    }

    private func detector(
        _ probe: ScriptedProbe,
        displays: [CGDirectDisplayID: RefreshRate] = [1: .hertz(120), 4: .hertz(60)],
        overrides: CapabilityOverrides = CapabilityOverrides()
    ) -> CapabilityDetector {
        CapabilityDetector(
            probe: probe, displays: FixedDisplays(rates: displays),
            operatingSystemVersion: "test OS", overrides: overrides)
    }

    // MARK: Refresh rules

    func testASourceSpanningDisplaysUsesTheLowestRate() {
        XCTAssertEqual(RefreshRate.spanning([.hertz(120)]), .hertz(120))
        XCTAssertEqual(RefreshRate.spanning([.hertz(120), .hertz(60)]), .hertz(60))
    }

    func testAnUnknownOrMissingDisplayMakesTheSpanUnknown() {
        XCTAssertEqual(RefreshRate.spanning([.hertz(120), .unknown("gone")]), .unknown("gone"))
        XCTAssertEqual(RefreshRate.spanning([]), .unknown("no display"))
    }

    func testOnlyAKnownRateAtLeastAsHighOffers120Or240() {
        XCTAssertEqual(RefreshRate.hertz(60).deliverableFrameRates, [30, 60])
        XCTAssertEqual(RefreshRate.hertz(120).deliverableFrameRates, [30, 60, 120])
        XCTAssertEqual(RefreshRate.hertz(240).deliverableFrameRates, [30, 60, 120, 240])
        XCTAssertEqual(RefreshRate.unknown("adaptive").deliverableFrameRates, [30, 60])
    }

    // MARK: Detection

    func testLiveDetectionReportsEachFormatEachDisplayAndTheFallback() {
        let report = detector(hardwareEverywhere()).detect(formats: [hevc, proRes])
        XCTAssertEqual(report.codecs[hevc], .available(EncoderSelection(
            format: hevc, path: .hardware, encoderID: "hw.hevc",
            operatingSystemVersion: "test OS", reduction: nil)))
        XCTAssertEqual(report.displayRefresh, [1: .hertz(120), 4: .hertz(60)])
        XCTAssertEqual(report.presenterOverlay, .fallback)
        XCTAssertEqual(report.headroom, .notMeasured)
        XCTAssertEqual(report.reductions, [
            "Presenter Overlay is reduced: the system composite cannot be kept out of the clean screen stream",
        ])
    }

    func testAResultHoldsForItsExactFormatOnly() {
        let other = EncoderFormat(codec: .hevc, width: 3840, height: 2160, frameRate: 120)
        let report = detector(hardwareEverywhere()).detect(formats: [hevc])
        XCTAssertNotNil(report.codecs[hevc])
        XCTAssertNil(report.codecs[other])
    }

    func testForcedAbsentHardwareSelectsTheSoftwareEncoderForReal() throws {
        let probe = hardwareEverywhere()
        var overrides = CapabilityOverrides()
        overrides.hardwareEncodeAbsent = [.hevc]
        let report = detector(probe, overrides: overrides).detect(formats: [hevc, proRes])

        guard case .available(let selection) = report.codecs[hevc] else {
            return XCTFail("hevc not available: \(String(describing: report.codecs[hevc]))")
        }
        XCTAssertEqual(selection.path, .software)
        XCTAssertEqual(selection.encoderID, "sw.hevc")
        XCTAssertTrue(try XCTUnwrap(selection.reduction).contains("forced absent"))
        XCTAssertTrue(probe.requests.contains { $0 == (.hevc, .software) })
        XCTAssertFalse(probe.requests.contains { $0 == (.hevc, .hardware) })
        guard case .available(let untouched) = report.codecs[proRes] else { return XCTFail("proRes") }
        XCTAssertEqual(untouched.path, .hardware)
        XCTAssertEqual(report.reductions.count, 2)
    }

    func testAForcedAbsentCodecIsUnavailableWithoutProbing() {
        let probe = hardwareEverywhere()
        var overrides = CapabilityOverrides()
        overrides.codecAbsent = [.proRes4444]
        let report = detector(probe, overrides: overrides).detect(formats: [hevc, proRes])
        XCTAssertEqual(report.codecs[proRes], .unavailable(proRes, reason: "forced absent by test override"))
        XCTAssertFalse(probe.requests.contains { $0.0 == .proRes4444 })
        guard case .available = report.codecs[hevc] else { return XCTFail("hevc") }
        XCTAssertTrue(report.reductions.contains(
            "proRes4444 1920x1080 60 fps cannot be encoded: forced absent by test override"))
    }

    func testACodecNeitherPathEncodesIsUnavailableWithBothReasons() {
        let probe = hardwareEverywhere()
        probe.outcomes[.proRes4444] = [.hardware: .failed("hw reason"), .software: .failed("sw reason")]
        let report = detector(probe).detect(formats: [hevc, proRes])
        XCTAssertEqual(report.codecs[proRes], .unavailable(proRes, reason: "hardware: hw reason; software: sw reason"))
        guard case .available = report.codecs[hevc] else { return XCTFail("hevc") }
    }

    func testForcedAbsentRefreshIsUnknownForThatDisplayOnly() {
        var overrides = CapabilityOverrides()
        overrides.refreshAbsent = [1]
        let report = detector(hardwareEverywhere(), overrides: overrides).detect(formats: [])
        XCTAssertEqual(report.displayRefresh, [1: .unknown("forced absent by test override"), 4: .hertz(60)])
        XCTAssertEqual(report.displayRefresh[1]?.deliverableFrameRates, [30, 60])
        XCTAssertTrue(report.reductions.contains {
            $0.hasPrefix("refresh rate of display 1 unknown") && $0.contains("120 and 240 fps not offered")
        })
    }

    func testAnUnknownDisplayRateStaysUnknown() {
        let report = detector(hardwareEverywhere(), displays: [7: .unknown("mode reports no fixed refresh rate")])
            .detect(formats: [])
        XCTAssertEqual(report.displayRefresh, [7: .unknown("mode reports no fixed refresh rate")])
    }

    func testForcedAbsentPresenterOverlayIsUnavailable() {
        var overrides = CapabilityOverrides()
        overrides.presenterOverlayAbsent = true
        let report = detector(hardwareEverywhere(), overrides: overrides).detect(formats: [])
        XCTAssertEqual(report.presenterOverlay, .unavailable("forced absent by test override"))
        XCTAssertEqual(report.reductions, ["Presenter Overlay unavailable: forced absent by test override"])
    }

    // MARK: This machine

    func testForcedAbsentHardwareRunsTheRealSoftwareEncoder() throws {
        let format = EncoderFormat(codec: .h264, width: 1280, height: 720, frameRate: 30)
        var detector = CapabilityDetector()
        detector.overrides.hardwareEncodeAbsent = [.h264]
        guard case .available(let selection) = detector.detect(formats: [format]).codecs[format] else {
            return XCTFail("h264 software not available")
        }
        XCTAssertEqual(selection.path, .software)
        print("capability: h264 1280x720 30 fps, hardware forced absent -> \(selection.encoderID)")
    }

    func testEveryAttachedDisplayReportsItsCurrentModeRate() {
        let source = CoreGraphicsDisplayRefreshSource()
        for display in source.activeDisplays() {
            let rate = source.refreshRate(of: display)
            if case .hertz(let hertz) = rate { XCTAssertGreaterThan(hertz, 0) }
            print("capability: display \(display) builtin \(CGDisplayIsBuiltin(display) != 0) -> \(rate), offers \(rate.deliverableFrameRates)")
        }
    }
}
