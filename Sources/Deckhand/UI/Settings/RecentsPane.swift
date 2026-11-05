import SwiftUI
import AppKit

/// Watched folders for Recents. Owned by the prompts, shelf and recents workstream.
struct RecentsPane: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        SettingsPane(.recents) {
            Section {
                ForEach(settings.watchedFolders, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                        Text((path as NSString).abbreviatingWithTildeInPath)
                        Spacer()
                        Button(role: .destructive) {
                            settings.watchedFolders.removeAll { $0 == path }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…") { pickFolder() }
            } header: {
                Text("Watched folders")
            } footer: {
                Text("Recents shows images and videos from these folders for the last 14 days, for example generations you downloaded from Higgsfield.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !settings.watchedFolders.contains(url.path) {
            settings.watchedFolders.append(url.path)
        }
    }
}
