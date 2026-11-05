import SwiftUI
import AppKit

/// Recents: watched folders, what to show and the prompt helper. Owned by the prompts, shelf and recents workstream.
struct RecentsPane: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var recents = RecentsSettings.shared
    @ObservedObject private var vm = RecentsViewModel.shared

    var body: some View {
        SettingsPane(.recents) {
            Section {
                ForEach(settings.watchedFolders, id: \.self) { path in
                    SettingsRow(FileManager.default.displayName(atPath: path),
                                detail: (path as NSString).abbreviatingWithTildeInPath,
                                icon: .image(NSWorkspace.shared.icon(forFile: path)),
                                detailIsPath: true) {
                        if let problem = vm.problems.first(where: { $0.path == path }) {
                            StatusChip(problem.kind == .noAccess ? String(localized: "No access") : String(localized: "Not found"),
                                       kind: .attention)
                        }
                        Button(role: .destructive) {
                            settings.watchedFolders.removeAll { $0 == path }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help(Text("Stop watching this folder"))
                        .accessibilityLabel(Text("Stop watching this folder"))
                    }
                }
                HStack {
                    Button("Add Folder…") { pickFolder() }
                        .buttonStyle(.settings)
                    Spacer()
                }
            } header: {
                Text("Folders")
            } footer: {
                SettingsFooter("For example the Downloads folder, where AI generations usually land.")
            }

            Section {
                Picker("Period", selection: $recents.days) {
                    ForEach(RecentsSettings.dayChoices, id: \.self) { days in
                        Text(Self.periodLabel(days)).tag(days)
                    }
                }
                Picker("Files", selection: $recents.kinds) {
                    Text("Images and videos").tag(RecentsKinds.all)
                    Text("Images only").tag(RecentsKinds.images)
                    Text("Videos only").tag(RecentsKinds.videos)
                }
                SettingsToggleRow(String(localized: "Include subfolders"), isOn: $recents.includeSubfolders)
                Picker("Maximum", selection: $recents.limit) {
                    ForEach(RecentsSettings.limitChoices, id: \.self) { n in
                        Text("\(n) files").tag(n)
                    }
                }
            } header: {
                Text("Show")
            }

            Section {
                SettingsToggleRow(String(localized: "Show the prompt field"), isOn: $recents.showPrompt)
                SettingsRow(String(localized: "Link button")) {
                    VStack(alignment: .trailing, spacing: 2) {
                        TextField("Link button", text: $recents.linkURL, prompt: Text(verbatim: RecentsSettings.defaultLinkURL))
                            .labelsHidden()
                            .frame(width: 240)
                        if !recents.linkURL.trimmingCharacters(in: .whitespaces).isEmpty, recents.link == nil {
                            Text("Not a web address").font(Theme.caption).foregroundStyle(Theme.warn)
                        }
                    }
                }
                ShortcutRow(action: .recents, title: String(localized: "Shortcut"))
            } header: {
                Text("Prompt helper")
            } footer: {
                SettingsFooter("The link button opens a site next to the prompt field, for example where you make generations. Leave it empty to hide it.")
            }
        }
    }

    /// The period as a menu value ("2 weeks"); the panel header uses the longer "Last 2 weeks".
    private static func periodLabel(_ days: Int) -> String {
        switch days {
        case 1: return String(localized: "recents.menu.day", defaultValue: "Day")
        case 3: return String(localized: "recents.menu.3days", defaultValue: "3 days")
        case 7: return String(localized: "recents.menu.week", defaultValue: "Week")
        case 30: return String(localized: "recents.menu.month", defaultValue: "Month")
        default: return String(localized: "recents.menu.2weeks", defaultValue: "2 weeks")
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Watch")
        let add: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            for url in panel.urls where !settings.watchedFolders.contains(url.path) {
                settings.watchedFolders.append(url.path)
            }
        }
        if let window = SettingsWindow.window {
            panel.beginSheetModal(for: window, completionHandler: add)
        } else {
            add(panel.runModal())
        }
    }
}
