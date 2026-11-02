import AppKit
import ApplicationServices

/// Tells whether the app in front is in full screen, so hovering the notch
/// does not pop the panel over a video or a presentation.
@MainActor
enum FullScreen {
    static func isFrontmostFullScreen(on screen: NSScreen) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
        let pid = app.processIdentifier

        // With Accessibility access the focused window says so directly
        if AXIsProcessTrusted() {
            let axApp = AXUIElementCreateApplication(pid)
            // A busy app would otherwise stall the main thread for seconds on every hover
            AXUIElementSetMessagingTimeout(axApp, 0.1)
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &window) == .success,
               let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(window as! AXUIElement, "AXFullScreen" as CFString, &value) == .success {
                    return (value as? Bool) ?? false
                }
            }
        }

        // Otherwise: a window of that app covering the whole screen
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let size = screen.frame.size
        return list.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return b["Width"] == size.width && b["Height"] == size.height
        }
    }
}
