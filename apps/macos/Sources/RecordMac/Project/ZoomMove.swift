import CoreGraphics
import Foundation

/// A span of time with a focus point and depth, generated from activity or placed by the
/// creator (data-model.md ZoomMove).
struct ZoomMove: Codable, Hashable, Identifiable, Sendable {
    enum Origin: String, Codable, Sendable {
        case generated
        case manual
    }

    var id: UUID
    /// Source time on the capture clock; retimed to edited time through the clips.
    var timeRange: CaptureTimeRange
    /// Normalized point in the captured frame, 0...1 on each axis (FR-047).
    var focus: CGPoint
    /// Magnification, at least 1 and capped by the creator's maximum (FR-032).
    var depth: Double
    var origin: Origin
    /// Set when the creator edits a generated move; regeneration then keeps it (FR-033).
    var manuallyAdjusted: Bool

    init(
        id: UUID = UUID(), timeRange: CaptureTimeRange, focus: CGPoint, depth: Double,
        origin: Origin, manuallyAdjusted: Bool = false
    ) {
        self.id = id
        self.timeRange = timeRange
        self.focus = focus
        self.depth = depth
        self.origin = origin
        self.manuallyAdjusted = manuallyAdjusted
    }

    /// This move with its depth held to `1...maximumDepth`.
    func capped(at maximumDepth: Double) -> ZoomMove {
        var move = self
        move.depth = min(max(depth, 1), max(maximumDepth, 1))
        return move
    }
}
