import AppKit
import ApplicationServices

/// Pastes into the app the user was working in by sending ⌘V.
/// Needs the Accessibility permission; without it the item stays copied and macOS shows the prompt.
@MainActor
enum PasteService {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Returns false when the permission is missing (the prompt is shown then).
    @discardableResult
    static func pasteIntoFrontApp() -> Bool {
        guard isTrusted else {
            let key = "AXTrustedCheckOptionPrompt"   // kAXTrustedCheckOptionPrompt
            AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            return false
        }
        // Let the panel close and keyboard focus return to the previous app first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let vKey: CGKeyCode = 9
            let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cgAnnotatedSessionEventTap)
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
        return true
    }
}
