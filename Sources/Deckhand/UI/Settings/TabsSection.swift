import SwiftUI

/// Which tabs the panel shows. Owned by the panel workstream.
struct TabsSection: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
            Section {
                ForEach(NotchTab.allCases.filter { $0 != .home }) { tab in
                    Toggle(isOn: Binding(
                        get: { !settings.hiddenTabs.contains(tab.rawValue) },
                        set: { on in
                            settings.hiddenTabs.removeAll { $0 == tab.rawValue }
                            if !on { settings.hiddenTabs.append(tab.rawValue) }
                        }
                    )) {
                        Label(tab.title, systemImage: tab.symbol)
                    }
                }
            } header: {
                Text("Tabs")
            } footer: {
                Text("Hidden tabs leave the panel and the menu bar. Their shortcuts still open them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
    }
}
