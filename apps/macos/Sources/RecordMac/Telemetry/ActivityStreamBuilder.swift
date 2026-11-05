import CoreGraphics
import CoreMedia
import Foundation

/// Why `ActivityStreamBuilder` refused an input or a stream.
enum ActivityStreamBuildError: Error, Equatable {
    /// Not finite, a start below zero, an empty or negative source extent, or a pixel size or
    /// scale factor that is not positive.
    case invalidGeometry(start: TimeInterval)
    /// The first segment must start at zero, and each later one after the one before.
    case geometryOutOfOrder(start: TimeInterval)
    /// Events were given but no geometry.
    case noGeometry
    /// A session time that is not numeric, or below zero.
    case invalidTimestamp(index: Int)
    /// A pointer kind without a finite point, or whose capture location is not finite.
    case invalidPoint(index: Int)
    /// An `activeWindowChange` without its window.
    case missingWindow(index: Int)
}

/// Collects the recorder's events and the source geometry of one recording, and freezes them into
/// an `ActivityStream` (T041).
///
/// Events are kept in global coordinates until `freeze`, which converts each pointer location
/// with the geometry in force at the event's own timestamp, so an event delivered after the
/// geometry changed still uses the geometry of its time. A pointer location becomes capture
/// coordinates (see `ActivityEvent.location`): x scales by pixel width over source width and y
/// by pixel height over source height, each on its own. A pointer outside the source is kept,
/// at a capture coordinate outside the frame, never clamped to its edge. Window and target
/// frames stay in global display points, unconverted.
///
/// Geometry is checked as it is added. Events are frozen in timestamp order; events with equal
/// timestamps keep the order they were added in, since the recorder's sources can deliver a
/// little out of time order. Each `freeze` returns an independent value: adding after it never
/// changes a stream already frozen.
struct ActivityStreamBuilder {
    private var events: [GlobalActivityEvent] = []
    private var geometry: [GeometrySegment] = []

    mutating func add(_ event: GlobalActivityEvent) {
        events.append(event)
    }

    /// Adds the geometry starting at `segment.start`; throws, adding nothing, if it is invalid,
    /// the first does not start at zero, or it does not start after the last.
    mutating func add(_ segment: GeometrySegment) throws {
        // The stored size, not `width` and `height`, which read a negative size as positive.
        let (origin, size) = (segment.sourceRect.origin, segment.sourceRect.size)
        guard segment.start.isFinite, segment.start >= 0,
              origin.x.isFinite, origin.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              segment.pixelSize.width > 0, segment.pixelSize.height > 0,
              segment.scaleFactor.isFinite, segment.scaleFactor > 0
        else { throw ActivityStreamBuildError.invalidGeometry(start: segment.start) }
        if let last = geometry.last {
            guard segment.start > last.start else { throw ActivityStreamBuildError.geometryOutOfOrder(start: segment.start) }
        } else {
            guard segment.start == 0 else { throw ActivityStreamBuildError.geometryOutOfOrder(start: segment.start) }
        }
        geometry.append(segment)
    }

    /// The stream as it stands, validated. Throws for an event it cannot convert; event indices
    /// in errors count events in the order they were added.
    func freeze() throws -> ActivityStream {
        guard events.isEmpty || !geometry.isEmpty else { throw ActivityStreamBuildError.noGeometry }
        var converted: [(time: TimeInterval, index: Int, event: ActivityEvent)] = []
        for (index, global) in events.enumerated() {
            let time = global.sessionTime.seconds
            guard global.sessionTime.isNumeric, time.isFinite, time >= 0 else {
                throw ActivityStreamBuildError.invalidTimestamp(index: index)
            }
            // The first segment starts at zero, so every valid time has one.
            let segment = geometry.segment(at: time)!
            var event = ActivityEvent(timestamp: time, kind: global.kind, target: global.target)
            if global.kind.bearsPointerLocation {
                guard let point = global.globalPoint, point.x.isFinite, point.y.isFinite else {
                    throw ActivityStreamBuildError.invalidPoint(index: index)
                }
                let location = Self.captureLocation(point, in: segment)
                guard location.x.isFinite, location.y.isFinite else { throw ActivityStreamBuildError.invalidPoint(index: index) }
                event.location = location
                event.buttonOrKey = global.button.map { .button($0) }
            }
            if global.kind == .activeWindowChange {
                guard let window = global.window else { throw ActivityStreamBuildError.missingWindow(index: index) }
                event.window = window
            }
            converted.append((time, index, event))
        }
        converted.sort { ($0.time, $0.index) < ($1.time, $1.index) }
        let stream = ActivityStream(events: converted.map(\.event), geometry: geometry)
        try stream.validate()
        return stream
    }

    /// `point`, in global display points, in the capture coordinates of `segment`.
    static func captureLocation(_ point: CGPoint, in segment: GeometrySegment) -> CGPoint {
        let rect = segment.sourceRect
        return CGPoint(
            x: (point.x - rect.minX) * CGFloat(segment.pixelSize.width) / rect.width,
            y: (point.y - rect.minY) * CGFloat(segment.pixelSize.height) / rect.height)
    }
}
