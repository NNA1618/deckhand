import AppKit

/// Deckhand is an accessory app: no Dock icon and no ⌘Tab entry. While a normal window
/// such as Settings or the editor is open, it becomes a regular app so the window can't get lost
/// behind other apps, and goes back to being an accessory once the last one closes.
@MainActor
enum AppActivation {
    private static var windows = Set<ObjectIdentifier>()
    private static var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

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
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate()
    }

    private static func windowClosed(_ id: ObjectIdentifier) {
        windows.remove(id)
        if let token = observers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(token) }
        guard windows.isEmpty else { return }
        // Let the window finish closing before the Dock icon goes away
        DispatchQueue.main.async {
            if windows.isEmpty { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
