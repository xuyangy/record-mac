import AppKit
import ApplicationServices
import XCTest
@testable import RecordMac

final class TargetResolverTests: XCTestCase {
    /// Elements with scripted attributes; records every attribute asked for.
    private final class FakeAccessibility: AccessibilityQueries, @unchecked Sendable {
        var trusted = true
        var atPoint: AccessibilityLookup = .none
        var focused: AccessibilityLookup = .none
        var attributes: [ObjectIdentifier: [String: (AXError, CFTypeRef?)]] = [:]
        private(set) var requested: [String] = []
        private(set) var pointsAsked: [CGPoint] = []

        func isTrusted() -> Bool { trusted }

        func element(at point: CGPoint) -> AccessibilityLookup {
            pointsAsked.append(point)
            return atPoint
        }

        func focusedElement() -> AccessibilityLookup { focused }

        func copyAttribute(_ attribute: String, of element: AccessibilityElement) -> (AXError, CFTypeRef?) {
            requested.append(attribute)
            return attributes[ObjectIdentifier(element)]?[attribute] ?? (.noValue, nil)
        }

        func add(_ values: [String: (AXError, CFTypeRef?)]) -> AccessibilityElement {
            let element = AccessibilityElement(NSObject())
            attributes[ObjectIdentifier(element)] = values
            return element
        }
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> CFTypeRef {
        var value = CGPoint(x: x, y: y)
        return AXValueCreate(.cgPoint, &value)!
    }

    private func size(_ width: CGFloat, _ height: CGFloat) -> CFTypeRef {
        var value = CGSize(width: width, height: height)
        return AXValueCreate(.cgSize, &value)!
    }

    private func button(origin: (CGFloat, CGFloat) = (-1200, -40)) -> [String: (AXError, CFTypeRef?)] {
        [
            kAXRoleAttribute: (.success, "AXButton" as CFString),
            kAXSubroleAttribute: (.success, "AXCloseButton" as CFString),
            kAXIdentifierAttribute: (.success, "close" as CFString),
            kAXPositionAttribute: (.success, point(origin.0, origin.1)),
            kAXSizeAttribute: (.success, size(14, 16)),
            kAXTitleAttribute: (.success, "must never be read" as CFString),
            kAXValueAttribute: (.success, "must never be read" as CFString),
        ]
    }

    // MARK: Pointer and focus

    func testAPointResolvesToTheAllowlistedDescriptorInGlobalCoordinates() {
        let fake = FakeAccessibility()
        fake.atPoint = .element(fake.add(button()))
        let target = TargetResolver(accessibility: fake).target(at: CGPoint(x: -1193, y: -32))
        XCTAssertEqual(target, ElementDescriptor(
            role: "AXButton", subrole: "AXCloseButton", identifier: "close",
            frame: CGRect(x: -1200, y: -40, width: 14, height: 16)))
        XCTAssertEqual(fake.pointsAsked, [CGPoint(x: -1193, y: -32)])
    }

    func testTheFocusedElementResolvesTheSameWay() {
        let fake = FakeAccessibility()
        fake.focused = .element(fake.add(button(origin: (300, 200))))
        XCTAssertEqual(
            TargetResolver(accessibility: fake).focusedTarget()?.frame,
            CGRect(x: 300, y: 200, width: 14, height: 16))
    }

    func testOnlyAllowlistedAttributesAreRequestedIncludingForASecureField() {
        let fake = FakeAccessibility()
        let secure = fake.add([
            kAXRoleAttribute: (.success, "AXTextField" as CFString),
            kAXSubroleAttribute: (.success, kAXSecureTextFieldSubrole as CFString),
            kAXValueAttribute: (.success, "secret" as CFString),
            kAXTitleAttribute: (.success, "Password" as CFString),
            kAXDescriptionAttribute: (.success, "Password" as CFString),
        ])
        fake.atPoint = .element(secure)
        fake.focused = .element(secure)
        let resolver = TargetResolver(accessibility: fake)
        let byPoint = resolver.target(at: CGPoint(x: 10, y: 10))
        let byFocus = resolver.focusedTarget()

        XCTAssertEqual(byPoint, ElementDescriptor(
            role: "AXTextField", subrole: kAXSecureTextFieldSubrole, identifier: nil, frame: nil))
        XCTAssertEqual(byFocus, byPoint)
        XCTAssertFalse(fake.requested.isEmpty)
        XCTAssertTrue(Set(fake.requested).isSubset(of: TargetResolver.readAttributes), "\(fake.requested)")
        XCTAssertEqual(TargetResolver.readAttributes, [
            kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute,
            kAXPositionAttribute, kAXSizeAttribute,
        ])
    }

    // MARK: Nothing to report

    func testUntrustedAccessibilityResolvesNothingAndAsksNothing() {
        let fake = FakeAccessibility()
        fake.trusted = false
        fake.atPoint = .element(fake.add(button()))
        fake.focused = fake.atPoint
        let resolver = TargetResolver(accessibility: fake)
        XCTAssertNil(resolver.target(at: CGPoint(x: 1, y: 1)))
        XCTAssertNil(resolver.focusedTarget())
        XCTAssertTrue(fake.pointsAsked.isEmpty)
        XCTAssertTrue(fake.requested.isEmpty)
    }

    func testNoElementAFailedLookupOrANonFinitePointResolvesNothing() {
        let fake = FakeAccessibility()
        let resolver = TargetResolver(accessibility: fake)
        fake.atPoint = .none
        XCTAssertNil(resolver.target(at: CGPoint(x: 1, y: 1)))
        fake.atPoint = .failed(.cannotComplete)
        XCTAssertNil(resolver.target(at: CGPoint(x: 1, y: 1)))
        fake.focused = .failed(.invalidUIElement)
        XCTAssertNil(resolver.focusedTarget())
        fake.atPoint = .element(fake.add(button()))
        XCTAssertNil(resolver.target(at: CGPoint(x: CGFloat.nan, y: 1)))
        XCTAssertNil(resolver.target(at: CGPoint(x: 1, y: CGFloat.infinity)))
        XCTAssertEqual(fake.pointsAsked.count, 2)
    }

    func testAnElementWithoutAUsableRoleResolvesNothing() {
        let fake = FakeAccessibility()
        let resolver = TargetResolver(accessibility: fake)
        var attributes = button()
        for role: (AXError, CFTypeRef?) in [
            (.cannotComplete, nil), (.noValue, nil), (.success, nil),
            (.success, "" as CFString), (.success, 3 as CFNumber),
        ] {
            attributes[kAXRoleAttribute] = role
            fake.atPoint = .element(fake.add(attributes))
            XCTAssertNil(resolver.target(at: CGPoint(x: 1, y: 1)), "\(role)")
        }
    }

    // MARK: Optional fields

    func testFailedOptionalAttributesAreAbsentAndTheRoleKept() {
        let fake = FakeAccessibility()
        var attributes = button()
        attributes[kAXSubroleAttribute] = (.cannotComplete, nil)
        attributes[kAXIdentifierAttribute] = (.success, 7 as CFNumber)
        attributes[kAXSizeAttribute] = (.attributeUnsupported, nil)
        fake.atPoint = .element(fake.add(attributes))
        XCTAssertEqual(
            TargetResolver(accessibility: fake).target(at: CGPoint(x: 1, y: 1)),
            ElementDescriptor(role: "AXButton", subrole: nil, identifier: nil, frame: nil))
    }

    func testAFrameOfTheWrongTypeOrNotFiniteOrNegativeIsAbsent() {
        let fake = FakeAccessibility()
        let resolver = TargetResolver(accessibility: fake)
        let wrong: [(String, CFTypeRef)] = [
            (kAXPositionAttribute, size(1, 1)),
            (kAXSizeAttribute, point(1, 1)),
            (kAXPositionAttribute, "10,10" as CFString),
            (kAXPositionAttribute, point(.nan, 0)),
            (kAXSizeAttribute, size(.infinity, 4)),
            (kAXSizeAttribute, size(-1, 4)),
        ]
        for (attribute, value) in wrong {
            var attributes = button()
            attributes[attribute] = (.success, value)
            fake.atPoint = .element(fake.add(attributes))
            let target = resolver.target(at: CGPoint(x: 1, y: 1))
            XCTAssertEqual(target?.role, "AXButton", "\(attribute)")
            XCTAssertNil(target?.frame, "\(attribute) \(value)")
        }
    }

    func testAResolvedTargetRoundTripsThroughJSON() throws {
        let fake = FakeAccessibility()
        fake.atPoint = .element(fake.add(button()))
        let target = try XCTUnwrap(TargetResolver(accessibility: fake).target(at: CGPoint(x: 1, y: 1)))
        let decoded = try JSONDecoder().decode(ElementDescriptor.self, from: JSONEncoder().encode(target))
        XCTAssertEqual(decoded, target)
    }

    // MARK: This machine

    /// Hit-tests a button in a window this test owns, through the system's Accessibility, and
    /// checks the descriptor against the button's known identifier and its Accessibility frame
    /// converted to global Accessibility coordinates.
    func testAControlledButtonResolvesThroughTheSystem() async throws {
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility is not trusted for this test process; the system path is unverified")
        }
        let (window, expectedFrame) = await MainActor.run { () -> (NSWindow, CGRect) in
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            application.finishLaunching()
            let window = NSWindow(
                contentRect: NSRect(x: 200, y: 200, width: 240, height: 120),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .screenSaver
            let button = NSButton(title: "Probe", target: nil, action: nil)
            button.identifier = NSUserInterfaceItemIdentifier("record-mac-target-probe")
            button.frame = NSRect(x: 40, y: 40, width: 120, height: 32)
            window.contentView?.addSubview(button)
            window.orderFrontRegardless()
            // The frame AppKit publishes to Accessibility, in screen coordinates with the origin
            // at the bottom left; a bezel button's extends past its drawn bounds.
            let onScreen = button.accessibilityFrame()
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let global = CGRect(
                x: onScreen.minX, y: primaryHeight - onScreen.maxY,
                width: onScreen.width, height: onScreen.height)
            return (window, global)
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        let resolver = TargetResolver()
        let target = await Task.detached {
            resolver.target(at: CGPoint(x: expectedFrame.midX, y: expectedFrame.midY))
        }.value
        await MainActor.run { window.close() }
        print("target resolver: controlled button -> \(String(describing: target)), expected frame \(expectedFrame)")
        let resolved = try XCTUnwrap(target)
        XCTAssertEqual(resolved.role, kAXButtonRole)
        XCTAssertEqual(resolved.identifier, "record-mac-target-probe")
        let frame = try XCTUnwrap(resolved.frame)
        XCTAssertEqual(frame.minX, expectedFrame.minX, accuracy: 1)
        XCTAssertEqual(frame.minY, expectedFrame.minY, accuracy: 1)
        XCTAssertEqual(frame.width, expectedFrame.width, accuracy: 1)
        XCTAssertEqual(frame.height, expectedFrame.height, accuracy: 1)
    }
}
