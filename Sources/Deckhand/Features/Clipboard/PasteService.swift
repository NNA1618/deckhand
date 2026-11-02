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

extension NSPasteboard {
    /// Clipboard text worth prefilling a text field with: words, not a password,
    /// an address, a number or a link.
    var prefillText: String? {
        let types = Set((types ?? []).map(\.rawValue))
        guard !ClipboardWatcher.isPassword(types: types, sourceApp: nil),
              let s = string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              s.looksLikeProse else { return nil }
        return s
    }
}

extension String {
    /// Mostly letters, and not an e-mail or a link.
    var looksLikeProse: Bool {
        guard !contains("://"), !contains("@") else { return false }
        let visible = unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        let letters = visible.filter { CharacterSet.letters.contains($0) }
        return letters.count >= 2 && Double(letters.count) >= Double(visible.count) * 0.5
    }
}
