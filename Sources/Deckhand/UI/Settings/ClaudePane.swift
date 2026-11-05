import SwiftUI

/// Claude Code in the notch and quick actions. Owned by the Claude workstream.
struct ClaudePane: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var monitor = ClaudeCodeMonitor.shared
    @State private var key = ""
    @State private var hasKey = ClaudeAPI.shared.hasAPIKey
    @State private var hookError: String?
    @State private var signedIn: Bool?

    var body: some View {
        SettingsPane(.claude) {
            Section {
                LabeledContent("Status") {
                    HStack {
                        Text(monitor.hooksInstalled ? "Connected" : "Not connected").foregroundStyle(.secondary)
                        Button(monitor.hooksInstalled ? "Disconnect" : "Connect") {
                            do {
                                if monitor.hooksInstalled { try monitor.removeHooks() } else { try monitor.installHooks() }
                                hookError = nil
                            } catch {
                                hookError = error.localizedDescription
                            }
                        }
                    }
                }
                if let hookError {
                    Text(hookError).font(.caption).foregroundStyle(.orange)
                }
                Toggle("Show working sessions around the notch", isOn: $settings.claudeInNotch)
                Toggle("Show a notice when a task is done", isOn: $settings.claudeDoneNotice)
                Toggle("Play a sound when Claude needs you", isOn: $settings.claudeSound)
            } header: {
                Text("Claude Code in the notch")
            } footer: {
                Text("Connect adds a small hook to ~/.claude/settings.json and keeps a backup next to it. Events stay on this Mac; prompts and code are never saved. Works for Claude Code in Terminal, editors and the Claude app.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Run with", selection: $settings.claudeBackend) {
                    Text("Claude Code (your plan)").tag(ClaudeBackend.claudeCode)
                    Text("API key").tag(ClaudeBackend.apiKey)
                }
                if settings.claudeBackend == .claudeCode {
                    LabeledContent("Claude Code") {
                        HStack {
                            if let path = ClaudeCLI.path {
                                Text(signedIn == false ? String(localized: "Not signed in") : (path as NSString).abbreviatingWithTildeInPath)
                                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                if signedIn == false {
                                    Button("Sign In…") { ClaudeCLI.openSignIn() }
                                }
                            } else {
                                Text("Not installed").foregroundStyle(.secondary)
                                Link("Install", destination: URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!)
                            }
                        }
                    }
                } else if hasKey {
                    LabeledContent("API key") {
                        HStack {
                            Text("Saved in Keychain").foregroundStyle(.secondary)
                            Button("Remove") {
                                ClaudeAPI.shared.apiKey = nil
                                hasKey = false
                            }
                        }
                    }
                } else {
                    SecureField("API key", text: $key, prompt: Text(verbatim: "sk-ant-…"))
                    Button("Save to Keychain") {
                        ClaudeAPI.shared.apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                        key = ""
                        hasKey = ClaudeAPI.shared.hasAPIKey
                    }
                    .disabled(key.isEmpty)
                }
            } header: {
                Text("Quick actions")
            } footer: {
                Group {
                    if settings.claudeBackend == .claudeCode {
                        Text("Rewrite, translate, Ask Claude in the editor and prompt help run through Claude Code with your Claude subscription. No API key needed.")
                    } else {
                        Link("Get a key at console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: settings.claudeBackend) {
            if settings.claudeBackend == .claudeCode, ClaudeCLI.isInstalled { signedIn = await ClaudeCLI.isSignedIn() }
        }
    }
}
