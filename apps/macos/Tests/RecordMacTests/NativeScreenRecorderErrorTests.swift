import XCTest
@testable import RecordMac

@MainActor
final class NativeScreenRecorderErrorTests: XCTestCase {
    func testUnsupportedSourceErrorDescriptionExplainsMissingAreaSelection() {
        XCTAssertEqual(
            NativeScreenRecorderError.unsupportedSource.errorDescription,
            "Selected-area video recording requires a valid area selection."
        )
    }

    /// With no capture engine, starting a recording fails with a reason the creator can read,
    /// writes no file, and leaves the controller not recording.
    func testStartingARecordingFailsVisiblyWithoutCreatingMedia() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-recorder-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = CaptureController(screenRecordingPermission: ScreenRecordingPermission(
            client: ScreenRecordingPermissionClient(
                preflight: { true }, request: { true },
                hasRequestedPrompt: { false }, setRequestedPrompt: { _ in })))
        let source = CaptureSource(id: "display:1", kind: .display, name: "Display", subtitle: "",
            displayIndex: 1, displayID: nil, windowID: nil, area: nil, thumbnailData: nil)
        let options = RecordingCaptureOptions(
            includeMicrophone: true, microphoneDeviceID: nil, includeSystemAudio: true,
            includeCamera: false, cameraDeviceID: nil, showCursor: false, showClicks: false)

        do {
            _ = try await controller.startRecording(
                source: source, outputURL: directory.appendingPathComponent("recording.mp4"), options: options)
            XCTFail("a recording started")
        } catch {
            guard case .recordingEngineUnavailable = error as? NativeScreenRecorderError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(
                error.localizedDescription,
                "Recording is not available in this build: the capture engine is not built yet.")
        }
        XCTAssertFalse(controller.isRecording)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, [], "no media or audio file is created")

        try await NativeScreenRecorder().stop()
    }
}
