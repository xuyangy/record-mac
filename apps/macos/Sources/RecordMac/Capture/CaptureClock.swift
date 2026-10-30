import CoreMedia
import Foundation

/// The session epoch every track and activity event is stamped against
/// (contracts/capture-engine.md guarantee 7).
///
/// A buffer's time comes only from its own presentation timestamp, converted to the host clock
/// from the clock that produced it. Callback arrival time is never used. Session time starts at
/// zero at the epoch and stops while paused, so a paused stretch appears in no track; a buffer
/// stamped inside a pause has no session time and is not written.
final class CaptureClock: @unchecked Sendable {
    typealias Pause = CaptureClockSnapshot.Pause

    let epochHostTime: CMTime
    private let lock = NSLock()
    private var pauseIntervals: [Pause] = []

    static var hostClock: CMClock { CMClockGetHostTimeClock() }

    static func hostTimeNow() -> CMTime {
        CMClockGetTime(hostClock)
    }

    init(epochHostTime: CMTime) {
        precondition(epochHostTime.isNumeric, "The epoch must be a numeric host time")
        self.epochHostTime = epochHostTime
    }

    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pauseIntervals.last.map { $0.endHostTime == nil } ?? false
    }

    /// Stops session time at `hostTime`. Returns false, changing nothing, if already paused or if
    /// `hostTime` precedes the epoch or the last resume.
    @discardableResult
    func pause(atHostTime hostTime: CMTime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard hostTime.isNumeric, hostTime >= epochHostTime else { return false }
        if let last = pauseIntervals.last {
            guard let end = last.endHostTime, hostTime >= end else { return false }
        }
        pauseIntervals.append(Pause(startHostTime: hostTime))
        return true
    }

    /// Restarts session time at `hostTime`. Returns false, changing nothing, if not paused or if
    /// `hostTime` precedes the pause.
    @discardableResult
    func resume(atHostTime hostTime: CMTime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard hostTime.isNumeric, var last = pauseIntervals.last, last.endHostTime == nil,
            hostTime >= last.startHostTime
        else { return false }
        last.endHostTime = hostTime
        pauseIntervals[pauseIntervals.count - 1] = last
        return true
    }

    /// The epoch and every pause as they stand now, so one buffer is mapped against one state
    /// even while a pause or resume lands.
    func snapshot() -> CaptureClockSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return CaptureClockSnapshot(epochHostTime: epochHostTime, pauses: pauseIntervals)
    }

    /// Session time for a host-clock timestamp, or nil if it precedes the epoch or falls inside a
    /// pause.
    func sessionTime(forHostTime hostTime: CMTime) -> CMTime? {
        snapshot().sessionTime(forHostTime: hostTime)
    }

    /// Session time for a timestamp from `clock`, such as a stream's or capture session's
    /// synchronization clock.
    func sessionTime(for timestamp: CMTime, from clock: CMClock) -> CMTime? {
        sessionTime(forHostTime: CMSyncConvertTime(timestamp, from: clock, to: Self.hostClock))
    }

    /// Session time for a sample buffer's own presentation timestamp.
    func sessionTime(of sampleBuffer: CMSampleBuffer, from clock: CMClock) -> CMTime? {
        sessionTime(for: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), from: clock)
    }

    /// The paused intervals, in seconds of host time elapsed since the epoch, for the project's
    /// `pauses` list. A pause still open is closed at `endHostTime`.
    func pauses(closingAt endHostTime: CMTime) -> [CaptureTimeRange] {
        lock.lock()
        defer { lock.unlock() }
        return pauseIntervals.map { pause in
            let end = pause.endHostTime ?? endHostTime
            return CaptureTimeRange(
                start: (pause.startHostTime - epochHostTime).seconds,
                end: (end - epochHostTime).seconds)
        }
    }

    var reference: CaptureClockReference {
        let nanoseconds = CMTimeConvertScale(epochHostTime, timescale: 1_000_000_000, method: .roundHalfAwayFromZero)
        return CaptureClockReference(epochHostTimeNanoseconds: UInt64(max(nanoseconds.value, 0)))
    }
}

/// A `CaptureClock`'s epoch and pauses at one moment. Session time runs from the epoch and stops
/// from each pause's start up to, not including, its end.
struct CaptureClockSnapshot: Sendable {
    struct Pause: Sendable {
        let startHostTime: CMTime
        /// Nil while the pause is open.
        var endHostTime: CMTime?
    }

    /// A stretch of host time that has session time, from `start` up to, not including, `end`;
    /// nil `end` is open-ended.
    struct Span: Equatable, Sendable {
        var start: CMTime
        var end: CMTime?
    }

    let epochHostTime: CMTime
    let pauses: [Pause]

    /// Session time for a host-clock timestamp, or nil if it precedes the epoch or falls inside a
    /// pause.
    func sessionTime(forHostTime hostTime: CMTime) -> CMTime? {
        guard hostTime.isNumeric, hostTime >= epochHostTime else { return nil }
        var paused = CMTime.zero
        for pause in pauses {
            guard hostTime >= pause.startHostTime else { break }
            guard let end = pause.endHostTime, hostTime >= end else { return nil }
            paused = paused + (end - pause.startHostTime)
        }
        return hostTime - epochHostTime - paused
    }

    /// The host time that has session time, in order: from the epoch, less every pause. Empty
    /// pauses leave no gap.
    var spans: [Span] {
        var spans: [Span] = []
        var start = epochHostTime
        for pause in pauses {
            if let end = pause.endHostTime, end <= pause.startHostTime { continue }
            if pause.startHostTime > start { spans.append(Span(start: start, end: pause.startHostTime)) }
            guard let end = pause.endHostTime else { return spans }
            start = max(start, end)
        }
        spans.append(Span(start: start, end: nil))
        return spans
    }
}
