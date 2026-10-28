import Foundation
import AppKit

/// What is playing now. macOS has no public API for now playing in any app,
/// so known sources are queried with AppleScript. Controls (play, next, previous)
/// use system media keys and work with any player.
struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var isPlaying: Bool
    var source: String

    static let empty = NowPlaying(title: "", artist: "", isPlaying: false, source: "")
}

/// Not tied to the main actor: AppleScript calls can take a while and must not block the UI.
final class MediaInfoService: @unchecked Sendable {
    static let shared = MediaInfoService()
    private init() {}

    func currentNowPlaying() -> NowPlaying {
        fromPlayer(bundleId: "com.apple.Music", app: "Music", source: "Apple Music")
            ?? fromPlayer(bundleId: "com.spotify.client", app: "Spotify", source: "Spotify")
            ?? fromYandexApp()
            ?? fromBrowsers()
            ?? .empty
    }

    // MARK: - helpers

    private func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error { Log.info("applescript error: \(error)") ; return nil }
        return result.stringValue
    }

    private func running(_ bundleId: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleId }
    }

    // MARK: - sources

    private func fromPlayer(bundleId: String, app: String, source: String) -> NowPlaying? {
        guard running(bundleId) != nil else { return nil }
        let script = """
        tell application "\(app)"
            if player state is playing or player state is paused then
                return (name of current track) & "|||" & (artist of current track) & "|||" & (player state as text)
            end if
            return ""
        end tell
        """
        guard let raw = run(script), !raw.isEmpty else { return nil }
        let p = raw.components(separatedBy: "|||")
        guard p.count == 3 else { return nil }
        return NowPlaying(title: p[0], artist: p[1], isPlaying: p[2] == "playing", source: source)
    }

    private func fromYandexApp() -> NowPlaying? {
        let app = NSWorkspace.shared.runningApplications.first {
            ($0.bundleIdentifier ?? "").lowercased().contains("yandex") && ($0.localizedName ?? "").lowercased().contains("муз")
                || ($0.bundleIdentifier ?? "").lowercased().contains("yandex.music")
        }
        guard let app, let name = app.localizedName else { return nil }
        let script = """
        tell application "System Events"
            tell process "\(name)"
                if exists front window then return name of front window
            end tell
        end tell
        return ""
        """
        let title = run(script) ?? ""
        return parseTitle(title, source: "Yandex Music", fallbackPlaying: true)
            ?? NowPlaying(title: "", artist: "", isPlaying: false, source: "Yandex Music")
    }

    /// Looks for a music tab in Safari, Edge and Chrome.
    private func fromBrowsers() -> NowPlaying? {
        let markers = ["music.yandex", "music.youtube.com", "youtube.com/watch", "soundcloud.com", "vk.com/audio"]
        let condition = markers.map { "u contains \"\($0)\"" }.joined(separator: " or ")

        let chromium: [(String, String)] = [
            ("com.microsoft.edgemac", "Microsoft Edge"),
            ("com.google.Chrome", "Google Chrome"),
        ]
        for (bundle, app) in chromium where running(bundle) != nil {
            let script = """
            tell application "\(app)"
                repeat with w in windows
                    repeat with t in tabs of w
                        set u to URL of t as string
                        if \(condition) then return (title of t as string) & "|||" & u
                    end repeat
                end repeat
            end tell
            return ""
            """
            if let found = browserResult(run(script)) { return found }
        }

        if running("com.apple.Safari") != nil {
            let script = """
            tell application "Safari"
                repeat with w in windows
                    repeat with t in tabs of w
                        set u to URL of t as string
                        if \(condition) then return (name of t as string) & "|||" & u
                    end repeat
                end repeat
            end tell
            return ""
            """
            if let found = browserResult(run(script)) { return found }
        }
        return nil
    }

    private func browserResult(_ raw: String?) -> NowPlaying? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "|||")
        guard parts.count == 2 else { return nil }
        var title = parts[0]
        let url = parts[1]
        let source: String
        if url.contains("music.yandex") { source = "Yandex Music" }
        else if url.contains("music.youtube") { source = "YouTube Music" }
        else if url.contains("soundcloud") { source = "SoundCloud" }
        else if url.contains("vk.com") { source = "VK Music" }
        else { source = "YouTube" }
        for suffix in [" - YouTube Music", " - YouTube", " — Яндекс Музыка", " — Яндекс.Музыка", " | SoundCloud"] {
            if title.hasSuffix(suffix) { title = String(title.dropLast(suffix.count)) }
        }
        return parseTitle(title, source: source, fallbackPlaying: true)
    }

    /// "Track — Artist" or "Track - Artist".
    private func parseTitle(_ raw: String, source: String, fallbackPlaying: Bool) -> NowPlaying? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        for sep in [" — ", " - ", " – "] {
            let parts = trimmed.components(separatedBy: sep)
            if parts.count >= 2 {
                return NowPlaying(title: parts[0], artist: parts[1...].joined(separator: sep),
                                  isPlaying: fallbackPlaying, source: source)
            }
        }
        return NowPlaying(title: trimmed, artist: "", isPlaying: fallbackPlaying, source: source)
    }
}
