@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import XCTest
@testable import RecordMac

/// Records the main display through `CaptureEngine` and `ScreenCaptureBackend` with a real
/// ScreenCaptureKit stream. Runs only with `RECORDMAC_LIVE_CAPTURE=1`, since it needs the Screen
/// Recording permission and moves the pointer: this app's own windows are left out of a display
/// capture, so the moving pointer is what changes the picture.
@MainActor
final class LiveCaptureTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["RECORDMAC_LIVE_CAPTURE"] == "1" else {
            throw XCTSkip("set RECORDMAC_LIVE_CAPTURE=1 to record the screen")
        }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            XCTFail("Screen Recording is not granted to this process; grant it to the terminal app and run again")
            throw XCTSkip("no Screen Recording permission")
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-capture-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private let display = CGMainDisplayID()

    private var source: CaptureSource {
        CaptureSource(id: "display:\(display)", kind: .display, name: "Main display", subtitle: "", displayIndex: 0,
            displayID: display, windowID: nil, area: nil, thumbnailData: nil)
    }

    private func options(rate: Int) -> CaptureEngineOptions {
        CaptureEngineOptions(microphoneDeviceID: nil, systemAudio: true, cameraDeviceID: nil, includesPointer: true,
            frameRate: rate, wantsAlpha: false, keepsPresenterComposite: false)
    }

    /// Moves the pointer in a small circle about the display's centre, 240 times a second, until
    /// stopped, then puts it back.
    private final class PointerMover {
        private var timer: Timer?
        private let original = CGEvent(source: nil)?.location ?? .zero

        init(display: CGDirectDisplayID) {
            let bounds = CGDisplayBounds(display)
            let start = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 240, repeats: true) { _ in
                let angle = Date().timeIntervalSince(start) * 2 * .pi
                CGWarpMouseCursorPosition(CGPoint(x: bounds.midX + 80 * cos(angle), y: bounds.midY + 80 * sin(angle)))
            }
            RunLoop.main.add(timer!, forMode: .common)
        }

        func stop() {
            timer?.invalidate()
            CGWarpMouseCursorPosition(original)
        }
    }

    private struct Recording {
        var tracks: [MediaTrack]
        /// Session times where a pause removed time, so frames on either side may lie closer
        /// together than the rate allows.
        var pauseSeams: [Double]
        /// Each pause's length, in seconds of host time.
        var pauseLengths: [Double]
        var report: ScreenCaptureBackendReport
        var directory: URL
    }

    /// Records for `seconds` of session time, pausing for `pause` seconds after `pauseAfter`.
    private func record(rate: Int, seconds: Double, pauseAfter: Double? = nil, pause: Double = 0) async throws -> Recording {
        let recordingDirectory = directory.appendingPathComponent("\(rate)fps-\(pauseAfter == nil ? "plain" : "paused")")
        var backend: ScreenCaptureBackend!
        let engine = CaptureEngine(
            makeBackend: { _ in
                backend = ScreenCaptureBackend(directory: recordingDirectory)
                return backend
            },
            refreshRate: { [display] _ in CoreGraphicsDisplayRefreshSource().refreshRate(of: display) })
        XCTAssertTrue(engine.offers(source).frameRates.contains(rate), "\(rate) fps is offered")
        let session = try await engine.prepare(source, options(rate: rate))
        let mover = PointerMover(display: display)
        defer { mover.stop() }
        let clock = try await engine.start(session)
        if let pauseAfter {
            try await Task.sleep(for: .seconds(pauseAfter))
            try await engine.pause(session)
            try await Task.sleep(for: .seconds(pause))
            try await engine.resume(session)
            try await Task.sleep(for: .seconds(seconds - pauseAfter))
        } else {
            try await Task.sleep(for: .seconds(seconds))
        }
        let tracks = try await engine.stop(session)
        var removed = 0.0
        var seams: [Double] = []
        let pauses = clock.pauses(closingAt: CaptureClock.hostTimeNow())
        for pause in pauses {
            seams.append(pause.start - removed)
            removed += pause.end - pause.start
        }
        return Recording(tracks: tracks, pauseSeams: seams, pauseLengths: pauses.map { $0.end - $0.start },
            report: backend.report, directory: recordingDirectory)
    }

    /// Every frame's presentation time in a video file.
    private func frameTimes(_ url: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            if sample.numSamples > 0 { times.append(sample.presentationTimeStamp.seconds) }
        }
        return times.sorted()
    }

    /// An audio file's timeline read from its own buffers: the first sample's time, the latest
    /// end of any buffer (its time plus its frames over the sample rate), and every gap between
    /// one buffer's end and the next one's start longer than one sample.
    private struct AudioTimeline {
        var frames = 0
        var sampleRate = 0.0
        var channels = 0
        var start: Double?
        var end = 0.0
        var gaps: [(at: Double, length: Double)] = []
    }

    private func audioTimeline(_ url: URL) async throws -> AudioTimeline {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var timeline = AudioTimeline()
        var previousEnd: Double?
        while let sample = output.copyNextSampleBuffer() {
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0, let description = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
            else { continue }
            timeline.sampleRate = asbd.mSampleRate
            timeline.channels = Int(asbd.mChannelsPerFrame)
            let start = sample.presentationTimeStamp.seconds
            let end = start + Double(frames) / asbd.mSampleRate
            if let previousEnd, start - previousEnd > 1 / asbd.mSampleRate {
                timeline.gaps.append((previousEnd, start - previousEnd))
            }
            timeline.start = timeline.start ?? start
            timeline.end = max(timeline.end, end)
            timeline.frames += frames
            previousEnd = end
        }
        XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
        return timeline
    }

    private func check(_ recording: Recording, rate: Int, sessionSeconds: Double, file: StaticString = #filePath, line: UInt = #line) async throws {
        let screen = try XCTUnwrap(recording.tracks.first { $0.kind == .screen }, file: file, line: line)
        for track in recording.tracks { XCTAssertNoThrow(try track.validate(), file: file, line: line) }
        XCTAssertNil(screen.endedEarlyAt, file: file, line: line)
        XCTAssertEqual(screen.requestedFrameRate, rate, file: file, line: line)
        let mode = try XCTUnwrap(CGDisplayCopyDisplayMode(display))
        let segment = try XCTUnwrap(screen.segments.first)
        XCTAssertEqual(segment.nativeSize, PixelSize(width: mode.pixelWidth, height: mode.pixelHeight),
            "the native pixel size of the display", file: file, line: line)
        XCTAssertEqual(screen.segments.last?.end ?? 0, sessionSeconds, accuracy: 0.25, file: file, line: line)

        let frames = try XCTUnwrap(recording.report.frameReport, "every segment's file was counted", file: file, line: line)
        XCTAssertGreaterThan(frames.delivered, rate / 2, "the moving pointer delivers frames", file: file, line: line)
        XCTAssertEqual(frames.writerFailed, 0, file: file, line: line)
        XCTAssertEqual(frames.written + frames.appendRejected, frames.delivered, file: file, line: line)
        XCTAssertEqual(recording.report.router?.screen.failed, [:], file: file, line: line)
        XCTAssertEqual(recording.report.router?.screenUnknownStatuses, [:], file: file, line: line)
        XCTAssertNil(recording.report.startFailure, file: file, line: line)
        XCTAssertNil(recording.report.stopCaptureFailure, file: file, line: line)
        XCTAssertNil(recording.report.streamStopped, file: file, line: line)

        var times: [Double] = []
        for segment in screen.segments {
            let fileTimes = try await frameTimes(recording.directory.appendingPathComponent(segment.fileRef))
            times += fileTimes.map { $0 + segment.start }
        }
        XCTAssertEqual(times.count, frames.written, "the files hold the written frames", file: file, line: line)
        let gaps = zip(times.dropFirst(), times)
            .filter { later, earlier in !recording.pauseSeams.contains { earlier <= $0 && $0 <= later } }
            .map { $0 - $1 }
        let smallest = gaps.min() ?? .infinity
        XCTAssertGreaterThanOrEqual(smallest, 1 / Double(rate) - 0.002, "no two frames closer than the rate allows", file: file, line: line)
        XCTAssertLessThanOrEqual(times.last ?? 0, segment.end + 1e-6, file: file, line: line)

        // System audio: its own track and file, every sample the writer took is in the file, and
        // nothing was refused. No audio was playing, so this shows routing, not fidelity.
        let system = try XCTUnwrap(recording.tracks.first { $0.kind == .systemAudio }, "a system audio track", file: file, line: line)
        let audio = try XCTUnwrap(recording.report.audio[.systemAudio], file: file, line: line)
        XCTAssertNil(audio.writerFailure, file: file, line: line)
        XCTAssertEqual(audio.rejectedAppendFrames + audio.rejectedFormatFrames + audio.droppedOverflowFrames, 0, file: file, line: line)
        XCTAssertEqual(recording.report.router?.audio[.systemAudio]?.failed, [:], file: file, line: line)
        XCTAssertGreaterThan(audio.appendedFrames, 0, file: file, line: line)
        XCTAssertEqual(audio.written, .decoded(audio.appendedFrames), file: file, line: line)
        let timeline = try await audioTimeline(recording.directory.appendingPathComponent(try XCTUnwrap(system.segments.first).fileRef))
        XCTAssertEqual(timeline.frames, audio.appendedFrames, file: file, line: line)
        let audioStart = try XCTUnwrap(timeline.start, file: file, line: line)
        let audioEnd = timeline.end
        let trackEnd = system.segments.last?.end ?? 0
        let audioGaps = timeline.gaps.map { String(format: "%.4f s at %.4f s", $0.length, $0.at) }
        print("""
            LIVE \(rate) fps audio: \(timeline.frames) sample frames at \(timeline.sampleRate) Hz, \
            \(timeline.channels) channels; first sample at \(String(format: "%.4f", audioStart)) s, \
            last ends at \(String(format: "%.4f", audioEnd)) s; segment end \(String(format: "%.4f", trackEnd)) s; \
            uncovered at the start \(String(format: "%.4f", audioStart)) s, at the end \(String(format: "%.4f", trackEnd - audioEnd)) s; \
            gaps inside \(audioGaps.isEmpty ? "none" : audioGaps.joined(separator: ", "))
            """)
        XCTAssertGreaterThanOrEqual(audioStart, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(audioEnd, trackEnd + 1e-6, "no audio past the end", file: file, line: line)
        print("""
            LIVE \(rate) fps: \(segment.nativeSize.map { "\($0.width)x\($0.height)" } ?? "?") \
            segments \(screen.segments.count) end \(String(format: "%.3f", screen.segments.last?.end ?? 0)) s; \
            afterEnd \(recording.report.screen?.segments.map(\.frames.afterEnd).reduce(0, +) ?? -1); \
            delivered \(frames.delivered) rejected \(frames.appendRejected) written \(frames.written) \
            writerFailed \(frames.writerFailed); smallest gap \(String(format: "%.4f", smallest)) s; \
            excluded \(recording.report.router?.screen.excluded ?? -1); statuses \(recording.report.router?.screenStatuses ?? [:]); \
            encoder \(recording.report.encoders.map { "\($0.format.codec.rawValue) \($0.path.rawValue) \($0.encoderID)" }); \
            system audio written \(audio.written.map { "\($0)" } ?? "-") \
            excluded \(recording.report.router?.audio[.systemAudio]?.excluded ?? -1) \
            failed \(recording.report.router?.audio[.systemAudio]?.failed ?? [:])
            """)
    }

    func testRecordingTheMainDisplayAtEachOfferedRate() async throws {
        let offered = CaptureEngine(makeBackend: { _ in fatalError() },
            refreshRate: { [display] _ in CoreGraphicsDisplayRefreshSource().refreshRate(of: display) }).offers(source).frameRates
        print("LIVE offered rates: \(offered); refresh \(CoreGraphicsDisplayRefreshSource().refreshRate(of: display))")
        for rate in offered {
            let recording = try await record(rate: rate, seconds: 2)
            try await check(recording, rate: rate, sessionSeconds: 2)
        }
    }

    func testAPauseLeavesItsTimeOutOfTheRecording() async throws {
        let recording = try await record(rate: 60, seconds: 2, pauseAfter: 0.8, pause: 1)
        try await check(recording, rate: 60, sessionSeconds: 2)
        let excludedFrames = try XCTUnwrap(recording.report.router?.screen.excluded)
        let excludedSamples = try XCTUnwrap(recording.report.router?.audio[.systemAudio]?.excluded)
        let pause = try XCTUnwrap(recording.pauseLengths.first)
        let excludedAudio = Double(excludedSamples) / 48_000
        print("LIVE pause: \(String(format: "%.4f", pause)) s; screen frames excluded \(excludedFrames); audio excluded \(excludedSamples) sample frames, \(String(format: "%.4f", excludedAudio)) s")
        XCTAssertGreaterThan(excludedFrames, 0, "frames inside the pause are left out")
        // Audio arrives in packets of about 10 ms; the excluded samples are those stamped inside
        // the pause, so their length matches the pause to within a packet or two.
        XCTAssertEqual(excludedAudio, pause, accuracy: 0.05, "the audio left out is the pause")
    }
}
