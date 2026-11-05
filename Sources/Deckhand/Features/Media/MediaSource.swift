import Foundation

/// An app Deckhand can tell is playing. Each one is a source the user can turn off in Settings → Music.
enum MediaApp: String, CaseIterable, Identifiable, Sendable {
    case music, spotify, yandexMusic, safari, chrome, edge

    var id: String { rawValue }

    enum Kind: Sendable { case player, yandexApp, browser }

    var kind: Kind {
        switch self {
        case .music, .spotify: return .player
        case .yandexMusic: return .yandexApp
        case .safari, .chrome, .edge: return .browser
        }
    }

    /// The bundle identifier Apple Events and permission checks go to.
    var bundleID: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        case .yandexMusic: return "ru.yandex.desktop.music"
        case .safari: return "com.apple.Safari"
        case .chrome: return "com.google.Chrome"
        case .edge: return "com.microsoft.edgemac"
        }
    }

    var displayName: String {
        switch self {
        case .music: return "Apple Music"
        case .spotify: return "Spotify"
        case .yandexMusic: return String(localized: "Yandex Music")
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        case .edge: return "Microsoft Edge"
        }
    }

    /// Sends Apple Events for the track, artwork and controls (Automation permission).
    var usesAppleEvents: Bool { kind != .yandexApp }

    /// The app a bundle identifier belongs to. Helper processes (`com.microsoft.edgemac.helper`,
    /// `com.google.Chrome.helper.renderer`) belong to the app whose identifier they extend.
    /// Safari plays sound through WebKit's shared GPU process, which has no app of its own.
    static func owner(ofBundleID id: String) -> MediaApp? {
        if id.hasPrefix("com.apple.WebKit.") || id.hasPrefix("com.apple.Safari.") { return .safari }
        for app in allCases where id == app.bundleID || id.hasPrefix(app.bundleID + ".") {
            return app
        }
        // The Yandex Music app has shipped under more than one identifier; its browser must not match.
        let lower = id.lowercased()
        if lower.contains("yandex"), lower.contains("music"), !lower.contains("browser") { return .yandexMusic }
        return nil
    }

    /// The outermost `.app` bundle in an executable path, so a helper buried inside
    /// `Foo.app/Contents/Frameworks/Foo Helper.app` maps back to `Foo.app`.
    static func outermostAppPath(in path: String) -> String? {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            parts.append(part)
            if part.hasSuffix(".app") { return "/" + parts.joined(separator: "/") }
        }
        return nil
    }
}

/// A music site in a browser tab.
enum MediaSite: String, CaseIterable, Sendable {
    case yandexMusic, youtubeMusic, soundcloud, vk, youtube

    var displayName: String {
        switch self {
        case .yandexMusic: return String(localized: "Yandex Music")
        case .youtubeMusic: return "YouTube Music"
        case .soundcloud: return "SoundCloud"
        case .vk: return String(localized: "VK Music")
        case .youtube: return "YouTube"
        }
    }

    /// Music sites win over YouTube videos when several tabs could be playing.
    var priority: Int { self == .youtube ? 0 : 1 }

    /// The site a tab URL belongs to, or nil for pages that aren't music players.
    static func from(url: String) -> MediaSite? {
        guard let comps = URLComponents(string: url), let host = comps.host?.lowercased() else { return nil }
        let path = comps.path.lowercased()
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if host.hasPrefix("music.yandex.") || host.hasPrefix("next.music.yandex.") { return .yandexMusic }
        if on("music.youtube.com") { return .youtubeMusic }
        if on("youtube.com") || on("youtu.be") {
            return path.hasPrefix("/watch") || path.hasPrefix("/shorts") || path.hasPrefix("/live") || on("youtu.be")
                ? .youtube : nil
        }
        if on("soundcloud.com") { return .soundcloud }
        if on("vk.com") || on("vk.ru") {
            return path.hasPrefix("/audio") || path.hasPrefix("/music") ? .vk : nil
        }
        return nil
    }
}

/// What is playing in one source.
struct NowPlaying: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String = ""
    var isPlaying: Bool
    var app: MediaApp?
    var site: MediaSite?
    /// Seconds; nil for live streams and sources that don't say.
    var duration: Double?
    /// Seconds at `positionDate`.
    var position: Double?
    var positionDate: Date?

    static let empty = NowPlaying(title: "", artist: "", isPlaying: false)

    /// The source as people know it: the site for a browser tab, else the app.
    var source: String { site?.displayName ?? app?.displayName ?? "" }

    /// "YouTube Music · Microsoft Edge" for a tab, "Spotify" for an app.
    var sourceDetail: String {
        guard let app else { return source }
        guard let site else { return app.displayName }
        return "\(site.displayName) · \(app.displayName)"
    }

    /// The line shown at the notch: the track and artist, or the player's name when the track is unknown.
    var badgeText: String {
        if title.isEmpty { return app?.kind == .browser ? "" : source }
        return artist.isEmpty ? title : "\(title) · \(artist)"
    }

    /// Worth showing at all: a known track, or a music app that is clearly the player.
    var isDisplayable: Bool { !badgeText.isEmpty }

    /// Playback position now, extrapolated from the last report while playing.
    func position(at date: Date) -> Double? {
        guard let position else { return nil }
        guard isPlaying, let positionDate else { return position }
        let value = position + date.timeIntervalSince(positionDate)
        if let duration { return min(max(value, 0), duration) }
        return max(value, 0)
    }
}

extension NowPlaying {
    /// For the snapshot runner and older callers that name the source as text.
    init(title: String, artist: String, isPlaying: Bool, source: String) {
        let app = MediaApp.allCases.first { $0.displayName == source || $0.rawValue == source }
        let site = MediaSite.allCases.first { $0.displayName == source || $0.rawValue == source }
        self.init(title: title, artist: artist, isPlaying: isPlaying, app: app ?? (site == nil ? nil : .safari), site: site)
    }
}

/// Turns window and tab titles into a track and artist. Pure, so the self-test covers it.
enum TrackTitle {
    /// Splits "Track — Artist" (any dash with spaces around it) after removing the site's suffix.
    static func parse(_ raw: String, site: MediaSite?) -> (title: String, artist: String)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = stripPlayingMarks(text)
        switch site {
        case .youtube:
            // "(3) Video - YouTube": the count of notifications goes, and video titles stay whole
            // because there is no reliable artist in them.
            if let match = text.range(of: #"^\(\d+\+?\)\s*"#, options: .regularExpression) { text.removeSubrange(match) }
            text = strip(text, suffixes: [" - YouTube"])
            return text.isEmpty ? nil : (text, "")
        case .soundcloud:
            text = strip(text, suffixes: [" | Listen online for free on SoundCloud", " | SoundCloud"])
            if text.hasPrefix("Stream ") { text.removeFirst("Stream ".count) }
            if let by = text.range(of: " by ", options: .backwards) {
                let title = String(text[..<by.lowerBound]), artist = String(text[by.upperBound...])
                if !title.isEmpty, !artist.isEmpty { return (title, artist) }
            }
            return text.isEmpty ? nil : (text, "")
        case .youtubeMusic:
            text = strip(text, suffixes: [" - YouTube Music"])
            if text == "YouTube Music" { return nil }
        case .yandexMusic, nil:
            text = strip(text, suffixes: yandexSuffixes)
            if yandexNames.contains(text) { return nil }
        case .vk:
            text = strip(text, suffixes: [" | VK", " | ВКонтакте", " — VK Музыка"])
            if ["VK", "ВКонтакте", "Музыка", "VK Музыка", "Music"].contains(text) { return nil }
        }
        guard !text.isEmpty else { return nil }
        for separator in [" — ", " – ", " - ", " • "] {
            if let range = text.range(of: separator) {
                let title = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let artist = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty, !artist.isEmpty { return (title, artist) }
            }
        }
        return (text, "")
    }

    private static let yandexSuffixes = [" — Яндекс Музыка", " — Яндекс.Музыка", " — Yandex Music", " - Yandex Music",
                                         " — Яндекс Музыка — собираем музыку и подкасты для вас"]
    private static let yandexNames: Set<String> = ["Яндекс Музыка", "Яндекс.Музыка", "Yandex Music",
                                                  "Яндекс Музыка — собираем музыку и подкасты для вас"]

    private static func stripPlayingMarks(_ text: String) -> String {
        var text = text
        for mark in ["▶︎ ", "▶ ", "► ", "🔊 "] where text.hasPrefix(mark) { text.removeFirst(mark.count) }
        return text
    }

    private static func strip(_ text: String, suffixes: [String]) -> String {
        for suffix in suffixes.sorted(by: { $0.count > $1.count }) where text.hasSuffix(suffix) {
            return String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }
}

/// One browser tab as the browser reported it.
struct BrowserTab: Equatable, Sendable {
    var url: String
    var title: String
    var isActive: Bool

    /// Parses the script output: fields split by U+001F, tabs by U+001E.
    static func parseList(_ raw: String) -> [BrowserTab] {
        raw.split(separator: "\u{1E}", omittingEmptySubsequences: true).compactMap { record in
            let fields = record.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2 else { return nil }
            return BrowserTab(url: fields[0], title: fields[1], isActive: fields.count > 2 && fields[2] == "true")
        }
    }

    /// The tab that is most likely making the sound. A browser can't say which tab plays, so:
    /// the tab chosen last time if it is still open, then music sites over videos, then the active tab.
    static func pick(_ tabs: [BrowserTab], previousURL: String?) -> (tab: BrowserTab, site: MediaSite)? {
        let candidates = tabs.compactMap { tab in MediaSite.from(url: tab.url).map { (tab: tab, site: $0) } }
        if let previousURL, let same = candidates.first(where: { $0.tab.url == previousURL }) { return same }
        return candidates.max { a, b in
            if a.site.priority != b.site.priority { return a.site.priority < b.site.priority }
            return !a.tab.isActive && b.tab.isActive
        }
    }
}

/// Decisions about which source to show and for how long. Pure, so the self-test covers it.
enum NowPlayingRules {
    /// A source as the rules see it.
    struct Entry: Equatable {
        var app: MediaApp
        var isPlaying: Bool
        var isDisplayable: Bool
        /// When it last started playing.
        var startedAt: Date
        /// When it last stopped; nil while playing.
        var stoppedAt: Date?
    }

    /// Silence shorter than this is a gap between tracks or a seek, not a pause.
    static let silenceDebounce: TimeInterval = 1.5

    /// The source to show: the one that started playing most recently; if none plays,
    /// the one that stopped last. Sources with nothing to show come last.
    static func current(_ entries: [Entry]) -> MediaApp? {
        func rank(_ e: Entry) -> (Int, Int, Date) {
            (e.isDisplayable ? 1 : 0, e.isPlaying ? 1 : 0, e.isPlaying ? e.startedAt : (e.stoppedAt ?? e.startedAt))
        }
        return entries.max { rank($0) < rank($1) }?.app
    }

    /// The badge stays while playing and for `hideDelay` after a pause, so a short gap doesn't make it blink.
    static func showsBadge(isPlaying: Bool, stoppedAt: Date?, now: Date, hideDelay: TimeInterval) -> Bool {
        if isPlaying { return true }
        guard let stoppedAt else { return false }
        return now.timeIntervalSince(stoppedAt) < hideDelay
    }

    /// Playing state of a source known only from its audio output.
    /// Returns whether it plays and since when it has been silent (nil while sound comes out).
    static func audioState(wasPlaying: Bool, silentSince: Date?, outputting: Bool, now: Date)
        -> (isPlaying: Bool, silentSince: Date?) {
        if outputting { return (true, nil) }
        let since = silentSince ?? now
        let stillPlaying = wasPlaying && now.timeIntervalSince(since) < silenceDebounce
        return (stillPlaying, since)
    }
}
