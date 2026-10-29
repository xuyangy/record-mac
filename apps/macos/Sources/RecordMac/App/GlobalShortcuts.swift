import Carbon.HIToolbox
import Foundation
import KeyboardShortcuts

/// A key and Carbon modifier set, as KeyboardShortcuts stores a shortcut and Carbon registers it.
struct ShortcutCombination: Hashable, Sendable, CustomStringConvertible {
    let keyCode: UInt32
    let modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(_ shortcut: KeyboardShortcuts.Shortcut) {
        self.init(keyCode: UInt32(shortcut.carbonKeyCode), modifiers: UInt32(shortcut.carbonModifiers))
    }

    /// The combination the creator stored under `name`, if any.
    static func stored(for name: KeyboardShortcuts.Name) -> ShortcutCombination? {
        KeyboardShortcuts.getShortcut(for: name).map(ShortcutCombination.init)
    }

    var description: String { "key \(keyCode) modifiers \(modifiers)" }
}

extension KeyboardShortcuts.Name {
    /// Suspends and resumes all activity recording (FR-024). No default binding.
    static let suspendActivityRecording = Self("suspendActivityRecording")
}

/// Why a requested binding is not the effective one.
enum ShortcutFailure: Equatable, Sendable {
    /// Another registration in this process holds the combination (`eventHotKeyExistsErr`).
    case conflict(requested: ShortcutCombination, status: OSStatus)
    case failed(requested: ShortcutCombination, status: OSStatus)
    /// The hot-key event handler could not be installed, so nothing can be registered.
    case handlerUnavailable(status: OSStatus)
}

/// A shortcut's registration: the combination that fires now, and why the requested one does
/// not when they differ.
struct ShortcutStatus: Equatable, Sendable {
    var effective: ShortcutCombination?
    var failure: ShortcutFailure?

    static let unbound = ShortcutStatus(effective: nil, failure: nil)
}

/// The Carbon calls a registrar makes, so its bookkeeping can be tested without the system.
@MainActor
protocol HotKeySystem: AnyObject {
    /// Installs the application's hot-key handler. `dispatch` gets each pressed or released hot
    /// key and returns whether it handled it.
    func installHandler(_ dispatch: @escaping (EventHotKeyID, _ released: Bool) -> Bool) -> OSStatus
    func removeHandler()
    func register(_ combination: ShortcutCombination, id: EventHotKeyID) -> (OSStatus, EventHotKeyRef?)
    func unregister(_ reference: EventHotKeyRef)
}

/// Registers through Carbon and keeps every status. KeyboardShortcuts registers its own hot
/// keys without reporting a failure, so it is used here for the shortcut type and its stored
/// binding only.
///
/// Releasing it, on the main actor, unregisters every hot key it still holds and removes its
/// handler before the handler's context is freed, whether or not its owner tore down first.
@MainActor
final class CarbonHotKeySystem: HotKeySystem {
    private var handlerReference: EventHandlerRef?
    private var box: HotKeyHandlerBox?
    private var held: Set<EventHotKeyRef> = []

    init() {}

    isolated deinit {
        for reference in held { UnregisterEventHotKey(reference) }
        if let handlerReference { RemoveEventHandler(handlerReference) }
    }

    func installHandler(_ dispatch: @escaping (EventHotKeyID, Bool) -> Bool) -> OSStatus {
        let box = HotKeyHandlerBox(dispatch: dispatch)
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        var reference: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(), hotKeyEventHandler, types.count, &types,
            Unmanaged.passUnretained(box).toOpaque(), &reference)
        if status == noErr {
            self.box = box
            handlerReference = reference
        }
        return status
    }

    func removeHandler() {
        if let handlerReference { RemoveEventHandler(handlerReference) }
        handlerReference = nil
        box = nil
    }

    func register(_ combination: ShortcutCombination, id: EventHotKeyID) -> (OSStatus, EventHotKeyRef?) {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combination.keyCode, combination.modifiers, id, GetApplicationEventTarget(), 0, &reference)
        if status == noErr, let reference { held.insert(reference) }
        return (status, reference)
    }

    func unregister(_ reference: EventHotKeyRef) {
        guard held.remove(reference) != nil else { return }
        UnregisterEventHotKey(reference)
    }
}

private final class HotKeyHandlerBox {
    let dispatch: (EventHotKeyID, Bool) -> Bool

    init(dispatch: @escaping (EventHotKeyID, Bool) -> Bool) {
        self.dispatch = dispatch
    }
}

/// Passes a hot key on unless its registrar owns it, so other handlers in the chain still get
/// theirs.
private let hotKeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return OSStatus(eventNotHandledErr) }
    let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
    let box = Unmanaged<HotKeyHandlerBox>.fromOpaque(userData).takeUnretainedValue()
    return box.dispatch(hotKeyID, released) ? noErr : OSStatus(eventNotHandledErr)
}

/// Registers global shortcuts by name and reports each one's real outcome (FR-064, FR-065).
///
/// Rebinding registers the new combination before releasing the old: if the new one fails, the
/// old one stays effective and the failure names the new one. Hot-key IDs are unique in the
/// process, and the handler acts only on IDs this registrar holds. Teardown releases only this
/// registrar's hot keys and handler; so does releasing the registrar with its Carbon system.
@MainActor
final class GlobalShortcutRegistrar {
    static let signature: OSType = 0x524D_4753 // "RMGS"

    private struct Binding {
        var combination: ShortcutCombination
        var id: UInt32
        var reference: EventHotKeyRef?
    }

    private struct Entry {
        var binding: Binding?
        var requested: ShortcutCombination?
        var failure: ShortcutFailure?
        var onRelease: () -> Void
    }

    private let system: HotKeySystem
    private var handlerStatus: OSStatus?
    private var entries: [String: Entry] = [:]

    init(system: HotKeySystem = CarbonHotKeySystem()) {
        self.system = system
    }

    /// Binds `name` to `combination`, or unbinds it when nil. `onRelease` runs when the key is
    /// released, so holding it down runs it once.
    @discardableResult
    func bind(_ name: String, to combination: ShortcutCombination?, onRelease: @escaping () -> Void) -> ShortcutStatus {
        var entry = entries[name] ?? Entry(onRelease: onRelease)
        entry.onRelease = onRelease
        entry.requested = combination
        entries[name] = entry
        return apply(name)
    }

    func status(of name: String) -> ShortcutStatus {
        guard let entry = entries[name] else { return .unbound }
        return ShortcutStatus(effective: entry.binding?.combination, failure: entry.failure)
    }

    /// Tries again every requested binding that is not in effect.
    func retryFailed() {
        for name in entries.keys where entries[name]?.failure != nil {
            apply(name)
        }
    }

    func teardown() {
        for (name, entry) in entries {
            if let reference = entry.binding?.reference { system.unregister(reference) }
            entries[name]?.binding = nil
        }
        entries = [:]
        if handlerStatus == noErr { system.removeHandler() }
        handlerStatus = nil
    }

    /// Handles a pressed or released hot key; false when this registrar does not own it.
    func handle(_ hotKeyID: EventHotKeyID, released: Bool) -> Bool {
        guard hotKeyID.signature == Self.signature,
            let entry = entries.values.first(where: { $0.binding?.id == hotKeyID.id })
        else { return false }
        if released { entry.onRelease() }
        return true
    }

    @discardableResult
    private func apply(_ name: String) -> ShortcutStatus {
        guard var entry = entries[name] else { return .unbound }
        defer { entries[name] = entry }

        guard let requested = entry.requested else {
            if let reference = entry.binding?.reference { system.unregister(reference) }
            entry.binding = nil
            entry.failure = nil
            return .unbound
        }
        if entry.binding?.combination == requested {
            entry.failure = nil
            return ShortcutStatus(effective: requested, failure: nil)
        }
        let installStatus = installHandlerIfNeeded()
        guard installStatus == noErr else {
            entry.failure = .handlerUnavailable(status: installStatus)
            return ShortcutStatus(effective: entry.binding?.combination, failure: entry.failure)
        }

        let id = HotKeyIdentifiers.next()
        let (status, reference) = system.register(requested, id: EventHotKeyID(signature: Self.signature, id: id))
        guard status == noErr else {
            entry.failure = status == OSStatus(eventHotKeyExistsErr)
                ? .conflict(requested: requested, status: status)
                : .failed(requested: requested, status: status)
            return ShortcutStatus(effective: entry.binding?.combination, failure: entry.failure)
        }
        if let old = entry.binding?.reference { system.unregister(old) }
        entry.binding = Binding(combination: requested, id: id, reference: reference)
        entry.failure = nil
        return ShortcutStatus(effective: requested, failure: nil)
    }

    private func installHandlerIfNeeded() -> OSStatus {
        if handlerStatus == noErr { return noErr }
        let status = system.installHandler { [weak self] hotKeyID, released in
            MainActor.assumeIsolated { self?.handle(hotKeyID, released: released) ?? false }
        }
        handlerStatus = status
        return status
    }
}

/// Hot-key IDs unique across every registrar in the process.
private enum HotKeyIdentifiers {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var last: UInt32 = 0

    static func next() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        last &+= 1
        return last
    }
}

/// The shortcut that suspends and resumes activity recording, toggling the filter it is given
/// (FR-024). The filter a recording session uses is wired by the recorder (T041).
@MainActor
final class ActivitySuspensionShortcut {
    private let registrar: GlobalShortcutRegistrar
    private let filter: ActivityEventFilter

    init(registrar: GlobalShortcutRegistrar, filter: ActivityEventFilter) {
        self.registrar = registrar
        self.filter = filter
    }

    @discardableResult
    func bind(_ combination: ShortcutCombination?) -> ShortcutStatus {
        registrar.bind(KeyboardShortcuts.Name.suspendActivityRecording.rawValue, to: combination) { [filter] in
            filter.setSuspended(!filter.isSuspended)
        }
    }
}
