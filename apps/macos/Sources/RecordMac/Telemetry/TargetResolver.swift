import ApplicationServices
import Foundation

/// An Accessibility element as the resolver sees it: opaque, compared by identity.
final class AccessibilityElement: @unchecked Sendable {
    let reference: AnyObject

    init(_ reference: AnyObject) {
        self.reference = reference
    }
}

/// The result of asking Accessibility for an element.
enum AccessibilityLookup {
    case element(AccessibilityElement)
    case none
    case failed(AXError)
}

/// The Accessibility calls the resolver makes, so it can be tested without the system.
protocol AccessibilityQueries: Sendable {
    /// Whether this process is trusted for Accessibility. Never requests access.
    func isTrusted() -> Bool
    /// The element at a point in global Accessibility coordinates.
    func element(at point: CGPoint) -> AccessibilityLookup
    /// The element with keyboard focus.
    func focusedElement() -> AccessibilityLookup
    func copyAttribute(_ attribute: String, of element: AccessibilityElement) -> (AXError, CFTypeRef?)
}

/// Asks the system, with a bounded messaging timeout so an unresponsive application cannot
/// hold the caller.
struct SystemAccessibilityQueries: AccessibilityQueries {
    static let messagingTimeout: Float = 0.25

    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func element(at point: CGPoint) -> AccessibilityLookup {
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWide(), Float(point.x), Float(point.y), &element)
        return lookup(result, element)
    }

    func focusedElement() -> AccessibilityLookup {
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide(), kAXFocusedUIElementAttribute as CFString, &focused)
        guard result == .success else { return lookup(result, nil) }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return .failed(.illegalArgument)
        }
        return .element(AccessibilityElement(focused))
    }

    func copyAttribute(_ attribute: String, of element: AccessibilityElement) -> (AXError, CFTypeRef?) {
        guard CFGetTypeID(element.reference) == AXUIElementGetTypeID() else { return (.illegalArgument, nil) }
        let axElement = element.reference as! AXUIElement
        AXUIElementSetMessagingTimeout(axElement, Self.messagingTimeout)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axElement, attribute as CFString, &value)
        return (result, value)
    }

    private func systemWide() -> AXUIElement {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.messagingTimeout)
        return systemWide
    }

    private func lookup(_ result: AXError, _ element: AXUIElement?) -> AccessibilityLookup {
        switch result {
        case .success:
            guard let element else { return .none }
            return .element(AccessibilityElement(element))
        case .noValue, .attributeUnsupported:
            return .none
        default:
            return .failed(result)
        }
    }
}

/// Resolves the target of pointer and keyboard activity to an `ElementDescriptor` (FR-023).
///
/// Reads only role, subrole, identifier, position, and size: never a title, value, description,
/// or other text, so a secure field yields its role and frame and nothing it holds.
/// `SecureInputGuard` alone decides whether a key event may be recorded.
///
/// Points and frames are global Accessibility coordinates: screen points with the origin at the
/// top left of the main display, negative to its left and above it. Converting them to capture
/// coordinates belongs with the recording's geometry.
///
/// Each lookup is a cross-process call bounded by `SystemAccessibilityQueries.messagingTimeout`.
/// A recorder runs it off the event tap's callback, and records the event whether or not a
/// target is found.
struct TargetResolver: Sendable {
    static let readAttributes: Set<String> = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute,
        kAXPositionAttribute, kAXSizeAttribute,
    ]

    var accessibility: any AccessibilityQueries = SystemAccessibilityQueries()

    /// The element under a pointer, or nil when Accessibility is not trusted, exposes nothing
    /// there, fails, or gives the element no role.
    func target(at point: CGPoint) -> ElementDescriptor? {
        guard point.x.isFinite, point.y.isFinite, accessibility.isTrusted() else { return nil }
        return describe(accessibility.element(at: point))
    }

    /// The element receiving keyboard input, on the same terms.
    func focusedTarget() -> ElementDescriptor? {
        guard accessibility.isTrusted() else { return nil }
        return describe(accessibility.focusedElement())
    }

    private func describe(_ lookup: AccessibilityLookup) -> ElementDescriptor? {
        guard case .element(let element) = lookup,
            let role = string(kAXRoleAttribute, of: element)
        else { return nil }
        return ElementDescriptor(
            role: role,
            subrole: string(kAXSubroleAttribute, of: element),
            identifier: string(kAXIdentifierAttribute, of: element),
            frame: frame(of: element))
    }

    private func string(_ attribute: String, of element: AccessibilityElement) -> String? {
        let (result, value) = accessibility.copyAttribute(attribute, of: element)
        guard result == .success, let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// The frame from position and size, each checked to be the AXValue type it should be. A
    /// non-finite or negative-size frame is absent rather than stored.
    private func frame(of element: AccessibilityElement) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard read(kAXPositionAttribute, .cgPoint, into: &origin, of: element),
            read(kAXSizeAttribute, .cgSize, into: &size, of: element)
        else { return nil }
        let frame = CGRect(origin: origin, size: size)
        guard [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite),
            size.width >= 0, size.height >= 0
        else { return nil }
        return frame
    }

    private func read<T>(
        _ attribute: String, _ type: AXValueType, into storage: inout T, of element: AccessibilityElement
    ) -> Bool {
        let (result, value) = accessibility.copyAttribute(attribute, of: element)
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return false }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == type else { return false }
        return AXValueGetValue(axValue, type, &storage)
    }
}
