import SwiftUI

/// Global shortcuts, grouped, plus the keys that work inside the panel and the editor.
/// Owned by the capture and hotkeys workstream.
struct ShortcutsPane: View {
    @ObservedObject private var hotkeys = HotkeyManager.shared
    @State private var confirmReset = false

    static let groups: [(title: LocalizedStringKey, actions: [HotkeyAction])] = [
        ("Deckhand", [.toggle]),
        ("Capture", [.screenshot, .captureAndEdit, .captureWindow, .captureScreen, .captureDelayed, .captureText, .colorPicker]),
        ("Tools", [.keepAwake, .translateSelection]),
        ("Open a Tab", [.clipboard, .translator, .claude, .prompts, .media, .shelf, .recents]),
    ]

    var body: some View {
        SettingsPane(.shortcuts) {
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, group in
                Section {
                    ForEach(group.actions) { ShortcutRow(action: $0) }
                } header: {
                    Text(group.title)
                } footer: {
                    if index == Self.groups.count - 1 { footer }
                }
            }
            Section {
                ForEach(PanelKeys.all, id: \.title) { row in
                    LabeledContent {
                        Text(row.keys).foregroundStyle(.secondary)
                    } label: {
                        Text(row.title)
                    }
                }
            } header: {
                Text("In the Panel")
            }
        }
        .confirmationDialog(Text("Restore the default shortcuts?"), isPresented: $confirmReset) {
            Button("Restore Defaults") { hotkeys.resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every global shortcut goes back to its default. Shortcuts you set yourself are replaced.")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Click a shortcut and press the new keys. Use ⌘ or ⌃, with ⌥ and ⇧ if you like. Esc cancels, ⌫ removes the shortcut.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Restore Defaults…") { confirmReset = true }
            }
        }
    }
}

/// Keys that work only inside Deckhand's own windows, shown read-only.
enum PanelKeys {
    struct Row {
        var title: String
        var keys: String
    }

    static var all: [Row] {
        let tools = EditorTool.allCases.map { KeyNames.name(for: UInt32($0.keyCode)) }.joined(separator: " ")
        return [
            Row(title: String(localized: "Close the panel"), keys: "Esc"),
            Row(title: String(localized: "Clipboard: pick"), keys: "↑ ↓"),
            Row(title: String(localized: "Clipboard: paste"), keys: "↩, ⌘1–⌘9"),
            Row(title: String(localized: "Editor tools"), keys: tools),
            Row(title: String(localized: "Editor: zoom"), keys: "⌘+  ⌘−  ⌘0"),
        ]
    }
}
