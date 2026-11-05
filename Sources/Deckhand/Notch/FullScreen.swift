import AppKit

/// Reads the on-screen window list to tell whether the notch display shows a full-screen app,
/// and whether a menu is open next to the notch. No permission is needed: only owners, layers and bounds are read.
///
/// The window list is read only when something changes (Space, front app, displays, wake),
/// never on pointer movement, and the answer is cached.
@MainActor
final class FullScreen {
    static let shared = FullScreen()

    struct WindowInfo: Equatable {
        var pid: pid_t
        var layer: Int
        /// Window-server coordinates: origin top left of the main display, y down.
        var bounds: CGRect
    }

    private(set) var isFullScreen = false
    private var observers: [NSObjectProtocol] = []
    private var settleWork: DispatchWorkItem?
    /// Called on the main thread with the screen to check; set by the controller.
    var screen: () -> NSScreen? = { nil }
    var onChange: (Bool) -> Void = { _ in }

    static let menuBarLayer = Int(CGWindowLevelForKey(.mainMenuWindow))
    static let popUpMenuLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))

    func start() {
        guard observers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didWakeNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSoon() }
            })
        }
        refresh()
    }

    /// Now and again once the full-screen animation has settled.
    func refreshSoon() {
        refresh()
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func refresh() {
        guard let screen = screen() else { return }
        let value = Self.isFullScreen(windows: Self.windows(), screen: Self.cgFrame(of: screen),
                                      notchHeight: screen.safeAreaInsets.top, ownPID: getpid())
        guard value != isFullScreen else { return }
        isFullScreen = value
        onChange(value)
    }

    /// Whether a menu (from the menu bar or a status item) is open near the notch. Read once per hover-open.
    func menuOpenNear(_ cutout: CGRect, on screen: NSScreen) -> Bool {
        Self.menuOpen(windows: Self.windows(), screen: Self.cgFrame(of: screen), cutout: Self.cgRect(cutout))
    }

    // MARK: - Pure

    /// Full screen: some app's normal window covers the whole display, or all of it below the camera housing
    /// (where notched Macs put full-screen content), and the menu bar is not showing on that display.
    /// The menu-bar check keeps a zoomed or "Fill" window with a hidden Dock from counting.
    static func isFullScreen(windows: [WindowInfo], screen: CGRect, notchHeight: CGFloat, ownPID: pid_t) -> Bool {
        let belowNotch = CGRect(x: screen.minX, y: screen.minY + notchHeight,
                                width: screen.width, height: screen.height - notchHeight)
        let covering = windows.contains { w in
            w.pid != ownPID && w.layer == 0 && (approx(w.bounds, screen) || (notchHeight > 0 && approx(w.bounds, belowNotch)))
        }
        guard covering else { return false }
        let menuBarShown = windows.contains { w in
            w.layer == menuBarLayer && w.bounds.minY >= screen.minY - 1
                && w.bounds.minX < screen.maxX && w.bounds.maxX > screen.minX
                && w.bounds.minY < screen.minY + max(notchHeight, 24)
        }
        return !menuBarShown
    }

    /// A pop-up menu hangs from the menu bar within reach of the notch. Menus far away (and floating panels of
    /// other apps that use the same level) don't count.
    static func menuOpen(windows: [WindowInfo], screen: CGRect, cutout: CGRect, reach: CGFloat = 400) -> Bool {
        windows.contains { w in
            w.layer == popUpMenuLayer
                && w.bounds.minY <= cutout.maxY + 4 && w.bounds.minY >= screen.minY - 1
                && w.bounds.maxX > cutout.minX - reach && w.bounds.minX < cutout.maxX + reach
        }
    }

    private static func approx(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    // MARK: - Window server

    private static func windows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: b) else { return nil }
            return WindowInfo(pid: pid, layer: layer, bounds: bounds)
        }
    }

    /// Cocoa (y up, origin bottom left of the main display) to window-server coordinates.
    static func cgRect(_ r: CGRect) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? r.maxY
        return CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }

    private static func cgFrame(of screen: NSScreen) -> CGRect { cgRect(screen.frame) }
}
