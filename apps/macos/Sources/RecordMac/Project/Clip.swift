import Foundation

/// One piece of the edited timeline: a range of the capture played at a speed (FR-044, FR-045).
struct Clip: Codable, Hashable, Identifiable, Sendable {
    /// The speeds the editor offers at minimum (FR-045).
    static let minimumSupportedSpeedRange: ClosedRange<Double> = 1.0...2.0

    /// This clip instance. Two clips may cover the same source range, so identity is not the range.
    var id: UUID
    var sourceRange: CaptureTimeRange
    /// Playback multiplier; must be positive.
    var speed: Double
    var order: Int

    init(id: UUID = UUID(), sourceRange: CaptureTimeRange, speed: Double = 1, order: Int) {
        self.id = id
        self.sourceRange = sourceRange
        self.speed = speed
        self.order = order
    }

    /// The clip's length on the edited timeline.
    var editedDuration: TimeInterval {
        sourceRange.duration / speed
    }
}
