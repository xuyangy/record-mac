import CoreGraphics
import Foundation

/// The capture source's geometry over one span of time. A new segment starts whenever the
/// captured area moves or changes size, and every screen media segment boundary is also a
/// geometry boundary (data-model.md GeometrySegment).
struct GeometrySegment: Codable, Hashable, Sendable {
    /// Time on the capture clock. The first segment starts at zero.
    var start: TimeInterval
    /// The captured area, in global display points: origin at the top left of the main display,
    /// y downwards, the space of CGEvent locations.
    var sourceRect: CGRect
    /// The captured frame's size; with `sourceRect` it gives the capture mapping on each axis.
    var pixelSize: PixelSize
    /// Backing scale of the display. Not used to map locations, since a native size rounded to
    /// whole pixels need not be exactly `sourceRect` times this.
    var scaleFactor: Double
}

extension GeometrySegment {
    /// A finite start at or above zero, a finite origin and size whose stored width and height
    /// are above zero (`CGRect.width` and `height` read a negative size as positive), a pixel
    /// width and height above zero, and a finite scale factor above zero.
    var isValid: Bool {
        let (origin, size) = (sourceRect.origin, sourceRect.size)
        return start.isFinite && start >= 0
            && origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
            && size.width > 0 && size.height > 0
            && pixelSize.width > 0 && pixelSize.height > 0
            && scaleFactor.isFinite && scaleFactor > 0
    }

    /// Whether the two describe the same source, whatever their starts.
    func sameSource(as other: GeometrySegment) -> Bool {
        sourceRect == other.sourceRect && pixelSize == other.pixelSize && scaleFactor == other.scaleFactor
    }
}

extension Array where Element == GeometrySegment {
    /// The segment in force at `time`: the last one starting at or before it. Segments are
    /// ordered by `start`; a time before the first segment has none.
    func segment(at time: TimeInterval) -> GeometrySegment? {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if self[middle].start <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low == 0 ? nil : self[low - 1]
    }
}
