import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The prompt library. Owned by the prompts, shelf and recents workstream.
struct PromptsPane: View {
    @ObservedObject private var settings = PromptSettings.shared
    @State private var message: String?
    @State private var confirmDeleteAll = false

    var body: some View {
        SettingsPane(.prompts) {
            Section {
                Picker("Clicking a prompt", selection: $settings.clickAction) {
                    Text("Copies it").tag(PromptClickAction.copy)
                    Text("Pastes it into the app").tag(PromptClickAction.paste)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Fill in {{variables}} first", isOn: $settings.fillVariables)
                    Text("Asks for {{product}} and similar before copying.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Sort", selection: $settings.sort) {
                    Text("Favorites and most used").tag(PromptSort.favoritesAndUsage)
                    Text("By name").tag(PromptSort.name)
                    Text("Recently edited").tag(PromptSort.recentlyEdited)
                }
            } footer: {
                Text("Hold ⌥ when pressing Return to do the other action.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Prompts file") {
                    HStack {
                        Button("Import…") { importPrompts() }
                        Button("Export…") { exportPrompts() }
                    }
                }
                LabeledContent("Starter prompts") {
                    Button("Restore Starter Prompts") {
                        let added = PromptStore.shared.addStarters()
                        PromptsViewModel.shared.refresh(resort: true)
                        message = added == 0 ? String(localized: "All starter prompts are already in the library.")
                                             : String(localized: "Starter prompts added: \(added)")
                    }
                }
                LabeledContent("All prompts") {
                    Button("Delete All Prompts…", role: .destructive) { confirmDeleteAll = true }
                        .disabled(PromptStore.shared.count == 0)
                }
            } header: {
                Text("Library")
            } footer: {
                Text(message ?? String(localized: "Export saves a JSON file you can import on another Mac."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Shortcut") { ShortcutRecorder(action: .prompts) }
            }
        }
        .confirmationDialog("Delete all prompts?", isPresented: $confirmDeleteAll) {
            Button("Delete All Prompts", role: .destructive) {
                PromptStore.shared.deleteAll()
                PromptsViewModel.shared.refresh(resort: true)
                message = String(localized: "All prompts deleted.")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. Export the library first if you may need it again.")
        }
    }

    private func exportPrompts() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = String(localized: "Deckhand Prompts") + ".json"
        present(panel) { url in
            do {
                try PromptStore.shared.exportJSON().write(to: url, options: .atomic)
                message = String(localized: "Prompts exported: \(PromptStore.shared.count)")
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func importPrompts() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        present(panel) { url in
            do {
                let result = try PromptStore.shared.importJSON(Data(contentsOf: url))
                PromptsViewModel.shared.refresh(resort: true)
                message = result.skipped == 0
                    ? String(localized: "Prompts imported: \(result.added)")
                    : String(localized: "Prompts imported: \(result.added) · already in the library: \(result.skipped)")
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Opens the panel as a sheet on the Settings window.
    private func present(_ panel: NSSavePanel, then use: @escaping (URL) -> Void) {
        let done: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            use(url)
        }
        if let window = SettingsWindow.window {
            panel.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(panel.runModal())
        }
    }
}
