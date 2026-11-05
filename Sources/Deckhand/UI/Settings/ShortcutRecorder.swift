import SwiftUI
import AppKit
import Carbon.HIToolbox

/// The one shortcut recording in progress, shared by every recorder in every pane.
/// Starting a recorder stops any other; leaving the window or the app stops it too,
/// so a forgotten recorder can never grab a later key press or leave the shortcuts off.
@MainActor
final class ShortcutRecording: ObservableObject {
    static let shared = ShortcutRecording()

    /// The recorder that is listening.
    @Published private(set) var activeRecorder: UUID?
    @Published private(set) var action: HotkeyAction?
    /// Modifiers held right now, shown while recording («⌃⌥…»).
    @Published private(set) var heldModifiers = ""
    /// Why the last key press was refused.
    @Published private(set) var refusal: String?

    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    func start(recorder: UUID, action: HotkeyAction) {
        stop()
        activeRecorder = recorder
        self.action = action
        refusal = nil
        heldModifiers = ""
        HotkeyManager.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let isFlags = event.type == .flagsChanged
            let keyCode = event.keyCode
            let modifiers = Shortcut(event: event).modifiers
            let consumed = MainActor.assumeIsolated {
                self?.handle(isFlags: isFlags, keyCode: keyCode, modifiers: modifiers) ?? false
            }
            return consumed ? nil : event
        }
        let center = NotificationCenter.default
        let stopNow: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        if let window = NSApp.keyWindow {
            observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: stopNow))
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main, using: stopNow))
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: stopNow))
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        guard activeRecorder != nil else { return }
        activeRecorder = nil
        action = nil
        heldModifiers = ""
        HotkeyManager.shared.registerAll()
    }

    /// Returns whether the key press was used up by the recorder.
    private func handle(isFlags: Bool, keyCode: UInt16, modifiers: UInt32) -> Bool {
        guard let action else { return false }
        let sc = Shortcut(keyCode: UInt32(keyCode), modifiers: modifiers)
        if isFlags {
            heldModifiers = sc.modifierSymbols
            return false
        }
        if ShortcutRules.isModifierOnly(keyCode: keyCode) { return true }
        if sc.modifiers == 0 {
            switch Int(keyCode) {
            case kVK_Escape:
                stop()
                return true
            case kVK_Delete, kVK_ForwardDelete:
                HotkeyManager.shared.set(nil, for: action)
                stop()
                return true
            default: break
            }
        }
        switch ShortcutRules.verdict(for: sc) {
        case .ok:
            HotkeyManager.shared.set(sc, for: action)
            stop()
        case .needsModifier:
            refusal = String(localized: "Add ⌘ or ⌃ to the shortcut.")
            NSSound.beep()
        case .reserved:
            refusal = String(localized: "macOS reserves this shortcut.")
            NSSound.beep()
        }
        return true
    }
}

/// Shortcut recorder: click, press keys, done. Return or Space start recording when it has focus.
struct ShortcutRecorder: View {
    let action: HotkeyAction
    @ObservedObject private var hotkeys = HotkeyManager.shared
    @ObservedObject private var recording = ShortcutRecording.shared
    @State private var id = UUID()
    @State private var hovering = false

    private var isRecording: Bool { recording.activeRecorder == id }
    private var shortcut: Shortcut? { hotkeys.shortcuts[action] }

    var body: some View {
        Button {
            isRecording ? recording.stop() : recording.start(recorder: id, action: action)
        } label: {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(isRecording ? Color.accentColor : (shortcut == nil ? .secondary : .primary))
                .lineLimit(1)
                .frame(minWidth: 140)
                .padding(.vertical, 4)
                .padding(.horizontal, 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quinary))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isRecording ? 2 : 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if hovering && shortcut != nil && !isRecording {
                Button {
                    hotkeys.set(nil, for: action)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                .help(Text("Remove Shortcut"))
                .accessibilityLabel(Text("Remove Shortcut"))
            }
        }
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(action.title))
        .accessibilityValue(Text(label))
        .onDisappear { if isRecording { recording.stop() } }
    }

    private var label: String {
        if isRecording {
            return recording.heldModifiers.isEmpty ? String(localized: "Press keys…") : recording.heldModifiers + "…"
        }
        return shortcut?.display ?? String(localized: "Not set")
    }
}

/// A Settings row: the action's name with any warning under it, and its recorder.
/// Feature panes use this too, bound to the same value as the Shortcuts pane.
struct ShortcutRow: View {
    let action: HotkeyAction
    var title: String?
    @ObservedObject private var hotkeys = HotkeyManager.shared
    @ObservedObject private var recording = ShortcutRecording.shared
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? action.title)
                if let caption {
                    Text(caption.text)
                        .font(.caption)
                        .foregroundStyle(caption.warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            ShortcutRecorder(action: action)
        }
    }

    private var caption: (text: String, warning: Bool)? {
        if recording.action == action, let refusal = recording.refusal { return (refusal, true) }
        if let move = hotkeys.lastMove, move.to == action {
            return (String(localized: "Removed from “\(move.from.title)”."), false)
        }
        if hotkeys.shortcuts[action] != nil, let conflict = hotkeys.conflicts[action] { return (conflict.message, true) }
        if let tab = action.tab, settings.hiddenTabs.contains(tab.rawValue) {
            return (String(localized: "Hidden tab"), false)
        }
        return nil
    }
}
