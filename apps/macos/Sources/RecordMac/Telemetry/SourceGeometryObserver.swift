import ApplicationServices
import AppKit
import CoreGraphics
import CoreMedia
import Foundation

/// The capture source whose geometry is observed, as capture resolved it: a display, an area of
/// a display, or one window. Application sources are not covered.
enum SourceGeometryTarget: Equatable, Sendable {
    case display(CGDirectDisplayID)
    /// `crop` is in the display's own points, origin at its top left: the space of
    /// `CaptureSourceGeometry.sourceRect`, so the area keeps its place on the display when the
    /// display moves in the arrangement.
    case area(CGDirectDisplayID, crop: CGRect)
    /// The window capture resolved, which can differ from the window the source named.
    case window(CGWindowID)

    /// The target for a resolved location and the geometry capture was prepared with.
    init(_ location: CaptureSourceLocator.Location, geometry: CaptureSourceGeometry) {
        switch location {
        case .display(let id):
            self = geometry.sourceRect.map { .area(id, crop: $0) } ?? .display(id)
        case .window(let id):
            self = .window(id)
        }
    }
}

/// Why no geometry could be read for the target.
enum SourceGeometryUnavailable: Error, Equatable, Sendable {
    /// The display is no longer attached, or the window no longer exists.
    case sourceGone
    /// The area no longer lies within its display.
    case areaOutsideDisplay
    /// Capture reported no frame geometry for the source.
    case noFrame
    /// The source's extent or the frame geometry is empty or not finite.
    case invalid
}

/// The frame capture produces for the source, as capture configured it: the authority for the
/// frame dimensions and scale of a GeometrySegment, never derived from the desktop.
struct CaptureFrameGeometry: Equatable, Sendable {
    var pixelSize: PixelSize
    /// The capture filter's point-to-pixel scale (`SCContentFilter.pointPixelScale`).
    var scaleFactor: Double

    init(pixelSize: PixelSize, scaleFactor: Double) {
        self.pixelSize = pixelSize
        self.scaleFactor = scaleFactor
    }

    /// The frame of a stream prepared with `geometry` on a filter of scale `pointPixelScale`.
    init(_ geometry: CaptureSourceGeometry, pointPixelScale: Double) {
        self.init(pixelSize: PixelSize(width: geometry.pixelWidth, height: geometry.pixelHeight),
            scaleFactor: pointPixelScale)
    }
}

/// One reading of the target, with the host time just after it was read.
struct SourceGeometryObservation: Equatable, Sendable {
    enum Reading: Equatable, Sendable {
        case geometry(SourceGeometry)
        case unavailable(SourceGeometryUnavailable)
    }

    var reading: Reading
    var hostTime: CMTime
}

/// Which changes a started observer can see. Without Accessibility trust a window that moves or
/// resizes is not seen until the next display reconfiguration.
struct SourceGeometryCoverage: Equatable, Sendable {
    var displayReconfiguration: Bool
    var windowMoveAndResize: Bool
}

/// A display as the platform reports it.
struct ObservedDisplay: Equatable, Sendable {
    var id: CGDirectDisplayID
    /// Global display points, origin at the top left of the main display.
    var bounds: CGRect
    /// Backing pixels per point of its current mode.
    var scale: Double
}

/// The system calls `SourceGeometryObserver` makes, so it can be tested without registering real
/// callbacks or reading the desktop.
protocol SourceGeometryPlatform: Sendable {
    func isMainThread() -> Bool
    func onMain(_ work: @escaping @Sendable () -> Void)
    /// Main thread only. Calls `handler` on the main thread each time a display reconfiguration
    /// has completed, never at its start; nil if the callback cannot be registered.
    func observeDisplayReconfiguration(_ handler: @escaping @Sendable () -> Void) -> AnyObject?
    /// Main thread only.
    func stopObservingDisplayReconfiguration(_ handle: AnyObject)
    /// Whether this process is trusted for Accessibility. Never asks.
    func isTrusted() -> Bool
    /// The process that owns the window, if the window exists.
    func windowOwner(_ id: CGWindowID) -> pid_t?
    /// Main thread only. Calls `handler` on the main thread each time a window of `pid` moves or
    /// resizes; nil if that cannot be observed.
    func observeWindowGeometry(of pid: pid_t, _ handler: @escaping @Sendable () -> Void) -> AnyObject?
    /// Main thread only.
    func stopObservingWindowGeometry(_ handle: AnyObject)
    func hostTimeNow() -> CMTime
    func displays() -> [ObservedDisplay]
    /// Global display points, origin at the top left of the main display; nil if the window no
    /// longer exists.
    func windowBounds(_ id: CGWindowID) -> CGRect?
}

extension SourceGeometryTarget {
    /// Where the target lies on the desktop, in global display points, origin at the top left of
    /// the main display. A window's bounds are its own, wherever it lies, on a display or not.
    func extent(displays: [ObservedDisplay], windowBounds: (CGWindowID) -> CGRect?) -> Result<CGRect, SourceGeometryUnavailable> {
        switch self {
        case .display(let id):
            guard let display = displays.first(where: { $0.id == id }) else { return .failure(.sourceGone) }
            return .success(display.bounds)
        case .area(let id, let crop):
            guard let display = displays.first(where: { $0.id == id }) else { return .failure(.sourceGone) }
            guard CGRect(origin: .zero, size: display.bounds.size).contains(crop) else {
                return .failure(.areaOutsideDisplay)
            }
            return .success(crop.offsetBy(dx: display.bounds.minX, dy: display.bounds.minY))
        case .window(let id):
            return windowBounds(id).map { .success($0) } ?? .failure(.sourceGone)
        }
    }

    /// The target's geometry: its extent on the desktop, with the frame dimensions and scale
    /// capture reports. The two are combined, never derived from each other: the desktop says
    /// where the source is, capture says what frame it produces. A frame capture has not been
    /// reconfigured for keeps its dimensions after the extent changes; that is the stream's part.
    func read(
        displays: [ObservedDisplay], windowBounds: (CGWindowID) -> CGRect?, frame: CaptureFrameGeometry?
    ) -> SourceGeometryObservation.Reading {
        let rect: CGRect
        switch extent(displays: displays, windowBounds: windowBounds) {
        case .failure(let reason): return .unavailable(reason)
        case .success(let extent): rect = extent
        }
        guard let frame else { return .unavailable(.noFrame) }
        let geometry = SourceGeometry(sourceRect: rect, pixelSize: frame.pixelSize, scaleFactor: frame.scaleFactor)
        guard geometry.segment(at: 0).isValid else { return .unavailable(.invalid) }
        return .geometry(geometry)
    }
}

/// Observes the geometry of one capture source and reports each reading (T041).
///
/// A completed display reconfiguration triggers a reading for every target, since a change of
/// arrangement or scale moves or rescales an area or a window without the window itself moving.
/// For a window, Accessibility window-moved and window-resized notifications on its owning
/// application trigger a reading too, registered only when this process is already trusted.
/// Starting takes one reading. Each reading combines the target's extent on the desktop with the
/// frame geometry capture reports at that moment. Unchanged readings are reported like any
/// other; the recorder drops them.
///
/// Every reading is taken on the main thread when its trigger arrives, never later, and is
/// stamped with the host time just after it was read, so readings arrive in time order, each
/// with the time its state was seen. Registration and removal happen on the main thread too.
///
/// Each start makes a registration that owns its callbacks and its handler, and installs it in the
/// same locked step that takes out the one it replaces, which is then stopped; so whatever the
/// threads, every registration but the current one is stopped and removed. Stopping cancels it
/// under its lock before anything else, so once `stop` returns, no reading of it is delivered,
/// even from a callback already queued; a reading under way on another thread finishes first.
/// A stopped registration never delivers to the handler of a later start. Removal is queued with
/// the registration alone, so a release off the main thread does not keep the observer alive.
final class SourceGeometryObserver: @unchecked Sendable {
    /// `cancelled` is read and written under `lock`; the handles on the main thread only.
    private final class Registration: @unchecked Sendable {
        let platform: SourceGeometryPlatform
        let target: SourceGeometryTarget
        let frame: @Sendable () -> CaptureFrameGeometry?
        let handler: @Sendable (SourceGeometryObservation) -> Void
        /// Recursive, so the handler may stop the observer from inside a delivery.
        let lock = NSRecursiveLock()
        var cancelled = false
        var coverage: SourceGeometryCoverage?
        var displayHandle: AnyObject?
        var windowHandle: AnyObject?

        init(platform: SourceGeometryPlatform, target: SourceGeometryTarget,
             frame: @escaping @Sendable () -> CaptureFrameGeometry?,
             handler: @escaping @Sendable (SourceGeometryObservation) -> Void) {
            self.platform = platform
            self.target = target
            self.frame = frame
            self.handler = handler
        }

        /// Main thread only.
        func setUp() {
            guard !lock.withLock({ cancelled }) else { return }
            displayHandle = platform.observeDisplayReconfiguration { [weak self] in self?.deliver() }
            if case .window(let id) = target, platform.isTrusted(), let pid = platform.windowOwner(id) {
                windowHandle = platform.observeWindowGeometry(of: pid) { [weak self] in self?.deliver() }
            }
            lock.withLock {
                coverage = SourceGeometryCoverage(
                    displayReconfiguration: displayHandle != nil, windowMoveAndResize: windowHandle != nil)
            }
            deliver()
        }

        /// Reads and delivers under the lock, so a stop on another thread waits for it.
        func deliver() {
            lock.withLock {
                guard !cancelled else { return }
                let platform = platform
                let reading = target.read(
                    displays: platform.displays(), windowBounds: { platform.windowBounds($0) }, frame: frame())
                handler(SourceGeometryObservation(reading: reading, hostTime: platform.hostTimeNow()))
            }
        }

        func cancel() {
            lock.withLock { cancelled = true }
        }

        /// Main thread only. Removes whatever was registered.
        func tearDown() {
            if let displayHandle { platform.stopObservingDisplayReconfiguration(displayHandle) }
            if let windowHandle { platform.stopObservingWindowGeometry(windowHandle) }
            displayHandle = nil
            windowHandle = nil
        }
    }

    private let platform: SourceGeometryPlatform
    private let lock = NSLock()
    private var current: Registration?

    init(platform: SourceGeometryPlatform = SystemSourceGeometryPlatform()) {
        self.platform = platform
    }

    deinit {
        stop()
    }

    /// What the running registration can see; nil until it is set up on the main thread, and
    /// when stopped.
    var coverage: SourceGeometryCoverage? {
        lock.withLock { current }.flatMap { registration in registration.lock.withLock { registration.coverage } }
    }

    /// Observes `target` in place of any running registration, calling `handler` on the main
    /// thread with each reading. `frame` is read at each reading, on the main thread, for the
    /// frame geometry capture produces for the source; nil while capture has none.
    func start(
        _ target: SourceGeometryTarget, frame: @escaping @Sendable () -> CaptureFrameGeometry?,
        handler: @escaping @Sendable (SourceGeometryObservation) -> Void
    ) {
        let registration = Registration(platform: platform, target: target, frame: frame, handler: handler)
        let replaced = exchange(registration)
        replaced.map(end)
        if platform.isMainThread() {
            registration.setUp()
        } else {
            platform.onMain { registration.setUp() }
        }
    }

    func stop() {
        exchange(nil).map(end)
    }

    private func exchange(_ registration: Registration?) -> Registration? {
        lock.withLock {
            defer { current = registration }
            return current
        }
    }

    private func end(_ registration: Registration) {
        registration.cancel()
        if platform.isMainThread() {
            registration.tearDown()
        } else {
            platform.onMain { registration.tearDown() }
        }
    }
}

/// What became of the readings a `GeometryRecorderFeed` passed on or held back.
struct GeometryFeedCounts: Equatable, Sendable {
    var added = 0
    var unchanged = 0
    var noSessionTime = 0
    /// Readings without geometry, never passed to the recorder.
    var unavailable = 0
    /// Readings the recorder refused, for example out of order.
    var refused = 0
}

/// Passes an observer's readings to a `GeometryRecorder`. A reading without geometry is counted
/// and dropped, so the geometry in force stands; the recorder only ever sees valid geometry.
final class GeometryRecorderFeed: @unchecked Sendable {
    let recorder: GeometryRecorder
    private let lock = NSLock()
    private var stored = GeometryFeedCounts()

    init(recorder: GeometryRecorder) {
        self.recorder = recorder
    }

    var counts: GeometryFeedCounts { lock.withLock { stored } }

    func take(_ observation: SourceGeometryObservation) {
        guard case .geometry(let geometry) = observation.reading else {
            return lock.withLock { stored.unavailable += 1 }
        }
        let outcome = try? recorder.observe(geometry, atHostTime: observation.hostTime)
        lock.withLock {
            switch outcome {
            case .added: stored.added += 1
            case .unchanged: stored.unchanged += 1
            case .noSessionTime: stored.noSessionTime += 1
            case nil: stored.refused += 1
            }
        }
    }
}

/// The system behind `SourceGeometryObserver`.
struct SystemSourceGeometryPlatform: SourceGeometryPlatform {
    /// Kept alive by its handle; the system callbacks refer to it unretained.
    fileprivate final class Handler: Sendable {
        let call: @Sendable () -> Void
        init(_ call: @escaping @Sendable () -> Void) { self.call = call }
    }

    private final class DisplayObservation {
        let handler: Handler
        init(handler: Handler) { self.handler = handler }
    }

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

    private static let windowNotifications = [kAXWindowMovedNotification, kAXWindowResizedNotification]

    func isMainThread() -> Bool { Thread.isMainThread }

    func onMain(_ work: @escaping @Sendable () -> Void) { DispatchQueue.main.async(execute: work) }

    func observeDisplayReconfiguration(_ handler: @escaping @Sendable () -> Void) -> AnyObject? {
        let box = Handler(handler)
        let refcon = Unmanaged.passUnretained(box).toOpaque()
        guard CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, refcon) == .success else { return nil }
        return DisplayObservation(handler: box)
    }

    func stopObservingDisplayReconfiguration(_ handle: AnyObject) {
        guard let observation = handle as? DisplayObservation else { return }
        CGDisplayRemoveReconfigurationCallback(
            displayReconfigurationCallback, Unmanaged.passUnretained(observation.handler).toOpaque())
    }

    func isTrusted() -> Bool { AXIsProcessTrusted() }

    func windowOwner(_ id: CGWindowID) -> pid_t? {
        windowInfo(id)?[kCGWindowOwnerPID] as? pid_t
    }

    func observeWindowGeometry(of pid: pid_t, _ handler: @escaping @Sendable () -> Void) -> AnyObject? {
        var created: AXObserver?
        guard AXObserverCreate(pid, windowGeometryCallback, &created) == .success, let observer = created else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, SystemAccessibilityQueries.messagingTimeout)
        let box = Handler(handler)
        let refcon = Unmanaged.passUnretained(box).toOpaque()
        var added: [String] = []
        for notification in Self.windowNotifications
        where AXObserverAddNotification(observer, application, notification as CFString, refcon) == .success {
            added.append(notification)
        }
        // A move without a resize, or the reverse, would leave changes unseen.
        guard added.count == Self.windowNotifications.count else {
            for notification in added { AXObserverRemoveNotification(observer, application, notification as CFString) }
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        return WindowObservation(observer: observer, application: application, handler: box)
    }

    func stopObservingWindowGeometry(_ handle: AnyObject) {
        guard let observation = handle as? WindowObservation else { return }
        for notification in Self.windowNotifications {
            AXObserverRemoveNotification(observation.observer, observation.application, notification as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observation.observer), .commonModes)
    }

    func hostTimeNow() -> CMTime { CaptureClock.hostTimeNow() }

    func displays() -> [ObservedDisplay] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).compactMap { id in
            guard let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else { return nil }
            return ObservedDisplay(id: id, bounds: CGDisplayBounds(id), scale: Double(mode.pixelWidth) / Double(mode.width))
        }
    }

    func windowBounds(_ id: CGWindowID) -> CGRect? {
        guard let bounds = windowInfo(id)?[kCGWindowBounds] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    /// The window list entry for `id`; window names are never read.
    private func windowInfo(_ id: CGWindowID) -> [CFString: Any]? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[CFString: Any]] else { return nil }
        return list.first { ($0[kCGWindowNumber] as? UInt32) == id }
    }

    fileprivate static func call(_ refcon: UnsafeMutableRawPointer?) {
        guard let refcon else { return }
        let handler = Unmanaged<Handler>.fromOpaque(refcon).takeUnretainedValue()
        if Thread.isMainThread {
            handler.call()
        } else {
            // Retained across the hop; the registration's cancel check drops it if stale.
            DispatchQueue.main.async { [handler] in handler.call() }
        }
    }
}

private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, refcon in
    guard !flags.contains(.beginConfigurationFlag) else { return }
    SystemSourceGeometryPlatform.call(refcon)
}

private let windowGeometryCallback: AXObserverCallback = { _, _, _, refcon in
    SystemSourceGeometryPlatform.call(refcon)
}
