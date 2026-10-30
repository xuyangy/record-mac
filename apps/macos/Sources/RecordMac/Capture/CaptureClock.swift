import CoreMedia
import Foundation

/// The session epoch every track and activity event is stamped against
/// (contracts/capture-engine.md guarantee 7).
///
/// A buffer's time comes only from its own presentation timestamp, converted to the host clock
/// from the clock that produced it. Callback arrival time is never used. Session time starts at
/// zero at the epoch and stops while paused, so a paused stretch appears in no track; a buffer
/// stamped inside a pause has no session time and is not written. Once the session ends, a
/// buffer stamped at or after the end has none either.
final class CaptureClock: @unchecked Sendable {
    typealias Pause = CaptureClockSnapshot.Pause

    let epochHostTime: CMTime
    private let lock = NSLock()
    private var pauseIntervals: [Pause] = []
    private var endHostTime: CMTime?

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
        guard endHostTime == nil, hostTime.isNumeric, hostTime >= epochHostTime else { return false }
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
        guard endHostTime == nil, hostTime.isNumeric, var last = pauseIntervals.last, last.endHostTime == nil,
            hostTime >= last.startHostTime
        else { return false }
        last.endHostTime = hostTime
        pauseIntervals[pauseIntervals.count - 1] = last
        return true
    }

    /// Ends session time at `hostTime`, so nothing stamped at or after it is written, while
    /// buffers stamped before it still are. An open pause stays open: the session already ended
    /// where it began. Returns false, changing nothing, if already ended or if `hostTime`
    /// precedes the epoch.
    @discardableResult
    func end(atHostTime hostTime: CMTime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard endHostTime == nil, hostTime.isNumeric, hostTime >= epochHostTime else { return false }
        endHostTime = hostTime
        return true
    }

    /// The epoch, every pause, and the end as they stand now, so one buffer is mapped against
    /// one state even while a pause, resume, or end lands.
    func snapshot() -> CaptureClockSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return CaptureClockSnapshot(epochHostTime: epochHostTime, pauses: pauseIntervals, endHostTime: endHostTime)
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
    /// Nil until the session ends.
    var endHostTime: CMTime?

    /// Session time for a host-clock timestamp, or nil if it precedes the epoch, falls inside a
    /// pause, or is at or after the end.
    func sessionTime(forHostTime hostTime: CMTime) -> CMTime? {
        guard hostTime.isNumeric, hostTime >= epochHostTime else { return nil }
        if let endHostTime, hostTime >= endHostTime { return nil }
        var paused = CMTime.zero
        for pause in pauses {
            guard hostTime >= pause.startHostTime else { break }
            guard let end = pause.endHostTime, hostTime >= end else { return nil }
            paused = paused + (end - pause.startHostTime)
        }
        return hostTime - epochHostTime - paused
    }

    /// Session time at `hostTime`, taken no later than the end, or where the pause began when it
    /// falls inside one, so a recording stopped while paused ends at its pause; nil before the
    /// epoch.
    func sessionTime(endingAt requested: CMTime) -> CMTime? {
        guard requested.isNumeric, requested >= epochHostTime else { return nil }
        let hostTime = endHostTime.map { min($0, requested) } ?? requested
        var paused = CMTime.zero
        for pause in pauses {
            guard hostTime >= pause.startHostTime else { break }
            guard let end = pause.endHostTime, hostTime >= end else {
                return pause.startHostTime - epochHostTime - paused
            }
            paused = paused + (end - pause.startHostTime)
        }
        return hostTime - epochHostTime - paused
    }

    /// The host time that has session time, in order: from the epoch to the end, less every
    /// pause. Empty pauses leave no gap.
    var spans: [Span] {
        var spans: [Span] = []
        var start = epochHostTime
        for pause in pauses {
            if let end = pause.endHostTime, end <= pause.startHostTime { continue }
            if pause.startHostTime > start { spans.append(Span(start: start, end: pause.startHostTime)) }
            guard let end = pause.endHostTime else { return clipped(spans) }
            start = max(start, end)
        }
        spans.append(Span(start: start, end: nil))
        return clipped(spans)
    }

    private func clipped(_ spans: [Span]) -> [Span] {
        guard let endHostTime else { return spans }
        return spans.compactMap { span in
            guard span.start < endHostTime else { return nil }
            return Span(start: span.start, end: span.end.map { min($0, endHostTime) } ?? endHostTime)
        }
    }
}
