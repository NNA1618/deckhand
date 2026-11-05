import SwiftUI
import AppKit

/// Translation languages and behavior. Owned by the translate workstream.
struct TranslatePane: View {
    @ObservedObject private var settings = TranslateSettings.shared
    @ObservedObject private var catalog = TranslationCatalog.shared
    @ObservedObject private var hotkeys = HotkeyManager.shared

    var body: some View {
        SettingsPane(.translate) {
            Section {
                Picker("Translate into", selection: $settings.target) { languageOptions }
                Picker(selection: $settings.secondLanguage) { languageOptions } label: {
                    Text("Second language")
                    Text("Text already in the first language goes into this one.")
                }
                Toggle("Detect the language automatically", isOn: $settings.autoDetect)
                if !settings.autoDetect {
                    Picker("Source language", selection: $settings.source) { languageOptions }
                }
                LabeledContent("Languages on this Mac") {
                    Button("Translation Languages…") { openTranslationLanguages() }
                }
            } header: {
                Text("Languages")
            } footer: {
                Text("On-device translation with Apple Translation. Languages that aren't on this Mac yet download the first time you use them.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(settings.favorites, id: \.self) { code in
                    HStack {
                        Text(TranslationLanguages.name(of: code))
                        Spacer()
                        Button {
                            settings.favorites.removeAll { $0 == code }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(Text("Remove from Favorites"))
                    }
                }
                Menu("Add Language…") {
                    ForEach(sorted.filter { !settings.favorites.contains($0) }, id: \.self) { code in
                        Button(TranslationLanguages.name(of: code)) { settings.favorites.append(code) }
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } header: {
                Text("Favorite languages")
            } footer: {
                Text("Favorites come first in the language lists and appear as one-click buttons in the Translate tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Translate as you type", isOn: $settings.translateAsYouType)
                LabeledContent("Translate selected text") {
                    HStack(spacing: 8) {
                        Text(hotkeys.shortcuts[.translateSelection]?.display ?? String(localized: "None"))
                            .foregroundStyle(.secondary)
                        Button("Change…") { SettingsRouter.shared.section = .shortcuts }
                    }
                }
            } header: {
                Text("Typing and Shortcut")
            } footer: {
                Text("Translates a moment after you stop typing. \("⌘↩") translates right away.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { catalog.loadIfNeeded() }
    }

    private var sorted: [String] { TranslationLanguages.sortedByName(catalog.codes) }

    @ViewBuilder
    private var languageOptions: some View {
        ForEach(sorted, id: \.self) { code in
            Text(TranslationLanguages.name(of: code)).tag(code)
        }
    }

    /// System Settings → General → Language & Region → Translation Languages.
    private func openTranslationLanguages() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
