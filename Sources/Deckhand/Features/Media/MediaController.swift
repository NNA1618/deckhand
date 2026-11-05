import AppKit
import ApplicationServices

/// System media keys. macOS sends them to the app it considers "now playing", which covers
/// browsers and the Yandex Music app. macOS drops synthetic key events from apps without
/// Accessibility, so they are only sent when Deckhand has it.
enum MediaKey: Int32 {
    case playPause = 16  // NX_KEYTYPE_PLAY
    case next = 17       // NX_KEYTYPE_NEXT
    case previous = 18   // NX_KEYTYPE_PREVIOUS
}

enum MediaController {
    enum Outcome: Equatable, Sendable {
        case sent
        /// Media keys need Accessibility.
        case needsAccessibility
        /// The player can only be controlled with Automation, which was turned off in System Settings.
        case needsAutomation(MediaApp)
    }

    /// Music and Spotify get Apple Events (asking for Automation on this click if macOS hasn't asked yet);
    /// everything else gets the media key.
    static func send(_ command: MediaScripts.Command, to app: MediaApp?) async -> Outcome {
        if let app, app.kind == .player {
            let id = app.bundleID
            var permission = await Task.detached { AutomationPermission.status(bundleId: id) }.value
            if permission == .notAsked {
                // A click on a control is the user action that may show the macOS prompt
                permission = await Task.detached { AutomationPermission.status(bundleId: id, ask: true) }.value
            }
            if permission == .allowed, case .success = await MediaScripts.send(command, to: app) { return .sent }
            if AXIsProcessTrusted() { press(command); return .sent }
            return .needsAutomation(app)
        }
        guard AXIsProcessTrusted() else { return .needsAccessibility }
        press(command)
        return .sent
    }

    /// Shows the macOS Accessibility prompt. Call only from a button the user clicked.
    static func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Opens Privacy & Security at the given pane ("Privacy_Automation", "Privacy_Accessibility").
    static func openPrivacySettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func press(_ command: MediaScripts.Command) {
        let key: MediaKey
        switch command {
        case .playPause: key = .playPause
        case .next: key = .next
        case .previous: key = .previous
        }
        post(key.rawValue, isDown: true)
        post(key.rawValue, isDown: false)
    }

    private static func post(_ key: Int32, isDown: Bool) {
        let flags = NSEvent.ModifierFlags(rawValue: isDown ? 0xa00 : 0xb00)
        let data1 = (Int(key) << 16) | ((isDown ? 0xA : 0xB) << 8)
        NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                           windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?
            .cgEvent?.post(tap: .cghidEventTap)
    }
}
