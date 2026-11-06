import AppKit
import CoreMedia
@preconcurrency import ScreenCaptureKit
import XCTest
@testable import RecordMac

/// The capture pipeline opt-in in `AppModel`: real `RecordingPipeline`, engine, and backend over the
/// stand-in streams, one per backend, with a spy telemetry or none, writing under a temporary
/// directory. No desktop, tap, hot key, camera, or user defaults of the system: camera permission is
/// refused, so the setup's camera prewarm stops before it opens a capture session. The epoch is
/// host 1000 s.
@MainActor
final class AppModelCapturePipelineTests: XCTestCase {
    private final class SpyTelemetry: BackendTelemetry {
        func start() throws -> TelemetryRecorderStatus { .running }
        func didResume(atHostTime hostTime: CMTime) {}
        func stop() async throws -> TelemetryOutcome {
            TelemetryOutcome(stream: ActivityStream(events: [], geometry: []), activity: .idle,
                counts: TelemetryRecorderCounts(), geometry: GeometryFeedCounts(), coverage: nil)
        }
    }

    private let epoch = 1000.0
    private var root: URL!
    private var streams: [FakeCaptureStream] = []
    private var streamsFailStart = false
    private var stream: FakeCaptureStream { streams.last! }
    private var now = CMTime.zero
    private var pipelineEnabled = true
    private var telemetryEnabled = true
    private var pipelinesMade: [RecordingPipeline] = []
    private var backends: [ScreenCaptureBackend] = []
    private var filtersGiven: [ActivityEventFilter] = []
    private var legacyCalls: [String] = []
    private var holdsResolve = false
    private var heldResolve: CheckedContinuation<Void, Never>?

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("app-pipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var locations: CapturePipelineRoute.Locations {
        CapturePipelineRoute.Locations(captures: root.appendingPathComponent("captures", isDirectory: true),
            projects: root.appendingPathComponent("projects", isDirectory: true))
    }

    private var outputURL: URL { root.appendingPathComponent("recording-1.mp4") }

    private func host(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }
    private func at(_ seconds: Double) { now = host(epoch + seconds) }

    private func makeModel() -> AppModel {
        let library = LegacyProjectLibraryStore(locations: LegacyLibraryLocations(
            recordings: root.appendingPathComponent("legacy-recordings"), screenshots: root.appendingPathComponent("legacy-shots"),
            projects: root.appendingPathComponent("legacy-projects"), support: root.appendingPathComponent("legacy-support")))
        return AppModel(
            screenRecordingPermission: makePermission(),
            captureUIHideDelayNanoseconds: 0,
            startRecordingCapture: { [unowned self] _, _, _ in
                legacyCalls.append("screen-start")
                return Date()
            },
            stopRecording: { [unowned self] in
                legacyCalls.append("screen-stop")
                return outputURL
            },
            prepareCameraPermission: { [unowned self] in
                legacyCalls.append("camera-permission")
                return false
            },
            prepareFacecamRecording: { [unowned self] _ in legacyCalls.append("facecam-prepare") },
            startFacecamRecording: { [unowned self] _, _ in
                legacyCalls.append("facecam-start")
                return Date()
            },
            stopFacecamRecording: { [unowned self] in
                legacyCalls.append("facecam-stop")
                return nil
            },
            runRecordingCountdown: { _ in },
            // Legacy registration fails, so a legacy recording never writes outside the test directory.
            registerCapturedMedia: { _, _ in throw CocoaError(.fileWriteUnknown) },
            capturePipelineEnabled: { [unowned self] in pipelineEnabled },
            makeRecordingPipeline: { [unowned self] directory, filter in
                filtersGiven.append(filter)
                let pipeline = RecordingPipeline(
                    captureDirectory: directory, activityFilter: filter, refreshRate: { _ in .hertz(60) },
                    hostTimeNow: { [unowned self] in now },
                    makeBackend: { [unowned self] directory, filter in
                        let telemetry: BackendTelemetryFactory? = telemetryEnabled ? { _, _, _ in SpyTelemetry() } : nil
                        let stream = FakeCaptureStream()
                        stream.failStart = streamsFailStart
                        streams.append(stream)
                        let backend = ScreenCaptureBackend(
                            directory: directory,
                            resolve: { [unowned self] _ in
                                if holdsResolve { await withCheckedContinuation { heldResolve = $0 } }
                                return ResolvedCaptureSource(filter: nil,
                                    geometry: CaptureSourceGeometry(pixelWidth: 256, pixelHeight: 144, sourceRect: nil),
                                    deviceID: "display:1", location: .display(1), pointPixelScale: 1)
                            },
                            makeStream: { _, _, _ in stream },
                            hasPermission: { true },
                            microphonePermitted: { true },
                            hostTimeNow: { [unowned self] in now },
                            telemetry: telemetry,
                            activityFilter: filter)
                        backends.append(backend)
                        return backend
                    })
                pipelinesMade.append(pipeline)
                return pipeline
            },
            capturePipelineLocations: locations,
            library: library)
    }

    private func makePermission() -> ScreenRecordingPermission {
        ScreenRecordingPermission(client: ScreenRecordingPermissionClient(
            preflight: { true }, request: { true }, hasRequestedPrompt: { false }, setRequestedPrompt: { _ in }))
    }

    private func source() -> CaptureSource {
        CaptureSource(id: "display:1", kind: .display, name: "Display 1", subtitle: "Built-in", displayIndex: 1,
            displayID: 1, windowID: nil, area: nil, thumbnailData: nil)
    }

    /// Starts a recording from the prepared file, as the capture machine does after preflight.
    private func startRecording(_ model: AppModel) async {
        let source = source()
        model.setCaptureStateForTesting(.ready(.recording, source))
        at(0)
        model.captureMachine.send(.recordingFilePrepared(source, outputURL))
    }

    private func deliver(_ seconds: Double) async throws {
        stream.deliver(try ScreenFrameFixtures.frame(atHostSeconds: epoch + seconds), .screen)
        let queue = try XCTUnwrap(backends.last).sampleQueue
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    private func wait(_ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !condition(), clock.now < deadline { try? await clock.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    private func stopped(_ model: AppModel) async {
        await wait { model.hudState.phase == .setup(.recording) }
    }

    private func projects() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: locations.projects.path)) ?? []
    }

    // MARK: Route

    func testWithTheOptInOffTheLegacyCaptureRecords() async throws {
        pipelineEnabled = false
        let model = makeModel()
        model.includeCamera = false
        await startRecording(model)
        await wait { model.hudState == .recording(self.source()) }
        XCTAssertEqual(legacyCalls, ["screen-start"])
        XCTAssertTrue(pipelinesMade.isEmpty)
        model.stopRecording()
        await wait { self.legacyCalls.contains("screen-stop") }
        XCTAssertTrue(pipelinesMade.isEmpty)
    }

    /// The whole recording runs on the pipeline: its project is written under the route's
    /// directory, and no legacy recorder, library, or editor is touched.
    func testWithTheOptInOnThePipelineRecordsAndWritesAProject() async throws {
        let model = makeModel()
        model.includeCamera = false
        var commands: [NativeWindowCommand] = []
        model.installNativeWindowCommandHandler { commands.append($0) }
        await startRecording(model)
        await wait { model.hudState == .recording(self.source()) }
        XCTAssertNotNil(model.activeRecordingStartDate)
        XCTAssertEqual(filtersGiven.count, 1)
        XCTAssertTrue(filtersGiven.first === model.activityFilter)
        try await deliver(0.1)
        at(0.5)
        model.stopRecording()
        await stopped(model)

        XCTAssertEqual(legacyCalls, [])
        XCTAssertFalse(commands.contains { $0.action == .showStudio }, "no editor")
        XCTAssertNil(model.currentVideoURL)
        XCTAssertNil(model.activeRecordingStartDate)
        XCTAssertEqual(projects(), ["recording-1.recordmac"])
        let store = ProjectStore(directory: locations.projects.appendingPathComponent("recording-1.recordmac"))
        let project = try store.readProject()
        XCTAssertEqual(project.displayName, "recording-1")
        XCTAssertEqual(project.sourceDescription, "Display 1")
        XCTAssertEqual(project.endReason, .completed)
        XCTAssertEqual(project.frameReport.written, 1)
        XCTAssertTrue(model.statusMessage.hasPrefix("Saved the capture project at \(store.directory.path)."), model.statusMessage)
        XCTAssertTrue(model.statusMessage.contains("Activity: tap idle, 0 events, 0 geometry segments."), model.statusMessage)
        XCTAssertEqual(model.lastFinalizedRecording?.tracks.map(\.kind), [.screen])
        XCTAssertEqual(stream.stopCalls, 1)
    }

    /// The route is chosen once: turning the opt-in off mid-recording still stops the pipeline.
    func testTheRouteIsKeptForTheWholeRecording() async throws {
        let model = makeModel()
        model.includeCamera = false
        await startRecording(model)
        await wait { model.hudState == .recording(self.source()) }
        pipelineEnabled = false
        try await deliver(0.1)
        at(0.5)
        model.stopRecording()
        await stopped(model)
        XCTAssertEqual(legacyCalls, [])
        XCTAssertEqual(projects(), ["recording-1.recordmac"])
    }

    // MARK: Refusals before capture

    /// The camera is refused before any permission, camera, or capture work, and stays on.
    func testTheCameraIsRefusedBeforeAnyCaptureWork() async throws {
        let model = makeModel()
        model.includeCamera = true
        // Turning the camera on prewarms the setup's preview, which asks for permission; refused, so
        // no capture session is opened.
        await wait { self.legacyCalls == ["camera-permission"] }
        legacyCalls = []
        model.setCaptureStateForTesting(.ready(.recording, source()))
        model.startRecording()
        XCTAssertEqual(model.statusMessage, CapturePipelineRoute.Refusal.camera.message)
        XCTAssertFalse(model.isCapturePreflightRunning)
        XCTAssertTrue(model.includeCamera, "the camera is not turned off")

        // A start that reaches the prepared file is refused the same way.
        await startRecording(model)
        await wait { model.hudState.phase == .setup(.recording) }
        XCTAssertEqual(model.statusMessage, CapturePipelineRoute.Refusal.camera.message)
        XCTAssertEqual(legacyCalls, [])
        XCTAssertTrue(pipelinesMade.isEmpty)
    }

    func testAMicrophoneWithNoDeviceIsRefused() async throws {
        let model = makeModel()
        model.includeCamera = false
        model.includeMicrophone = true
        model.captureOptions.send(.devicesRefreshed(microphones: [], cameras: []))
        await startRecording(model)
        await wait { model.hudState.phase == .setup(.recording) }
        XCTAssertEqual(model.statusMessage, CapturePipelineRoute.Refusal.noMicrophone.message)
        XCTAssertTrue(pipelinesMade.isEmpty)
    }

    func testEngineOptionsMapTheRecordingOptions() {
        let microphones = [CaptureDeviceInfo(id: "usb", name: "USB", isDefault: false),
            CaptureDeviceInfo(id: "built-in", name: "Built-in", isDefault: true)]
        var options = RecordingCaptureOptions(includeMicrophone: true, microphoneDeviceID: nil, includeSystemAudio: true,
            includeCamera: false, cameraDeviceID: nil, showCursor: true, showClicks: true)
        XCTAssertEqual(try CapturePipelineRoute.engineOptions(options, microphones: microphones).get(),
            CaptureEngineOptions(microphoneDeviceID: "built-in", systemAudio: true, cameraDeviceID: nil,
                includesPointer: true, frameRate: 60, wantsAlpha: false, keepsPresenterComposite: false))
        options.microphoneDeviceID = "usb"
        XCTAssertEqual(try CapturePipelineRoute.engineOptions(options, microphones: microphones).get().microphoneDeviceID, "usb")
        options.includeMicrophone = false
        options.showCursor = false
        options.includeSystemAudio = false
        let off = try? CapturePipelineRoute.engineOptions(options, microphones: microphones).get()
        XCTAssertNil(off?.microphoneDeviceID)
        XCTAssertEqual(off?.systemAudio, false)
        XCTAssertEqual(off?.includesPointer, false)
        options.includeMicrophone = true
        options.microphoneDeviceID = nil
        XCTAssertEqual(CapturePipelineRoute.engineOptions(options, microphones: []), .failure(.noMicrophone))
        options.includeCamera = true
        XCTAssertEqual(CapturePipelineRoute.engineOptions(options, microphones: microphones), .failure(.camera))
    }

    // MARK: Lifecycle

    /// A stop asked for while the pipeline starts finalises once, after the start.
    func testAStopDuringTheStartFinalizesOnceAfterIt() async throws {
        holdsResolve = true
        let model = makeModel()
        model.includeCamera = false
        await startRecording(model)
        await wait { self.heldResolve != nil }
        model.stopRecording()
        XCTAssertEqual(model.hudState.phase, .startingRecording(source(), stopRequested: true))
        heldResolve?.resume()
        await stopped(model)
        XCTAssertEqual(stream.stopCalls, 1)
        XCTAssertEqual(projects(), ["recording-1.recordmac"])
        XCTAssertEqual(legacyCalls, [])
    }

    func testAFailedStartRestoresTheSetup() async throws {
        streamsFailStart = true
        let model = makeModel()
        model.includeCamera = false
        await startRecording(model)
        await wait { model.hudState.phase == .setup(.recording) }
        XCTAssertEqual(model.statusMessage, "The recording did not start: the stream did not start.")
        XCTAssertNil(model.activeRecordingStartDate)
        XCTAssertEqual(legacyCalls, [])

        // Nothing of it is left for a later stop.
        model.stopRecording()
        XCTAssertEqual(legacyCalls, [])
        XCTAssertEqual(stream.stopCalls, 0)
    }

    /// A start cancelled while it runs changes nothing it no longer owns: the pipeline it started is
    /// finalised, no project is written, and a later stop finds nothing.
    func testACancelledStartIsFinalizedWithoutRecording() async throws {
        holdsResolve = true
        let model = makeModel()
        model.includeCamera = false
        await startRecording(model)
        await wait { self.heldResolve != nil }
        model.cancelCapture()
        XCTAssertEqual(model.hudState.phase, .setup(.recording))
        heldResolve?.resume()
        await wait { self.stream.stopCalls == 1 }
        XCTAssertTrue(stream.started)
        XCTAssertEqual(model.hudState.phase, .setup(.recording))
        XCTAssertEqual(model.statusMessage, "Ready")
        XCTAssertNil(model.activeRecordingStartDate)
        XCTAssertEqual(projects(), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: locations.captures.path).count, 1, "capture kept")

        model.stopRecording()
        XCTAssertEqual(stream.stopCalls, 1)
        XCTAssertEqual(legacyCalls, [])
    }

    /// A cancelled start that finishes after a newer recording started leaves the newer one alone.
    func testAStaleStartDoesNotReplaceANewerRecording() async throws {
        holdsResolve = true
        let model = makeModel()
        model.includeCamera = false
        await startRecording(model)
        await wait { self.heldResolve != nil }
        let stale = try XCTUnwrap(heldResolve)
        heldResolve = nil
        model.cancelCapture()

        holdsResolve = false
        await startRecording(model)
        await wait { model.hudState == .recording(self.source()) }
        XCTAssertEqual(streams.count, 2)
        let (old, current) = (streams[0], streams[1])

        stale.resume()
        await wait { old.stopCalls == 1 }
        XCTAssertEqual(model.hudState, .recording(source()))
        XCTAssertNotNil(model.activeRecordingStartDate)
        XCTAssertEqual(current.stopCalls, 0)

        try await deliver(0.1)
        at(0.5)
        model.stopRecording()
        await stopped(model)
        XCTAssertEqual(current.stopCalls, 1)
        XCTAssertEqual(old.stopCalls, 1)
        XCTAssertEqual(projects(), ["recording-1.recordmac"])
    }

    /// An older cancelled start that finishes while a newer start is pending leaves the newer one
    /// cancellable: cancelling it keeps the setup, and neither start records or writes a project.
    func testANewerPendingStartStaysCancellableAfterAnOlderOneFinishes() async throws {
        holdsResolve = true
        let model = makeModel()
        model.includeCamera = false
        await startRecording(model)
        await wait { self.heldResolve != nil }
        let first = try XCTUnwrap(heldResolve)
        heldResolve = nil
        model.cancelCapture()

        await startRecording(model)
        await wait { self.heldResolve != nil }
        let second = try XCTUnwrap(heldResolve)
        heldResolve = nil
        XCTAssertEqual(streams.count, 2)
        let (old, newer) = (streams[0], streams[1])

        first.resume()
        await wait { old.stopCalls == 1 }
        await Task.yield()
        model.cancelCapture()
        XCTAssertEqual(model.hudState.phase, .setup(.recording))

        second.resume()
        await wait { newer.stopCalls == 1 }
        XCTAssertEqual(model.hudState.phase, .setup(.recording))
        XCTAssertNil(model.activeRecordingStartDate)
        XCTAssertEqual(old.stopCalls, 1)
        XCTAssertEqual(projects(), [])
        model.stopRecording()
        XCTAssertEqual(newer.stopCalls, 1)
        XCTAssertEqual(legacyCalls, [])
    }

    func testTerminationWaitsForAPipelineRecording() async throws {
        let model = makeModel()
        model.includeCamera = false
        await startRecording(model)
        await wait { model.hudState == .recording(self.source()) }
        let canTerminate = await model.prepareForTermination()
        XCTAssertFalse(canTerminate)
    }

    // MARK: Captured without a project

    func testUnrecordedTelemetryKeepsTheCaptureWithoutAProject() async throws {
        telemetryEnabled = false
        let model = makeModel()
        model.includeCamera = false
        await startRecording(model)
        await wait { model.hudState == .recording(self.source()) }
        try await deliver(0.1)
        at(0.5)
        model.stopRecording()
        await stopped(model)

        let finalized = try XCTUnwrap(model.lastFinalizedRecording)
        XCTAssertEqual(model.statusMessage, "Captured, but no project was created: activity telemetry was not recorded "
            + "(disabled). The capture files are in \(finalized.captureDirectory.path).")
        XCTAssertEqual(projects(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalized.captureDirectory.appendingPathComponent("screen-0.mov").path))
        XCTAssertTrue(finalized.captureDirectory.standardizedFileURL.path.hasPrefix(locations.captures.standardizedFileURL.path))
    }

    func testAStreamThatStoppedOnItsOwnWritesNoProject() async throws {
        let model = makeModel()
        model.includeCamera = false
        await startRecording(model)
        await wait { model.hudState == .recording(self.source()) }
        try await deliver(0.1)
        at(0.2)
        try XCTUnwrap(backends.last).stopObserver.streamDidStop(reason: "the display was disconnected")
        at(0.5)
        model.stopRecording()
        await stopped(model)

        let finalized = try XCTUnwrap(model.lastFinalizedRecording)
        XCTAssertEqual(finalized.end, .streamStopped(reason: "the display was disconnected"))
        XCTAssertEqual(model.statusMessage, "Captured, but no project was created: the capture stopped on its own "
            + "(the display was disconnected). The capture files are in \(finalized.captureDirectory.path).")
        XCTAssertEqual(projects(), [])
    }
}
