import CoreGraphics
import Foundation

enum ActivityEventKind: String, Codable, CaseIterable, Sendable {
    case pointerMove
    case click
    case scroll
    case dragStart
    case dragEnd
    case keyPress
    case activeWindowChange

    var bearsPointerLocation: Bool {
        switch self {
        case .pointerMove, .click, .scroll, .dragStart, .dragEnd: true
        case .keyPress, .activeWindowChange: false
        }
    }
}

/// A pressed key: its virtual key code, the modifier flags held, and the characters it produced
/// for display on a badge.
struct KeyStroke: Codable, Hashable, Sendable {
    var keyCode: UInt16
    /// `CGEventFlags` raw value, device-independent bits only.
    var modifiers: UInt64
    var characters: String?
}

/// The button of a pointer event, or the key of a key press.
enum ButtonOrKey: Codable, Hashable, Sendable {
    case button(Int)
    case key(KeyStroke)

    private enum CodingKeys: String, CodingKey {
        case button
        case key
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasButton = container.contains(.button)
        let hasKey = container.contains(.key)
        switch (hasButton, hasKey) {
        case (true, false):
            self = .button(try container.decode(Int.self, forKey: .button))
        case (false, true):
            self = .key(try container.decode(KeyStroke.self, forKey: .key))
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected exactly one of button or key"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .button(let index): try container.encode(index, forKey: .button)
        case .key(let stroke): try container.encode(stroke, forKey: .key)
        }
    }
}

/// The frontmost window, by identity and frame only, never by title (FR-024).
struct WindowDescriptor: Codable, Hashable, Sendable {
    var bundleIdentifier: String
    var windowID: UInt32
    var frame: CGRect
}

/// An on-screen element from Accessibility: role, identifier, and frame only, never its value
/// (FR-023).
struct ElementDescriptor: Codable, Hashable, Sendable {
    var role: String
    var subrole: String?
    var identifier: String?
    var frame: CGRect?
}

/// One timestamped input occurrence, the source for every derived effect.
struct ActivityEvent: Codable, Hashable, Sendable {
    /// Time on the capture clock.
    var timestamp: TimeInterval
    var kind: ActivityEventKind
    /// Capture coordinates, for pointer-bearing kinds.
    var location: CGPoint?
    var buttonOrKey: ButtonOrKey?
    /// `activeWindowChange` only.
    var window: WindowDescriptor?
    var target: ElementDescriptor?
}

/// The frozen activity of one recording and its source geometry, encoded as `activity.json`.
///
/// Decoding is strict (contracts/telemetry-stream.md guarantee 8): an unknown kind, a timestamp
/// that goes backwards, or an event outside every GeometrySegment fails the read rather than
/// being dropped.
struct ActivityStream: Codable, Hashable, Sendable {
    var events: [ActivityEvent]
    var geometry: [GeometrySegment]

    init(events: [ActivityEvent], geometry: [GeometrySegment]) {
        self.events = events
        self.geometry = geometry
    }

    private enum CodingKeys: String, CodingKey {
        case events
        case geometry
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = try container.decode([ActivityEvent].self, forKey: .events)
        geometry = try container.decode([GeometrySegment].self, forKey: .geometry)
        do {
            try validate()
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath, debugDescription: "\(error)",
                    underlyingError: error))
        }
    }

    func validate() throws {
        if let first = geometry.first, first.start != 0 {
            throw ActivityStreamError.geometryDoesNotStartAtZero(first.start)
        }
        for (earlier, later) in zip(geometry, geometry.dropFirst()) where later.start <= earlier.start {
            throw ActivityStreamError.geometryOutOfOrder(later.start)
        }
        var previousTimestamp = -Double.infinity
        for (index, event) in events.enumerated() {
            guard event.timestamp >= previousTimestamp else {
                throw ActivityStreamError.timestampWentBackwards(index: index, timestamp: event.timestamp)
            }
            guard geometry.segment(at: event.timestamp) != nil else {
                throw ActivityStreamError.eventOutsideGeometry(index: index, timestamp: event.timestamp)
            }
            previousTimestamp = event.timestamp
        }
    }
}

enum ActivityStreamError: Error, Equatable {
    case geometryDoesNotStartAtZero(TimeInterval)
    case geometryOutOfOrder(TimeInterval)
    case timestampWentBackwards(index: Int, timestamp: TimeInterval)
    case eventOutsideGeometry(index: Int, timestamp: TimeInterval)
}
