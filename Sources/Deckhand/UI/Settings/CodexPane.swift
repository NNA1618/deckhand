import SwiftUI

/// OpenAI Codex sessions in the notch: the connection, approvals and Codex's own notices.
/// Owned by the Codex workstream.
struct CodexPane: View {
    @ObservedObject private var monitor = CodexMonitor.shared
    @ObservedObject private var codex = CodexSettings.shared
    @State private var hookError: String?

    var body: some View {
        SettingsPane(.codex) {
            connectionSection
            approvalsSection
            noticesSection
            SettingsPaneActions {
                RestoreDefaultsButton(section: .codex, message: String(localized: "Approvals and notices go back to the defaults. Codex stays connected.")) {
                    codex.restoreDefaults()
                }
            }
        }
        .onSettingsActivation {
            if !AppPaths.isSnapshot { monitor.refresh() }
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section {
            SettingsRow(String(localized: "Connection"), detail: connectionDetail) {
                StatusChip(status.text, kind: status.kind)
                if monitor.hooksInstalled {
                    ConfirmedButton(
                        title: String(localized: "Disconnect…"),
                        alertTitle: String(localized: "Disconnect Codex?"),
                        message: String(localized: "Deckhand removes only its own hooks from \(monitor.hooksFile.displayPath). Codex sessions stop showing in the notch."),
                        confirmTitle: String(localized: "Disconnect"),
                        action: { run { try monitor.removeHooks() } }
                    )
                } else if notFound {
                    Link(String(localized: "Get Codex…"), destination: CodexMonitor.installURL)
                        .buttonStyle(.settings)
                } else {
                    Button(String(localized: "Connect")) { run { try monitor.installHooks() } }
                        .buttonStyle(.settings(.prominent))
                        .disabled(!monitor.checked)
                }
            }
            if monitor.awaitingReview {
                SettingsRow(String(localized: "Where to approve"),
                            detail: String(localized: "In the Codex CLI type /hooks or answer the “Hooks need review” prompt; in the ChatGPT app use Review hooks or Settings → Hooks. Then start a new session."),
                            icon: .symbol("checkmark.shield.fill", .orange))
            }
            if notFound {
                SettingsRow(String(localized: "Codex isn't installed on this Mac."),
                            detail: String(localized: "Install the Codex CLI or the ChatGPT app, sign in once, then come back here to connect."),
                            icon: .symbol("questionmark.app.dashed", .gray))
            }
            ForEach(warningRows, id: \.self) { text in
                SettingsRow(text, icon: .symbol("exclamationmark.triangle.fill", .orange))
            }
            if let hookError {
                Text(hookError)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !notFound {
                SettingsRow(String(localized: "Hooks file"), detail: monitor.hooksFile.displayPath, detailIsPath: true) {
                    RevealInFinderButton(url: monitor.hooksFile.url)
                }
            }
        } footer: {
            SettingsFooter("Connect adds Deckhand's hooks after your own in \(monitor.hooksFile.displayPath) and keeps a copy of the original file next to it. Codex runs them only after you approve them. Deckhand updates only its script later, so you approve once.")
        }
    }

    private var notFound: Bool { monitor.checked && !monitor.availability.isInstalled && !monitor.hooksInstalled }

    private var status: (text: String, kind: StatusChip.Kind) {
        if !monitor.checked { return (String(localized: "Checking…"), .neutral) }
        if monitor.hooksInstalled {
            return monitor.awaitingReview ? (String(localized: "Waiting for approval"), .attention) : (String(localized: "Connected"), .good)
        }
        if notFound { return (String(localized: "Codex not found"), .neutral) }
        return (String(localized: "Not connected"), .neutral)
    }

    private var connectionDetail: String? {
        if monitor.awaitingReview {
            return String(localized: "Connected — approve Deckhand's hooks in Codex (/hooks or Review hooks), then start a new session.")
        }
        if monitor.hooksInstalled { return String(localized: "Sessions from the Codex CLI, editors and the ChatGPT app show in the notch.") }
        if notFound { return nil }
        return String(localized: "See when Codex works, finishes or needs you, right in the notch.")
    }

    private var warningRows: [String] {
        let w = monitor.warnings
        var rows: [String] = []
        if w.hooksDisabled {
            rows.append(String(localized: "Hooks are turned off in Codex's config.toml ([features] hooks = false), so Codex runs none of them."))
        }
        if w.claudeHookImported {
            rows.append(String(localized: "Codex has imported Deckhand's Claude Code hook (claude-hook.sh). Remove it from Codex's hooks, or Codex sessions may show as Claude Code."))
        }
        if w.inlineHooks {
            rows.append(String(localized: "Codex's config.toml also defines hooks. Codex then warns that hooks come from two places; Deckhand's still run."))
        }
        if let error = w.fileError { rows.append(error) }
        return rows
    }

    // MARK: - Approvals

    private var approvalsSection: some View {
        Section {
            SettingsToggleRow(String(localized: "Approve from the notch"),
                              detail: String(localized: "Allow or deny Codex's permission requests in the panel"),
                              isOn: $codex.approveFromNotch)
                .disabled(!monitor.hooksInstalled)
            if codex.approveFromNotch {
                ChipPicker(String(localized: "Wait for an answer"), selection: $codex.approvalWait,
                           options: CodexSettings.approvalWaits.map { ($0, Duration.seconds($0).formatted(.units(allowed: [.seconds], width: .abbreviated))) })
            }
        } footer: {
            if codex.approveFromNotch {
                SettingsFooter("Codex waits for the notch first and shows its own prompt if you don't answer in time. The panel shows only the tool and file or command name, and offers no “always allow”; check Codex when in doubt.")
            } else {
                SettingsFooter("Off: Codex asks in its own window as usual, and the notch only shows that it waits.")
            }
        }
    }

    // MARK: - Notices

    private var noticesSection: some View {
        Section {
            SettingsToggleRow(String(localized: "Codex needs you"), isOn: $codex.noticeNeedsYou)
            SettingsToggleRow(String(localized: "Codex finished a task"), isOn: $codex.doneNotice)
            CodexSoundRow(title: String(localized: "Sound"), selection: $codex.soundNeedsYou)
            SettingsLinkRow(String(localized: "Badge and other notices"), to: .section(.closedNotch))
        } header: {
            Text("Notices")
        } footer: {
            SettingsFooter("Deckhand keeps only the session id, project folder, event and tool name; prompts, code and output never leave Codex.")
        }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            hookError = nil
        } catch {
            hookError = error.localizedDescription
        }
    }
}

/// The "needs you" sound: a menu of the macOS alert sounds and a button to hear it.
private struct CodexSoundRow: View {
    let title: String
    @Binding var selection: String

    /// The alert sounds that come with macOS, read once when the pane first shows.
    private static let names: [String] = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        return files.filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
    }()

    var body: some View {
        SettingsRow(title) {
            Picker(title, selection: $selection) {
                Text("None").tag("")
                Divider()
                ForEach(Self.names, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Button {
                NSSound(named: NSSound.Name(selection))?.play()
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(selection.isEmpty)
            .help(Text("Play"))
            .accessibilityLabel(Text("Play"))
        }
    }
}
