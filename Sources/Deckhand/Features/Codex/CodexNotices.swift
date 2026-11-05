import AppKit

/// Starts the Codex monitor and turns signals of Codex sessions into notch notices and sounds,
/// with Codex's own switches. Signals of other agents go on to the handler installed before it.
@MainActor
enum CodexNotices {
    /// How long a permission request must stand before Deckhand calls for the user. Codex asks its
    /// hooks before its own automatic review, which often answers within a moment.
    static let needsYouDelay: Duration = .milliseconds(1500)

    /// Waits already announced, by session and the moment the wait began.
    private static var announced = Set<String>()

    /// Call after `ClaudeNotices.install`, which sets the handler this one forwards to.
    static func install(notch: NotchController) {
        let monitor = ClaudeCodeMonitor.shared
        let previous = monitor.onSignal
        monitor.onSignal = { [weak notch] session, signal in
            guard session.provider == .codex else { return previous(session, signal) }
            guard let notch else { return }
            handle(signal, session: session, notch: notch)
        }
        CodexMonitor.shared.start()
        CodexMonitor.shared.useShellHome()
    }

    private static func handle(_ signal: ClaudeStateMachine.Signal, session: ClaudeSession, notch: NotchController) {
        let settings = CodexSettings.shared
        switch signal {
        case .finished(let project, _):
            guard settings.doneNotice, !isInFront(session) else { return }
            notch.showToast(symbol: "checkmark.circle", text: String(localized: "Codex is done · \(project)"))
        case .needsYou:
            let key = "\(session.key)@\(session.waitingSince?.timeIntervalSince1970 ?? 0)"
            announced = announced.filter { $0.hasPrefix(session.key + "@") ? $0 == key : true }
            guard !announced.contains(key) else { return }
            let since = session.waitingSince
            Task { @MainActor in
                try? await Task.sleep(for: needsYouDelay)
                // Dropped when anything else happened in the session meanwhile, e.g. the automatic review answered
                guard let now = ClaudeCodeMonitor.shared.sessions.first(where: { $0.key == session.key }),
                      now.state == .waiting, now.waitingSince == since, now.updated == session.updated,
                      !announced.contains(key) else { return }
                guard !isInFront(now) || ClaudeCodeMonitor.shared.pendingRequest(for: now) != nil else { return }
                announced.insert(key)
                if !settings.soundNeedsYou.isEmpty { NSSound(named: settings.soundNeedsYou)?.play() }
                if settings.noticeNeedsYou {
                    notch.showToast(symbol: "hand.raised.fill", text: String(localized: "Codex needs you · \(now.project)"), style: .alert)
                }
            }
        case .failed(let project, let message):
            guard settings.noticeNeedsYou else { return }
            notch.showToast(symbol: "exclamationmark.triangle.fill", text: "\(message) · \(project)")
        }
    }

    /// Whether the app running the session is the one in front.
    private static func isInFront(_ session: ClaudeSession) -> Bool {
        guard let app = session.app else { return false }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == app
    }
}
