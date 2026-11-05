@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
@testable import RecordMac

/// Offset and drift between screen, system audio, microphone, and camera timestamps put on the
/// session clock by `SessionRetimer`, over an hour of host time and across pauses.
///
/// Synthetic only. Each source stamps its buffers on its own timebase, with its own origin and a
/// rate a few parts per million off the host clock, as separate devices do; in a recording,
/// ScreenCaptureKit's outputs share the stream's clock and the camera has its own. The camera
/// source is a camera-like video buffer, not a camera pipeline (T068). No device, stream, or
/// real clock is read.
///
/// A source's stamp for host time h is its timebase's reading at h, worked out here as
/// origin + rate × (h − anchor) and rounded to the source's timescale, the rounding a real
/// stamp has. The expected session time of that stamp is the host instant it denotes, less the
/// epoch and every pause before it, also worked out here. Neither comes from the code under test.
final class TrackAlignmentTests: XCTestCase {
    private enum Media {
        case video(timescale: CMTimeScale)
        case audio(AVAudioFormat)
    }

    private struct Source {
        var name: String
        var media: Media
        /// The timebase's reading at host time `anchorHost`.
        var origin: Double
        var anchorHost: Double
        /// The timebase's rate relative to the host clock.
        var rate: Double
        /// When the source's first buffer is stamped, in seconds of host time after the epoch.
        var firstAt: Double

        /// Seconds of host time one step of the source's stamps spans.
        var quantum: Double {
            switch media {
            case .video(let timescale): 1 / Double(timescale) / rate
            case .audio(let format): 1 / format.sampleRate / rate
            }
        }
    }

    private let epoch = 1000.0
    private let systemFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
    private let microphoneFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 1, interleaved: true)!

    /// Origins from 0 to 5000 s, rates from −20 to +40 parts per million: at an hour, an unread
    /// rate would put a source up to 144 ms off.
    private lazy var sources = [
        Source(name: "screen", media: .video(timescale: 1_000_000_000), origin: 0, anchorHost: 0, rate: 1, firstAt: 0.050),
        Source(name: "system audio", media: .audio(systemFormat), origin: 312.5, anchorHost: 900, rate: 1 - 20e-6, firstAt: 0.071),
        Source(name: "microphone", media: .audio(microphoneFormat), origin: 77.25, anchorHost: 950, rate: 1 + 15e-6, firstAt: 0.113),
        Source(name: "camera", media: .video(timescale: 600), origin: 5000, anchorHost: 990, rate: 1 + 40e-6, firstAt: 0.267),
    ]

    /// Common instants every source stamps, in seconds of host time after the epoch.
    private let events = [0.5, 1.0, 59.0, 600.0, 1799.0, 3599.0]

    private func cmHost(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1_000_000_000) }

    private func timebase(_ source: Source) throws -> CMTimebase {
        var timebase: CMTimebase?
        XCTAssertEqual(CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: CaptureClock.hostClock, timebaseOut: &timebase), noErr)
        let created = try XCTUnwrap(timebase)
        XCTAssertEqual(CMTimebaseSetRateAndAnchorTime(created, rate: source.rate,
            anchorTime: CMTime(seconds: source.origin, preferredTimescale: 1_000_000_000),
            immediateSourceTime: cmHost(source.anchorHost)), noErr)
        return created
    }

    /// The source's stamp for `offset` seconds of host time after the epoch, rounded to its
    /// timescale, and the host offset the rounded stamp denotes.
    private func stamp(_ source: Source, at offset: Double) -> (value: Int64, timescale: CMTimeScale, hostOffset: Double) {
        let reading = source.origin + source.rate * (epoch + offset - source.anchorHost)
        let timescale: CMTimeScale = switch source.media {
        case .video(let timescale): timescale
        case .audio(let format): CMTimeScale(format.sampleRate)
        }
        let value = Int64((reading * Double(timescale)).rounded())
        let denoted = source.anchorHost + (Double(value) / Double(timescale) - source.origin) / source.rate - epoch
        return (value, timescale, denoted)
    }

    /// One buffer from `source` stamped for `offset`: a 64 × 36 frame, or 10 ms of audio.
    private func buffer(_ source: Source, at offset: Double, seed: Int) throws -> CMSampleBuffer {
        let (value, timescale, _) = stamp(source, at: offset)
        switch source.media {
        case .video:
            let frame = try ScreenFrameFixtures.frame(atHostSeconds: 0, width: 64, height: 36)
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: value, timescale: timescale),
                decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: frame, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleBufferOut: &copy), noErr)
            return try XCTUnwrap(copy)
        case .audio(let format):
            let buffer = try AudioFixtures.buffer(format: format, frames: Int(format.sampleRate) / 100,
                start: Double(value) / Double(timescale), seed: seed).0
            XCTAssertEqual(buffer.presentationTimeStamp, CMTime(value: value, timescale: timescale))
            return buffer
        }
    }

    /// The session time the retimer gives `buffer`, or nil when it leaves the buffer out.
    private func retimed(_ buffer: CMSampleBuffer, _ source: Source, by retimer: SessionRetimer) throws -> Double? {
        switch source.media {
        case .video:
            return try retimer.screenFrame(buffer).get()?.presentationTimeStamp.seconds
        case .audio:
            let result = try retimer.audio(buffer).get()
            guard let first = result.pieces.first else {
                XCTAssertEqual(result.excludedFrames, CMSampleBufferGetNumSamples(buffer))
                return nil
            }
            XCTAssertEqual(result.pieces.count, 1, "\(source.name): 10 ms clear of every pause edge stays whole")
            return first.presentationTimeStamp.seconds
        }
    }

    /// Pauses as (start, end) offsets after the epoch.
    private func expectedSession(_ hostOffset: Double, pauses: [(Double, Double)]) -> Double? {
        var removed = 0.0
        for (start, end) in pauses {
            if hostOffset >= end { removed += end - start } else if hostOffset >= start { return nil }
        }
        return hostOffset - removed
    }

    private struct Measured {
        /// Session times of each source's own first buffer.
        var first: [String: Double] = [:]
        /// Session times of each common event, per source; nil when left out.
        var events: [String: [Double?]] = [:]
    }

    /// Stamps every source's first buffer and the common events, retimes them on one clock with
    /// `pauses` applied, and checks each against its expected session time. `inOrder` retimes
    /// each buffer once the clock has reached its time; otherwise every buffer is retimed in
    /// reverse after the last pause.
    private func measure(
        events: [Double], pauses: [(Double, Double)], inOrder: Bool, line: UInt = #line
    ) throws -> Measured {
        let clock = CaptureClock(epochHostTime: cmHost(epoch))
        var retimers: [String: SessionRetimer] = [:]
        for source in sources { retimers[source.name] = SessionRetimer(clock: clock, syncClock: try timebase(source)) }

        // (host offset, source, index among the source's buffers; -1 for its first buffer)
        var work: [(at: Double, source: Source, index: Int)] = []
        for source in sources {
            work.append((source.firstAt, source, -1))
            for (index, event) in events.enumerated() { work.append((event, source, index)) }
        }
        var transitions = pauses.flatMap { [(at: $0.0, pause: true), (at: $0.1, pause: false)] }
        func applyTransitions(through offset: Double) {
            while let next = transitions.first, next.at <= offset {
                transitions.removeFirst()
                XCTAssertTrue(next.pause ? clock.pause(atHostTime: cmHost(epoch + next.at)) : clock.resume(atHostTime: cmHost(epoch + next.at)))
            }
        }
        if inOrder {
            work.sort { $0.at < $1.at }
        } else {
            applyTransitions(through: .infinity)
            work.reverse()
        }

        var measured = Measured()
        for source in sources { measured.events[source.name] = Array(repeating: nil, count: events.count) }
        for (seed, item) in work.enumerated() {
            if inOrder { applyTransitions(through: item.at) }
            let source = item.source
            let session = try retimed(try buffer(source, at: item.at, seed: seed), source, by: try XCTUnwrap(retimers[source.name]))
            // The rounded stamp's own instant, mapped by arithmetic; conversion adds at most a
            // few nanoseconds.
            let expected = expectedSession(stamp(source, at: item.at).hostOffset, pauses: pauses)
            if let expected, let session {
                XCTAssertEqual(session, expected, accuracy: 1e-8, "\(source.name) at \(item.at)", line: line)
            } else {
                XCTAssertEqual(session == nil, expected == nil, "\(source.name) at \(item.at): left out \(expected == nil)", line: line)
            }
            if item.index < 0 { measured.first[source.name] = session } else { measured.events[source.name]?[item.index] = session }
        }
        return measured
    }

    /// For each pair of sources and each event both kept, their offset in session time; the
    /// offset at the first and last kept events, and its change, are within the pair's rounding.
    private func assertAligned(_ measured: Measured, events: [Double], pauses: [(Double, Double)], line: UInt = #line) {
        for (a, b) in pairs() {
            let (first, second) = (sources[a], sources[b])
            let bound = first.quantum / 2 + second.quantum / 2 + 2e-8
            let kept = events.indices.compactMap { index -> (Double, Double, Double)? in
                guard let x = measured.events[first.name]?[index], let y = measured.events[second.name]?[index],
                      let expected = expectedSession(events[index], pauses: pauses)
                else { return nil }
                XCTAssertEqual(x, expected, accuracy: first.quantum / 2 + 1e-8, "\(first.name) at \(events[index])", line: line)
                return (x - y, x, y)
            }
            guard let start = kept.first?.0, let end = kept.last?.0 else {
                XCTFail("\(first.name) and \(second.name) share no kept event", line: line)
                continue
            }
            XCTAssertLessThanOrEqual(abs(start), bound, "\(first.name) − \(second.name) at the first event", line: line)
            XCTAssertLessThanOrEqual(abs(end), bound, "\(first.name) − \(second.name) at the last event", line: line)
            XCTAssertLessThanOrEqual(abs(end - start), 2 * bound, "\(first.name) − \(second.name) drift", line: line)
            print(String(format: "ALIGN %@ − %@: offset %+.9f s at first, %+.9f s at last, drift %+.9f s, bound %.9f s",
                first.name, second.name, start, end, end - start, bound))
        }
    }

    private func pairs() -> [(Int, Int)] {
        sources.indices.flatMap { a in sources.indices.filter { $0 > a }.map { (a, $0) } }
    }

    func testFourClocksAgreeOnEveryEventAcrossAnHour() throws {
        let measured = try measure(events: events, pauses: [], inOrder: true)
        assertAligned(measured, events: events, pauses: [])
        // Each source keeps its own start: none is moved to zero.
        for source in sources {
            XCTAssertEqual(try XCTUnwrap(measured.first[source.name]), source.firstAt, accuracy: source.quantum / 2 + 1e-8, source.name)
        }
    }

    /// Two pauses: 60 s from 600 s and 0.25 s from 1800 s after the epoch. Events 5 ms either
    /// side of each pause edge; those inside are left out, and those after each resume lose
    /// exactly the time paused before them.
    func testFourClocksAgreeAfterPauses() throws {
        let pauses = [(600.0, 660.0), (1800.0, 1800.25)]
        let edges = [0.5, 599.98, 600.005, 659.98, 660.005, 1799.98, 1800.005, 1800.23, 1800.255, 3599.0]
        let measured = try measure(events: edges, pauses: pauses, inOrder: true)
        assertAligned(measured, events: edges, pauses: pauses)
        let kept = [true, true, false, false, true, true, false, false, true, true]
        for source in sources {
            XCTAssertEqual(measured.events[source.name]?.map { $0 != nil }, kept, source.name)
        }
        // Fixed values: 660.005 → 600.005, 1800.255 → 1740.005, 3599 → 3538.75.
        for (index, expected) in [(4, 600.005), (8, 1740.005), (9, 3538.75)] {
            for source in sources {
                XCTAssertEqual(try XCTUnwrap(measured.events[source.name]?[index] ?? nil), expected,
                    accuracy: source.quantum / 2 + 1e-8, "\(source.name) at \(edges[index])")
            }
        }
    }

    /// The same buffers retimed in reverse, each long after its time and after every pause, get
    /// the same session times as in order.
    func testDeliveryOrderAndDelayDoNotMoveATimestamp() throws {
        let pauses = [(600.0, 660.0), (1800.0, 1800.25)]
        let edges = [0.5, 599.98, 600.005, 660.005, 1800.255, 3599.0]
        let inOrder = try measure(events: edges, pauses: pauses, inOrder: true)
        let delayed = try measure(events: edges, pauses: pauses, inOrder: false)
        for source in sources {
            XCTAssertEqual(delayed.first[source.name], inOrder.first[source.name], source.name)
            XCTAssertEqual(delayed.events[source.name]!, inOrder.events[source.name]!, source.name)
        }
    }
}
