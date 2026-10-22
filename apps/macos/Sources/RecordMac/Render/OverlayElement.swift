import CoreGraphics
import Foundation

/// A reference to one event in a project's frozen activity stream, by its position.
struct ActivityEventRef: Codable, Hashable, Sendable {
    var index: Int
}

/// A keystroke badge or click ripple, derived from recorded activity and rendered, never
/// captured (FR-037, FR-038).
struct OverlayElement: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case keystrokeBadge
        case clickRipple
    }

    /// Position, size, and duration the creator can adjust after recording (FR-039).
    struct Appearance: Codable, Hashable, Sendable {
        /// Normalized point in the output frame.
        var position: CGPoint
        var scale: Double
        var duration: TimeInterval
    }

    var id: UUID
    /// Non-empty and ordered: one event for a ripple, one or more for a badge that combines keys
    /// (FR-040). Older entries leave a badge's display but stay here.
    private(set) var sourceEventRefs: [ActivityEventRef]
    var kind: Kind
    var timeRange: CaptureTimeRange
    var appearance: Appearance
    /// The creator turned this one off.
    var suppressed: Bool

    init(
        id: UUID = UUID(), sourceEventRefs: [ActivityEventRef], kind: Kind,
        timeRange: CaptureTimeRange, appearance: Appearance, suppressed: Bool = false
    ) throws {
        guard !sourceEventRefs.isEmpty else { throw OverlayElementError.noSourceEvents }
        self.id = id
        self.sourceEventRefs = sourceEventRefs
        self.kind = kind
        self.timeRange = timeRange
        self.appearance = appearance
        self.suppressed = suppressed
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceEventRefs, kind, timeRange, appearance, suppressed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            sourceEventRefs: container.decode([ActivityEventRef].self, forKey: .sourceEventRefs),
            kind: container.decode(Kind.self, forKey: .kind),
            timeRange: container.decode(CaptureTimeRange.self, forKey: .timeRange),
            appearance: container.decode(Appearance.self, forKey: .appearance),
            suppressed: container.decode(Bool.self, forKey: .suppressed))
    }

    mutating func append(_ ref: ActivityEventRef) {
        sourceEventRefs.append(ref)
    }
}

enum OverlayElementError: Error, Equatable {
    case noSourceEvents
}
