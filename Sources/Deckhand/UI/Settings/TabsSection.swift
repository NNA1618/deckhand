import SwiftUI

/// Which tabs the panel shows, in which order, and which one it opens on. Owned by the panel workstream.
struct TabsSection: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var panelSettings = PanelSettings.shared

    var body: some View {
        Section {
            Picker("Tab when opened", selection: $panelSettings.openTab) {
                Text("Last used").tag(PanelSettings.lastUsed)
                Divider()
                ForEach(panelSettings.visibleTabs) { tab in
                    Text(tab.title).tag(tab.rawValue)
                }
            }
            row(.home, locked: true)
            ForEach(movableTabs) { tab in
                row(tab, locked: false)
                    .contextMenu {
                        Button("Move Up") { move(tab, by: -1) }.disabled(tab == movableTabs.first)
                        Button("Move Down") { move(tab, by: 1) }.disabled(tab == movableTabs.last)
                    }
            }
            .onMove { panelSettings.move(from: $0, to: $1) }
        } header: {
            Text("Tabs")
        } footer: {
            Text("Drag to reorder. Hidden tabs leave the panel and the menu bar; their shortcuts still open them.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var movableTabs: [NotchTab] { panelSettings.allTabs.filter { $0 != .home } }

    private func row(_ tab: NotchTab, locked: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .opacity(locked ? 0 : 1)
                .accessibilityHidden(true)
            TabIcon(tab: tab)
                .foregroundStyle(.secondary)
            Toggle(isOn: binding(for: tab)) { Text(tab.title) }
                .disabled(locked)
        }
        .help(locked ? Text("Home is always first and can't be hidden.") : Text(tab.title))
    }

    private func binding(for tab: NotchTab) -> Binding<Bool> {
        Binding(
            get: { tab == .home || !settings.hiddenTabs.contains(tab.rawValue) },
            set: { on in
                settings.hiddenTabs.removeAll { $0 == tab.rawValue }
                if !on {
                    settings.hiddenTabs.append(tab.rawValue)
                    if panelSettings.openTab == tab.rawValue { panelSettings.openTab = PanelSettings.lastUsed }
                }
            }
        )
    }

    private func move(_ tab: NotchTab, by step: Int) {
        guard let i = movableTabs.firstIndex(of: tab) else { return }
        let target = i + step
        guard movableTabs.indices.contains(target) else { return }
        panelSettings.move(from: IndexSet(integer: i), to: step > 0 ? target + 1 : target)
    }
}
