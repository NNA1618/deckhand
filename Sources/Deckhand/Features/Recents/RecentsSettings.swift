import Foundation
import Combine

/// Settings of the Recents tab, in UserDefaults. The watched folders stay in `Settings.watchedFolders`.
@MainActor
final class RecentsSettings: ObservableObject {
    static let shared = RecentsSettings()
    private let d = UserDefaults.standard

    static let dayChoices = [1, 3, 7, 14, 30]
    static let limitChoices = [20, 40, 100]
    static let defaultLinkURL = "https://higgsfield.ai"

    /// How far back to look.
    @Published var days: Int { didSet { d.set(days, forKey: "recentsDays") } }
    @Published var kinds: RecentsKinds { didSet { d.set(kinds.rawValue, forKey: "recentsKinds") } }
    @Published var includeSubfolders: Bool { didSet { d.set(includeSubfolders, forKey: "recentsIncludeSubfolders") } }
    @Published var limit: Int { didSet { d.set(limit, forKey: "recentsLimit") } }
    /// The prompt field with "Improve with Claude" next to the files.
    @Published var showPrompt: Bool { didSet { d.set(showPrompt, forKey: "recentsShowPrompt") } }
    /// A site the link button opens, e.g. where the user makes generations; empty hides the button.
    @Published var linkURL: String { didSet { d.set(linkURL, forKey: "recentsLinkURL") } }

    private init() {
        d.register(defaults: [
            "recentsDays": 14,
            "recentsKinds": RecentsKinds.all.rawValue,
            "recentsIncludeSubfolders": true,
            "recentsLimit": 40,
            "recentsShowPrompt": true,
            "recentsLinkURL": Self.defaultLinkURL,
        ])
        days = d.integer(forKey: "recentsDays")
        kinds = RecentsKinds(rawValue: d.string(forKey: "recentsKinds") ?? "") ?? .all
        includeSubfolders = d.bool(forKey: "recentsIncludeSubfolders")
        limit = d.integer(forKey: "recentsLimit")
        showPrompt = d.bool(forKey: "recentsShowPrompt")
        linkURL = d.string(forKey: "recentsLinkURL") ?? Self.defaultLinkURL
    }

    /// The link as a web address, or nil when it's empty or not http(s).
    var link: URL? { Self.webURL(from: linkURL) }

    /// Accepts "example.com" as well as a full address.
    nonisolated static func webURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let full = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: full), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host, host.contains(".") else { return nil }
        return url
    }

    /// "Last 2 weeks" and the like, for the period menu and the tab header.
    static func periodTitle(days: Int) -> String {
        switch days {
        case 1: return String(localized: "recents.period.day", defaultValue: "Last 24 hours")
        case 3: return String(localized: "recents.period.3days", defaultValue: "Last 3 days")
        case 7: return String(localized: "recents.period.week", defaultValue: "Last week")
        case 30: return String(localized: "recents.period.month", defaultValue: "Last month")
        default: return String(localized: "recents.period.2weeks", defaultValue: "Last 2 weeks")
        }
    }
}
