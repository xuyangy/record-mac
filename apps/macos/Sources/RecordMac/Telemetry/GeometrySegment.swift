import CoreGraphics
import Foundation

/// The capture source's geometry over one span of time. A new segment starts whenever the
/// captured area moves or changes size, and every screen media segment boundary is also a
/// geometry boundary (data-model.md GeometrySegment).
struct GeometrySegment: Codable, Hashable, Sendable {
    /// Time on the capture clock. The first segment starts at zero.
    var start: TimeInterval
    /// The captured area, in global display points.
    var sourceRect: CGRect
    var pixelSize: PixelSize
    /// Backing scale of the display.
    var scaleFactor: Double
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
