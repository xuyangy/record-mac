import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
import VideoToolbox

/// A source located, ready to open a stream on.
struct ResolvedCaptureSource {
    /// Nil only for a source made up in a test, whose stream is not a real one.
    var filter: SCContentFilter?
    var geometry: CaptureSourceGeometry
    /// The `deviceID` of the screen segments.
    var deviceID: String
}

/// The part of `SCStream` the backend uses, so its lifecycle is testable without a stream. The
/// router reads `synchronizationClock` on the sample queue.
protocol CaptureStreaming: AnyObject, Sendable {
    var synchronizationClock: CMClock? { get }
    func addOutput(_ output: CaptureStreamRouter, type: SCStreamOutputType, queue: DispatchQueue) throws
    func startCapture() async throws
    func stopCapture() async throws
}

final class LiveCaptureStream: CaptureStreaming, @unchecked Sendable {
    let stream: SCStream

    init(filter: SCContentFilter, configuration: SCStreamConfiguration, delegate: SCStreamDelegate) {
        stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
    }

    var synchronizationClock: CMClock? { stream.synchronizationClock }

    func addOutput(_ output: CaptureStreamRouter, type: SCStreamOutputType, queue: DispatchQueue) throws {
        try stream.addStreamOutput(output, type: type, sampleHandlerQueue: queue)
    }

    func startCapture() async throws { try await stream.startCapture() }
    func stopCapture() async throws { try await stream.stopCapture() }
}

/// What a recording's backend did, beyond its tracks, for the frame report and diagnostics.
struct ScreenCaptureBackendReport {
    var router: CaptureStreamRouterReport?
    var screen: ScreenTrackOutcome?
    var audio: [AudioCaptureSource: AudioTrackCounts] = [:]
    /// Every encoder chosen for a screen segment's format, in the order the formats appeared.
    var encoders: [EncoderSelection] = []
    /// Why the stream stopped on its own, and when on the session clock.
    var streamStopped: (reason: String, at: CMTime?)?
    var startFailure: String?
    var stopCaptureFailure: String?

    /// The selected audio sources that wrote no sample, so have no track.
    var audioWithoutSamples: [AudioCaptureSource] {
        AudioCaptureSource.allCases.filter { audio[$0].map { $0.appendedFrames == 0 } ?? false }
    }

    /// The four screen frame counters, with frames refused before the writer; nil when a
    /// segment's file could not be counted.
    var frameReport: FrameReport? {
        guard let screen else { return nil }
        return FrameReport(segments: screen.frames + (router?.screenRejections.map { [$0] } ?? []))
    }
}

/// Records a display, window, or area with ScreenCaptureKit: one stream, its screen, system
/// audio, and microphone outputs on one serial sample queue, routed by `CaptureStreamRouter`
/// into native screen segments and one file per audio source in `directory` (T029). Adapted from
/// QuickRecorder's `RecordEngine` (UPSTREAM.md).
///
/// The stream keeps running while paused; the session clock leaves paused samples out. Screen
/// segments are HEVC, the encoder chosen per format by `EncoderSelector`. Alpha, the camera, and
/// the Presenter Overlay composite are not captured here, so `validate` refuses them rather than
/// recording without them. A selected microphone needs Microphone permission already granted;
/// the backend asks for no permission.
///
/// `stop` ends the session clock at the stop before it stops the stream, so a buffer stamped at
/// or after it is not written, and one stamped before it and still queued is. If the stream
/// stopped on its own before that, the session ends where it stopped: `stop` returns what was
/// captured with `endedEarlyAt` set, and `report` says why. `stop` finalises everything that
/// was created, also after a failed start.
@MainActor
final class ScreenCaptureBackend: CaptureBackend {
    /// Throws a `CapturePrepareError`.
    typealias Resolve = @MainActor (CaptureSource) async throws -> ResolvedCaptureSource
    typealias MakeStream = @MainActor (ResolvedCaptureSource, SCStreamConfiguration, SCStreamDelegate) throws -> CaptureStreaming

    let directory: URL
    private(set) var report = ScreenCaptureBackendReport()

    private let resolve: Resolve
    private let makeStream: MakeStream
    private let hasPermission: () -> Bool
    private let microphonePermitted: () -> Bool
    private let encoders: EncoderSelector
    private let queue = DispatchQueue(label: "local.recordmac.capture.samples")
    let stopObserver: StreamStopObserver

    private var options: CaptureEngineOptions?
    private var resolved: ResolvedCaptureSource?
    private var configuration: SCStreamConfiguration?
    private var clock: CaptureClock?
    private var stream: CaptureStreaming?
    private var captureStarted = false
    private var router: CaptureStreamRouter?
    private var screen: ScreenSegmentWriter?
    private var audio: AudioSourceWriters?
    private var segmentFiles: ScreenSegmentFiles?

    init(
        directory: URL,
        resolve: Resolve? = nil,
        makeStream: MakeStream? = nil,
        hasPermission: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        microphonePermitted: @escaping () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
        encoders: EncoderSelector = EncoderSelector(),
        hostTimeNow: @escaping () -> CMTime = CaptureClock.hostTimeNow
    ) {
        self.directory = directory
        stopObserver = StreamStopObserver(hostTimeNow: hostTimeNow)
        self.resolve = resolve ?? { try await ScreenCaptureSourceResolver.resolve($0) }
        self.makeStream = makeStream ?? { resolved, configuration, delegate in
            guard let filter = resolved.filter else { throw CapturePrepareError.sourceUnavailable("the source has no content filter") }
            return LiveCaptureStream(filter: filter, configuration: configuration, delegate: delegate)
        }
        self.hasPermission = hasPermission
        self.microphonePermitted = microphonePermitted
        self.encoders = encoders
    }

    /// The queue every output of the stream delivers on.
    var sampleQueue: DispatchQueue { queue }

    func validate(_ source: CaptureSource, _ options: CaptureEngineOptions) async throws {
        guard hasPermission() else { throw CapturePrepareError.permissionMissing("Screen Recording") }
        if options.microphoneDeviceID != nil, !microphonePermitted() {
            throw CapturePrepareError.permissionMissing("Microphone")
        }
        if options.wantsAlpha {
            throw CapturePrepareError.settingsNotProducible("alpha capture is not available in the screen backend")
        }
        if options.keepsPresenterComposite {
            throw CapturePrepareError.settingsNotProducible("the Presenter Overlay composite track is not available in the screen backend")
        }
        if options.cameraDeviceID != nil {
            throw CapturePrepareError.settingsNotProducible("camera capture is not available in the screen backend")
        }
        let resolved = try await resolve(source)
        let settings = CaptureStreamSettings(
            pixelWidth: resolved.geometry.pixelWidth, pixelHeight: resolved.geometry.pixelHeight,
            sourceRect: resolved.geometry.sourceRect, frameRate: options.frameRate,
            includesPointer: options.includesPointer, systemAudio: options.systemAudio,
            microphoneDeviceID: options.microphoneDeviceID)
        do {
            configuration = try CaptureStreamConfiguration.make(settings)
        } catch {
            throw CapturePrepareError.settingsNotProducible("\(error)")
        }
        self.options = options
        self.resolved = resolved
    }

    func start(clock: CaptureClock) async throws {
        guard let options, let resolved, let configuration else {
            throw CapturePrepareError.settingsNotProducible("start before a successful validate")
        }
        self.clock = clock
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let files = ScreenSegmentFiles(directory: directory, frameRate: options.frameRate, encoders: encoders)
            segmentFiles = files
            let screen = ScreenSegmentWriter(factory: files, deviceID: resolved.deviceID, frameRate: Double(options.frameRate))
            self.screen = screen
            var sources: Set<AudioCaptureSource> = []
            if options.systemAudio { sources.insert(.systemAudio) }
            if options.microphoneDeviceID != nil { sources.insert(.microphone) }
            let directory = directory
            let audio = AudioSourceWriters(sources: sources, start: nil) {
                directory.appendingPathComponent("\($0.rawValue).mov")
            }
            self.audio = audio

            stopObserver.clock = clock
            let stream = try makeStream(resolved, configuration, stopObserver)
            self.stream = stream
            let router = CaptureStreamRouter(
                clock: clock, syncClock: { [weak stream] in stream?.synchronizationClock },
                screen: screen, audio: audio, queue: queue)
            self.router = router
            try stream.addOutput(router, type: .screen, queue: queue)
            if options.systemAudio { try stream.addOutput(router, type: .audio, queue: queue) }
            if options.microphoneDeviceID != nil { try stream.addOutput(router, type: .microphone, queue: queue) }
            try await stream.startCapture()
            captureStarted = true
        } catch {
            report.startFailure = "\(error)"
            throw error
        }
    }

    func pause(atHostTime hostTime: CMTime) async throws {}

    func resume(atHostTime hostTime: CMTime) async throws {}

    func stop(atHostTime hostTime: CMTime) async throws -> [MediaTrack] {
        // The session ends before the stream is told to stop, so nothing stamped at or after the
        // stop, or after the stream stopped on its own, is written; buffers stamped before it and
        // still queued are.
        let early = stopObserver.stopped.flatMap { stopped in stopped.hostTime.flatMap { $0 < hostTime ? $0 : nil } }
        clock?.end(atHostTime: early ?? hostTime)
        let end = clock?.snapshot().sessionTime(endingAt: hostTime) ?? .zero
        if let stream, captureStarted {
            do { try await stream.stopCapture() } catch { report.stopCaptureFailure = "\(error)" }
        }
        let stopped = stopObserver.stopped
        if let stopped { report.streamStopped = (stopped.reason, early == nil ? nil : end) }

        if let router { report.router = await router.close() }
        if let screen { report.screen = await screen.finish(at: end) }
        if let audio { report.audio = await audio.finish() }
        report.encoders = segmentFiles?.selections ?? []

        var tracks: [MediaTrack] = []
        let endedEarlyAt = early == nil ? nil : end.seconds
        if let outcome = report.screen {
            let segments = outcome.segments.compactMap(\.segment)
            if !segments.isEmpty {
                tracks.append(MediaTrack(kind: .screen, segments: segments, requestedFrameRate: options?.frameRate,
                    endedEarlyAt: endedEarlyAt))
            }
        }
        for (source, kind) in [(AudioCaptureSource.systemAudio, MediaTrackKind.systemAudio), (.microphone, .microphone)] {
            guard let counts = report.audio[source], counts.appendedFrames > 0,
                  let first = counts.firstSampleTime, let last = counts.endTime,
                  let url = audio?.writer(for: source)?.url
            else { continue }
            let deviceID = source == .microphone ? options?.microphoneDeviceID ?? "microphone" : "system-audio"
            // The file starts at its first sample; the segment spans the samples written.
            tracks.append(MediaTrack(
                kind: kind,
                segments: [MediaSegment(fileRef: url.lastPathComponent, start: first.seconds, end: last.seconds, deviceID: deviceID)],
                endedEarlyAt: endedEarlyAt))
        }
        return tracks
    }
}

/// Keeps why the stream stopped on its own. ScreenCaptureKit calls it on its own queue.
final class StreamStopObserver: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: (reason: String, hostTime: CMTime?)?
    var clock: CaptureClock?
    let hostTimeNow: () -> CMTime

    init(hostTimeNow: @escaping () -> CMTime = CaptureClock.hostTimeNow) {
        self.hostTimeNow = hostTimeNow
    }

    var stopped: (reason: String, hostTime: CMTime?)? { lock.withLock { recorded } }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        streamDidStop(reason: "\(error.localizedDescription) (\(error))")
    }

    /// Records the first stop; the stream says nothing after it.
    func streamDidStop(reason: String) {
        let now = hostTimeNow()
        lock.withLock {
            if recorded == nil { recorded = (reason, now) }
        }
    }
}

/// Opens each screen segment's HEVC file at its native size, with the encoder chosen for that
/// exact format, and keeps every choice.
final class ScreenSegmentFiles: ScreenSegmentFileFactory, @unchecked Sendable {
    let directory: URL
    let frameRate: Int
    private let encoders: EncoderSelector
    private let lock = NSLock()
    private var chosen: [EncoderSelection] = []

    init(directory: URL, frameRate: Int, encoders: EncoderSelector) {
        self.directory = directory
        self.frameRate = frameRate
        self.encoders = encoders
    }

    var selections: [EncoderSelection] { lock.withLock { chosen } }

    func makeFile(index: Int, format: ScreenFrameFormat, start: CMTime) throws -> ScreenSegmentFile {
        let selection = try encoders.select(EncoderFormat(
            codec: .hevc, width: format.width, height: format.height, frameRate: frameRate,
            sourcePixelFormat: format.pixelFormat))
        lock.withLock { chosen.append(selection) }
        let fileRef = "screen-\(index).mov"
        let specification: [String: Any] = selection.path == .hardware
            ? [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true]
            : [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false]
        let writer = try AssetScreenSampleWriter(
            url: directory.appendingPathComponent(fileRef),
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: format.width,
                AVVideoHeightKey: format.height,
                AVVideoEncoderSpecificationKey: specification,
            ],
            startTime: start)
        return ScreenSegmentFile(writer: writer, fileRef: fileRef, hasAlpha: false)
    }
}

/// Finds a source in ScreenCaptureKit's shareable content and builds its filter and geometry.
@MainActor
enum ScreenCaptureSourceResolver {
    static func resolve(_ source: CaptureSource) async throws(CapturePrepareError) -> ResolvedCaptureSource {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw .sourceUnavailable("the shareable content could not be read: \(error.localizedDescription)")
        }
        let windows = content.windows.map {
            CaptureSourceLocator.Window(id: $0.windowID, bundleID: $0.owningApplication?.bundleIdentifier, title: $0.title,
                isOwnApplication: isOwnApplication($0.owningApplication))
        }
        let location = try CaptureSourceLocator.locate(source, displays: content.displays.map(\.displayID), windows: windows)
        let ownApplications = content.applications.filter(isOwnApplication)
        switch location {
        case .display(let id):
            let display = content.displays.first { $0.displayID == id }!
            let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
            if let area = source.area, source.kind == .area {
                guard let frame = NSScreen.screen(displayID: id)?.frame else {
                    throw .sourceUnavailable("display \(id) has no screen frame")
                }
                return ResolvedCaptureSource(filter: filter,
                    geometry: try .area(area, displayFrame: frame, scale: CGFloat(filter.pointPixelScale)),
                    deviceID: "display:\(id)")
            }
            return ResolvedCaptureSource(filter: filter,
                geometry: try .whole(pointSize: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale)),
                deviceID: "display:\(id)")
        case .window(let id):
            let window = content.windows.first { $0.windowID == id }!
            let filter = SCContentFilter(desktopIndependentWindow: window)
            return ResolvedCaptureSource(filter: filter,
                geometry: try .whole(pointSize: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale)),
                deviceID: "window:\(id)")
        }
    }

    private static func isOwnApplication(_ application: SCRunningApplication?) -> Bool {
        guard let application else { return false }
        return OpenRecorderCaptureExclusion.shouldExcludeApplication(
            bundleIdentifier: application.bundleIdentifier, applicationName: application.applicationName,
            processID: application.processID)
    }
}

/// Matches a capture source to the displays and windows on screen now.
enum CaptureSourceLocator {
    struct Window: Equatable {
        var id: CGWindowID
        var bundleID: String?
        var title: String?
        var isOwnApplication: Bool
    }

    enum Location: Equatable {
        case display(CGDirectDisplayID)
        case window(CGWindowID)
    }

    /// A display by its ID (an area by its own display, else the source's); a window by its ID
    /// when its owner still matches, else by owner and title. A window of this app is refused.
    static func locate(_ source: CaptureSource, displays: [CGDirectDisplayID], windows: [Window]) throws(CapturePrepareError) -> Location {
        switch source.kind {
        case .display, .area:
            let id = (source.kind == .area ? source.area?.displayID : nil) ?? source.displayID
            guard let id, displays.contains(id) else {
                throw .sourceUnavailable("the display for \(source.name) is no longer attached")
            }
            if source.kind == .area, source.area == nil {
                throw .settingsNotProducible("the area source has no area")
            }
            return .display(id)
        case .window:
            let byID = source.windowID.flatMap { id in windows.first { $0.id == id } }
            let window = byID.flatMap { $0.bundleID == source.ownerBundleID || source.ownerBundleID == nil ? $0 : nil }
                ?? source.ownerBundleID.flatMap { bundle in windows.first { $0.bundleID == bundle && $0.title == source.name } }
            guard let window else { throw .sourceUnavailable("the window \(source.name) is no longer open") }
            guard !window.isOwnApplication else {
                throw .settingsNotProducible("this app's own windows are not recorded")
            }
            return .window(window.id)
        }
    }
}
