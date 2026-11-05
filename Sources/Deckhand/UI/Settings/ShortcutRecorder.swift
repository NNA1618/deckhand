import SwiftUI
import AppKit

struct ShortcutRecorder: View {
    let action: HotkeyAction
    @ObservedObject private var hotkeys = HotkeyManager.shared
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(minWidth: 110)
                .padding(.vertical, 3)
                .foregroundStyle(recording ? Color.accentColor : (hotkeys.shortcuts[action] == nil ? .secondary : .primary))
        }
        .buttonStyle(.bordered)
        .onDisappear { stop() }
    }

    private var label: String {
        if recording { return String(localized: "Press keys…") }
        return hotkeys.shortcuts[action]?.display ?? String(localized: "Not set")
    }

    private func start() {
        recording = true
        hotkeys.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: // Esc
                stop()
            case 51, 117: // Delete, Forward Delete
                hotkeys.set(nil, for: action)
                stop()
            default:
                if let sc = Shortcut(event: event) {
                    hotkeys.set(sc, for: action)
                    stop()
                } else {
                    NSSound.beep()
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            hotkeys.registerAll()
        }
    }
}
