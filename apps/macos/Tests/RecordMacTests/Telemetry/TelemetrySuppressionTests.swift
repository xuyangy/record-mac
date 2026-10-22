import CoreGraphics
import XCTest
@testable import RecordMac

private struct StubSignals: SecureInputSignals {
    var secureEventInput: Bool?
    var secureField: Bool?

    func secureEventInputEnabled() -> Bool? { secureEventInput }
    func focusedElementIsSecureTextField() -> Bool? { secureField }
}

final class TelemetrySuppressionTests: XCTestCase {
    private let stream = makeFixtureActivity().events

    private func recorded(_ signals: StubSignals, suspended: Bool = false) -> [ActivityEvent] {
        let filter = ActivityEventFilter(guard: SecureInputGuard(signals: signals))
        filter.setSuspended(suspended)
        return stream.compactMap(filter.filter)
    }

    private var keyEvents: Int { stream.filter { $0.kind == .keyPress }.count }

    func testKeysPassWhenBothSignalsSayNotSecure() {
        XCTAssertEqual(recorded(StubSignals(secureEventInput: false, secureField: false)), stream)
    }

    func testEitherSignalDropsKeyEventsOnly() {
        for signals in [
            StubSignals(secureEventInput: true, secureField: false),
            StubSignals(secureEventInput: false, secureField: true),
            StubSignals(secureEventInput: true, secureField: true),
        ] {
            let result = recorded(signals)
            XCTAssertFalse(result.contains { $0.kind == .keyPress }, "\(signals)")
            XCTAssertEqual(result.count, stream.count - keyEvents, "\(signals)")
        }
    }

    func testUndeterminedStateFailsClosedForKeyEvents() {
        for signals in [
            StubSignals(secureEventInput: nil, secureField: false),
            StubSignals(secureEventInput: false, secureField: nil),
            StubSignals(secureEventInput: nil, secureField: nil),
        ] {
            let result = recorded(signals)
            XCTAssertFalse(result.contains { $0.kind == .keyPress }, "\(signals)")
        }
    }

    func testPointerEventsSurviveSecureInputAndMissingAccessibility() {
        // Missing Accessibility leaves the secure-field signal undetermined.
        let result = recorded(StubSignals(secureEventInput: true, secureField: nil))
        let pointerKinds: Set<ActivityEventKind> = [.pointerMove, .click, .scroll, .dragStart, .dragEnd]
        XCTAssertEqual(
            result.filter { pointerKinds.contains($0.kind) },
            stream.filter { pointerKinds.contains($0.kind) })
        XCTAssertTrue(result.contains { $0.kind == .activeWindowChange })
    }

    func testSuspendDropsEveryKind() {
        XCTAssertEqual(recorded(StubSignals(secureEventInput: false, secureField: false), suspended: true), [])

        let filter = ActivityEventFilter(guard: SecureInputGuard(signals: StubSignals(secureEventInput: false, secureField: false)))
        filter.setSuspended(true)
        XCTAssertNil(filter.filter(stream[0]))
        filter.setSuspended(false)
        XCTAssertEqual(filter.filter(stream[0]), stream[0])
    }

    func testTargetAndWindowCarryNoText() throws {
        // Only roles, identifiers, and frames: the encoded descriptors have no field that could
        // hold a value, typed text, or a title.
        let event = try XCTUnwrap(stream.first { $0.target != nil })
        let target = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(event.target)) as? [String: Any])
        XCTAssertTrue(Set(target.keys).isSubset(of: ["role", "subrole", "identifier", "frame"]))

        let windowEvent = try XCTUnwrap(stream.first { $0.window != nil })
        let window = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(windowEvent.window)) as? [String: Any])
        XCTAssertEqual(Set(window.keys), ["bundleIdentifier", "windowID", "frame"])
    }
}
