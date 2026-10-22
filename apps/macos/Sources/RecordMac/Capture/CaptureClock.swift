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
    private struct Pause {
        let startHostTime: CMTime
        var endHostTime: CMTime?
    }

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

    /// Session time for a host-clock timestamp, or nil if it precedes the epoch or falls inside a
    /// pause.
    func sessionTime(forHostTime hostTime: CMTime) -> CMTime? {
        guard hostTime.isNumeric, hostTime >= epochHostTime else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var paused = CMTime.zero
        for pause in pauseIntervals {
            guard hostTime >= pause.startHostTime else { break }
            guard let end = pause.endHostTime, hostTime >= end else { return nil }
            paused = paused + (end - pause.startHostTime)
        }
        return hostTime - epochHostTime - paused
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
