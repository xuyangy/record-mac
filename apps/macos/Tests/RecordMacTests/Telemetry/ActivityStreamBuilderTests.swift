import CoreGraphics
import CoreMedia
import XCTest
@testable import RecordMac

/// Freezing recorder events and source geometry into an `ActivityStream`. Every expected capture
/// coordinate is worked out by hand from the geometry below, not by the mapping under test.
final class ActivityStreamBuilderTests: XCTestCase {
    /// A Retina display left of and above the main display: 1440 × 900 points at (−1440, −200),
    /// 2880 × 1800 pixels.
    private let retinaLeft = GeometrySegment(start: 0, sourceRect: CGRect(x: -1440, y: -200, width: 1440, height: 900),
        pixelSize: PixelSize(width: 2880, height: 1800), scaleFactor: 2)
    /// The same source moved and resized at 2 s: a 1920 × 1080 non-Retina display at the origin.
    private let plainAt2 = GeometrySegment(start: 2, sourceRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        pixelSize: PixelSize(width: 1920, height: 1080), scaleFactor: 1)
    /// A 333 × 200 point window at scale 2 whose width rounded up to 667 pixels: x scales by
    /// 667/333, y by exactly 2.
    private let roundedWindow = GeometrySegment(start: 0, sourceRect: CGRect(x: 100, y: 50, width: 333, height: 200),
        pixelSize: PixelSize(width: 667, height: 400), scaleFactor: 2)

    private func at(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1_000_000) }

    private func pointer(_ seconds: Double, _ x: CGFloat, _ y: CGFloat, _ kind: ActivityEventKind = .pointerMove,
                         button: Int? = nil, target: ElementDescriptor? = nil) -> GlobalActivityEvent {
        GlobalActivityEvent(sessionTime: at(seconds), kind: kind, globalPoint: CGPoint(x: x, y: y), button: button, target: target)
    }

    private func builder(_ segments: GeometrySegment...) throws -> ActivityStreamBuilder {
        var builder = ActivityStreamBuilder()
        for segment in segments { try builder.add(segment) }
        return builder
    }

    private func assertLocation(_ event: ActivityEvent?, _ x: CGFloat, _ y: CGFloat, line: UInt = #line) {
        guard let location = event?.location else { return XCTFail("no location", line: line) }
        XCTAssertEqual(location.x, x, accuracy: 1e-9, line: line)
        XCTAssertEqual(location.y, y, accuracy: 1e-9, line: line)
    }

    func testPointerLocationsBecomeCapturePixelsFromTheSourcesTopLeft() throws {
        var retina = try builder(retinaLeft)
        retina.add(pointer(0.5, -720, 250))
        retina.add(pointer(0.6, -1440, -200))
        let stream = try retina.freeze()
        // (−720 − −1440) × 2, (250 − −200) × 2; the source's top left is pixel zero.
        assertLocation(stream.events[0], 1440, 900)
        assertLocation(stream.events[1], 0, 0)

        var window = try builder(roundedWindow)
        window.add(pointer(0.5, 266.5, 150))
        // (266.5 − 100) × 667/333 = 333.5; (150 − 50) × 400/200 = 200.
        assertLocation(try window.freeze().events[0], 333.5, 200)
    }

    func testEachEventUsesTheGeometryOfItsOwnTimeEvenWhenAddedLater() throws {
        var builder = try builder(retinaLeft, plainAt2)
        builder.add(pointer(1.999, -720, 250))
        builder.add(pointer(2, 960, 540))
        builder.add(pointer(3, 100.5, 20))
        // Delivered after the geometry at 2 s was known, stamped before it.
        builder.add(pointer(1.5, -1080, 25))
        let stream = try builder.freeze()

        XCTAssertEqual(stream.events.map(\.timestamp), [1.5, 1.999, 2, 3])
        assertLocation(stream.events[0], 720, 450)
        assertLocation(stream.events[1], 1440, 900)
        assertLocation(stream.events[2], 960, 540)
        assertLocation(stream.events[3], 100.5, 20)
        XCTAssertEqual(stream.geometry, [retinaLeft, plainAt2])
    }

    /// A pointer outside the source keeps its place outside the frame.
    func testAPointerOutsideTheSourceIsNotClampedToItsEdge() throws {
        var builder = try builder(retinaLeft)
        builder.add(pointer(0.5, 300, -500, .click, button: 0))
        assertLocation(try builder.freeze().events[0], 3480, -600)
    }

    /// Kinds without a pointer get no location; button, target, and window are kept, frames
    /// unconverted.
    func testMetadataIsKeptAndWindowsAndTargetsStayInGlobalPoints() throws {
        let target = ElementDescriptor(role: "AXButton", subrole: nil, identifier: "save", frame: CGRect(x: -700, y: 240, width: 60, height: 20))
        let window = WindowDescriptor(bundleIdentifier: "com.example.editor", windowID: 41, frame: CGRect(x: -1400, y: -180, width: 800, height: 600))
        var builder = try builder(retinaLeft)
        builder.add(pointer(0.5, -720, 250, .click, button: 1, target: target))
        builder.add(GlobalActivityEvent(sessionTime: at(0.7), kind: .activeWindowChange, globalPoint: CGPoint(x: 5, y: 5), window: window))
        builder.add(pointer(0.9, -720, 250, .dragEnd, button: 1))
        let stream = try builder.freeze()

        XCTAssertEqual(stream.events[0].buttonOrKey, .button(1))
        XCTAssertEqual(stream.events[0].target, target)
        XCTAssertNil(stream.events[0].window)
        XCTAssertEqual(stream.events[1].kind, .activeWindowChange)
        XCTAssertNil(stream.events[1].location, "a window change has no pointer location")
        XCTAssertNil(stream.events[1].buttonOrKey)
        XCTAssertEqual(stream.events[1].window, window)
        XCTAssertEqual(stream.events[2].buttonOrKey, .button(1))
    }

    func testEqualTimesKeepTheOrderTheyWereAddedIn() throws {
        var builder = try builder(retinaLeft)
        builder.add(pointer(1, -720, 250, .click, button: 0))
        builder.add(pointer(0.5, -720, 250))
        builder.add(pointer(1, -720, 250, .dragStart, button: 0))
        builder.add(pointer(1, -720, 250, .pointerMove))
        XCTAssertEqual(try builder.freeze().events.map(\.kind), [.pointerMove, .click, .dragStart, .pointerMove])
    }

    func testInvalidGeometryIsRefusedAndNothingIsAdded() throws {
        func refused(_ segment: GeometrySegment, after earlier: [GeometrySegment] = [], line: UInt = #line) {
            var builder = ActivityStreamBuilder()
            for each in earlier { XCTAssertNoThrow(try builder.add(each), line: line) }
            XCTAssertThrowsError(try builder.add(segment), line: line)
            XCTAssertEqual(try? builder.freeze().geometry, earlier, "nothing added", line: line)
        }
        var segment = retinaLeft
        segment.sourceRect.size.width = 0; refused(segment)
        segment = retinaLeft; segment.sourceRect.size.height = -1; refused(segment)
        segment = retinaLeft; segment.sourceRect.origin.x = .nan; refused(segment)
        segment = retinaLeft; segment.sourceRect.size.width = .infinity; refused(segment)
        segment = retinaLeft; segment.pixelSize.width = 0; refused(segment)
        segment = retinaLeft; segment.scaleFactor = 0; refused(segment)
        segment = retinaLeft; segment.scaleFactor = .nan; refused(segment)
        segment = retinaLeft; segment.start = -1; refused(segment)
        segment = retinaLeft; segment.start = .nan; refused(segment)
        segment = retinaLeft; segment.start = 1; refused(segment)
        segment = plainAt2; segment.start = 0; refused(segment, after: [retinaLeft])
        refused(retinaLeft, after: [retinaLeft])
        segment = plainAt2; segment.start = 1; refused(segment, after: [retinaLeft, plainAt2])

        var builder = ActivityStreamBuilder()
        segment = retinaLeft; segment.start = 1
        XCTAssertThrowsError(try builder.add(segment)) { XCTAssertEqual($0 as? ActivityStreamBuildError, .geometryOutOfOrder(start: 1)) }
        segment.sourceRect.size.width = 0
        XCTAssertThrowsError(try builder.add(segment)) { XCTAssertEqual($0 as? ActivityStreamBuildError, .invalidGeometry(start: 1)) }
    }

    func testEventsThatCannotBeConvertedFailTheFreeze() throws {
        func fails(_ event: GlobalActivityEvent, _ expected: ActivityStreamBuildError, line: UInt = #line) throws {
            var builder = try builder(retinaLeft)
            builder.add(pointer(0.1, -720, 250))
            builder.add(event)
            XCTAssertThrowsError(try builder.freeze(), line: line) { XCTAssertEqual($0 as? ActivityStreamBuildError, expected, line: line) }
        }
        try fails(pointer(0.5, .nan, 250), .invalidPoint(index: 1))
        try fails(pointer(0.5, -720, .infinity), .invalidPoint(index: 1))
        // Finite, but twice it is not.
        try fails(pointer(0.5, .greatestFiniteMagnitude, 250), .invalidPoint(index: 1))
        try fails(GlobalActivityEvent(sessionTime: at(0.5), kind: .click, button: 0), .invalidPoint(index: 1))
        try fails(GlobalActivityEvent(sessionTime: .invalid, kind: .pointerMove, globalPoint: .zero), .invalidTimestamp(index: 1))
        try fails(pointer(-0.5, -720, 250), .invalidTimestamp(index: 1))
        try fails(GlobalActivityEvent(sessionTime: at(0.5), kind: .activeWindowChange), .missingWindow(index: 1))

        var noGeometry = ActivityStreamBuilder()
        noGeometry.add(pointer(0.1, 0, 0))
        XCTAssertThrowsError(try noGeometry.freeze()) { XCTAssertEqual($0 as? ActivityStreamBuildError, .noGeometry) }
        XCTAssertEqual(try ActivityStreamBuilder().freeze(), ActivityStream(events: [], geometry: []))
    }

    /// A frozen stream is a value: adding afterwards changes only the next one. It reads back
    /// through `ActivityStream`'s strict decoding unchanged.
    func testAFrozenStreamIsAnIndependentValueThatRoundTrips() throws {
        var builder = try builder(retinaLeft)
        builder.add(pointer(0.5, -720, 250))
        let first = try builder.freeze()
        try builder.add(plainAt2)
        builder.add(pointer(2.5, 960, 540))
        let second = try builder.freeze()

        XCTAssertEqual(first.events.count, 1)
        XCTAssertEqual(first.geometry, [retinaLeft])
        XCTAssertEqual(second.events.count, 2)
        assertLocation(second.events[1], 960, 540)

        let decoded = try JSONDecoder().decode(ActivityStream.self, from: try JSONEncoder().encode(second))
        XCTAssertEqual(decoded, second)
        XCTAssertNoThrow(try decoded.validate())
    }
}
