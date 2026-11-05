import CoreGraphics
import CoreMedia
import XCTest
@testable import RecordMac

/// GeometrySegments from supplied observations of the capture source, on a clock whose epoch is
/// host 10 s. Every expected start and coordinate is worked out by hand.
final class GeometryRecorderTests: XCTestCase {
    private let display = SourceGeometry(sourceRect: CGRect(x: 0, y: 0, width: 1440, height: 900),
        pixelSize: PixelSize(width: 2880, height: 1800), scaleFactor: 2)
    private let clock = CaptureClock(epochHostTime: CMTime(value: 10, timescale: 1))

    private func host(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1_000_000) }

    private func recorder() throws -> GeometryRecorder { try GeometryRecorder(clock: clock, initial: display) }

    private func changed(_ change: (inout SourceGeometry) -> Void) -> SourceGeometry {
        var geometry = display
        change(&geometry)
        return geometry
    }

    func testTheFirstSegmentStartsAtZeroAndRepeatsAddNothing() throws {
        let recorder = try recorder()
        XCTAssertEqual(recorder.segments, [display.segment(at: 0)])
        XCTAssertEqual(try recorder.observe(display, atHostTime: host(10)), .unchanged, "at the epoch, the same geometry")
        XCTAssertEqual(try recorder.observe(display, atHostTime: host(11.5)), .unchanged)
        XCTAssertEqual(recorder.segments.count, 1)
    }

    /// A move, a resize, a pixel size, and a scale change each start a segment.
    func testEveryGeometryFieldStartsASegment() throws {
        let recorder = try recorder()
        let moved = changed { $0.sourceRect.origin = CGPoint(x: -100, y: 40) }
        let resized = changed { $0.sourceRect.origin = CGPoint(x: -100, y: 40); $0.sourceRect.size.width = 1200 }
        let repixeled = changed { $0.sourceRect.origin = CGPoint(x: -100, y: 40); $0.sourceRect.size.width = 1200; $0.pixelSize.width = 2401 }
        let rescaled = changed { $0.sourceRect.origin = CGPoint(x: -100, y: 40); $0.sourceRect.size.width = 1200; $0.pixelSize.width = 2401; $0.scaleFactor = 1 }
        XCTAssertEqual(try recorder.observe(moved, atHostTime: host(11)), .added(1))
        XCTAssertEqual(try recorder.observe(resized, atHostTime: host(12)), .added(2))
        XCTAssertEqual(try recorder.observe(repixeled, atHostTime: host(13)), .added(3))
        XCTAssertEqual(try recorder.observe(rescaled, atHostTime: host(14)), .added(4))
        XCTAssertEqual(try recorder.observe(rescaled, atHostTime: host(15)), .unchanged)
        XCTAssertEqual(recorder.segments, [display.segment(at: 0), moved.segment(at: 1), resized.segment(at: 2),
            repixeled.segment(at: 3), rescaled.segment(at: 4)])
    }

    /// A media boundary starts a segment with the geometry in force even when nothing changed,
    /// and adds nothing where a segment already starts.
    func testAMediaBoundaryAlwaysStartsASegment() throws {
        let recorder = try recorder()
        XCTAssertEqual(try recorder.markMediaBoundary(atHostTime: host(10)), .unchanged, "the first segment starts there")
        XCTAssertEqual(try recorder.markMediaBoundary(atHostTime: host(12.5)), .added(2.5))
        XCTAssertEqual(try recorder.markMediaBoundary(atHostTime: host(12.5)), .unchanged)
        XCTAssertEqual(recorder.segments, [display.segment(at: 0), display.segment(at: 2.5)])
    }

    /// A pointer exactly at a boundary maps with the segment starting there, through the builder.
    func testSegmentsFeedTheStreamBuilderWithExactBoundaries() throws {
        let recorder = try recorder()
        let moved = changed { $0.sourceRect.origin = CGPoint(x: 200, y: 100) }
        try recorder.observe(moved, atHostTime: host(12))
        var builder = ActivityStreamBuilder()
        for segment in recorder.segments { try builder.add(segment) }
        for seconds in [1.999, 2.0] {
            builder.add(GlobalActivityEvent(sessionTime: CMTime(seconds: seconds, preferredTimescale: 1000), kind: .pointerMove,
                globalPoint: CGPoint(x: 300, y: 150)))
        }
        let stream = try builder.freeze()
        // 300 × 2, 150 × 2 before; (300 − 200) × 2, (150 − 100) × 2 from 2 s.
        XCTAssertEqual(stream.events.map(\.location), [CGPoint(x: 600, y: 300), CGPoint(x: 200, y: 100)])
    }

    /// An observation inside a pause is dropped; the fresh observation at the resume, not the
    /// dropped one, sets the resumed geometry, at the session time the pause began.
    func testAfterAPauseTheResumesObservationSetsTheGeometry() throws {
        let recorder = try recorder()
        XCTAssertTrue(clock.pause(atHostTime: host(12)))
        let duringPause = changed { $0.sourceRect.origin = CGPoint(x: 500, y: 0) }
        XCTAssertEqual(try recorder.observe(duringPause, atHostTime: host(12.5)), .noSessionTime)
        XCTAssertEqual(try recorder.markMediaBoundary(atHostTime: host(12.6)), .noSessionTime)
        XCTAssertTrue(clock.resume(atHostTime: host(13)))
        let atResume = changed { $0.sourceRect.origin = CGPoint(x: 700, y: 0) }
        // 13 − 10 − the 1 s pause = 2.
        XCTAssertEqual(try recorder.observe(atResume, atHostTime: host(13)), .added(2))
        XCTAssertEqual(try recorder.observe(atResume, atHostTime: host(14)), .unchanged)
        XCTAssertEqual(recorder.segments, [display.segment(at: 0), atResume.segment(at: 2)])
    }

    func testTimesWithoutSessionTimeAddNothingAndInvalidTimesAreRefused() throws {
        let recorder = try recorder()
        let moved = changed { $0.sourceRect.origin = CGPoint(x: 1, y: 1) }
        XCTAssertEqual(try recorder.observe(moved, atHostTime: host(9)), .noSessionTime, "before the epoch")
        XCTAssertThrowsError(try recorder.observe(moved, atHostTime: .invalid)) {
            XCTAssertEqual($0 as? GeometryRecorderError, .invalidTimestamp)
        }
        XCTAssertThrowsError(try recorder.markMediaBoundary(atHostTime: .positiveInfinity)) {
            XCTAssertEqual($0 as? GeometryRecorderError, .invalidTimestamp)
        }
        XCTAssertTrue(clock.end(atHostTime: host(15)))
        XCTAssertEqual(try recorder.observe(moved, atHostTime: host(15)), .noSessionTime, "at the end")
        XCTAssertEqual(try recorder.markMediaBoundary(atHostTime: host(16)), .noSessionTime, "after the end")
        XCTAssertEqual(recorder.segments, [display.segment(at: 0)])
    }

    /// Refusals change nothing: an earlier time, a different geometry at the last start, and
    /// invalid geometry.
    func testRefusalsLeaveTheSegmentsAsTheyWere() throws {
        let recorder = try recorder()
        let moved = changed { $0.sourceRect.origin = CGPoint(x: 50, y: 0) }
        let other = changed { $0.sourceRect.origin = CGPoint(x: 60, y: 0) }
        try recorder.observe(moved, atHostTime: host(12))
        let before = recorder.segments

        XCTAssertThrowsError(try recorder.observe(other, atHostTime: host(11))) {
            XCTAssertEqual($0 as? GeometryRecorderError, .outOfOrder(at: 1))
        }
        XCTAssertThrowsError(try recorder.markMediaBoundary(atHostTime: host(11.5))) {
            XCTAssertEqual($0 as? GeometryRecorderError, .outOfOrder(at: 1.5))
        }
        XCTAssertThrowsError(try recorder.observe(other, atHostTime: host(12))) {
            XCTAssertEqual($0 as? GeometryRecorderError, .conflictingGeometry(at: 2))
        }
        XCTAssertEqual(try recorder.observe(moved, atHostTime: host(12)), .unchanged, "the same geometry at the same instant")
        for invalid in [
            changed { $0.sourceRect.size.width = 0 }, changed { $0.sourceRect.size.height = -900 },
            changed { $0.sourceRect.origin.x = .nan }, changed { $0.pixelSize.height = 0 },
            changed { $0.scaleFactor = .infinity }, changed { $0.scaleFactor = 0 },
        ] {
            XCTAssertThrowsError(try recorder.observe(invalid, atHostTime: host(13))) {
                XCTAssertEqual($0 as? GeometryRecorderError, .invalidGeometry)
            }
        }
        XCTAssertEqual(recorder.segments, before)
        XCTAssertThrowsError(try GeometryRecorder(clock: clock, initial: changed { $0.pixelSize.width = -1 })) {
            XCTAssertEqual($0 as? GeometryRecorderError, .invalidGeometry)
        }
    }

    /// An observation that confirmed the geometry in force still sets the time order: an earlier
    /// observation or boundary after it is refused, a different geometry at its instant is
    /// refused, and a boundary at its instant adds the segment the boundary needs.
    func testAConfirmingObservationSetsTheTimeOrder() throws {
        let recorder = try recorder()
        let moved = changed { $0.sourceRect.origin = CGPoint(x: 30, y: 0) }
        XCTAssertEqual(try recorder.observe(display, atHostTime: host(15)), .unchanged)

        XCTAssertThrowsError(try recorder.observe(moved, atHostTime: host(13))) {
            XCTAssertEqual($0 as? GeometryRecorderError, .outOfOrder(at: 3))
        }
        XCTAssertThrowsError(try recorder.markMediaBoundary(atHostTime: host(14))) {
            XCTAssertEqual($0 as? GeometryRecorderError, .outOfOrder(at: 4))
        }
        XCTAssertThrowsError(try recorder.observe(moved, atHostTime: host(15))) {
            XCTAssertEqual($0 as? GeometryRecorderError, .conflictingGeometry(at: 5))
        }
        XCTAssertEqual(recorder.segments, [display.segment(at: 0)])

        XCTAssertEqual(try recorder.markMediaBoundary(atHostTime: host(15)), .added(5))
        XCTAssertEqual(try recorder.markMediaBoundary(atHostTime: host(15)), .unchanged)
        XCTAssertEqual(try recorder.observe(display, atHostTime: host(15)), .unchanged)
        XCTAssertThrowsError(try recorder.observe(moved, atHostTime: host(15))) {
            XCTAssertEqual($0 as? GeometryRecorderError, .conflictingGeometry(at: 5))
        }
        XCTAssertEqual(try recorder.observe(moved, atHostTime: host(16)), .added(6))
        XCTAssertEqual(recorder.segments, [display.segment(at: 0), display.segment(at: 5), moved.segment(at: 6)])
    }

    /// For one instant, a change and then its media boundary: the boundary adds nothing more.
    func testAChangeAndItsMediaBoundaryAtOneInstantMakeOneSegment() throws {
        let recorder = try recorder()
        let resized = changed { $0.sourceRect.size = CGSize(width: 1280, height: 800); $0.pixelSize = PixelSize(width: 2560, height: 1600) }
        XCTAssertEqual(try recorder.observe(resized, atHostTime: host(12)), .added(2))
        XCTAssertEqual(try recorder.markMediaBoundary(atHostTime: host(12)), .unchanged)
        XCTAssertEqual(recorder.segments, [display.segment(at: 0), resized.segment(at: 2)])
    }

    func testASnapshotIsUnchangedByLaterObservations() throws {
        let recorder = try recorder()
        let snapshot = recorder.segments
        try recorder.observe(changed { $0.sourceRect.origin = CGPoint(x: 9, y: 9) }, atHostTime: host(11))
        try recorder.markMediaBoundary(atHostTime: host(12))
        XCTAssertEqual(snapshot, [display.segment(at: 0)])
        XCTAssertEqual(recorder.segments.map(\.start), [0, 1, 2])
    }
}
