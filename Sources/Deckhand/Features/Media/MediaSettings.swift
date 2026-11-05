import Foundation
import Combine

/// Now playing settings, shown in Settings → Music. The badge switch itself is
/// `Settings.showPlayingInNotch`, shown in Settings → Closed Notch.
@MainActor
final class MediaSettings: ObservableObject {
    static let shared = MediaSettings()
    private let d = UserDefaults.standard

    /// Master switch. Off means no audio checks, no Apple Events and no badge.
    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "nowPlayingEnabled") } }
    /// Sources the user turned off. Stored as the turned-off set so sources added later start on.
    @Published var disabledSources: [String] { didSet { d.set(disabledSources, forKey: "nowPlayingDisabledSources") } }
    /// Seconds the badge stays after playback pauses.
    @Published var hideDelay: Double { didSet { d.set(hideDelay, forKey: "nowPlayingHideDelay") } }
    /// Album artwork from Apple Music and Spotify in the Music tab.
    @Published var showArtwork: Bool { didSet { d.set(showArtwork, forKey: "nowPlayingArtwork") } }

    static let hideDelays: [Double] = [2, 5, 15, 60]

    private init() {
        d.register(defaults: [
            "nowPlayingEnabled": true,
            "nowPlayingDisabledSources": [String](),
            "nowPlayingHideDelay": 2.0,
            "nowPlayingArtwork": true,
        ])
        enabled = d.bool(forKey: "nowPlayingEnabled")
        disabledSources = d.stringArray(forKey: "nowPlayingDisabledSources") ?? []
        hideDelay = d.double(forKey: "nowPlayingHideDelay")
        showArtwork = d.bool(forKey: "nowPlayingArtwork")
    }

    func isOn(_ app: MediaApp) -> Bool { !disabledSources.contains(app.rawValue) }

    func set(_ app: MediaApp, on: Bool) {
        var set = Set(disabledSources)
        if on { set.remove(app.rawValue) } else { set.insert(app.rawValue) }
        disabledSources = MediaApp.allCases.map(\.rawValue).filter(set.contains)
    }

    var enabledApps: Set<MediaApp> { Set(MediaApp.allCases.filter(isOn)) }
}
