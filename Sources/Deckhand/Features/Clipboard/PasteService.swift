import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Pastes into the app the user was working in by sending ⌘V.
/// Needs the Accessibility permission; check `isTrusted` first and explain when it's missing.
@MainActor
enum PasteService {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// The last app other than Deckhand that was in front: where a paste should land.
    private(set) static var targetApp: NSRunningApplication?
    private static var observer: NSObjectProtocol?

    /// Starts following the frontmost app. Safe to call more than once.
    static func startTracking() {
        guard observer == nil else { return }
        if let front = NSWorkspace.shared.frontmostApplication, !isDeckhand(front) { targetApp = front }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, !isDeckhand(app) { targetApp = app }
            }
        }
    }

    private static func isDeckhand(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    /// Shows the system Accessibility prompt and opens the matching Settings pane.
    /// Only call it from a button the user clicked.
    static func requestAccess() {
        let key = "AXTrustedCheckOptionPrompt"   // kAXTrustedCheckOptionPrompt
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Sends ⌘V to the app the user was working in. Returns false when the permission is missing
    /// (the system prompt is shown then, so call it only from a user action).
    @discardableResult
    static func pasteIntoFrontApp() -> Bool {
        guard isTrusted else {
            requestAccess()
            return false
        }
        // If Deckhand itself is active (Settings or the editor was used), ⌘V would land in Deckhand
        var delay = 0.18   // lets the panel close and keyboard focus return first
        if let front = NSWorkspace.shared.frontmostApplication, isDeckhand(front), let target = targetApp, !target.isTerminated {
            target.activate()
            delay = 0.35
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { postCommandV() }
        return true
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(vKeyCode())
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// The key that types "v" with ⌘ held in the current layout: "." on Dvorak, the QWERTY V on
    /// "Dvorak – QWERTY ⌘" and on Russian (macOS uses the Latin layout for shortcuts there).
    static func vKeyCode() -> UInt16 {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let code = keyCode(for: "v", in: source) else { return UInt16(kVK_ANSI_V) }
        return code
    }

    static func keyCode(for character: Character, in source: TISInputSource) -> UInt16? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> UInt16? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            let commandState = UInt32((cmdKey >> 8) & 0xFF)
            for code in UInt16(0)..<128 {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), commandState,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &dead, chars.count, &length, &chars)
                if status == noErr, length == 1, String(utf16CodeUnits: chars, count: 1).lowercased() == String(character) {
                    return code
                }
            }
            return nil
        }
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
