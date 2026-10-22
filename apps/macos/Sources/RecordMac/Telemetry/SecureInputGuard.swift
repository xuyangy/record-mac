import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// The two independent signals that typing is secure (research.md R-007). Each answers nil when
/// its state cannot be determined.
protocol SecureInputSignals: Sendable {
    /// Whether any process has enabled secure event input, as password fields do system-wide.
    func secureEventInputEnabled() -> Bool?
    /// Whether the focused element is a secure text field, as read through Accessibility.
    func focusedElementIsSecureTextField() -> Bool?
}

/// Reads both signals from the system.
struct SystemSecureInputSignals: SecureInputSignals {
    func secureEventInputEnabled() -> Bool? {
        IsSecureEventInputEnabled()
    }

    func focusedElementIsSecureTextField() -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        switch focusResult {
        case .success:
            break
        case .noValue, .attributeUnsupported:
            // Nothing has keyboard focus, so nothing secure does.
            return false
        default:
            return nil
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var subrole: CFTypeRef?
        let subroleResult = AXUIElementCopyAttributeValue(
            focused as! AXUIElement, kAXSubroleAttribute as CFString, &subrole)
        switch subroleResult {
        case .success:
            return (subrole as? String) == (kAXSecureTextFieldSubrole as String)
        case .noValue, .attributeUnsupported:
            return false
        default:
            return nil
        }
    }
}

/// Decides whether a key event may be recorded. Key events are dropped while either signal
/// reports secure input, and also while either cannot be determined: failing closed costs at most
/// a missing badge, failing open leaks a password (FR-041, SC-009). Other events are unaffected.
struct SecureInputGuard: Sendable {
    let signals: any SecureInputSignals

    init(signals: any SecureInputSignals = SystemSecureInputSignals()) {
        self.signals = signals
    }

    func admitsKeyEvent() -> Bool {
        signals.secureEventInputEnabled() == false && signals.focusedElementIsSecureTextField() == false
    }

    func admits(_ event: ActivityEvent) -> Bool {
        event.kind != .keyPress || admitsKeyEvent()
    }
}

/// The last stage before an event joins the activity stream: suspension drops every kind of
/// event (FR-024), and the secure-input guard drops key events.
final class ActivityEventFilter: @unchecked Sendable {
    private let guardrail: SecureInputGuard
    private let lock = NSLock()
    private var suspended = false

    init(guard guardrail: SecureInputGuard = SecureInputGuard()) {
        self.guardrail = guardrail
    }

    var isSuspended: Bool {
        lock.lock()
        defer { lock.unlock() }
        return suspended
    }

    func setSuspended(_ value: Bool) {
        lock.lock()
        suspended = value
        lock.unlock()
    }

    /// Returns `event` if it may be recorded, or nil.
    func filter(_ event: ActivityEvent) -> ActivityEvent? {
        guard !isSuspended, guardrail.admits(event) else { return nil }
        return event
    }
}
