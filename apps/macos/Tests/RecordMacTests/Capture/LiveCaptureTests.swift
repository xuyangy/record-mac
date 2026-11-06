@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import XCTest
@testable import RecordMac

/// The largest magnitude among the 32-bit float samples in `block`, copied out of every memory
/// block it spans.
func floatPeak(_ block: CMBlockBuffer) throws -> Float {
    let length = CMBlockBufferGetDataLength(block)
    guard length % MemoryLayout<Float>.size == 0 else { throw CocoaError(.fileReadCorruptFile) }
    var floats = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
    let status = floats.withUnsafeMutableBytes {
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
    }
    guard status == kCMBlockBufferNoErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    return floats.reduce(0) { max($0, abs($1)) }
}

final class FloatPeakTests: XCTestCase {
    /// A buffer made of two memory blocks, the louder sample in the second.
    func testThePeakCoversEveryBlockOfABuffer() throws {
        func block(_ values: [Float]) throws -> CMBlockBuffer {
            var block: CMBlockBuffer?
            let length = values.count * MemoryLayout<Float>.size
            XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length,
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0,
                blockBufferOut: &block), kCMBlockBufferNoErr)
            let result = try XCTUnwrap(block)
            _ = values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: result,
                offsetIntoDestination: 0, dataLength: length) }
            return result
        }
        let joined = try block([0.1, -0.2])
        XCTAssertEqual(CMBlockBufferAppendBufferReference(joined, targetBBuf: try block([0.05, -0.75, 0.3]),
            offsetToData: 0, dataLength: 0, flags: 0), kCMBlockBufferNoErr)
        XCTAssertFalse(CMBlockBufferIsRangeContiguous(joined, atOffset: 0, length: 0), "two memory blocks")
        XCTAssertEqual(try floatPeak(joined), 0.75)
        XCTAssertEqual(try floatPeak(try block([-0.5, 0.25])), 0.5)
    }
}

/// Records the main display through `CaptureEngine` and `ScreenCaptureBackend` with a real
/// ScreenCaptureKit stream. Runs only with `RECORDMAC_LIVE_CAPTURE=1`, since it needs the Screen
/// Recording permission and moves the pointer: this app's own windows are left out of a display
/// capture, so the moving pointer is what changes the picture.
///
/// The microphone case runs only with `RECORDMAC_LIVE_MICROPHONE` set as well: to a microphone's
/// unique ID, or to `default` for the system's default input. It needs the Microphone permission,
/// and someone should speak or tap the microphone while it records.
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

    private func options(rate: Int, microphone: String?) -> CaptureEngineOptions {
        CaptureEngineOptions(microphoneDeviceID: microphone, systemAudio: true, cameraDeviceID: nil, includesPointer: true,
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
    private func record(
        rate: Int, seconds: Double, pauseAfter: Double? = nil, pause: Double = 0, microphone: String? = nil
    ) async throws -> Recording {
        let recordingDirectory = directory.appendingPathComponent(
            "\(rate)fps-\(pauseAfter == nil ? "plain" : "paused")\(microphone == nil ? "" : "-microphone")")
        var backend: ScreenCaptureBackend!
        let engine = CaptureEngine(
            makeBackend: { _ in
                backend = ScreenCaptureBackend(directory: recordingDirectory, telemetry: nil)
                return backend
            },
            refreshRate: { [display] _ in CoreGraphicsDisplayRefreshSource().refreshRate(of: display) })
        XCTAssertTrue(engine.offers(source).frameRates.contains(rate), "\(rate) fps is offered")
        let session = try await engine.prepare(source, options(rate: rate, microphone: microphone))
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

    /// The largest sample magnitude in an audio file, from 0 to 1.
    private func peak(_ url: URL) async throws -> Float {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var peak: Float = 0
        while let sample = output.copyNextSampleBuffer() {
            guard sample.numSamples > 0 else { continue }
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample), "decoded audio has its samples")
            peak = max(peak, try floatPeak(block))
        }
        XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
        return peak
    }

    /// Checks one audio source's track against its file: its own track and file, every sample
    /// the writer took is in the file, nothing was refused, and the file's timeline mapped by
    /// the segment's start covers the segment exactly.
    @discardableResult
    private func checkAudio(
        _ recording: Recording, _ source: AudioCaptureSource, _ kind: MediaTrackKind, rate: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> (segment: MediaSegment, timeline: AudioTimeline, peak: Float) {
        let track = try XCTUnwrap(recording.tracks.first { $0.kind == kind }, "a \(kind) track", file: file, line: line)
        let audio = try XCTUnwrap(recording.report.audio[source], file: file, line: line)
        XCTAssertNil(audio.writerFailure, file: file, line: line)
        XCTAssertEqual(audio.rejectedAppendFrames + audio.rejectedFormatFrames + audio.droppedOverflowFrames, 0, file: file, line: line)
        XCTAssertEqual(recording.report.router?.audio[source]?.failed, [:], file: file, line: line)
        XCTAssertGreaterThan(audio.appendedFrames, 0, file: file, line: line)
        XCTAssertEqual(audio.written, .decoded(audio.appendedFrames), file: file, line: line)
        XCTAssertEqual(track.segments.count, 1, file: file, line: line)
        let segment = try XCTUnwrap(track.segments.first, file: file, line: line)
        let url = recording.directory.appendingPathComponent(segment.fileRef)
        let timeline = try await audioTimeline(url)
        XCTAssertEqual(timeline.frames, audio.appendedFrames, file: file, line: line)
        let sample = 1 / timeline.sampleRate
        let fileStart = try XCTUnwrap(timeline.start, file: file, line: line)
        XCTAssertEqual(segment.start + fileStart, segment.start, accuracy: sample, "the file starts at the segment's start", file: file, line: line)
        XCTAssertEqual(segment.start + timeline.end, segment.end, accuracy: sample, "the file ends at the segment's end", file: file, line: line)
        let fileDuration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(fileDuration, segment.end - segment.start, accuracy: 0.002,
            "the file holds no time before its first sample", file: file, line: line)
        let screen = try XCTUnwrap(recording.tracks.first { $0.kind == .screen }, file: file, line: line)
        let screenEnd = screen.segments.last?.end ?? 0
        XCTAssertLessThanOrEqual(segment.end, screenEnd + 1e-6, "no audio past the recording's end", file: file, line: line)
        let level = try await peak(url)
        let gaps = timeline.gaps.map { String(format: "%.4f s at %.4f s", $0.length, segment.start + $0.at) }
        print("""
            LIVE \(rate) fps \(source.rawValue) \(segment.deviceID) \(segment.fileRef): \(timeline.frames) sample frames at \(timeline.sampleRate) Hz, \
            \(timeline.channels) channels; segment \(String(format: "%.4f", segment.start))-\(String(format: "%.4f", segment.end)) s; \
            file \(String(format: "%.4f", fileStart))-\(String(format: "%.4f", timeline.end)) s, duration \(String(format: "%.4f", fileDuration)) s; \
            recording ends \(String(format: "%.4f", screenEnd)) s; no audio for the last \(String(format: "%.4f", screenEnd - segment.end)) s; \
            gaps inside \(gaps.isEmpty ? "none" : gaps.joined(separator: ", ")); peak \(String(format: "%.4f", level)); \
            excluded \(recording.report.router?.audio[source]?.excluded ?? -1)
            """)
        return (segment, timeline, level)
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
        // No frame is written twice, and no more frames are written than the rate allows over
        // the recording. ScreenCaptureKit paces delivery to whole display refreshes, so one
        // interval can be shorter than 1/rate; the smallest is reported, not required.
        XCTAssertGreaterThan(smallest, 0.001, "no frame is written twice", file: file, line: line)
        XCTAssertLessThanOrEqual(Double(times.count), Double(rate) * (segment.end - segment.start) + 1,
            "no more frames than the rate allows", file: file, line: line)
        let shortGaps = zip(times.dropFirst(), times)
            .filter { later, earlier in later - earlier < 1 / Double(rate) - 0.002 }
            .map { later, earlier in String(format: "%.4f-%.4f", earlier, later) }
        let early = gaps.filter { $0 < 1 / Double(rate) - 0.002 }.count
        print("LIVE \(rate) fps short intervals: \(shortGaps); pause seams \(recording.pauseSeams.map { String(format: "%.4f", $0) })")
        XCTAssertLessThanOrEqual(times.last ?? 0, segment.end + 1e-6, file: file, line: line)

        // System audio. The test does not control what the Mac plays, so this shows routing, not
        // fidelity.
        try await checkAudio(recording, .systemAudio, .systemAudio, rate: rate, file: file, line: line)
        let audio = try XCTUnwrap(recording.report.audio[.systemAudio], file: file, line: line)
        if recording.report.audio[.microphone] == nil {
            XCTAssertFalse(recording.tracks.contains { $0.kind == .microphone }, "no microphone selected, no microphone track",
                file: file, line: line)
        }
        print("""
            LIVE \(rate) fps: \(segment.nativeSize.map { "\($0.width)x\($0.height)" } ?? "?") \
            segments \(screen.segments.count) end \(String(format: "%.3f", screen.segments.last?.end ?? 0)) s; \
            afterEnd \(recording.report.screen?.segments.map(\.frames.afterEnd).reduce(0, +) ?? -1); \
            delivered \(frames.delivered) rejected \(frames.appendRejected) written \(frames.written) \
            writerFailed \(frames.writerFailed); smallest gap \(String(format: "%.4f", smallest)) s, \
            \(early) of \(gaps.count) shorter than 1/\(rate) s; \
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

    func testAMicrophoneIsRecordedToItsOwnFileBesideSystemAudio() async throws {
        guard let selected = ProcessInfo.processInfo.environment["RECORDMAC_LIVE_MICROPHONE"] else {
            throw XCTSkip("set RECORDMAC_LIVE_MICROPHONE to a microphone's unique ID, or to default, to record it")
        }
        let device = try XCTUnwrap(selected == "default"
            ? AVCaptureDevice.default(for: .audio)
            : AVCaptureDevice(uniqueID: selected), "the microphone \(selected) is connected")
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else {
            XCTFail("Microphone is not granted to this process (status \(status.rawValue)); grant it to the terminal app and run again")
            throw XCTSkip("no Microphone permission")
        }
        print("LIVE microphone: \(device.localizedName) \(device.uniqueID); speak or tap it now")

        let recording = try await record(rate: 60, seconds: 3, pauseAfter: 1.5, pause: 1, microphone: device.uniqueID)
        try await check(recording, rate: 60, sessionSeconds: 3)
        let microphone = try await checkAudio(recording, .microphone, .microphone, rate: 60)
        let system = try XCTUnwrap(recording.tracks.first { $0.kind == .systemAudio }?.segments.first)
        XCTAssertEqual(microphone.segment.deviceID, device.uniqueID, "the selected microphone is kept")
        XCTAssertNotEqual(microphone.segment.fileRef, system.fileRef, "its own file")
        XCTAssertEqual(recording.report.audioWithoutSamples, [])
        XCTAssertGreaterThan(microphone.peak, 0, "the file holds sound, not only zeros")

        let pause = try XCTUnwrap(recording.pauseLengths.first)
        let excludedSamples = try XCTUnwrap(recording.report.router?.audio[.microphone]?.excluded)
        let excludedAudio = Double(excludedSamples) / microphone.timeline.sampleRate
        print("LIVE microphone pause: \(String(format: "%.4f", pause)) s; excluded \(excludedSamples) sample frames, \(String(format: "%.4f", excludedAudio)) s")
        XCTAssertEqual(excludedAudio, pause, accuracy: 0.05, "the microphone audio left out is the pause")
    }
}
