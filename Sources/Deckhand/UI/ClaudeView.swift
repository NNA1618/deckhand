import SwiftUI

/// Claude tab: live Claude Code sessions on the left, quick text actions on the right.
struct ClaudeView: View {
    @ObservedObject private var vm = ClaudeViewModel.shared
    @ObservedObject private var claudeSettings = ClaudeSettings.shared
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
                        ForEach(claudeSettings.visiblePresets) { p in
                            let selected = vm.selectedPreset?.id == p.id
                            Button { vm.selectedPresetId = p.id } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: p.symbol).font(.system(size: 10))
                                    Text(p.name).font(Theme.label)
                                }
                                .foregroundColor(selected ? .black : Theme.fgDim)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Capsule().fill(selected ? Theme.accent : Theme.surface2))
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
                    .disabled(vm.isRunning)

                HStack(spacing: 8) {
                    Button { ClaudeEngine.openClaudeApp() } label: {
                        Label("Open Claude", systemImage: "arrow.up.forward.app")
                            .font(Theme.label).foregroundColor(Theme.fgDim)
                    }
                    .buttonStyle(.plain)
                    .help(Text("Chat in the Claude app"))
                    Text(engineLabel)
                        .font(Theme.caption).foregroundColor(Theme.fgMute)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if vm.isRunning {
                        ProgressView().controlSize(.small)
                        GlassButton(title: "Stop", symbol: "stop.fill") { vm.stop() }
                            .keyboardShortcut(.cancelAction)
                    } else {
                        PrimaryButton(title: "Run") { vm.runPreset() }
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(!vm.canRun)
                            .opacity(vm.canRun ? 1 : 0.5)
                            .help(Text("Run") + Text(verbatim: " (⌘↩)"))
                    }
                }

                if let err = vm.error {
                    Text(err).font(Theme.caption).foregroundColor(Theme.warn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
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

    /// "Claude Code · Haiku 5.5": where the action runs and with which model.
    private var engineLabel: String {
        let via = settings.claudeBackend == .claudeCode ? "Claude Code" : String(localized: "API key")
        guard let preset = vm.selectedPreset else { return via }
        return "\(via) · \(claudeSettings.model(for: preset).label)"
    }

    private var setupPrompt: some View {
        VStack(spacing: 10) {
            AgentIcon(provider: .claudeCode, size: 30)
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
                    SettingsRouter.shared.section = .claude
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
    @ObservedObject private var claudeSettings = ClaudeSettings.shared
    @State private var installError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AgentIcon(provider: .claudeCode, size: 14)
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
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if monitor.sessions.isEmpty {
                Text("No sessions right now. Start Claude Code in Terminal or the Claude app.")
                    .font(Theme.caption).foregroundColor(Theme.fgMute)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 4) {
                        ForEach(monitor.sessions.prefix(limit), id: \.key) { s in
                            ClaudeSessionRow(session: s, now: context.date,
                                             request: claudeSettings.approveFromNotch ? monitor.pendingRequest(for: s, now: context.date) : nil)
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
    /// A permission request the notch can answer right now; shows Allow and Deny.
    var request: ClaudeRequest?

    var body: some View {
        VStack(spacing: 5) {
            Button { ClaudeCodeMonitor.shared.reveal(session) } label: {
                HStack(spacing: 8) {
                    AgentIcon(provider: session.provider, size: 16, state: session.state)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.project).font(Theme.body).foregroundColor(Theme.fg).lineLimit(1)
                        Text(status).font(Theme.caption).foregroundColor(session.state == .waiting ? Theme.warn : Theme.fgMute)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if session.state == .working {
                        Text(ClaudeCodeMonitor.elapsed(since: session.workStarted, now: now))
                            .font(Theme.monoSmall).foregroundColor(Theme.fgDim)
                            .fixedSize()
                    }
                    if let icon = ClaudeAppIcons.icon(for: session.app) {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: session.cwd))

            if request != nil {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Button { ClaudeCodeMonitor.shared.answer(session, allow: nil); ClaudeCodeMonitor.shared.reveal(session) } label: {
                        Image(systemName: "terminal").font(.system(size: 12, weight: .medium)).foregroundColor(Theme.fgDim)
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text("Answer in Claude Code instead"))
                    GlassButton(title: "Deny") { ClaudeCodeMonitor.shared.answer(session, allow: false) }
                    PrimaryButton(title: "Allow") { ClaudeCodeMonitor.shared.answer(session, allow: true) }
                }
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
    }

    private var status: String {
        switch session.state {
        case .working: return session.detail ?? String(localized: "Working")
        case .waiting: return session.detail ?? String(localized: "Needs you")
        case .idle: return session.detail ?? String(localized: "Waiting for a prompt")
        }
    }
}

/// App icons by bundle id, looked up once instead of on every redraw.
@MainActor
enum ClaudeAppIcons {
    private static var cache: [String: NSImage?] = [:]

    static func icon(for bundleId: String?) -> NSImage? {
        guard let bundleId else { return nil }
        if let known = cache[bundleId] { return known }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId).map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleId] = .some(icon)
        return icon
    }
}

/// The state of a session as an agent icon with a mark. Kept for callers of the old symbol view.
struct ClaudeStateIcon: View {
    let state: ClaudeSession.State
    var provider: AgentProvider = .claudeCode

    var body: some View {
        AgentIcon(provider: provider, size: 14, state: state)
    }
}

/// Around the closed notch while Claude Code works or needs you.
struct ClaudeBadge: View {
    let notchWidth: CGFloat
    let height: CGFloat
    /// Wide enough for "1h 02m" in the right ear.
    static let sideWidth: CGFloat = 62
    @ObservedObject private var monitor = ClaudeCodeMonitor.shared

    var body: some View {
        let waiting = monitor.needsYou
        let working = monitor.active.filter { $0.state == .working }
        let provider = (waiting ?? working.first)?.provider ?? .claudeCode
        Color.clear
            .frame(width: notchWidth + Self.sideWidth * 2, height: height)
            .overlay(alignment: .leading) {
                HStack(spacing: 5) {
                    AgentIcon(provider: provider, size: 15, state: waiting == nil ? .working : .waiting)
                    if monitor.active.count > 1 {
                        Text(verbatim: "\(monitor.active.count)")
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
                                .fixedSize()
                        }
                    }
                }
                .padding(.trailing, 14)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(waiting != nil ? "Claude needs you" : "Claude is working"))
    }
}
