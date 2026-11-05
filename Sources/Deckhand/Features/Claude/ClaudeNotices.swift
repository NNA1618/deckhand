import AppKit

/// Starts the Claude Code monitor and turns its signals into notch notices and sounds.
/// Owned by the Claude workstream.
@MainActor
enum ClaudeNotices {
    static func install(notch: NotchController) {
        let claude = ClaudeCodeMonitor.shared
        claude.onSignal = { [weak notch] _, signal in
            let settings = Settings.shared
            switch signal {
            case .finished(let project, _):
                guard settings.claudeDoneNotice else { return }
                notch?.showToast(symbol: "checkmark.circle", text: String(localized: "Done · \(project)"))
            case .needsYou(let project):
                if settings.claudeSound { NSSound(named: "Ping")?.play() }
                notch?.showToast(symbol: "hand.raised.fill", text: String(localized: "Needs you · \(project)"))
            }
        }
        claude.start()
        // Finding the claude binary may ask the login shell; do it before the first quick action
        Task.detached(priority: .utility) { ClaudeCLI.resolve() }
    }
}
