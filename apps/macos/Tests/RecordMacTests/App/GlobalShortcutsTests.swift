import AppKit
import Carbon.HIToolbox
import XCTest
@testable import RecordMac

@MainActor
final class GlobalShortcutsTests: XCTestCase {
    /// Scripted Carbon: records calls and answers with set statuses.
    private final class FakeHotKeySystem: HotKeySystem {
        var installStatus: OSStatus = noErr
        var registerStatus: [ShortcutCombination: OSStatus] = [:]
        private(set) var dispatch: ((EventHotKeyID, Bool) -> Bool)?
        private(set) var installs = 0
        private(set) var removals = 0
        private(set) var registered: [(ShortcutCombination, EventHotKeyID)] = []
        private(set) var unregistered: [ShortcutCombination] = []
        private var live: [EventHotKeyRef: ShortcutCombination] = [:]

        func installHandler(_ dispatch: @escaping (EventHotKeyID, Bool) -> Bool) -> OSStatus {
            installs += 1
            if installStatus == noErr { self.dispatch = dispatch }
            return installStatus
        }

        func removeHandler() {
            removals += 1
            dispatch = nil
        }

        func register(_ combination: ShortcutCombination, id: EventHotKeyID) -> (OSStatus, EventHotKeyRef?) {
            let status = registerStatus[combination] ?? noErr
            guard status == noErr else { return (status, nil) }
            registered.append((combination, id))
            let reference = EventHotKeyRef(bitPattern: registered.count)!
            live[reference] = combination
            return (noErr, reference)
        }

        func unregister(_ reference: EventHotKeyRef) {
            if let combination = live.removeValue(forKey: reference) {
                unregistered.append(combination)
            }
        }
    }

    fileprivate let a = ShortcutCombination(keyCode: UInt32(kVK_F17), modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))
    private let b = ShortcutCombination(keyCode: UInt32(kVK_F18), modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))
    fileprivate let exists = OSStatus(eventHotKeyExistsErr)

    // MARK: Binding

    func testABindingIsEffectiveAndRebindingTheSameCombinationRegistersNothing() {
        let system = FakeHotKeySystem()
        let registrar = GlobalShortcutRegistrar(system: system)
        XCTAssertEqual(registrar.bind("x", to: a) {}, ShortcutStatus(effective: a, failure: nil))
        XCTAssertEqual(registrar.bind("x", to: a) {}, ShortcutStatus(effective: a, failure: nil))
        XCTAssertEqual(system.registered.count, 1)
        XCTAssertEqual(system.installs, 1)
        XCTAssertEqual(registrar.status(of: "x"), ShortcutStatus(effective: a, failure: nil))
        XCTAssertEqual(registrar.status(of: "never bound"), .unbound)
    }

    func testAHeldCombinationIsAConflictAndOtherFailuresAreNamed() {
        let system = FakeHotKeySystem()
        system.registerStatus = [a: exists, b: -50]
        let registrar = GlobalShortcutRegistrar(system: system)
        XCTAssertEqual(registrar.bind("x", to: a) {}, ShortcutStatus(effective: nil, failure: .conflict(requested: a, status: exists)))
        XCTAssertEqual(registrar.bind("y", to: b) {}, ShortcutStatus(effective: nil, failure: .failed(requested: b, status: -50)))
    }

    func testAFailedRebindKeepsTheOldCombinationEffective() {
        let system = FakeHotKeySystem()
        let registrar = GlobalShortcutRegistrar(system: system)
        registrar.bind("x", to: a) {}
        system.registerStatus = [b: exists]
        XCTAssertEqual(registrar.bind("x", to: b) {}, ShortcutStatus(effective: a, failure: .conflict(requested: b, status: exists)))
        XCTAssertEqual(system.unregistered, [])
    }

    func testASuccessfulRebindReleasesTheOldCombinationAfterTakingTheNew() {
        let system = FakeHotKeySystem()
        let registrar = GlobalShortcutRegistrar(system: system)
        registrar.bind("x", to: a) {}
        XCTAssertEqual(registrar.bind("x", to: b) {}, ShortcutStatus(effective: b, failure: nil))
        XCTAssertEqual(system.registered.map(\.0), [a, b])
        XCTAssertEqual(system.unregistered, [a])
    }

    func testUnbindingReleasesTheCombination() {
        let system = FakeHotKeySystem()
        let registrar = GlobalShortcutRegistrar(system: system)
        registrar.bind("x", to: a) {}
        XCTAssertEqual(registrar.bind("x", to: nil) {}, .unbound)
        XCTAssertEqual(system.unregistered, [a])
    }

    func testRetryTakesACombinationThatHasBecomeFree() {
        let system = FakeHotKeySystem()
        system.registerStatus = [a: exists]
        let registrar = GlobalShortcutRegistrar(system: system)
        registrar.bind("x", to: a) {}
        system.registerStatus = [:]
        registrar.retryFailed()
        XCTAssertEqual(registrar.status(of: "x"), ShortcutStatus(effective: a, failure: nil))
    }

    func testAHandlerThatCannotBeInstalledRegistersNothingUntilRetried() {
        let system = FakeHotKeySystem()
        system.installStatus = -9870
        let registrar = GlobalShortcutRegistrar(system: system)
        XCTAssertEqual(registrar.bind("x", to: a) {}, ShortcutStatus(effective: nil, failure: .handlerUnavailable(status: -9870)))
        XCTAssertTrue(system.registered.isEmpty)
        system.installStatus = noErr
        registrar.retryFailed()
        XCTAssertEqual(registrar.status(of: "x"), ShortcutStatus(effective: a, failure: nil))
        XCTAssertEqual(system.installs, 2)
    }

    func testTeardownReleasesOnlyThisRegistrarsKeysAndHandler() {
        let system = FakeHotKeySystem()
        let registrar = GlobalShortcutRegistrar(system: system)
        registrar.bind("x", to: a) {}
        registrar.bind("y", to: b) {}
        registrar.teardown()
        XCTAssertEqual(Set(system.unregistered), [a, b])
        XCTAssertEqual(system.removals, 1)
        XCTAssertEqual(registrar.status(of: "x"), .unbound)
    }

    // MARK: Dispatch

    func testOnlyTheReleaseOfAnOwnedKeyRunsTheActionOnce() throws {
        let system = FakeHotKeySystem()
        let registrar = GlobalShortcutRegistrar(system: system)
        var runs = 0
        registrar.bind("x", to: a) { runs += 1 }
        let id = try XCTUnwrap(system.registered.first?.1)
        let dispatch = try XCTUnwrap(system.dispatch)

        for _ in 0..<5 { XCTAssertTrue(dispatch(id, false)) }
        XCTAssertEqual(runs, 0, "a held or repeating key runs nothing")
        XCTAssertTrue(dispatch(id, true))
        XCTAssertEqual(runs, 1)
    }

    func testKeysThisRegistrarDoesNotOwnArePassedOn() throws {
        let systemA = FakeHotKeySystem()
        let systemB = FakeHotKeySystem()
        let first = GlobalShortcutRegistrar(system: systemA)
        let second = GlobalShortcutRegistrar(system: systemB)
        var firstRuns = 0
        first.bind("x", to: a) { firstRuns += 1 }
        second.bind("x", to: b) {}
        let firstID = try XCTUnwrap(systemA.registered.first?.1)
        let secondID = try XCTUnwrap(systemB.registered.first?.1)

        XCTAssertNotEqual(firstID.id, secondID.id, "IDs are unique across registrars")
        let dispatch = try XCTUnwrap(systemA.dispatch)
        XCTAssertFalse(dispatch(secondID, true))
        XCTAssertFalse(dispatch(EventHotKeyID(signature: 0x4F52_5243, id: firstID.id), true))
        XCTAssertEqual(firstRuns, 0)
        first.bind("x", to: nil) {}
        XCTAssertFalse(dispatch(firstID, true), "a released key is no longer owned")
    }

    // MARK: Suspension

    func testTheSuspensionShortcutTogglesItsFilterOnRelease() throws {
        let system = FakeHotKeySystem()
        let filter = ActivityEventFilter(guard: SecureInputGuard(signals: NotSecure()))
        let shortcut = ActivitySuspensionShortcut(registrar: GlobalShortcutRegistrar(system: system), filter: filter)
        XCTAssertEqual(shortcut.bind(a), ShortcutStatus(effective: a, failure: nil))
        let id = try XCTUnwrap(system.registered.first?.1)
        let dispatch = try XCTUnwrap(system.dispatch)
        let stream = makeFixtureActivity().events
        XCTAssertEqual(Set(stream.map(\.kind)), Set(ActivityEventKind.allCases))

        _ = dispatch(id, false)
        _ = dispatch(id, true)
        XCTAssertTrue(filter.isSuspended)
        XCTAssertEqual(stream.compactMap(filter.filter), [], "every kind is dropped while suspended")

        _ = dispatch(id, false)
        _ = dispatch(id, true)
        XCTAssertFalse(filter.isSuspended)
        XCTAssertEqual(stream.compactMap(filter.filter), stream, "every kind is admitted after resuming")
    }

    // MARK: Carbon on this machine

    fileprivate func rawRegister(_ combination: ShortcutCombination) -> OSStatus {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combination.keyCode, combination.modifiers, EventHotKeyID(signature: 0x5445_5354, id: 1),
            GetApplicationEventTarget(), 0, &reference)
        if let reference { UnregisterEventHotKey(reference) }
        return status
    }

    func testCarbonReportsAHeldCombinationAndTeardownReleasesOnlyItsOwn() {
        _ = NSApplication.shared
        let first = GlobalShortcutRegistrar()
        let second = GlobalShortcutRegistrar()
        defer {
            first.teardown()
            second.teardown()
        }

        XCTAssertEqual(first.bind("x", to: a) {}, ShortcutStatus(effective: a, failure: nil))
        XCTAssertEqual(second.bind("x", to: a) {}, ShortcutStatus(effective: nil, failure: .conflict(requested: a, status: exists)))
        XCTAssertEqual(second.bind("y", to: b) {}, ShortcutStatus(effective: b, failure: nil))
        XCTAssertEqual(rawRegister(a), exists, "another owner, such as the recording hot keys, sees the conflict")

        first.teardown()
        XCTAssertEqual(rawRegister(a), noErr, "teardown released its own combination")
        XCTAssertEqual(rawRegister(b), exists, "and left the other registrar's in place")
        second.retryFailed()
        XCTAssertEqual(second.status(of: "x"), ShortcutStatus(effective: a, failure: nil))
    }
}

@MainActor
extension GlobalShortcutsTests {
    func testReleasingABoundRegistrarWithoutTeardownReleasesItsKeysAndHandler() {
        _ = NSApplication.shared
        weak var releasedSystem: CarbonHotKeySystem?
        do {
            let system = CarbonHotKeySystem()
            releasedSystem = system
            let registrar = GlobalShortcutRegistrar(system: system)
            XCTAssertEqual(registrar.bind("x", to: a) {}, ShortcutStatus(effective: a, failure: nil))
            XCTAssertEqual(rawRegister(a), exists)
        }
        XCTAssertNil(releasedSystem, "the registrar and its Carbon system are released")
        XCTAssertEqual(rawRegister(a), noErr, "its hot key was unregistered")

        let next = GlobalShortcutRegistrar()
        defer { next.teardown() }
        XCTAssertEqual(next.bind("x", to: a) {}, ShortcutStatus(effective: a, failure: nil))
    }
}

private struct NotSecure: SecureInputSignals {
    func secureEventInputEnabled() -> Bool? { false }
    func focusedElementIsSecureTextField() -> Bool? { false }
}
