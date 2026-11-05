import AppKit
import ApplicationServices

/// What a player said about itself, from its notification or a one-off script.
struct PlayerReport: Equatable, Sendable {
    enum State: Sendable { case playing, paused, stopped }
    var state: State
    var track: NowPlaying
    /// Identifies the track, so artwork is fetched once per track.
    var key: String
    /// Spotify only: where its artwork lives.
    var artworkURL: String?

    /// Parses `com.apple.Music.playerInfo` and `com.spotify.client.PlaybackStateChanged`.
    /// Music gives "Total Time" in milliseconds and no position; Spotify gives "Duration" in milliseconds
    /// and "Playback Position" in seconds.
    static func parse(_ info: [String: Any], app: MediaApp, at date: Date) -> PlayerReport? {
        guard let raw = info["Player State"] as? String else { return nil }
        let state: State
        switch raw.lowercased() {
        case "playing": state = .playing
        case "paused": state = .paused
        default: state = .stopped
        }
        var title = (info["Name"] as? String) ?? ""
        let artist = (info["Artist"] as? String) ?? ""
        // Radio in Music: the station is the name and the song is the stream title
        if let stream = info["Stream Title"] as? String, !stream.isEmpty { title = stream }
        let millis = number(info["Total Time"]) ?? number(info["Duration"])
        let duration = millis.flatMap { $0 > 0 ? $0 / 1000 : nil }
        let position = number(info["Playback Position"])
        let key = (info["PersistentID"].map { "\($0)" }) ?? (info["Track ID"] as? String) ?? "\(title)|\(artist)"
        let track = NowPlaying(title: title, artist: artist, album: (info["Album"] as? String) ?? "",
                               isPlaying: state == .playing, app: app, duration: duration,
                               position: position, positionDate: position == nil ? nil : date)
        return PlayerReport(state: state, track: track, key: key, artworkURL: nil)
    }

    /// Parses the field list the details scripts below return: state, name, artist, album,
    /// duration (seconds), position (seconds), track id, artwork URL.
    static func parseScript(_ raw: String, app: MediaApp, at date: Date) -> PlayerReport? {
        let fields = raw.components(separatedBy: "\u{1F}")
        guard let first = fields.first, !first.isEmpty else { return nil }
        let state: State = first == "playing" ? .playing : first == "paused" ? .paused : .stopped
        guard state != .stopped, fields.count >= 7 else {
            return PlayerReport(state: .stopped, track: NowPlaying(title: "", artist: "", isPlaying: false, app: app), key: "")
        }
        var duration = decimal(fields[4])
        // Spotify reports milliseconds
        if app == .spotify, let ms = duration { duration = ms / 1000 }
        let position = decimal(fields[5])
        let track = NowPlaying(title: fields[1], artist: fields[2], album: fields[3], isPlaying: state == .playing,
                               app: app, duration: duration.flatMap { $0 > 0 ? $0 : nil },
                               position: position, positionDate: position == nil ? nil : date)
        let url = fields.count > 7 && fields[7].hasPrefix("http") ? fields[7] : nil
        return PlayerReport(state: state, track: track, key: fields[6].isEmpty ? "\(fields[1])|\(fields[2])" : fields[6],
                            artworkURL: url)
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return decimal(s)
        default: return nil
        }
    }

    /// AppleScript writes reals with the system's decimal separator.
    private static func decimal(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }
}

/// The Apple Events Deckhand sends to players and browsers, all through `AppleScriptRunner`
/// (one queue, 2-second timeout). Every script checks that the app is running first, so a
/// script never launches or relaunches an app that is quitting.
enum MediaScripts {
    private static let separator = "(character id 31)"

    /// Every tab of every window in one go: URL, title, and whether it is the window's active tab.
    static func browserTabs(_ app: MediaApp) async -> Result<[BrowserTab], AppleScriptRunner.Failure> {
        let titleProperty = app == .safari ? "name" : "title"
        let activeIndex = app == .safari ? "index of current tab of every window" : "active tab index of every window"
        let script = """
        if application id "\(app.bundleID)" is running then
            tell application id "\(app.bundleID)"
                set theURLs to URL of every tab of every window
                set theTitles to \(titleProperty) of every tab of every window
                set theActive to {}
                try
                    set theActive to \(activeIndex)
                end try
            end tell
            set out to ""
            repeat with w from 1 to count of theURLs
                set us to item w of theURLs
                set ts to item w of theTitles
                set a to 0
                if (count of theActive) ≥ w then set a to item w of theActive
                repeat with i from 1 to count of us
                    set out to out & (item i of us as text) & \(separator) & (item i of ts as text) & \(separator) & ((i = a) as text) & (character id 30)
                end repeat
            end repeat
            return out
        end if
        return ""
        """
        return await AppleScriptRunner.shared.run(script, timeout: 2).map { BrowserTab.parseList($0 ?? "") }
    }

    /// The current track of Music or Spotify, for when playback started before Deckhand did
    /// and for the position, which Music's notification leaves out.
    static func playerDetails(_ app: MediaApp) async -> PlayerReport? {
        guard app.kind == .player else { return nil }
        let extra = app == .spotify ? "(id of t) & \(separator) & (artwork url of t)" : "(persistent ID of t)"
        let script = """
        if application id "\(app.bundleID)" is running then
            tell application id "\(app.bundleID)"
                set s to player state as text
                if s is "stopped" then return s
                set t to current track
                return s & \(separator) & (name of t) & \(separator) & (artist of t) & \(separator) & (album of t) & \(separator) & ((duration of t) as text) & \(separator) & ((player position) as text) & \(separator) & \(extra)
            end tell
        end if
        return ""
        """
        guard case .success(let raw?) = await AppleScriptRunner.shared.run(script, timeout: 2) else { return nil }
        return PlayerReport.parseScript(raw, app: app, at: Date())
    }

    /// Apple Music's artwork for the current track, as image data.
    static func musicArtwork() async -> Data? {
        let script = """
        if application id "com.apple.Music" is running then
            tell application id "com.apple.Music"
                if (count of artworks of current track) > 0 then return raw data of artwork 1 of current track
            end tell
        end if
        return ""
        """
        guard case .success(let descriptor) = await AppleScriptRunner.shared.runDescriptor(script, timeout: 3) else { return nil }
        let data = descriptor.data
        return data.count > 16 ? data : nil
    }

    enum Command: Sendable { case playPause, next, previous }

    /// Controls Music or Spotify directly, without media keys or Accessibility.
    static func send(_ command: Command, to app: MediaApp) async -> Result<Void, AppleScriptRunner.Failure> {
        let verb: String
        switch command {
        case .playPause: verb = "playpause"
        case .next: verb = "next track"
        // Music's "back track" acts like its button: restart the song, or go back near its start
        case .previous: verb = app == .music ? "back track" : "previous track"
        }
        let script = """
        if application id "\(app.bundleID)" is running then
            tell application id "\(app.bundleID)" to \(verb)
        end if
        """
        return await AppleScriptRunner.shared.run(script, timeout: 2).map { _ in () }
    }
}

/// The Yandex Music app has no scripting dictionary; its window title shows the track.
/// Read through Accessibility by process ID, off the main thread, with a short timeout.
enum YandexMusicWindow {
    private static let queue = DispatchQueue(label: "deckhand.yandex-title", qos: .utility)

    static func title(pid: pid_t) async -> String? {
        guard AXIsProcessTrusted() else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 1.0)
                var window: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &window) == .success
                        || AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
                      let window, CFGetTypeID(window) == AXUIElementGetTypeID() else {
                    continuation.resume(returning: nil)
                    return
                }
                var title: CFTypeRef?
                AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
                continuation.resume(returning: title as? String)
            }
        }
    }
}
