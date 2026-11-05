import SwiftUI

/// Global shortcuts. Owned by the capture and hotkeys workstream.
struct ShortcutsPane: View {
    @ObservedObject private var hotkeys = HotkeyManager.shared

    var body: some View {
        SettingsPane(.shortcuts) {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    LabeledContent {
                        ShortcutRecorder(action: action)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.title)
                            if hotkeys.conflicts.contains(action) {
                                Text("Taken by another app. Pick a different shortcut.")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            } footer: {
                HStack {
                    Text("Click a shortcut and press new keys. Use ⌘, ⌥ or ⌃. Esc cancels, ⌫ clears.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { hotkeys.resetToDefaults() }
                }
            }
        }
    }
}

/// Shortcut recorder: click, press keys, done.
