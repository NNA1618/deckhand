import SwiftUI

/// Claude tab: live Claude Code sessions on the left, quick text actions on the right.
struct ClaudeView: View {
    @StateObject private var vm = ClaudeViewModel()
    @EnvironmentObject private var notch: NotchViewModel
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ClaudeSessionsCard(limit: 6)
                .frame(width: 270)
                .frame(maxHeight: .infinity, alignment: .top)
            actions
        }
        .onAppear { vm.loadFromClipboardIfEmpty() }
    }

    // MARK: - Quick actions

    @ViewBuilder
    private var actions: some View {
        if !ClaudeEngine.isAvailable {
            setupPrompt
        } else {
            VStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Presets.all) { p in
                            Button { vm.selectedPresetId = p.id } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: p.symbol).font(.system(size: 10))
                                    Text(p.name).font(Theme.label)
                                }
                                .foregroundColor(vm.selectedPresetId == p.id ? .black : Theme.fgDim)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Capsule().fill(vm.selectedPresetId == p.id ? Theme.accent : Theme.surface2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                TextEditor(text: $vm.inputText)
                    .scrollContentBackground(.hidden)
                    .padding(8).font(Theme.body)
                    .foregroundColor(Theme.fg)
                    .background(Theme.surface2)
                    .cornerRadius(10)
                    .frame(minHeight: 70, maxHeight: vm.outputText.isEmpty ? .infinity : 110)

                HStack(spacing: 8) {
                    Button { ClaudeEngine.openClaudeApp() } label: {
                        Label("Open Claude", systemImage: "arrow.up.forward.app")
                            .font(Theme.label).foregroundColor(Theme.fgDim)
                    }
                    .buttonStyle(.plain)
                    .help(Text("Chat in the Claude app"))
                    Text(settings.claudeBackend == .claudeCode ? "via Claude Code" : "via API key")
                        .font(Theme.caption).foregroundColor(Theme.fgMute)
                    Spacer()
                    if vm.isRunning { ProgressView().controlSize(.small) }
                    PrimaryButton(title: "Run") { vm.runPreset() }
                        .disabled(vm.inputText.isEmpty || vm.isRunning)
                        .opacity(vm.inputText.isEmpty || vm.isRunning ? 0.5 : 1)
                }

                if let err = vm.error {
                    Text(err).font(Theme.caption).foregroundColor(Theme.warn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !vm.outputText.isEmpty {
                    ScrollView {
                        Text(vm.outputText).font(Theme.body).foregroundColor(Theme.fg)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .background(Theme.surface.opacity(0.8))
                    .cornerRadius(10)
                    HStack(spacing: 14) {
                        Spacer()
                        Button { vm.useOutput() } label: {
                            Label("Use as Input", systemImage: "arrow.uturn.up").font(Theme.label).foregroundColor(Theme.fgDim)
                        }.buttonStyle(.plain)
                        Button { vm.copyOutput() } label: {
                            Label("Copy", systemImage: "doc.on.doc").font(Theme.label).foregroundColor(Theme.fgDim)
                        }.buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var setupPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkle")
                .font(.system(size: 26, weight: .light))
                .foregroundColor(Theme.fgMute)
            Text(settings.claudeBackend == .claudeCode ? "Install Claude Code for quick actions" : "Add your Claude API key")
                .font(Theme.title).foregroundColor(Theme.fg)
            Text(settings.claudeBackend == .claudeCode
                 ? "Quick actions run through Claude Code with your Claude plan, so no API key is needed."
                 : "It is stored in your Mac's Keychain and only used to talk to the Anthropic API.")
                .font(Theme.caption).foregroundColor(Theme.fgDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            HStack(spacing: 8) {
                PrimaryButton(title: "Open Settings") {
                    notch.requestClose()
                    SettingsRouter.shared.tab = .claude
                    SettingsWindow.show()
                }
                GlassButton(title: "Open Claude", symbol: "arrow.up.forward.app") { ClaudeEngine.openClaudeApp() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sessions

/// Claude Code sessions with what each is doing; on Home and in the Claude tab.
struct ClaudeSessionsCard: View {
    var limit = 3
    @ObservedObject private var monitor = ClaudeCodeMonitor.shared
    @State private var installError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.system(size: 11, weight: .medium)).foregroundColor(Theme.fgDim)
                Text("Claude Code").font(Theme.label).foregroundColor(Theme.fg)
                Spacer()
                if !monitor.sessions.isEmpty {
                    Text("\(monitor.active.count) active")
                        .font(Theme.caption).foregroundColor(Theme.fgMute)
                }
            }
            if !monitor.hooksInstalled {
                Text("See when Claude Code works, finishes or needs you, right in the notch.")
                    .font(Theme.caption).foregroundColor(Theme.fgDim)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    PrimaryButton(title: "Connect") {
                        do { try monitor.installHooks(); installError = nil } catch { installError = error.localizedDescription }
                    }
                    Spacer()
                }
                if let installError {
                    Text(installError).font(Theme.caption).foregroundColor(Theme.warn)
                }
            } else if monitor.sessions.isEmpty {
                Text("No sessions right now. Start Claude Code in Terminal or the Claude app.")
                    .font(Theme.caption).foregroundColor(Theme.fgMute)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 4) {
                        ForEach(monitor.sessions.prefix(limit)) { s in
                            ClaudeSessionRow(session: s, now: context.date)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassChip(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ClaudeSessionRow: View {
    let session: ClaudeSession
    let now: Date

    var body: some View {
        Button { ClaudeCodeMonitor.shared.reveal(session) } label: {
            HStack(spacing: 8) {
                ClaudeStateIcon(state: session.state)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.project).font(Theme.body).foregroundColor(Theme.fg).lineLimit(1)
                    Text(status).font(Theme.caption).foregroundColor(session.state == .waiting ? Theme.warn : Theme.fgMute)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if session.state == .working {
                    Text(ClaudeCodeMonitor.elapsed(since: session.workStarted, now: now))
                        .font(Theme.monoSmall).foregroundColor(Theme.fgDim)
                }
                if let icon = appIcon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
            }
            .padding(.vertical, 5).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(session.cwd))
    }

    private var status: String {
        switch session.state {
        case .working: return session.detail ?? String(localized: "Working")
        case .waiting: return session.detail ?? String(localized: "Needs you")
        case .idle: return String(localized: "Waiting for a prompt")
        }
    }

    private var appIcon: NSImage? {
        guard let app = session.app, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

struct ClaudeStateIcon: View {
    let state: ClaudeSession.State

    var body: some View {
        switch state {
        case .working:
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.fg)
        case .waiting:
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.warn)
        case .idle:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.fgMute)
        }
    }
}

/// Around the closed notch while Claude Code works or needs you.
struct ClaudeBadge: View {
    let notchWidth: CGFloat
    let height: CGFloat
    static let sideWidth: CGFloat = 54
    @ObservedObject private var monitor = ClaudeCodeMonitor.shared

    var body: some View {
        let waiting = monitor.needsYou
        let working = monitor.active.filter { $0.state == .working }
        Color.clear
            .frame(width: notchWidth + Self.sideWidth * 2, height: height)
            .overlay(alignment: .leading) {
                HStack(spacing: 4) {
                    ClaudeStateIcon(state: waiting == nil ? .working : .waiting)
                    if monitor.active.count > 1 {
                        Text("\(monitor.active.count)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundColor(Theme.fgDim)
                    }
                }
                .padding(.leading, 16)
            }
            .overlay(alignment: .trailing) {
                Group {
                    if waiting != nil {
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(Theme.warn)
                    } else {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(ClaudeCodeMonitor.elapsed(since: working.compactMap(\.workStarted).min(), now: context.date))
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundColor(Theme.fg)
                        }
                    }
                }
                .padding(.trailing, 14)
            }
    }
}
