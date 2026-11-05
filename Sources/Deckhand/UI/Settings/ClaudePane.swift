import SwiftUI

/// Claude Code in the notch and quick actions. Owned by the Claude workstream.
struct ClaudePane: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var claude = ClaudeSettings.shared
    @ObservedObject private var monitor = ClaudeCodeMonitor.shared
    @State private var key = ""
    @State private var keyError: String?
    @State private var hasKey = ClaudeAPI.shared.hasAPIKey
    @State private var hookError: String?
    @State private var auth: ClaudeCLI.AuthStatus?
    @State private var cliPath: String?
    @State private var checking = false
    @State private var confirmDisconnect = false
    @State private var confirmRemoveKey = false

    var body: some View {
        SettingsPane(.claude) {
            notchSection
            quickActionsSection
            presetsSection
        }
        .onChange(of: settings.claudeBackend) { Task { await checkCLI(force: false) } }
        // Only the Settings window coming forward re-checks; the notch panel becoming key must not
        // start `claude auth status` each time
        .onSettingsActivation {
            if !AppPaths.isSnapshot { monitor.refreshConnection() }
            hasKey = ClaudeAPI.shared.hasAPIKey
            await checkCLI(force: false)
        }
        .confirmationDialog("Disconnect Claude Code?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) {
                run { try monitor.removeHooks() }
            }
        } message: {
            Text("Deckhand removes only its own entries from \(monitor.settingsFile.displayPath). Sessions stop showing in the notch.")
        }
        .confirmationDialog("Remove the API key?", isPresented: $confirmRemoveKey) {
            Button("Remove", role: .destructive) {
                ClaudeAPI.shared.apiKey = nil
                hasKey = false
            }
        } message: {
            Text("The key is deleted from your Keychain.")
        }
    }

    // MARK: - Claude Code in the notch

    private var notchSection: some View {
        Section {
            LabeledContent("Connection") {
                HStack(spacing: 8) {
                    Circle().fill(monitor.hooksInstalled ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
                    Text(monitor.hooksInstalled ? "Connected" : "Not connected").foregroundStyle(.secondary)
                    if monitor.hooksInstalled {
                        Button("Disconnect…") { confirmDisconnect = true }
                    } else {
                        Button("Connect") { run { try monitor.installHooks() } }
                    }
                }
            }
            if let hookError {
                Text(hookError).font(.caption).foregroundStyle(.orange)
            }
            Toggle(isOn: $claude.approveFromNotch) {
                Text("Approve from the notch")
                Text("Allow or deny Claude Code's permission requests in the panel")
            }
            .disabled(!monitor.hooksInstalled)
            if claude.approveFromNotch {
                Picker("Wait for an answer", selection: $claude.approvalWait) {
                    ForEach(ClaudeSettings.approvalWaits, id: \.self) { seconds in
                        Text(Duration.seconds(seconds).formatted(.units(allowed: [.seconds], width: .wide))).tag(seconds)
                    }
                }
            }
            Button {
                SettingsRouter.shared.section = .closedNotch
            } label: {
                HStack {
                    Text("Badge, notices and sound").foregroundStyle(Color.primary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text("Claude Code in the notch")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect adds a small hook to \(monitor.settingsFile.displayPath) and keeps a copy of the original file next to it. While Deckhand runs, the hook passes the project folder, the tool and the file or command name to it. Prompts, code and command output are never saved. Works for Claude Code in Terminal, editors and the Claude app.")
                if claude.approveFromNotch {
                    Text("While this is on, Claude Code waits for the notch first and shows its own prompt if you don't answer in time. The panel shows only the tool and file or command name; check the terminal when in doubt.")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Quick actions

    private var quickActionsSection: some View {
        Section {
            Picker("Run with", selection: $settings.claudeBackend) {
                Text("Claude Code (your plan)").tag(ClaudeBackend.claudeCode)
                Text("API key").tag(ClaudeBackend.apiKey)
            }
            if settings.claudeBackend == .claudeCode {
                LabeledContent("Claude Code") {
                    HStack(spacing: 8) {
                        cliStatus
                        Button("Check Again") { Task { await checkCLI(force: true) } }
                            .disabled(checking)
                    }
                }
                Picker("Location", selection: locationChoice) {
                    Text("Automatic").tag("")
                    if !claude.cliPath.isEmpty {
                        Text(verbatim: (claude.cliPath as NSString).abbreviatingWithTildeInPath).tag(claude.cliPath)
                    }
                    Divider()
                    Text("Choose…").tag("choose")
                }
            } else {
                apiKeyRows
            }
            Picker("Model", selection: $claude.model) {
                Text("Per action").tag("")
                Divider()
                Text("Haiku 5.5 (fastest)").tag(ClaudeModel.haiku55.rawValue)
                Text(verbatim: ClaudeModel.sonnet55.label).tag(ClaudeModel.sonnet55.rawValue)
                Text("Opus 5.5 (smartest)").tag(ClaudeModel.opus55.rawValue)
            }
        } header: {
            Text("Quick actions")
        } footer: {
            Group {
                if settings.claudeBackend == .claudeCode {
                    Text("Rewrite, translate, Ask Claude in the editor and prompt help run through Claude Code with your Claude subscription. No API key needed. They run without your hooks, plugins and CLAUDE.md.")
                } else {
                    Link("Get a key at console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var cliStatus: some View {
        if checking && cliPath == nil {
            ProgressView().controlSize(.small)
        } else if let cliPath {
            if auth?.loggedIn == false {
                Text("Not signed in").foregroundStyle(.secondary)
                Button("Sign In…") { ClaudeCLI.openSignIn() }
            } else {
                Text(signedInText(path: cliPath))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(Text(verbatim: cliPath))
            }
        } else {
            Text("Not installed").foregroundStyle(.secondary)
            Link("Install…", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
        }
    }

    private func signedInText(path: String) -> String {
        let place = (path as NSString).abbreviatingWithTildeInPath
        if let email = auth?.email, !email.isEmpty { return String(localized: "Signed in · \(email)") }
        if auth?.loggedIn == true { return String(localized: "Signed in · \(place)") }
        return place
    }

    @ViewBuilder private var apiKeyRows: some View {
        if hasKey {
            LabeledContent("API key") {
                HStack {
                    Text("Saved in Keychain").foregroundStyle(.secondary)
                    Button("Remove…") { confirmRemoveKey = true }
                }
            }
        } else {
            LabeledContent("API key") {
                HStack {
                    SecureField("API key", text: $key, prompt: Text(verbatim: "sk-ant-…"))
                        .labelsHidden()
                        .onSubmit(saveKey)
                    Button("Save", action: saveKey).disabled(key.isEmpty)
                }
            }
            if let keyError {
                Text(keyError).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func saveKey() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ClaudeAPI.looksLikeKey(trimmed) else {
            keyError = String(localized: "This doesn't look like an Anthropic key. Keys start with sk-ant-.")
            return
        }
        ClaudeAPI.shared.apiKey = trimmed
        key = ""
        keyError = nil
        hasKey = ClaudeAPI.shared.hasAPIKey
    }

    /// The Location menu: picking "Choose…" opens a file panel and keeps the old choice when cancelled.
    private var locationChoice: Binding<String> {
        Binding {
            claude.cliPath
        } set: { value in
            if value == "choose" {
                chooseBinary()
            } else {
                claude.cliPath = value
                Task { await checkCLI(force: true) }
            }
        }
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = String(localized: "Choose the claude program")
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        claude.cliPath = url.path
        Task { await checkCLI(force: true) }
    }

    // MARK: - Actions in the panel

    private var presetsSection: some View {
        Section {
            let presets = claude.orderedPresets
            ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                HStack(spacing: 10) {
                    Image(systemName: preset.symbol).frame(width: 18).foregroundStyle(.secondary)
                    Toggle(preset.name, isOn: visible(preset))
                    Spacer()
                    Button { move(preset, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).disabled(index == 0)
                        .help(Text("Move up"))
                    Button { move(preset, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).disabled(index == presets.count - 1)
                        .help(Text("Move down"))
                }
            }
        } header: {
            Text("Actions in the panel")
        }
    }

    private func visible(_ preset: ClaudePreset) -> Binding<Bool> {
        Binding {
            !claude.hiddenPresets.contains(preset.id)
        } set: { on in
            if on { claude.hiddenPresets.removeAll { $0 == preset.id } } else if !claude.hiddenPresets.contains(preset.id) {
                claude.hiddenPresets.append(preset.id)
            }
        }
    }

    private func move(_ preset: ClaudePreset, by offset: Int) {
        var ids = claude.orderedPresets.map(\.id)
        guard let i = ids.firstIndex(of: preset.id), ids.indices.contains(i + offset) else { return }
        ids.swapAt(i, i + offset)
        claude.presetOrder = ids
    }

    // MARK: - Helpers

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            hookError = nil
        } catch {
            hookError = error.localizedDescription
        }
    }

    /// Finds `claude` and asks whether it is signed in, without blocking the window.
    private func checkCLI(force: Bool) async {
        guard settings.claudeBackend == .claudeCode else { return }
        checking = true
        cliPath = await Task.detached { ClaudeCLI.resolve(force: force) }.value
        auth = cliPath == nil ? nil : await ClaudeCLI.authStatus()
        if let dir = auth?.configDirectory, !dir.isEmpty, !AppPaths.isSnapshot {
            monitor.setConfigDirectory(URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true))
        }
        checking = false
    }
}
