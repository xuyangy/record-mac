import CoreGraphics
import CoreMedia
import Foundation

/// The capture source's geometry as observed: `GeometrySegment` without a start.
struct SourceGeometry: Hashable, Sendable {
    /// Global display points, origin at the top left of the main display.
    var sourceRect: CGRect
    var pixelSize: PixelSize
    var scaleFactor: Double

    func segment(at start: TimeInterval) -> GeometrySegment {
        GeometrySegment(start: start, sourceRect: sourceRect, pixelSize: pixelSize, scaleFactor: scaleFactor)
    }
}

enum GeometryRecorderError: Error, Equatable {
    /// See `GeometrySegment.isValid`.
    case invalidGeometry
    /// The host time is not numeric.
    case invalidTimestamp
    /// Earlier than the latest observation or boundary taken.
    case outOfOrder(at: TimeInterval)
    /// A different geometry at the instant of the latest observation or boundary taken, which
    /// already established the geometry in force there.
    case conflictingGeometry(at: TimeInterval)
}

/// What became of one observation or boundary.
enum GeometryRecorderOutcome: Equatable {
    /// A segment starting at this session time.
    case added(TimeInterval)
    /// The geometry in force already, or a boundary already there: nothing added.
    case unchanged
    /// Before the epoch, inside a pause, or at or after the end: nothing added, and the
    /// observation is not kept.
    case noSessionTime
}

/// Builds the recording's GeometrySegments from supplied observations of the capture source
/// (T041). It subscribes to nothing; whoever observes the source calls it.
///
/// The first segment holds the geometry given at the session epoch and starts at zero. Each
/// observation carries the host time the source was observed, mapped through the session's
/// `CaptureClock`; a new segment starts there when the source rect, native pixel size, or scale
/// factor differs from the segment in force, and an identical observation adds nothing. A screen
/// media segment boundary adds a segment with the geometry in force even when nothing changed,
/// since every media boundary is a geometry boundary.
///
/// Input is taken in time order. The latest observation or boundary taken, whether or not it
/// added a segment, sets the time from which the next is taken, starting at zero: anything
/// earlier is refused, since an observation that confirmed the geometry in force still says
/// which geometry held then. At exactly that time, the same geometry adds nothing, a boundary
/// adds a segment unless one starts there already, and a different geometry is refused: the
/// geometry there is already established, and two segments cannot start at one instant. So for
/// one instant, a geometry change is supplied before its media boundary, which then adds
/// nothing; a boundary first and a different geometry after it is refused. A refusal changes
/// nothing.
///
/// An observation without session time, inside a pause for one, is dropped, not kept for later:
/// the geometry of a resumed source is set by a fresh observation at the resume, whose host time
/// maps to the session time the pause began at.
///
/// Calls are serialised by a lock and may come from any thread; they are taken in the order they
/// acquire it, so each caller supplies its observations in time order. `segments` returns a
/// value that later calls never change.
final class GeometryRecorder: @unchecked Sendable {
    private let clock: CaptureClock
    private let lock = NSLock()
    private var recorded: [GeometrySegment]
    /// The session time of the latest observation or boundary taken.
    private var latest: TimeInterval = 0

    init(clock: CaptureClock, initial: SourceGeometry) throws {
        let first = initial.segment(at: 0)
        guard first.isValid else { throw GeometryRecorderError.invalidGeometry }
        self.clock = clock
        recorded = [first]
    }

    var segments: [GeometrySegment] { lock.withLock { recorded } }

    @discardableResult
    func observe(_ geometry: SourceGeometry, atHostTime hostTime: CMTime) throws -> GeometryRecorderOutcome {
        guard geometry.segment(at: 0).isValid else { throw GeometryRecorderError.invalidGeometry }
        return try record(atHostTime: hostTime) { _ in geometry }
    }

    /// A screen media segment boundary at `hostTime`.
    @discardableResult
    func markMediaBoundary(atHostTime hostTime: CMTime) throws -> GeometryRecorderOutcome {
        try record(atHostTime: hostTime, forced: true) { last in
            SourceGeometry(sourceRect: last.sourceRect, pixelSize: last.pixelSize, scaleFactor: last.scaleFactor)
        }
    }

    private func record(
        atHostTime hostTime: CMTime, forced: Bool = false, geometry: (GeometrySegment) -> SourceGeometry
    ) throws -> GeometryRecorderOutcome {
        guard hostTime.isNumeric else { throw GeometryRecorderError.invalidTimestamp }
        guard let time = clock.sessionTime(forHostTime: hostTime)?.seconds else { return .noSessionTime }
        return try lock.withLock {
            guard time >= latest else { throw GeometryRecorderError.outOfOrder(at: time) }
            // The last segment holds the geometry every input taken so far established.
            let last = recorded[recorded.count - 1]
            let segment = geometry(last).segment(at: time)
            let same = segment.sameSource(as: last)
            guard same || time > latest else { throw GeometryRecorderError.conflictingGeometry(at: time) }
            latest = time
            guard !same || (forced && time > last.start) else { return .unchanged }
            recorded.append(segment)
            return .added(time)
        }
    }
}
