import AppKit
import ApplicationServices
import CoreGraphics
import CoreMedia
import Foundation

/// The frontmost window as a source reads it.
enum FrontmostWindowLookup: Equatable, Sendable {
    case window(WindowDescriptor)
    /// No frontmost application, no on-screen window of it, or the window list could not be
    /// read.
    case unavailable
}

/// Where the recorder learns that the frontmost window may have changed, and reads which window
/// it is, so the recorder can be tested without the desktop.
protocol FrontmostWindowSource: AnyObject, Sendable {
    /// Starts reporting, on any thread, each moment the frontmost window may have changed, with
    /// the host time it was observed. Returns false if nothing can be observed.
    func start(onChange: @escaping @Sendable (_ hostTime: CMTime) -> Void) -> Bool
    func stop()
    /// The window frontmost now. Reads identity and frame only, never a title.
    func frontmostWindow() -> FrontmostWindowLookup
}

/// The system calls `SystemFrontmostWindowSource` makes, so its lifecycle can be tested without
/// registering a real observer.
protocol FrontmostWindowPlatform: Sendable {
    func isMainThread() -> Bool
    func onMain(_ work: @escaping @Sendable () -> Void)
    /// Calls `handler` on the main thread with the process of each newly activated application.
    /// Returns a token for `stopObservingActivations`, which any thread may call.
    func observeActivations(_ handler: @escaping @Sendable (pid_t?) -> Void) -> AnyObject
    func stopObservingActivations(_ token: AnyObject)
    func frontmostProcess() -> pid_t?
    /// Whether this process is trusted for Accessibility. Never asks.
    func isTrusted() -> Bool
    /// Main thread only. Calls `handler` on the main thread each time `pid`'s focused or main
    /// window changes, until the handle is passed to `stopObservingWindowChanges`; nil if that
    /// cannot be observed.
    func observeWindowChanges(of pid: pid_t, _ handler: @escaping @Sendable () -> Void) -> AnyObject?
    /// Main thread only.
    func stopObservingWindowChanges(_ handle: AnyObject)
    func hostTimeNow() -> CMTime
    func frontmostWindow() -> FrontmostWindowLookup
}

/// Observes the frontmost window from the system without asking for any permission.
///
/// Application activation comes from `NSWorkspace`. A switch between windows of one application
/// comes from Accessibility focused-window and main-window notifications on the frontmost
/// application, observed only when this process is already trusted; without trust, only
/// application switches are seen. Starting reports one observation, so the window frontmost at
/// the start is recorded.
///
/// Each start makes a registration that owns its workspace observer and Accessibility observer.
/// The Accessibility observer is set up, replaced, and removed only on the main thread, where it
/// calls back, and only for a registration still active, so cleanup queued by a stop never
/// touches the observer of a later start. A stop, from any thread and also from `deinit`, queues
/// the cleanup with the registration alone, never with the source.
///
/// The window is read from the on-screen window list: the frontmost normal-layer window owned by
/// the frontmost application, by its window number, owner's bundle identifier, and bounds. The
/// list's window names are never read.
final class SystemFrontmostWindowSource: FrontmostWindowSource, @unchecked Sendable {
    /// One start's observers. `active` and `windowHandle` are read and written on the main
    /// thread only.
    private final class Registration: @unchecked Sendable {
        let platform: FrontmostWindowPlatform
        let onChange: @Sendable (CMTime) -> Void
        var activationToken: AnyObject?
        var active = true
        var windowHandle: AnyObject?

        init(platform: FrontmostWindowPlatform, onChange: @escaping @Sendable (CMTime) -> Void) {
            self.platform = platform
            self.onChange = onChange
        }

        /// Main thread only: observes `pid`'s window changes in place of the last application's.
        func observeWindows(of pid: pid_t?) {
            guard active else { return }
            if let windowHandle { platform.stopObservingWindowChanges(windowHandle) }
            windowHandle = nil
            guard let pid, platform.isTrusted() else { return }
            let (platform, onChange) = (platform, onChange)
            windowHandle = platform.observeWindowChanges(of: pid) { onChange(platform.hostTimeNow()) }
        }

        /// Main thread only.
        func invalidate() {
            active = false
            if let windowHandle { platform.stopObservingWindowChanges(windowHandle) }
            windowHandle = nil
        }
    }

    private let platform: FrontmostWindowPlatform
    private let lock = NSLock()
    private var current: Registration?

    init(platform: FrontmostWindowPlatform = SystemFrontmostWindowPlatform()) {
        self.platform = platform
    }

    deinit {
        stop()
    }

    func start(onChange: @escaping @Sendable (CMTime) -> Void) -> Bool {
        stop()
        let registration = Registration(platform: platform, onChange: onChange)
        let platform = platform
        registration.activationToken = platform.observeActivations { [weak registration] pid in
            guard let registration, registration.active else { return }
            onChange(platform.hostTimeNow())
            registration.observeWindows(of: pid)
        }
        lock.withLock { current = registration }
        platform.onMain { [weak registration] in
            registration?.observeWindows(of: platform.frontmostProcess())
        }
        onChange(platform.hostTimeNow())
        return true
    }

    func stop() {
        guard let registration = lock.withLock({ () -> Registration? in
            defer { current = nil }
            return current
        }) else { return }
        if let token = registration.activationToken { platform.stopObservingActivations(token) }
        if platform.isMainThread() {
            registration.invalidate()
        } else {
            platform.onMain { registration.invalidate() }
        }
    }

    func frontmostWindow() -> FrontmostWindowLookup {
        platform.frontmostWindow()
    }
}

/// The system behind `SystemFrontmostWindowSource`.
struct SystemFrontmostWindowPlatform: FrontmostWindowPlatform {
    /// An Accessibility observer, the application element it watches, and the handler it calls
    /// back with, which the observer refers to unretained and this keeps alive.
    private final class WindowObservation {
        let observer: AXObserver
        let application: AXUIElement
        let handler: Handler

        init(observer: AXObserver, application: AXUIElement, handler: Handler) {
            self.observer = observer
            self.application = application
            self.handler = handler
        }
    }

    fileprivate final class Handler {
        let call: @Sendable () -> Void
        init(_ call: @escaping @Sendable () -> Void) { self.call = call }
    }

    private static let windowNotifications = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification]

    func isMainThread() -> Bool { Thread.isMainThread }

    func onMain(_ work: @escaping @Sendable () -> Void) { DispatchQueue.main.async(execute: work) }

    func observeActivations(_ handler: @escaping @Sendable (pid_t?) -> Void) -> AnyObject {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            handler((notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier)
        }
    }

    func stopObservingActivations(_ token: AnyObject) {
        NSWorkspace.shared.notificationCenter.removeObserver(token)
    }

    func frontmostProcess() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    func isTrusted() -> Bool { AXIsProcessTrusted() }

    func observeWindowChanges(of pid: pid_t, _ handler: @escaping @Sendable () -> Void) -> AnyObject? {
        var created: AXObserver?
        guard AXObserverCreate(pid, frontmostWindowCallback, &created) == .success, let observer = created else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, SystemAccessibilityQueries.messagingTimeout)
        let box = Handler(handler)
        let refcon = Unmanaged.passUnretained(box).toOpaque()
        var added = false
        for notification in Self.windowNotifications {
            added = AXObserverAddNotification(observer, application, notification as CFString, refcon) == .success || added
        }
        guard added else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        return WindowObservation(observer: observer, application: application, handler: box)
    }

    func stopObservingWindowChanges(_ handle: AnyObject) {
        guard let observation = handle as? WindowObservation else { return }
        for notification in Self.windowNotifications {
            AXObserverRemoveNotification(observation.observer, observation.application, notification as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observation.observer), .commonModes)
    }

    func hostTimeNow() -> CMTime { CaptureClock.hostTimeNow() }

    func frontmostWindow() -> FrontmostWindowLookup {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = application.bundleIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[CFString: Any]]
        else { return .unavailable }
        // The list runs front to back.
        for info in list {
            guard (info[kCGWindowOwnerPID] as? pid_t) == application.processIdentifier,
                  (info[kCGWindowLayer] as? Int) == 0,
                  let number = info[kCGWindowNumber] as? UInt32,
                  let bounds = info[kCGWindowBounds] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds)
            else { continue }
            return .window(WindowDescriptor(bundleIdentifier: bundleIdentifier, windowID: number, frame: frame))
        }
        return .unavailable
    }

    fileprivate static func handle(_ refcon: UnsafeMutableRawPointer?) {
        guard let refcon else { return }
        Unmanaged<Handler>.fromOpaque(refcon).takeUnretainedValue().call()
    }
}

private let frontmostWindowCallback: AXObserverCallback = { _, _, _, refcon in
    SystemFrontmostWindowPlatform.handle(refcon)
}
