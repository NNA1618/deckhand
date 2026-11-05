import AppKit

/// The coding agents Deckhand can show in the notch. Claude Code is the only one wired up;
/// another agent plugs in with an adapter that turns its events into `AgentEvent`s.
enum AgentProvider: String, CaseIterable, Sendable {
    case claudeCode
    case codex

    var name: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// Apps whose icon stands for the agent, tried in order. The Codex id is the one the
    /// Codex desktop app is expected to use; add more ids here as apps appear.
    var iconApps: [String] {
        switch self {
        case .claudeCode: return ["com.anthropic.claudefordesktop"]
        case .codex: return ["com.openai.codex"]
        }
    }

    /// A neutral symbol for when none of those apps is installed.
    var fallbackSymbol: String {
        switch self {
        case .claudeCode: return "terminal"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// The agent's icon taken from its installed app, looked up once. Deckhand ships no logos.
    /// Snapshot runs (README images) use the neutral symbol: the repository carries no third-party logos,
    /// not even in screenshots, and the images come out the same on every Mac.
    @MainActor
    var appIcon: NSImage? {
        if AppPaths.isSnapshot { return nil }
        if let cached = Self.icons[self] { return cached }
        let icon = iconApps.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        Self.icons[self] = .some(icon)
        return icon
    }

    @MainActor private static var icons: [AgentProvider: NSImage?] = [:]
}
