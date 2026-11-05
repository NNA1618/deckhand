import AppKit

/// Delivers pointer movement and clicks anywhere on screen, driven by events rather than a timer.
///
/// Global monitors see events going to other apps; local monitors see the ones going to Deckhand's own windows.
/// While Deckhand itself is the active app (Settings or the editor in front), mouse-moved events only reach
/// windows that ask for them, so a light poll stands in; the controller can also ask for it while the panel
/// is open, where a missed exit would leave the panel stuck. Everything stops while the screen is locked or asleep.
@MainActor
final class PointerTracker {
    struct Handlers {
        var moved: (CGPoint) -> Void = { _ in }
        var mouseDown: (CGPoint, NSEvent.EventType) -> Void = { _, _ in }
        var mouseUp: (CGPoint) -> Void = { _ in }
        /// Tracking resumed after lock or sleep: refresh cached geometry, require the pointer to leave first.
        var resumed: () -> Void = {}
    }

    var handlers = Handlers()
    /// Asked whenever the poll might need to start or stop.
    var wantsPoll: () -> Bool = { false }

    private var monitors: [Any] = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var poll: Timer?
    private var lastPolled: CGPoint?
    private var locked = false
    private var asleep = false

    private(set) var isRunning = false

    func start() {
        guard observers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        observe(dnc, "com.apple.screenIsLocked") { $0.locked = true }
        observe(dnc, "com.apple.screenIsUnlocked") { $0.locked = false }
        observe(ws, NSWorkspace.willSleepNotification.rawValue) { $0.asleep = true }
        observe(ws, NSWorkspace.screensDidSleepNotification.rawValue) { $0.asleep = true }
        observe(ws, NSWorkspace.didWakeNotification.rawValue) { $0.asleep = false }
        observe(ws, NSWorkspace.screensDidWakeNotification.rawValue) { $0.asleep = false }
        observe(.default, NSApplication.didBecomeActiveNotification.rawValue) { $0.updatePoll() }
        observe(.default, NSApplication.didResignActiveNotification.rawValue) { $0.updatePoll() }
        apply()
    }

    /// Call when `wantsPoll` may have changed (the panel opened or closed).
    func updatePoll() {
        let want = isRunning && (NSApp.isActive || wantsPoll())
        if want, poll == nil {
            let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollTick() }
            }
            RunLoop.main.add(t, forMode: .common)
            poll = t
        } else if !want, let t = poll {
            t.invalidate()
            poll = nil
            lastPolled = nil
        }
    }

    private func observe(_ center: NotificationCenter, _ name: String, _ change: @escaping @MainActor (PointerTracker) -> Void) {
        let token = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(self)
                self.apply()
            }
        }
        observers.append((center, token))
    }

    private func apply() {
        let shouldRun = !locked && !asleep
        guard shouldRun != isRunning else { updatePoll(); return }
        isRunning = shouldRun
        if shouldRun {
            installMonitors()
            handlers.resumed()
        } else {
            monitors.forEach(NSEvent.removeMonitor)
            monitors.removeAll()
        }
        updatePoll()
    }

    private func installMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let downs: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let ups: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .otherMouseUp]

        if let m = NSEvent.addGlobalMonitorForEvents(matching: moves.union(downs).union(ups), handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.dispatch(type) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moves.union(downs).union(ups), handler: { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.dispatch(type) }
            return event
        }) { monitors.append(m) }
    }

    private func dispatch(_ type: NSEvent.EventType) {
        let p = NSEvent.mouseLocation
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: handlers.mouseDown(p, type)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: handlers.mouseUp(p)
        default: handlers.moved(p)
        }
    }

    private func pollTick() {
        let p = NSEvent.mouseLocation
        guard p != lastPolled else { return }
        lastPolled = p
        handlers.moved(p)
    }
}
