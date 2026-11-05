import AppKit

/// Starts the Claude Code monitor and turns its signals into notch notices and sounds.
/// Owned by the Claude workstream.
@MainActor
enum ClaudeNotices {
    /// Waits already announced, by session and the moment the wait began, so Claude Code's
    /// reminder for the same prompt doesn't ring again.
    private static var announced = Set<String>()

    static func install(notch: NotchController) {
        let claude = ClaudeCodeMonitor.shared
        claude.onSignal = { [weak notch] session, signal in
            guard let notch else { return }
            handle(signal, session: session, notch: notch)
        }
        claude.start()
        // Finding the claude binary may ask the login shell; do it before the first quick action.
        // The shell also says where Claude Code keeps its settings when CLAUDE_CONFIG_DIR is set there.
        Task.detached(priority: .utility) {
            ClaudeCLI.resolve()
            if let dir = ClaudeCLI.location?.configDirectory, !dir.isEmpty {
                let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
                await MainActor.run { ClaudeCodeMonitor.shared.setConfigDirectory(url) }
            }
        }
    }

    private static func handle(_ signal: ClaudeStateMachine.Signal, session: ClaudeSession, notch: NotchController) {
        let settings = Settings.shared
        switch signal {
        case .finished(let project, _):
            guard settings.claudeDoneNotice, !isInFront(session) else { return }
            notch.showToast(symbol: "checkmark.circle", text: String(localized: "Done · \(project)"))
        case .needsYou(let project):
            let key = "\(session.key)@\(session.waitingSince?.timeIntervalSince1970 ?? 0)"
            announced = announced.filter { $0.hasPrefix(session.key + "@") ? $0 == key : true }
            // Someone looking at the session's window sees the prompt; Claude Code reminds
            // again after a few idle seconds, and that reminder is announced then
            guard !announced.contains(key), !isInFront(session) || ClaudeCodeMonitor.shared.pendingRequest(for: session) != nil else { return }
            announced.insert(key)
            if !settings.soundClaudeNeedsYou.isEmpty { NSSound(named: settings.soundClaudeNeedsYou)?.play() }
            if settings.noticeClaudeNeedsYou {
                notch.showToast(symbol: "hand.raised.fill", text: String(localized: "Needs you · \(project)"), style: .alert)
            }
        case .failed(let project, let message):
            guard settings.noticeClaudeNeedsYou else { return }
            notch.showToast(symbol: "exclamationmark.triangle.fill", text: "\(message) · \(project)")
        }
    }

    /// Whether the app running the session is the one in front.
    private static func isInFront(_ session: ClaudeSession) -> Bool {
        guard let app = session.app else { return false }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == app
    }
}
