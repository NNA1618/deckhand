import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The prompt library. Owned by the prompts, shelf and recents workstream.
struct PromptsPane: View {
    @ObservedObject private var settings = PromptSettings.shared
    @State private var message: String?

    var body: some View {
        SettingsPane(.prompts) {
            Section {
                Picker("Clicking a prompt", selection: $settings.clickAction) {
                    Text("Copies it").tag(PromptClickAction.copy)
                    Text("Pastes it into the app").tag(PromptClickAction.paste)
                }
                SettingsToggleRow(String(localized: "Fill in {{variables}} first"),
                                  detail: String(localized: "Asks for {{product}} and similar before copying."),
                                  isOn: $settings.fillVariables)
                Picker("Sort", selection: $settings.sort) {
                    Text("Favorites and most used").tag(PromptSort.favoritesAndUsage)
                    Text("By name").tag(PromptSort.name)
                    Text("Recently edited").tag(PromptSort.recentlyEdited)
                }
            } footer: {
                SettingsFooter("Hold ⌥ when pressing Return to do the other action.")
            }

            Section {
                SettingsRow(String(localized: "Prompts file")) {
                    Button("Import…") { importPrompts() }
                        .buttonStyle(.settings)
                    Button("Export…") { exportPrompts() }
                        .buttonStyle(.settings)
                }
                SettingsRow(String(localized: "Starter prompts")) {
                    Button("Restore Starter Prompts") {
                        let added = PromptStore.shared.addStarters()
                        PromptsViewModel.shared.refresh(resort: true)
                        message = added == 0 ? String(localized: "All starter prompts are already in the library.")
                                             : String(localized: "Starter prompts added: \(added)")
                    }
                    .buttonStyle(.settings)
                }
                SettingsRow(String(localized: "All prompts")) {
                    ConfirmedButton(
                        title: String(localized: "Delete All Prompts…"),
                        alertTitle: String(localized: "Delete all prompts?"),
                        message: String(localized: "This can't be undone. Export the library first if you may need it again."),
                        confirmTitle: String(localized: "Delete All Prompts"),
                        action: {
                            PromptStore.shared.deleteAll()
                            PromptsViewModel.shared.refresh(resort: true)
                            message = String(localized: "All prompts deleted.")
                        }
                    )
                    .disabled(PromptStore.shared.count == 0)
                }
            } header: {
                Text("Library")
            } footer: {
                Text(message ?? String(localized: "Export saves a JSON file you can import on another Mac."))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.fgMute)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                ShortcutRow(action: .prompts, title: String(localized: "Shortcut"))
            }
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
