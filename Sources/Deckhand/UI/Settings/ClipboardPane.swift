import SwiftUI
import AppKit

/// Clipboard history. Owned by the clipboard workstream.
struct ClipboardPane: View {
    @ObservedObject private var settings = Settings.shared
    @State private var newApp = ""

    var body: some View {
        SettingsPane(.clipboard) {
            Section {
                Picker("Keep history", selection: $settings.historyLimit) {
                    Text("100 items").tag(100)
                    Text("500 items").tag(500)
                    Text("1000 items").tag(1000)
                    Text("Unlimited").tag(0)
                }
                Toggle("Save copied passwords to history", isOn: $settings.savePasswordsToHistory)
            } footer: {
                Text("Passwords from password managers always paste normally. This only controls whether they stay in the history.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ignore apps") {
                ForEach(settings.excludedApps, id: \.self) { bundleId in
                    HStack {
                        Text(appName(bundleId))
                        Text(bundleId).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) {
                            settings.excludedApps.removeAll { $0 == bundleId }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add App…") { pickApp() }
            }
        }
    }

    private func appName(_ bundleId: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return bundleId }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier,
              !settings.excludedApps.contains(id) else { return }
        settings.excludedApps.append(id)
    }
}
