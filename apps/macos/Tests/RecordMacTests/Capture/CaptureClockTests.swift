import CoreMedia
import XCTest
@testable import RecordMac

final class CaptureClockTests: XCTestCase {
    private func t(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
    }

    func testSessionTimeCountsFromTheEpoch() throws {
        let clock = CaptureClock(epochHostTime: t(100))
        XCTAssertNil(clock.sessionTime(forHostTime: t(99.999)))
        XCTAssertEqual(try XCTUnwrap(clock.sessionTime(forHostTime: t(100))).seconds, 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(clock.sessionTime(forHostTime: t(102.5))).seconds, 2.5, accuracy: 1e-9)
    }

    func testPausedTimeIsExcludedAndBuffersInsideAPauseHaveNoTime() throws {
        let clock = CaptureClock(epochHostTime: t(100))
        XCTAssertTrue(clock.pause(atHostTime: t(103)))
        XCTAssertTrue(clock.isPaused)
        XCTAssertNil(clock.sessionTime(forHostTime: t(104)))
        XCTAssertTrue(clock.resume(atHostTime: t(110)))
        XCTAssertFalse(clock.isPaused)

        XCTAssertEqual(try XCTUnwrap(clock.sessionTime(forHostTime: t(102))).seconds, 2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(clock.sessionTime(forHostTime: t(110))).seconds, 3, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(clock.sessionTime(forHostTime: t(111))).seconds, 4, accuracy: 1e-9)

        XCTAssertTrue(clock.pause(atHostTime: t(112)))
        XCTAssertTrue(clock.resume(atHostTime: t(113)))
        XCTAssertEqual(try XCTUnwrap(clock.sessionTime(forHostTime: t(114))).seconds, 6, accuracy: 1e-9)
        XCTAssertEqual(
            clock.pauses(closingAt: t(120)),
            [CaptureTimeRange(start: 3, end: 10), CaptureTimeRange(start: 12, end: 13)])
    }

    func testTracksStampedOnOneHostTimeAgreeAcrossAPause() throws {
        // Screen, microphone, system audio, and camera buffers from the same host instant map to
        // the same session time, before and after a pause.
        let clock = CaptureClock(epochHostTime: t(50))
        clock.pause(atHostTime: t(55))
        clock.resume(atHostTime: t(58))
        for instant in [51.0, 54.99, 58.0, 70.123] {
            let times = (0..<4).compactMap { _ in clock.sessionTime(forHostTime: t(instant)) }
            XCTAssertEqual(times.count, 4)
            XCTAssertEqual(Set(times.map(\.value)).count, 1, "\(instant)")
        }
    }

    func testRejectedTransitionsChangeNothing() {
        let clock = CaptureClock(epochHostTime: t(100))
        XCTAssertFalse(clock.resume(atHostTime: t(101)), "resume while recording")
        XCTAssertFalse(clock.pause(atHostTime: t(99)), "pause before the epoch")
        XCTAssertTrue(clock.pause(atHostTime: t(101)))
        XCTAssertFalse(clock.pause(atHostTime: t(102)), "pause while paused")
        XCTAssertFalse(clock.resume(atHostTime: t(100.5)), "resume before the pause")
        XCTAssertTrue(clock.resume(atHostTime: t(102)))
        XCTAssertFalse(clock.pause(atHostTime: t(101.5)), "pause before the last resume")
        XCTAssertEqual(clock.pauses(closingAt: t(200)), [CaptureTimeRange(start: 1, end: 2)])
    }

    func testOpenPauseIsClosedAtStop() {
        let clock = CaptureClock(epochHostTime: t(10))
        clock.pause(atHostTime: t(12))
        XCTAssertEqual(clock.pauses(closingAt: t(15)), [CaptureTimeRange(start: 2, end: 5)])
    }

    func testHostClockTimestampsConvertUnchanged() throws {
        let now = CaptureClock.hostTimeNow()
        let clock = CaptureClock(epochHostTime: now)
        let later = now + t(1.25)
        let viaClock = try XCTUnwrap(clock.sessionTime(for: later, from: CaptureClock.hostClock))
        XCTAssertEqual(viaClock.seconds, 1.25, accuracy: 1e-6)
    }

    func testReferenceRecordsTheEpochInNanoseconds() {
        XCTAssertEqual(CaptureClock(epochHostTime: t(2.5)).reference.epochHostTimeNanoseconds, 2_500_000_000)
    }
}
