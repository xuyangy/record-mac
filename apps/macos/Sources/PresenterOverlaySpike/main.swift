// Presenter Overlay spike (research.md R-009, tasks.md T013).
//
// Runs the camera through AVCaptureSession and two named SCStreams, "clean" and "overlay", over
// the same display filter. The creator turns Presenter Overlay on from the system Video menu and
// chooses which stream receives it. For every complete frame of each stream the spike logs the
// stream name, presentation timestamp, and SCStreamFrameInfo.presenterOverlayContentRect, and it
// saves one frame per second of each stream as PNG. The camera is written to its own movie file
// so its usability while the effect is on can be checked afterwards.
//
// Output, under --output DIR or ~/Movies/PresenterOverlaySpike/<timestamp>/:
//   events.log       permissions, stream lifecycle, effect start and stop, camera changes
//   frames.jsonl     one line per complete frame of either stream
//   clean/, overlay/ one PNG per second of each stream
//   camera-N.mov     the camera recording, a new file after each camera switch
//   summary.json     per-stream frame counts, written on quit

import AppKit
import AVFoundation
import CoreImage
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

// MARK: - Log

/// Appends to events.log and frames.jsonl on one serial queue, so lines from the stream queues and
/// the main thread never interleave.
final class SpikeLog: @unchecked Sendable {
    let directory: URL
    private let queue = DispatchQueue(label: "spike.log")
    private let events: FileHandle
    private let frames: FileHandle
    private let timestampFormatter: ISO8601DateFormatter
    var onEvent: (@Sendable (String) -> Void)?

    init(directory: URL) throws {
        self.directory = directory
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["clean", "overlay"] {
            try fileManager.createDirectory(
                at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let eventsURL = directory.appendingPathComponent("events.log")
        let framesURL = directory.appendingPathComponent("frames.jsonl")
        fileManager.createFile(atPath: eventsURL.path, contents: nil)
        fileManager.createFile(atPath: framesURL.path, contents: nil)
        events = try FileHandle(forWritingTo: eventsURL)
        frames = try FileHandle(forWritingTo: framesURL)
        timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func event(_ message: String) {
        let line = "\(timestampFormatter.string(from: Date())) \(message)"
        queue.async {
            self.events.write(Data((line + "\n").utf8))
            print(line)
            self.onEvent?(line)
        }
    }

    func frame(_ record: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        else { return }
        queue.async {
            self.frames.write(data)
            self.frames.write(Data("\n".utf8))
        }
    }

    func flush() {
        queue.sync {
            try? events.synchronize()
            try? frames.synchronize()
        }
    }
}

// MARK: - Stream probe

/// Receives one stream's frames and delegate callbacks.
final class StreamProbe: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let name: String
    let generation: Int
    let log: SpikeLog
    private let imageQueue = DispatchQueue(label: "spike.png", qos: .utility)
    private let ciContext = CIContext()
    private let lock = NSLock()
    private var lastSavedSecond = Int.min
    private(set) var counts = FrameCounts()

    struct FrameCounts {
        var complete = 0
        var completeWithEngagedOverlayRect = 0
        var otherStatus: [String: Int] = [:]
        var effectStarts = 0
        var effectStops = 0
    }

    init(name: String, generation: Int, log: SpikeLog) {
        self.name = name
        self.generation = generation
        self.log = log
    }

    func snapshot() -> FrameCounts {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard
            let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let attachments = attachmentsArray.first,
            let statusRaw = attachments[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRaw)
        else { return }

        guard status == .complete else {
            lock.lock()
            counts.otherStatus[Self.describe(status), default: 0] += 1
            lock.unlock()
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let overlayValue = attachments[.presenterOverlayContentRect]
        let overlayRect = Self.rect(overlayValue)
        let contentRect = Self.rect(attachments[.contentRect])

        lock.lock()
        counts.complete += 1
        if let overlayRect, Self.isEngaged(overlayRect) { counts.completeWithEngagedOverlayRect += 1 }
        // A non-finite timestamp is still logged, but saves no PNG.
        var saveThisFrame = false
        if pts.seconds.isFinite {
            let second = Int(pts.seconds.rounded(.down))
            saveThisFrame = second != lastSavedSecond
            if saveThisFrame { lastSavedSecond = second }
        }
        lock.unlock()

        var record: [String: Any] = [
            "stream": name,
            "generation": generation,
            "pts": Self.number(pts.seconds),
            "ptsValue": pts.value,
            "ptsTimescale": pts.timescale,
            "presenterOverlayContentRect": Self.describe(overlayValue: overlayValue, rect: overlayRect),
            "presenterOverlayEngaged": overlayRect.map(Self.isEngaged) ?? false,
        ]
        if let contentRect { record["contentRect"] = Self.array(contentRect) }
        if let pixelBuffer = sampleBuffer.imageBuffer {
            record["pixelWidth"] = CVPixelBufferGetWidth(pixelBuffer)
            record["pixelHeight"] = CVPixelBufferGetHeight(pixelBuffer)
            if saveThisFrame { save(pixelBuffer, pts: pts) }
        }
        log.frame(record)
    }

    func outputVideoEffectDidStart(for stream: SCStream) {
        lock.lock()
        counts.effectStarts += 1
        lock.unlock()
        log.event("[\(name) g\(generation)] outputVideoEffectDidStart")
    }

    func outputVideoEffectDidStop(for stream: SCStream) {
        lock.lock()
        counts.effectStops += 1
        lock.unlock()
        log.event("[\(name) g\(generation)] outputVideoEffectDidStop")
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.event("[\(name) g\(generation)] didStopWithError: \(error.localizedDescription)")
    }

    private func save(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        let url = log.directory
            .appendingPathComponent(name)
            .appendingPathComponent(String(format: "g%d-%012.3f.png", generation, pts.seconds))
        let frame = UncheckedPixelBuffer(buffer: pixelBuffer)
        imageQueue.async { [ciContext] in
            let image = CIImage(cvPixelBuffer: frame.buffer)
            guard
                let cgImage = ciContext.createCGImage(image, from: image.extent),
                let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(destination, cgImage, nil)
            CGImageDestinationFinalize(destination)
        }
    }

    private static func rect(_ value: Any?) -> CGRect? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CFDictionaryGetTypeID() else {
            return nil
        }
        return CGRect(dictionaryRepresentation: value as! CFDictionary)
    }

    /// A rect counts as the overlay being engaged only when it is a finite, non-empty area.
    /// CGRect.null, whose origin is infinite, does not count; which value the system attaches
    /// while the overlay is off is for T014 to observe.
    private static func isEngaged(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && !rect.isEmpty
            && [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite)
    }

    /// The attachment as logged: null when absent, "null-rect" for CGRect.null, the raw value as
    /// text when it is not a rect, and [x, y, width, height] otherwise.
    private static func describe(overlayValue: Any?, rect: CGRect?) -> Any {
        guard let overlayValue else { return NSNull() }
        guard let rect else { return "unparsed: \(overlayValue)" }
        return rect.isNull ? "null-rect" : array(rect)
    }

    /// JSONSerialization throws an Objective-C exception on NaN and infinity, so those are
    /// written as text.
    private static func number(_ value: Double) -> Any {
        value.isFinite ? value : String(describing: value)
    }

    private static func array(_ rect: CGRect) -> [Any] {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].map { number(Double($0)) }
    }

    static func describe(_ status: SCFrameStatus) -> String {
        switch status {
        case .complete: "complete"
        case .idle: "idle"
        case .blank: "blank"
        case .suspended: "suspended"
        case .started: "started"
        case .stopped: "stopped"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }
}

/// Carries a frame to the PNG queue. ScreenCaptureKit does not reuse a delivered buffer while it
/// is retained, and the PNG queue only reads it.
struct UncheckedPixelBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

// MARK: - Camera

/// Records the camera to camera-N.mov, starting a new file on each camera switch.
@MainActor
final class CameraRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let log: SpikeLog
    private var input: AVCaptureDeviceInput?
    private var fileIndex = 0
    private var observers: [NSObjectProtocol] = []
    /// Files stopped on purpose by a switch or stop, whose finish needs no restart.
    private var intentionalStops = Set<URL>()
    private var restartsAfterFailure = 0
    private var isPaused = false
    /// A replacement file that was due while paused.
    private var restartPendingResume = false
    private static let maximumRestartsAfterFailure = 3

    init(log: SpikeLog) {
        self.log = log
        super.init()
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main
            ) { [log] note in
                let device = note.object as? AVCaptureDevice
                log.event("camera disconnected: \(device?.localizedName ?? "?") (\(device?.uniqueID ?? "?"))")
            })
        observers.append(
            center.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main
            ) { [log] note in
                let device = note.object as? AVCaptureDevice
                log.event("camera connected: \(device?.localizedName ?? "?") (\(device?.uniqueID ?? "?"))")
            })
        observers.append(
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main
            ) { [log] note in
                let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                log.event("camera session runtime error: \(error?.localizedDescription ?? "?")")
            })
    }

    static func availableCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified
        ).devices
    }

    var currentDevice: AVCaptureDevice? { input?.device }

    func start(with device: AVCaptureDevice) throws {
        session.beginConfiguration()
        let newInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(newInput) else {
            session.commitConfiguration()
            throw SpikeError("cannot add camera input \(device.localizedName)")
        }
        session.addInput(newInput)
        input = newInput
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        session.startRunning()
        log.event("camera started: \(device.localizedName) (\(device.uniqueID)) format \(device.activeFormat.formatDescription.dimensions)")
        startNewFile()
    }

    func switchTo(_ device: AVCaptureDevice) {
        guard device.uniqueID != input?.device.uniqueID else { return }
        stopRecordingIntentionally()
        session.beginConfiguration()
        if let input { session.removeInput(input) }
        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                input = newInput
            }
        } catch {
            log.event("camera switch failed: \(error.localizedDescription)")
        }
        session.commitConfiguration()
        log.event("camera switched to: \(device.localizedName) (\(device.uniqueID)) format \(device.activeFormat.formatDescription.dimensions)")
        startNewFile()
    }

    /// Pause is kept here, not read back from the movie output, because a file may be between a
    /// failure and its replacement when Pause is pressed.
    func pause() {
        isPaused = true
        if output.isRecording { output.pauseRecording() }
        log.event("camera recording paused")
    }

    func resume() {
        isPaused = false
        if output.isRecordingPaused {
            output.resumeRecording()
        } else if restartPendingResume, session.isRunning, !output.isRecording {
            log.event("starting the camera file deferred while paused")
            startNewFile()
        }
        restartPendingResume = false
        log.event("camera recording resumed")
    }

    func stop() {
        stopRecordingIntentionally()
        session.stopRunning()
    }

    private func stopRecordingIntentionally() {
        guard output.isRecording else { return }
        if let url = output.outputFileURL { intentionalStops.insert(url) }
        output.stopRecording()
    }

    private func startNewFile() {
        fileIndex += 1
        let url = log.directory.appendingPathComponent("camera-\(fileIndex).mov")
        output.startRecording(to: url, recordingDelegate: self)
    }

    /// A file that finished with an error, without the successfully-finished flag, and without a
    /// switch or stop asking for it, is followed by a new file while the session runs, at most
    /// three times. While paused, the new file waits for resume.
    private func handleFinish(of url: URL, failed: Bool) {
        guard intentionalStops.remove(url) == nil, failed, session.isRunning else { return }
        guard restartsAfterFailure < Self.maximumRestartsAfterFailure else {
            log.event("camera file stopped again; no further restart")
            return
        }
        restartsAfterFailure += 1
        guard !isPaused else {
            restartPendingResume = true
            log.event("camera file stopped unexpectedly while paused; a new file starts on resume (restart \(restartsAfterFailure))")
            return
        }
        log.event("camera file stopped unexpectedly; starting a new file (restart \(restartsAfterFailure))")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard self.session.isRunning, !self.output.isRecording else { return }
            guard !self.isPaused else {
                self.restartPendingResume = true
                self.log.event("paused during the restart delay; a new file starts on resume")
                return
            }
            self.startNewFile()
        }
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        log.event("camera file started: \(fileURL.lastPathComponent)")
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection], error: Error?
    ) {
        var failed = false
        if let error {
            let nsError = error as NSError
            // A finish can carry an error yet still have written a usable file.
            let finished = nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false
            failed = !finished
            log.event("camera file finished: \(outputFileURL.lastPathComponent) with error \(nsError.domain) \(nsError.code), successfullyFinished=\(finished): \(error.localizedDescription)")
        } else {
            log.event("camera file finished: \(outputFileURL.lastPathComponent)")
        }
        Task { @MainActor in self.handleFinish(of: outputFileURL, failed: failed) }
    }
}

struct SpikeError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: - Controller

@MainActor
final class SpikeController: NSObject, NSApplicationDelegate {
    private let log: SpikeLog
    private var camera: CameraRecorder!
    private var displays: [SCDisplay] = []
    /// The captured display, kept by ID because the shareable-content order can change.
    private var selectedDisplayID: CGDirectDisplayID?
    private var excludeOwnWindows = true
    private var generation = 0
    private var streams: [(stream: SCStream, probe: StreamProbe)] = []
    private var retiredProbes: [StreamProbe] = []
    private var paused = false

    private var window: NSWindow!
    private let statusField = NSTextField(wrappingLabelWithString: "")
    private let eventsView = NSTextView()
    private let cameraPopup = NSPopUpButton()
    private let pauseButton = NSButton()

    init(log: SpikeLog) {
        self.log = log
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        camera = CameraRecorder(log: log)
        buildWindow()
        // The controller lives for the whole process, so the log may hold it.
        log.onEvent = { [controller = self] line in
            Task { @MainActor in controller.appendEvent(line) }
        }
        log.event("output directory: \(log.directory.path)")
        log.event("bundle: \(Bundle.main.bundleIdentifier ?? "none") at \(Bundle.main.bundlePath)")
        log.event("os: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        Task { await self.begin() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await self.finish()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func begin() async {
        logPermissionState("before request")

        let cameraGranted = await AVCaptureDevice.requestAccess(for: .video)
        log.event("camera access request returned \(cameraGranted)")

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            displays = content.displays
            log.event("screen recording: shareable content returned \(displays.count) display(s)")
        } catch {
            log.event("screen recording: shareable content failed: \(error.localizedDescription)")
        }
        logPermissionState("after request")

        if cameraGranted, let device = AVCaptureDevice.default(for: .video) {
            do {
                // The preview joins the session before it runs and before the movie file starts.
                // A movie file started before the preview was attached stopped at once; the
                // preview's reconfiguration of the running session is the suspected cause.
                attachPreview()
                try camera.start(with: device)
            } catch {
                log.event("camera start failed: \(error.localizedDescription)")
            }
        } else if cameraGranted {
            log.event("no camera available")
        }
        reloadCameraPopup()

        guard !displays.isEmpty else {
            setStatus("Screen recording is not available. See events below.")
            return
        }
        await startStreams()
    }

    private func logPermissionState(_ moment: String) {
        let camera = AVCaptureDevice.authorizationStatus(for: .video)
        let cameraDescription: String
        switch camera {
        case .authorized: cameraDescription = "authorized"
        case .denied: cameraDescription = "denied"
        case .restricted: cameraDescription = "restricted"
        case .notDetermined: cameraDescription = "notDetermined"
        @unknown default: cameraDescription = "unknown"
        }
        log.event("permissions \(moment): camera=\(cameraDescription) screenRecordingPreflight=\(CGPreflightScreenCaptureAccess())")
    }

    // MARK: Streams

    /// Only called while `displays` is non-empty.
    private var currentDisplay: SCDisplay {
        displays.first { $0.displayID == selectedDisplayID } ?? displays[0]
    }

    private func currentFilter() -> SCContentFilter {
        let display = currentDisplay
        let excluded = excludeOwnWindows ? ownApplications : []
        return SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
    }

    /// This process, from the latest shareable content, for the filter toggle.
    private var ownApplications: [SCRunningApplication] = []

    private func refreshContent() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            displays = content.displays
            let pid = ProcessInfo.processInfo.processIdentifier
            ownApplications = content.applications.filter { $0.processID == pid }
            if !displays.contains(where: { $0.displayID == selectedDisplayID }) {
                // Start on the built-in display, the reference display for SC-002.
                selectedDisplayID = (displays.first { CGDisplayIsBuiltin($0.displayID) != 0 } ?? displays.first)?.displayID
            }
        } catch {
            log.event("shareable content refresh failed: \(error.localizedDescription)")
        }
    }

    private func configuration(named name: String, for display: SCDisplay) -> SCStreamConfiguration {
        let scale = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == display.displayID
        }?.backingScaleFactor ?? 2
        let configuration = SCStreamConfiguration()
        configuration.streamName = name
        configuration.width = Int(CGFloat(display.width) * scale)
        configuration.height = Int(CGFloat(display.height) * scale)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.showsCursor = true
        configuration.queueDepth = 6
        configuration.presenterOverlayPrivacyAlertSetting = .system
        return configuration
    }

    private func startStreams() async {
        await refreshContent()
        guard !displays.isEmpty else { return }
        generation += 1
        let display = currentDisplay
        let filter = currentFilter()
        var started: [(SCStream, StreamProbe)] = []
        for name in ["clean", "overlay"] {
            let probe = StreamProbe(name: name, generation: generation, log: log)
            let configuration = configuration(named: name, for: display)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: probe)
            do {
                try stream.addStreamOutput(
                    probe, type: .screen,
                    sampleHandlerQueue: DispatchQueue(label: "spike.stream.\(name)", qos: .userInteractive))
                try await stream.startCapture()
                started.append((stream, probe))
                log.event("[\(name) g\(generation)] started on display \(display.displayID) at \(configuration.width)x\(configuration.height), excludeOwnWindows=\(excludeOwnWindows)")
            } catch {
                log.event("[\(name) g\(generation)] start failed: \(error.localizedDescription)")
            }
        }
        streams = started.map { (stream: $0.0, probe: $0.1) }
        updateStatus()
    }

    private func stopStreams() async {
        for entry in streams {
            do {
                try await entry.stream.stopCapture()
                log.event("[\(entry.probe.name) g\(entry.probe.generation)] stopped")
            } catch {
                log.event("[\(entry.probe.name) g\(entry.probe.generation)] stop failed: \(error.localizedDescription)")
            }
            retiredProbes.append(entry.probe)
        }
        streams = []
    }

    private func applyFilter() async {
        await refreshContent()
        guard !displays.isEmpty else { return }
        let filter = currentFilter()
        let display = currentDisplay
        for entry in streams {
            do {
                try await entry.stream.updateContentFilter(filter)
                try await entry.stream.updateConfiguration(
                    configuration(named: entry.probe.name, for: display))
                log.event("[\(entry.probe.name) g\(entry.probe.generation)] filter updated: display \(display.displayID), excludeOwnWindows=\(excludeOwnWindows)")
            } catch {
                log.event("[\(entry.probe.name) g\(entry.probe.generation)] filter update failed: \(error.localizedDescription)")
            }
        }
        updateStatus()
    }

    // MARK: Actions

    @objc private func togglePause() {
        Task {
            if paused {
                paused = false
                camera.resume()
                await startStreams()
                pauseButton.title = "Pause"
                log.event("resumed")
            } else {
                paused = true
                await stopStreams()
                camera.pause()
                pauseButton.title = "Resume"
                log.event("paused")
            }
            updateStatus()
        }
    }

    @objc private func toggleFilter() {
        excludeOwnWindows.toggle()
        Task { await applyFilter() }
    }

    @objc private func nextDisplay() {
        guard displays.count > 1 else {
            log.event("only one display; source unchanged")
            return
        }
        let index = displays.firstIndex { $0.displayID == selectedDisplayID } ?? 0
        selectedDisplayID = displays[(index + 1) % displays.count].displayID
        Task { await applyFilter() }
    }

    @objc private func cameraChosen() {
        let cameras = CameraRecorder.availableCameras()
        let index = cameraPopup.indexOfSelectedItem
        guard cameras.indices.contains(index) else { return }
        camera.switchTo(cameras[index])
    }

    @objc private func refreshCameras() {
        reloadCameraPopup()
    }

    @objc private func revealOutput() {
        NSWorkspace.shared.activateFileViewerSelecting([log.directory])
    }

    private func finish() async {
        await stopStreams()
        camera?.stop()
        writeSummary()
        log.event("finished")
        log.flush()
    }

    private func writeSummary() {
        var perStream: [[String: Any]] = []
        for probe in retiredProbes + streams.map(\.probe) {
            let counts = probe.snapshot()
            perStream.append([
                "stream": probe.name,
                "generation": probe.generation,
                "complete": counts.complete,
                "completeWithEngagedPresenterOverlayRect": counts.completeWithEngagedOverlayRect,
                "otherStatus": counts.otherStatus,
                "effectStarts": counts.effectStarts,
                "effectStops": counts.effectStops,
            ])
        }
        let summary: [String: Any] = ["streams": perStream]
        if let data = try? JSONSerialization.data(
            withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        {
            try? data.write(to: log.directory.appendingPathComponent("summary.json"))
        }
    }

    // MARK: Window

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false)
        window.title = "Presenter Overlay Spike"

        let preview = NSView()
        preview.wantsLayer = true
        preview.identifier = NSUserInterfaceItemIdentifier("preview")
        preview.heightAnchor.constraint(equalToConstant: 240).isActive = true

        pauseButton.title = "Pause"
        pauseButton.bezelStyle = .rounded
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)

        cameraPopup.target = self
        cameraPopup.action = #selector(cameraChosen)

        func button(_ title: String, _ action: Selector) -> NSButton {
            NSButton(title: title, target: self, action: action)
        }
        let controls = NSStackView(views: [
            pauseButton,
            button("Toggle Filter", #selector(toggleFilter)),
            button("Next Display", #selector(nextDisplay)),
            cameraPopup,
            button("Refresh Cameras", #selector(refreshCameras)),
            button("Reveal Output", #selector(revealOutput)),
        ])
        controls.orientation = .horizontal

        eventsView.isEditable = false
        eventsView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scroll = NSScrollView()
        scroll.documentView = eventsView
        scroll.hasVerticalScroller = true
        eventsView.autoresizingMask = [.width]

        let stack = NSStackView(views: [preview, statusField, controls, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        for view in [preview, scroll] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        setStatus("Starting…")
    }

    private func attachPreview() {
        guard
            let preview = window.contentView?.subviews.first(where: {
                $0.identifier?.rawValue == "preview"
            })
        else { return }
        let layer = AVCaptureVideoPreviewLayer(session: camera.session)
        layer.videoGravity = .resizeAspect
        layer.frame = preview.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        preview.layer?.addSublayer(layer)
    }

    private func reloadCameraPopup() {
        cameraPopup.removeAllItems()
        let cameras = CameraRecorder.availableCameras()
        cameraPopup.addItems(withTitles: cameras.map(\.localizedName))
        if let current = camera.currentDevice,
            let index = cameras.firstIndex(where: { $0.uniqueID == current.uniqueID })
        {
            cameraPopup.selectItem(at: index)
        }
    }

    private func updateStatus() {
        let display = selectedDisplayID ?? 0
        setStatus(
            "\(paused ? "Paused" : "Capturing") · generation \(generation) · display \(display) · own windows \(excludeOwnWindows ? "excluded" : "included") · output \(log.directory.path)\nTurn Presenter Overlay on from the Video menu in the menu bar, and choose the \"overlay\" stream."
        )
    }

    private func setStatus(_ text: String) {
        statusField.stringValue = text
    }

    private func appendEvent(_ line: String) {
        eventsView.textStorage?.append(
            NSAttributedString(
                string: line + "\n",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ]))
        eventsView.scrollToEndOfDocument(nil)
    }
}

// MARK: - Entry point

func outputDirectory() -> URL {
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--output"), arguments.indices.contains(index + 1) {
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/PresenterOverlaySpike", isDirectory: true)
        .appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
}

let spikeLog: SpikeLog
do {
    spikeLog = try SpikeLog(directory: outputDirectory())
} catch {
    FileHandle.standardError.write(Data("Cannot create the output directory: \(error)\n".utf8))
    exit(1)
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let controller = SpikeController(log: spikeLog)
    application.delegate = controller
    withExtendedLifetime(controller) {
        application.run()
    }
}
