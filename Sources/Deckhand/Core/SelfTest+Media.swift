import AppKit

extension SelfTest {
    /// Now playing. Owned by the media workstream. Pure logic only: no Apple Events, no CoreAudio.
    static func media(_ check: Check) {
        mediaSources(check)
        mediaTitles(check)
        mediaRules(check)
        mediaReports(check)
    }

    private static func mediaSources(_ check: Check) {
        check(MediaApp.owner(ofBundleID: "com.microsoft.edgemac.helper") == .edge, "media: Edge helper maps to Edge")
        check(MediaApp.owner(ofBundleID: "com.microsoft.edgemac") == .edge, "media: Edge maps to Edge")
        check(MediaApp.owner(ofBundleID: "com.google.Chrome.helper.renderer") == .chrome, "media: Chrome helper maps to Chrome")
        check(MediaApp.owner(ofBundleID: "com.apple.WebKit.GPU") == .safari, "media: WebKit GPU maps to Safari")
        check(MediaApp.owner(ofBundleID: "com.spotify.client.helper") == .spotify, "media: Spotify helper maps to Spotify")
        check(MediaApp.owner(ofBundleID: "com.apple.Music") == .music, "media: Music maps to Music")
        check(MediaApp.owner(ofBundleID: "ru.yandex.desktop.music") == .yandexMusic, "media: Yandex Music app")
        check(MediaApp.owner(ofBundleID: "ru.yandex.desktop.yandex-browser") == nil, "media: Yandex Browser is not Yandex Music")
        check(MediaApp.owner(ofBundleID: "com.microsoft.edgemacx") == nil, "media: a lookalike identifier doesn't match")
        check(MediaApp.owner(ofBundleID: "com.apple.MusicRecognition") == nil, "media: prefix without a dot doesn't match")
        check(MediaApp.outermostAppPath(in: "/Applications/Yandex Music.app/Contents/Frameworks/Yandex Music Helper.app/Contents/MacOS/Yandex Music Helper")
              == "/Applications/Yandex Music.app", "media: helper path maps to the outer app")
        check(MediaApp.outermostAppPath(in: "/usr/libexec/coreaudiod") == nil, "media: a path outside an app has no app")

        check(MediaSite.from(url: "https://music.yandex.ru/album/1/track/2") == .yandexMusic, "media: site Yandex Music")
        check(MediaSite.from(url: "https://music.youtube.com/watch?v=x") == .youtubeMusic, "media: site YouTube Music")
        check(MediaSite.from(url: "https://www.youtube.com/watch?v=x") == .youtube, "media: site YouTube video")
        check(MediaSite.from(url: "https://www.youtube.com/") == nil, "media: YouTube home page is not a player")
        check(MediaSite.from(url: "https://soundcloud.com/a/b") == .soundcloud, "media: site SoundCloud")
        check(MediaSite.from(url: "https://vk.com/audios1") == .vk, "media: site VK audio")
        check(MediaSite.from(url: "https://vk.com/feed") == nil, "media: VK feed is not a player")
        check(MediaSite.from(url: "https://evil.com/music.yandex.ru") == nil, "media: site match uses the host, not the path")

        let tabs = [
            BrowserTab(url: "https://mail.google.com", title: "Inbox", isActive: true),
            BrowserTab(url: "https://www.youtube.com/watch?v=1", title: "Video - YouTube", isActive: false),
            BrowserTab(url: "https://music.yandex.ru/home", title: "Song — Band", isActive: false),
        ]
        check(BrowserTab.pick(tabs, previousURL: nil)?.site == .yandexMusic, "media: music site beats a video tab")
        check(BrowserTab.pick(tabs, previousURL: "https://www.youtube.com/watch?v=1")?.site == .youtube,
              "media: the tab picked last time stays picked")
        check(BrowserTab.pick(Array(tabs.prefix(1)), previousURL: nil) == nil, "media: no music tab, no pick")
        let parsed = BrowserTab.parseList("https://a\u{1F}A\u{1F}true\u{1E}https://b\u{1F}B\u{1F}false\u{1E}")
        check(parsed.count == 2 && parsed[0].isActive && !parsed[1].isActive && parsed[1].title == "B",
              "media: tab list parsing")
    }

    private static func mediaTitles(_ check: Check) {
        func same(_ raw: String, _ site: MediaSite?, _ title: String, _ artist: String) -> Bool {
            guard let p = TrackTitle.parse(raw, site: site) else { return false }
            return p.title == title && p.artist == artist
        }
        check(same("Midnight City — M83 — Яндекс Музыка", .yandexMusic, "Midnight City", "M83"), "media: Yandex title")
        check(TrackTitle.parse("Яндекс Музыка", site: .yandexMusic) == nil, "media: Yandex idle title is no track")
        check(same("(3) Lofi beats - live radio - YouTube", .youtube, "Lofi beats - live radio", ""),
              "media: YouTube title stays whole, without the count")
        check(same("Song - Artist - YouTube Music", .youtubeMusic, "Song", "Artist"), "media: YouTube Music title")
        check(same("Stream Stand by Me by Ben E. King | Listen online for free on SoundCloud", .soundcloud,
                   "Stand by Me", "Ben E. King"), "media: SoundCloud title, last \"by\" splits")
        check(same("▶ Track – Artist", nil, "Track", "Artist"), "media: play mark and en dash")
        check(TrackTitle.parse("   ", site: nil) == nil, "media: empty title")
        check(NowPlaying(title: "", artist: "", isPlaying: true, app: .edge).isDisplayable == false,
              "media: a browser without a known track shows nothing")
        check(NowPlaying(title: "", artist: "", isPlaying: true, app: .spotify).badgeText == "Spotify",
              "media: a player without a track shows its name")
        let old = NowPlaying(title: "Midnight City", artist: "M83", isPlaying: true, source: "Apple Music")
        check(old.app == .music && old.badgeText == "Midnight City · M83", "media: source-name initializer")
    }

    private static func mediaRules(_ check: Check) {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        typealias Entry = NowPlayingRules.Entry
        let music = Entry(app: .music, isPlaying: true, isDisplayable: true, startedAt: t0, stoppedAt: nil)
        let edge = Entry(app: .edge, isPlaying: true, isDisplayable: true, startedAt: t0 + 5, stoppedAt: nil)
        check(NowPlayingRules.current([music, edge]) == .edge, "media: newest playing source wins")
        var pausedEdge = edge; pausedEdge.isPlaying = false; pausedEdge.stoppedAt = t0 + 9
        check(NowPlayingRules.current([music, pausedEdge]) == .music, "media: playing beats paused")
        var pausedMusic = music; pausedMusic.isPlaying = false; pausedMusic.stoppedAt = t0 + 2
        check(NowPlayingRules.current([pausedMusic, pausedEdge]) == .edge, "media: if none plays, the last to stop")
        var unknown = edge; unknown.isDisplayable = false; unknown.startedAt = t0 + 20
        check(NowPlayingRules.current([music, unknown]) == .music, "media: a source with nothing to show comes last")
        check(NowPlayingRules.current([]) == nil, "media: no sources")

        check(NowPlayingRules.showsBadge(isPlaying: true, stoppedAt: nil, now: t0, hideDelay: 2), "media: badge while playing")
        check(NowPlayingRules.showsBadge(isPlaying: false, stoppedAt: t0, now: t0 + 1.9, hideDelay: 2), "media: badge in grace")
        check(!NowPlayingRules.showsBadge(isPlaying: false, stoppedAt: t0, now: t0 + 2.1, hideDelay: 2),
              "media: badge hides after grace")
        check(!NowPlayingRules.showsBadge(isPlaying: false, stoppedAt: .distantPast, now: t0, hideDelay: 60),
              "media: found paused, no badge")

        let first = NowPlayingRules.audioState(wasPlaying: true, silentSince: nil, outputting: false, now: t0)
        check(first.isPlaying && first.silentSince == t0, "media: one silent poll is not a pause")
        let second = NowPlayingRules.audioState(wasPlaying: true, silentSince: t0, outputting: false, now: t0 + 1.6)
        check(!second.isPlaying && second.silentSince == t0, "media: sustained silence is a pause")
        let back = NowPlayingRules.audioState(wasPlaying: true, silentSince: t0, outputting: true, now: t0 + 1)
        check(back.isPlaying && back.silentSince == nil, "media: sound again clears the silence")
        let idle = NowPlayingRules.audioState(wasPlaying: false, silentSince: nil, outputting: false, now: t0)
        check(!idle.isPlaying, "media: silent and not playing stays paused")
    }

    private static func mediaReports(_ check: Check) {
        let date = Date(timeIntervalSinceReferenceDate: 500)
        let music = PlayerReport.parse(["Player State": "Paused", "Name": "Song", "Artist": "Band",
                                        "Total Time": NSNumber(value: 215_000), "PersistentID": NSNumber(value: 42)],
                                       app: .music, at: date)
        check(music?.state == .paused && music?.track.duration == 215 && music?.track.isPlaying == false
              && music?.key == "42", "media: Music notification")
        let spotify = PlayerReport.parse(["Player State": "Playing", "Name": "Song", "Artist": "Band",
                                          "Duration": NSNumber(value: 180_000), "Playback Position": NSNumber(value: 30.5),
                                          "Track ID": "spotify:track:1"], app: .spotify, at: date)
        check(spotify?.state == .playing && spotify?.track.position == 30.5 && spotify?.track.duration == 180,
              "media: Spotify notification")
        check(spotify?.track.position(at: date + 10) == 40.5, "media: position runs on while playing")
        check(PlayerReport.parse(["Name": "x"], app: .music, at: date) == nil, "media: notification without a state")
        let script = PlayerReport.parseScript("playing\u{1F}Song\u{1F}Band\u{1F}Album\u{1F}215,5\u{1F}12,25\u{1F}ABC",
                                              app: .music, at: date)
        check(script?.track.duration == 215.5 && script?.track.position == 12.25 && script?.key == "ABC",
              "media: script answer with a decimal comma")
        check(PlayerReport.parseScript("stopped", app: .music, at: date)?.state == .stopped, "media: stopped player")
    }
}
