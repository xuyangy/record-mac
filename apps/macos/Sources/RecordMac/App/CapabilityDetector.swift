import CoreGraphics
import Foundation

/// A display's refresh rate as its current mode reports it, or why no rate is known.
enum RefreshRate: Equatable, Sendable {
    case hertz(Double)
    case unknown(String)

    /// The rate a source spanning these displays can rely on: the lowest. An unknown display
    /// makes the result unknown, since the faster known displays say nothing about it.
    static func spanning(_ rates: [RefreshRate]) -> RefreshRate {
        guard !rates.isEmpty else { return .unknown("no display") }
        var lowest = Double.infinity
        for rate in rates {
            switch rate {
            case .unknown(let reason): return .unknown(reason)
            case .hertz(let hertz): lowest = min(lowest, hertz)
            }
        }
        return .hertz(lowest)
    }

    /// The capture rates a source at this refresh rate can deliver: 30 and 60 always, 120 and
    /// 240 only at a known refresh rate at least that high (FR-074). Whether the machine can
    /// sustain a rate is the separate headroom question.
    var deliverableFrameRates: [Int] {
        let baseline = [30, 60]
        guard case .hertz(let hertz) = self else { return baseline }
        return baseline + [120, 240].filter { hertz >= Double($0) }
    }
}

/// Where display refresh rates come from, so detection can be tested without the attached
/// displays.
protocol DisplayRefreshSource: Sendable {
    func activeDisplays() -> [CGDirectDisplayID]
    func refreshRate(of display: CGDirectDisplayID) -> RefreshRate
}

/// Reads the refresh rate of each display's current mode, not the panel's maximum: a 120 Hz
/// panel set to a 60 Hz mode refreshes at 60. A mode that reports no fixed rate stays unknown.
struct CoreGraphicsDisplayRefreshSource: DisplayRefreshSource {
    func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }

    func refreshRate(of display: CGDirectDisplayID) -> RefreshRate {
        guard let mode = CGDisplayCopyDisplayMode(display) else {
            return .unknown("display \(display) has no current mode")
        }
        guard mode.refreshRate > 0 else {
            return .unknown("display \(display) mode reports no fixed refresh rate")
        }
        return .hertz(mode.refreshRate)
    }
}

/// Whether one exact format can be encoded, and on which path.
enum CodecCapability: Equatable, Sendable {
    case available(EncoderSelection)
    case unavailable(EncoderFormat, reason: String)
}

/// The Presenter Overlay branch decided by Gate C (research.md R-009).
enum PresenterOverlayCapability: Equatable, Sendable {
    /// The fallback: the system applies its composite to the stream of its choosing, so the
    /// clean screen stream cannot be kept free of it. The creator is told before recording.
    case reduced(String)
    case unavailable(String)

    static let fallback = PresenterOverlayCapability.reduced(
        "Presenter Overlay is reduced: the system composite cannot be kept out of the clean screen stream")
}

/// Frame-rate headroom needs a measurement under real capture. Until one exists it is reported
/// as not measured, never estimated from encoder or display results.
enum FrameRateHeadroom: Equatable, Sendable {
    case notMeasured
}

/// Capabilities forced absent, for tests only; detection is otherwise live.
struct CapabilityOverrides: Sendable {
    /// Codecs whose hardware encoder is treated as absent, so the software encoder is selected
    /// for real.
    var hardwareEncodeAbsent: Set<EncoderCodec> = []
    /// Codecs reported unavailable without probing.
    var codecAbsent: Set<EncoderCodec> = []
    /// Displays whose refresh rate is reported unknown.
    var refreshAbsent: Set<CGDirectDisplayID> = []
    var presenterOverlayAbsent = false
}

struct CapabilityReport: Equatable, Sendable {
    let codecs: [EncoderFormat: CodecCapability]
    let displayRefresh: [CGDirectDisplayID: RefreshRate]
    let presenterOverlay: PresenterOverlayCapability
    let headroom: FrameRateHeadroom

    /// Every reduced or missing capability, for the creator to see (FR-071).
    var reductions: [String] {
        var reductions: [String] = []
        for (format, capability) in codecs.sorted(by: { describe($0.key) < describe($1.key) }) {
            switch capability {
            case .available(let selection):
                if let reduction = selection.reduction { reductions.append(reduction) }
            case .unavailable(_, let reason):
                reductions.append("\(describe(format)) cannot be encoded: \(reason)")
            }
        }
        for (display, rate) in displayRefresh.sorted(by: { $0.key < $1.key }) {
            if case .unknown(let reason) = rate {
                reductions.append("refresh rate of display \(display) unknown: \(reason); 120 and 240 fps not offered")
            }
        }
        switch presenterOverlay {
        case .reduced(let reason): reductions.append(reason)
        case .unavailable(let reason): reductions.append("Presenter Overlay unavailable: \(reason)")
        }
        return reductions
    }

    private func describe(_ format: EncoderFormat) -> String {
        "\(format.codec.rawValue) \(format.width)x\(format.height) \(format.frameRate) fps"
    }
}

/// Detects, at startup or on use, what this machine can do (FR-071): the encoder path for each
/// exact format, each display's refresh rate, and the Presenter Overlay branch. Frame-rate
/// headroom is not measured yet. Nothing here is wired into capture or export.
struct CapabilityDetector: Sendable {
    var probe: any EncoderProbe = VideoToolboxEncoderProbe()
    var displays: any DisplayRefreshSource = CoreGraphicsDisplayRefreshSource()
    var operatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersionString
    var overrides = CapabilityOverrides()

    func detect(formats: [EncoderFormat]) -> CapabilityReport {
        let selector = EncoderSelector(
            probe: OverriddenEncoderProbe(probe: probe, hardwareAbsent: overrides.hardwareEncodeAbsent),
            operatingSystemVersion: operatingSystemVersion)
        var codecs: [EncoderFormat: CodecCapability] = [:]
        for format in formats {
            if overrides.codecAbsent.contains(format.codec) {
                codecs[format] = .unavailable(format, reason: "forced absent by test override")
                continue
            }
            do {
                codecs[format] = .available(try selector.select(format))
            } catch EncoderSelectionError.noEncoder(_, let hardwareFailure, let softwareFailure) {
                codecs[format] = .unavailable(
                    format, reason: "hardware: \(hardwareFailure); software: \(softwareFailure)")
            } catch {
                codecs[format] = .unavailable(format, reason: "\(error)")
            }
        }

        var displayRefresh: [CGDirectDisplayID: RefreshRate] = [:]
        for display in displays.activeDisplays() {
            displayRefresh[display] = overrides.refreshAbsent.contains(display)
                ? .unknown("forced absent by test override")
                : displays.refreshRate(of: display)
        }

        return CapabilityReport(
            codecs: codecs,
            displayRefresh: displayRefresh,
            presenterOverlay: overrides.presenterOverlayAbsent
                ? .unavailable("forced absent by test override") : .fallback,
            headroom: .notMeasured)
    }
}

/// Fails the hardware path for the codecs forced absent and passes everything else to the real
/// probe, so the software result is a real software encode.
private struct OverriddenEncoderProbe: EncoderProbe {
    let probe: any EncoderProbe
    let hardwareAbsent: Set<EncoderCodec>

    func encode(_ format: EncoderFormat, on path: EncoderPath) -> EncoderProbeOutcome {
        if path == .hardware, hardwareAbsent.contains(format.codec) {
            return .failed("hardware encoder forced absent by test override")
        }
        return probe.encode(format, on: path)
    }
}
