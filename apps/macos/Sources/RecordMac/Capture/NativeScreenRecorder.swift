@preconcurrency import AVFoundation
import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

enum NativeScreenRecorderError: LocalizedError {
    case missingDisplay
    case missingWindow
    case windowIdentityChanged(expected: String?, actual: String?)
    case selfCaptureUnsupported
    case unsupportedSource
    case recordingEngineUnavailable

    var errorDescription: String? {
        switch self {
        case .missingDisplay:
            return "The selected display is no longer available. Refresh sources and pick again."
        case .missingWindow:
            return "The selected window is no longer available. Refresh sources and pick again."
        case .windowIdentityChanged(let expected, let actual):
            let expectedLabel = expected ?? "the selected window"
            let actualLabel = actual.map { " (now belongs to \($0))" } ?? ""
            return "The selected window has been replaced\(actualLabel). Refresh sources and pick \(expectedLabel) again."
        case .selfCaptureUnsupported:
            return "Open Recorder windows are excluded from recordings."
        case .unsupportedSource:
            return "Selected-area video recording requires a valid area selection."
        case .recordingEngineUnavailable:
            return "Recording is not available in this build: the capture engine is not built yet."
        }
    }
}

/// Resolves capture sources to ScreenCaptureKit filters and stream configurations. It records
/// nothing: `start` fails before creating a stream or a file until the capture engine records
/// (research.md R-001).
@MainActor
final class NativeScreenRecorder: NSObject {
    func start(
        source: CaptureSource,
        outputURL: URL,
        options: RecordingCaptureOptions
    ) async throws -> Date {
        throw NativeScreenRecorderError.recordingEngineUnavailable
    }

    static func makeStreamConfiguration(
        width: Int,
        height: Int,
        sourceRect: CGRect?,
        options: RecordingCaptureOptions
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = evenVideoDimension(width)
        configuration.height = evenVideoDimension(height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 8
        // Record without cursor capture here; playback and export reapply the saved cursor preference after capture.
        configuration.showsCursor = false
        // These format settings apply to system audio. ScreenCaptureKit delivers
        // microphone samples in the selected device's native format.
        configuration.capturesAudio = options.includeSystemAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = false
        configuration.captureMicrophone = options.includeMicrophone
        configuration.microphoneCaptureDeviceID = options.includeMicrophone ? options.microphoneDeviceID : nil
        configuration.shouldBeOpaque = true
        configuration.captureDynamicRange = .SDR
        configuration.showMouseClicks = options.showClicks
        if let sourceRect {
            configuration.sourceRect = sourceRect
        }
        return configuration
    }

    private static func evenVideoDimension(_ value: Int) -> Int {
        let clamped = max(value, 2)
        return clamped.isMultiple(of: 2) ? clamped : clamped + 1
    }

    /// Nothing is started, so there is nothing to stop.
    func stop() async throws {}

    private func shareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            ) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(throwing: NativeScreenRecorderError.unsupportedSource)
                }
            }
        }
    }

    private func makeFilter(
        for source: CaptureSource,
        from content: SCShareableContent
    ) throws -> (filter: SCContentFilter, width: Int, height: Int, sourceRect: CGRect?) {
        switch source.kind {
        case .display:
            guard let displayID = source.displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw NativeScreenRecorderError.missingDisplay
            }
            let excludedApplications = openRecorderApplications(in: content)
            return (
                SCContentFilter(
                    display: display,
                    excludingApplications: excludedApplications,
                    exceptingWindows: []
                ),
                max(display.width, 640),
                max(display.height, 360),
                nil
            )

        case .window:
            guard let window = resolveWindow(for: source, in: content) else {
                throw NativeScreenRecorderError.missingWindow
            }
            try verifyWindowIdentity(source: source, window: window)
            guard !isOpenRecorderApplication(window.owningApplication) else {
                throw NativeScreenRecorderError.selfCaptureUnsupported
            }
            let width = max(Int(window.frame.width), 640)
            let height = max(Int(window.frame.height), 360)
            return (
                SCContentFilter(desktopIndependentWindow: window),
                width,
                height,
                nil
            )

        case .area:
            guard let area = source.area else {
                throw NativeScreenRecorderError.unsupportedSource
            }
            let displayID = area.displayID ?? source.displayID
            let display = displayID.flatMap { id in
                content.displays.first(where: { $0.displayID == id })
            } ?? content.displays.first
            guard let display else {
                throw NativeScreenRecorderError.missingDisplay
            }

            let sourceRect = sourceRect(for: area, display: display)
            let excludedApplications = openRecorderApplications(in: content)
            return (
                SCContentFilter(
                    display: display,
                    excludingApplications: excludedApplications,
                    exceptingWindows: []
                ),
                max(Int(sourceRect.width.rounded()), 2),
                max(Int(sourceRect.height.rounded()), 2),
                sourceRect
            )
        }
    }

    private func openRecorderApplications(in content: SCShareableContent) -> [SCRunningApplication] {
        content.applications.filter { application in
            isOpenRecorderApplication(application)
        }
    }

    private func isOpenRecorderApplication(_ application: SCRunningApplication?) -> Bool {
        guard let application else {
            return false
        }

        return OpenRecorderCaptureExclusion.shouldExcludeApplication(
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.applicationName,
            processID: application.processID
        )
    }

    private func resolveWindow(for source: CaptureSource, in content: SCShareableContent) -> SCWindow? {
        if let windowID = source.windowID,
           let window = content.windows.first(where: { $0.windowID == windowID }) {
            if let expectedBundleID = source.ownerBundleID,
               let actualBundleID = window.owningApplication?.bundleIdentifier,
               expectedBundleID != actualBundleID {
                if let recovered = findWindowByIdentity(source: source, in: content) {
                    return recovered
                }
                return window
            }
            return window
        }

        return findWindowByIdentity(source: source, in: content)
    }

    private func findWindowByIdentity(source: CaptureSource, in content: SCShareableContent) -> SCWindow? {
        guard let bundleID = source.ownerBundleID else {
            return nil
        }
        return content.windows.first {
            $0.owningApplication?.bundleIdentifier == bundleID && $0.title == source.name
        }
    }

    private func verifyWindowIdentity(source: CaptureSource, window: SCWindow) throws {
        guard let expectedBundleID = source.ownerBundleID else {
            return
        }
        let actualBundleID = window.owningApplication?.bundleIdentifier
        guard expectedBundleID != actualBundleID else {
            return
        }
        throw NativeScreenRecorderError.windowIdentityChanged(
            expected: source.ownerName ?? source.name,
            actual: window.owningApplication?.applicationName
        )
    }

    private func sourceRect(for area: CaptureArea, display: SCDisplay) -> CGRect {
        guard let screen = NSScreen.screen(displayID: display.displayID) else {
            return CGRect(
                x: area.x,
                y: area.y,
                width: max(area.width, 1),
                height: max(area.height, 1)
            )
        }

        let frame = screen.frame
        let scaleX = CGFloat(display.width) / max(frame.width, 1)
        let scaleY = CGFloat(display.height) / max(frame.height, 1)
        let localX = CGFloat(area.x) - frame.minX
        let localBottomY = CGFloat(area.y) - frame.minY
        let width = CGFloat(area.width) * scaleX
        let height = CGFloat(area.height) * scaleY
        let topY = (frame.height - localBottomY - CGFloat(area.height)) * scaleY

        return CGRect(
            x: max(0, localX * scaleX),
            y: max(0, topY),
            width: max(width, 2),
            height: max(height, 2)
        )
    }
}
