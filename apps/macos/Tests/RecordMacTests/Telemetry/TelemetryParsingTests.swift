import CoreGraphics
import XCTest
@testable import RecordMac

final class TelemetryParsingTests: XCTestCase {
    private func encode(_ stream: ActivityStream) throws -> Data {
        try ProjectStore.makeEncoder().encode(stream)
    }

    private func decode(_ data: Data) throws -> ActivityStream {
        try ProjectStore.makeDecoder().decode(ActivityStream.self, from: data)
    }

    private func jsonObject(_ stream: ActivityStream) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: encode(stream)) as? [String: Any])
    }

    func testRoundTripOfEveryEventKindAndGeometry() throws {
        let stream = makeFixtureActivity()
        XCTAssertEqual(Set(stream.events.map(\.kind)), Set(ActivityEventKind.allCases))

        let read = try decode(encode(stream))

        XCTAssertEqual(read, stream)
        XCTAssertEqual(read.geometry.count, 2)
        XCTAssertEqual(read.events[2].buttonOrKey, .key(KeyStroke(keyCode: 1, modifiers: 0x100000, characters: "s")))
        XCTAssertEqual(read.events[1].target?.role, "AXButton")
        XCTAssertEqual(read.events[6].window?.bundleIdentifier, "com.apple.Terminal")
    }

    func testRejectsUnknownKind() throws {
        var object = try jsonObject(makeFixtureActivity())
        var events = try XCTUnwrap(object["events"] as? [[String: Any]])
        events[0]["kind"] = "telepathy"
        object["events"] = events
        XCTAssertThrowsError(try decode(JSONSerialization.data(withJSONObject: object)))
    }

    func testRejectsBackwardsTimestamps() throws {
        var stream = makeFixtureActivity()
        stream.events[3].timestamp = 0.5
        XCTAssertThrowsError(try stream.validate()) {
            XCTAssertEqual($0 as? ActivityStreamError, .timestampWentBackwards(index: 3, timestamp: 0.5))
        }
        XCTAssertThrowsError(try decode(encode(stream)))
    }

    func testRejectsEventsOutsideEveryGeometrySegment() throws {
        var stream = makeFixtureActivity()
        stream.geometry = []
        XCTAssertThrowsError(try stream.validate()) {
            XCTAssertEqual($0 as? ActivityStreamError, .eventOutsideGeometry(index: 0, timestamp: 0.1))
        }
        XCTAssertThrowsError(try decode(encode(stream)))

        stream = makeFixtureActivity()
        stream.events.insert(ActivityEvent(timestamp: -1, kind: .pointerMove, location: .zero), at: 0)
        XCTAssertThrowsError(try decode(encode(stream)))
    }

    func testRejectsGeometryThatDoesNotStartAtZeroOrIsUnordered() throws {
        var stream = makeFixtureActivity()
        stream.geometry[0].start = 0.05
        XCTAssertThrowsError(try decode(encode(stream)))

        stream = makeFixtureActivity()
        stream.geometry[1].start = 0
        XCTAssertThrowsError(try decode(encode(stream)))
    }

    func testButtonOrKeyNeedsExactlyOneValue() throws {
        let both = #"{"button":0,"key":{"keyCode":1,"modifiers":0}}"#
        let neither = #"{}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ButtonOrKey.self, from: Data(both.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(ButtonOrKey.self, from: Data(neither.utf8)))
    }

    func testGeometryLookupFindsTheSegmentInForce() {
        let geometry = makeFixtureActivity().geometry
        XCTAssertNil(geometry.segment(at: -0.1))
        XCTAssertEqual(geometry.segment(at: 0)?.start, 0)
        XCTAssertEqual(geometry.segment(at: 5.2)?.start, 0)
        XCTAssertEqual(geometry.segment(at: 5.25)?.start, 5.25)
        XCTAssertEqual(geometry.segment(at: 1_000)?.start, 5.25)
        XCTAssertNil([GeometrySegment]().segment(at: 1))
    }
}
