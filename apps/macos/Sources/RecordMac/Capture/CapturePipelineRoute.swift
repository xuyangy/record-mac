import CoreGraphics
import Foundation

/// The developer opt-in that records through `RecordingPipeline` instead of `CaptureController`,
/// and what that route needs from the app: where it writes, the engine options it records with,
/// and the messages it shows. Off unless the defaults key is set; it has no interface. The editor
/// does not open its projects.
enum CapturePipelineRoute {
    /// `defaults write <bundle id> RecordMacCapturePipeline -bool YES` turns the route on.
    static let defaultsKey = "RecordMacCapturePipeline"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    /// Where the route writes, beside the legacy library and apart from its projects.
    struct Locations: Equatable {
        /// Holds one directory per recording, kept after its project is written or refused.
        var captures: URL
        /// Holds the written `.recordmac` projects.
        var projects: URL

        static func beside(_ library: LegacyLibraryLocations) -> Self {
            Self(captures: library.support.appendingPathComponent("CaptureRecordings", isDirectory: true),
                projects: library.support.appendingPathComponent("CaptureProjects", isDirectory: true))
        }
    }

    /// Why the route does not record with the chosen options.
    enum Refusal: Error, Equatable {
        /// The screen backend records no camera.
        case camera
        /// The microphone is on with no device chosen, and no default device is listed.
        case noMicrophone

        var message: String {
            switch self {
            case .camera:
                "The capture pipeline records no camera. Turn the camera off to record with it."
            case .noMicrophone:
                "The capture pipeline needs a microphone device, and no default microphone is available."
            }
        }
    }

    /// The engine options for the app's recording options, at 60 fps. A microphone that is on
    /// with no device chosen records the listed default device.
    static func engineOptions(
        _ options: RecordingCaptureOptions, microphones: [CaptureDeviceInfo]
    ) -> Result<CaptureEngineOptions, Refusal> {
        guard !options.includeCamera else { return .failure(.camera) }
        var microphone: String?
        if options.includeMicrophone {
            guard let id = options.microphoneDeviceID ?? microphones.first(where: \.isDefault)?.id else {
                return .failure(.noMicrophone)
            }
            microphone = id
        }
        return .success(CaptureEngineOptions(
            microphoneDeviceID: microphone, systemAudio: options.includeSystemAudio, cameraDeviceID: nil,
            includesPointer: options.showCursor, frameRate: 60, wantsAlpha: false, keepsPresenterComposite: false))
    }

    /// The refresh rate of the display a display or area source is on; unknown for a source with no
    /// display.
    static func refreshRate(of source: CaptureSource, displays: DisplayRefreshSource) -> RefreshRate {
        let display = (source.kind == .area ? source.area?.displayID : nil) ?? source.displayID
        guard let display else { return .unknown("\(source.name) has no display") }
        return displays.refreshRate(of: display)
    }

    static func startFailureMessage(_ error: Error) -> String {
        if case RecordingPipelineError.startFailed(let primary, let cleanup) = error {
            if case .failure(let cleanupError) = cleanup {
                return "The recording did not start: \(primary). Its cleanup also failed: \(cleanupError)."
            }
            return "The recording did not start: \(primary)."
        }
        if let error = error as? CapturePrepareError {
            return "The recording did not start: \(error)."
        }
        return "The recording did not start: \(error.localizedDescription)"
    }

    /// Where the project is, and what its activity telemetry collected, without calling it complete.
    static func savedMessage(_ result: ProjectWriteResult) -> String {
        var parts = ["Saved the capture project at \(result.store.directory.path)."]
        if let outcome = result.telemetry.outcome {
            parts.append("Activity: tap \(outcome.activity), \(outcome.stream.events.count) events, "
                + "\(outcome.stream.geometry.count) geometry segments.")
        }
        if result.telemetry.suspendedAtStart == true {
            parts.append("Activity recording was suspended when the recording started.")
        }
        return parts.joined(separator: " ")
    }

    /// That the media were captured but no project was written, why, and where the capture is.
    static func notPublishedMessage(_ error: Error, captureDirectory: URL) -> String {
        let reason: String = switch error {
        case RecordingPublishError.endNotClassified(let text):
            "the capture stopped on its own (\(text))"
        case ProjectWriterError.telemetryNotRecorded(let status):
            "activity telemetry was not recorded (\(status))"
        default:
            "\(error)"
        }
        return "Captured, but no project was created: \(reason). The capture files are in \(captureDirectory.path)."
    }
}
