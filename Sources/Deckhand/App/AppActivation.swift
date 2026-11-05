import AppKit

/// Deckhand is an accessory app: no Dock icon and no ⌘Tab entry. While a normal window
/// such as Settings or the editor is open, it becomes a regular app so the window can't get lost
/// behind other apps, and goes back to being an accessory once the last one closes.
@MainActor
enum AppActivation {
    private static var windows = Set<ObjectIdentifier>()
    private static var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// Call before showing the window. Brings Deckhand and the window to the front.
    static func windowOpened(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        if !windows.contains(id) {
            windows.insert(id)
            observers[id] = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { windowClosed(id) }
            }
        }
        // A snapshot run must stay out of the Dock and must not take focus from the user
        guard !AppPaths.isSnapshot else { return }
        let becameRegular = NSApp.activationPolicy() != .regular
        if becameRegular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Activation is cooperative: if another app keeps the focus, at least show the window on top.
        // Right after the policy change the Dock needs a moment, so try once more on the next turn.
        window.orderFrontRegardless()
        if becameRegular {
            DispatchQueue.main.async {
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private static func windowClosed(_ id: ObjectIdentifier) {
        windows.remove(id)
        if let token = observers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(token) }
        guard windows.isEmpty else { return }
        // Let the window finish closing before the Dock icon goes away
        DispatchQueue.main.async {
            if windows.isEmpty, !AppPaths.isSnapshot { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
