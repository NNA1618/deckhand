import AppKit

extension SelfTest {
    /// Now playing. Owned by the media workstream. Pure logic only: no Apple Events, no CoreAudio.
    static func media(_ check: Check) {
        mediaSources(check)
        mediaTitles(check)
        mediaRules(check)
        mediaReports(check)
        mediaAdapterLines(check)
        mediaSystemTrack(check)
        mediaAdapterRestarts(check)
        mediaFeed(check)
        mediaBundledAdapter(check)
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

    // MARK: - System Now Playing

    private static func line(_ text: String) -> AdapterLine? { AdapterLine.parse(Data(text.utf8)) }

    private static func mediaAdapterLines(_ check: Check) {
        check(line(#"{"type":"hello","version":1}"#) == .hello(version: 1), "media: adapter hello line")
        check(line(#"{"type":"state","active":false}"#) == .idle, "media: adapter idle line")
        check(line(#"{"type":"error","message":"dlopen failed"}"#) == .error("dlopen failed"), "media: adapter error line")
        check(line("not json") == nil && line(#"{"active":true}"#) == nil && line(#"{"type":"later"}"#) == nil,
              "media: lines the adapter doesn't write are ignored")
        let full = line(#"{"type":"state","active":true,"playing":true,"title":"Song","artist":"Band","album":"LP","#
                        + #""duration":215.5,"elapsed":12,"rate":1,"timestamp":1700000000.5,"bundle":"com.spotify.client","#
                        + #""artwork":"AQID"}"#)
        if case .track(let track, let artwork)? = full {
            check(track.title == "Song" && track.artist == "Band" && track.album == "LP" && track.isPlaying
                  && track.duration == 215.5 && track.elapsed == 12 && track.rate == 1
                  && track.timestamp == Date(timeIntervalSince1970: 1_700_000_000.5) && track.bundleID == "com.spotify.client",
                  "media: adapter track line")
            check(artwork == .image(Data([1, 2, 3])), "media: adapter artwork is base64")
        } else {
            check(false, "media: adapter track line")
        }
        let paused = line(#"{"type":"state","active":true,"playing":false,"title":"Song","bundle":"com.apple.podcasts"}"#)
        if case .track(let track, let artwork)? = paused {
            check(!track.isPlaying && track.duration == nil && track.elapsed == nil && artwork == .unchanged,
                  "media: adapter line without artwork keeps the last one")
        } else {
            check(false, "media: adapter line without artwork keeps the last one")
        }
        if case .track(_, let artwork)? = line(#"{"type":"state","active":true,"title":"x","artwork":""}"#) {
            check(artwork == .none, "media: empty artwork means the track has none")
        } else {
            check(false, "media: empty artwork means the track has none")
        }
        check(line(#"{"type":"state","active":true,"playing":true,"title":"  ","bundle":"com.example"}"#) == .idle,
              "media: a session without a title shows nothing")

        var buffer = LineBuffer()
        let first = buffer.append(Data("{\"a\":1}\n{\"b\"".utf8))
        let second = buffer.append(Data(":2}\n\n".utf8))
        check(first.map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#]
              && second.map { String(decoding: $0, as: UTF8.self) } == [#"{"b":2}"#, ""],
              "media: adapter output is split into lines across reads")
    }

    private static func mediaSystemTrack(_ check: Check) {
        let date = Date(timeIntervalSinceReferenceDate: 2000)
        var track = SystemTrack(title: "Episode", artist: "Host", album: "", isPlaying: true, duration: 0, elapsed: 30,
                                rate: 1, timestamp: date, bundleID: "com.apple.podcasts")
        check(track.app == .other, "media: an app without its own source is Other apps")
        let shown = track.nowPlaying(appName: "Podcasts")
        check(shown.source == "Podcasts" && shown.bundleID == "com.apple.podcasts" && shown.duration == nil
              && shown.position(at: date + 5) == 35 && shown.badgeText == "Episode · Host",
              "media: system track shows with the app's own name")
        track.bundleID = "com.spotify.client"
        check(track.app == .spotify && track.nowPlaying(appName: "Spotify").appName == nil, "media: Spotify via the system")
        track.bundleID = "com.google.Chrome"
        check(track.app == .chrome, "media: a browser via the system")
        track.bundleID = ""
        check(track.app == .other && track.nowPlaying(appName: nil).source == MediaApp.other.displayName,
              "media: a system track without an app")
        check(MediaApp.owner(ofBundleID: "") == nil && MediaApp.owner(ofBundleID: ".x") == nil,
              "media: Other apps never matches an identifier")

        // Paused means hidden: the badge goes when the pause delay ends
        let stopped = NowPlayingRules.stoppedAt(wasPlaying: true, isPlaying: false, stoppedAt: nil, now: date)
        check(stopped == date, "media: a pause is dated")
        check(NowPlayingRules.showsBadge(isPlaying: false, stoppedAt: stopped, now: date + 1, hideDelay: 2)
              && !NowPlayingRules.showsBadge(isPlaying: false, stoppedAt: stopped, now: date + 2.5, hideDelay: 2),
              "media: paused system track leaves the notch after the delay")
        let found = NowPlayingRules.stoppedAt(wasPlaying: nil, isPlaying: false, stoppedAt: nil, now: date)
        check(!NowPlayingRules.showsBadge(isPlaying: false, stoppedAt: found, now: date, hideDelay: 60),
              "media: a track found paused never shows at the notch")
        check(NowPlayingRules.stoppedAt(wasPlaying: false, isPlaying: false, stoppedAt: date - 10, now: date) == date - 10,
              "media: a second paused report keeps the pause time")
        check(NowPlayingRules.stoppedAt(wasPlaying: false, isPlaying: true, stoppedAt: date, now: date) == nil,
              "media: playing clears the pause")
        var paused = track
        paused.isPlaying = false
        check(paused.nowPlaying(appName: nil).isPlaying == false, "media: a paused system track is not playing")
    }

    /// A child process the test drives by hand.
    @MainActor
    private final class FakeAdapterProcess: AdapterProcess {
        var onLine: ((AdapterLine) -> Void)?
        var onExit: (() -> Void)?
        var sent: [String] = []
        var terminated = false
        var failsToStart = false

        func start(onLine: @escaping @MainActor (AdapterLine) -> Void, onExit: @escaping @MainActor () -> Void) throws {
            if failsToStart { throw CocoaError(.executableLoad) }
            self.onLine = onLine
            self.onExit = onExit
        }
        func send(_ command: String) { sent.append(command) }
        func terminate() { terminated = true }
        func die() { onExit?() }
    }

    private static func mediaAdapterRestarts(_ check: Check) {
        var processes: [FakeAdapterProcess] = []
        var timers: [(delay: TimeInterval, work: @MainActor () -> Void)] = []
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        var states: [MediaRemoteAdapter.State] = []
        let adapter = MediaRemoteAdapter(makeProcess: {
            let process = FakeAdapterProcess()
            processes.append(process)
            return process
        }, launchTimeout: 0.5, schedule: { delay, work in timers.append((delay, work)) }, now: { clock })
        adapter.onStateChange = { states.append($0) }
        var lines: [AdapterLine] = []
        adapter.onLine = { lines.append($0) }
        /// Runs the restart timer, the one that isn't the launch timeout.
        func runRestart() -> TimeInterval? {
            guard let index = timers.lastIndex(where: { $0.delay != 0.5 }) else { return nil }
            let timer = timers.remove(at: index)
            timer.work()
            return timer.delay
        }

        adapter.start()
        check(adapter.state == .launching && processes.count == 1, "media: adapter launches")
        processes[0].onLine?(.hello(version: 1))
        check(adapter.state == .running && lines == [.hello(version: 1)], "media: first line means running")
        adapter.send(.toggle)
        check(processes[0].sent == ["toggle"], "media: commands go to the adapter's stdin")

        clock += 2
        processes[0].die()
        check(adapter.state == .waitingToRestart, "media: a dead adapter waits to restart")
        check(runRestart() == 1 && processes.count == 2 && adapter.state == .launching, "media: first restart after 1 s")
        processes[1].die()
        check(runRestart() == 5 && processes.count == 3, "media: second restart after 5 s")
        processes[2].die()
        check(runRestart() == 20 && processes.count == 4, "media: third restart after 20 s")
        processes[3].die()
        check(adapter.state == .failed && runRestart() == nil, "media: gives up after three restarts")
        adapter.start()
        check(processes.count == 4, "media: a failed adapter stays off")

        // A long healthy run starts the count over
        processes.removeAll(); timers.removeAll(); states.removeAll()
        let healthy = MediaRemoteAdapter(makeProcess: {
            let process = FakeAdapterProcess()
            processes.append(process)
            return process
        }, launchTimeout: 0.5, schedule: { delay, work in timers.append((delay, work)) }, now: { clock })
        healthy.start()
        processes[0].die()
        _ = runRestart()
        processes[1].onLine?(.idle)
        clock += 3600
        processes[1].die()
        check(runRestart() == 1, "media: after an hour's run a death counts as the first")

        // Stopping on purpose is no failure
        healthy.start()
        processes.last?.onLine?(.idle)
        timers.removeAll()
        healthy.stop()
        check(healthy.state == .stopped && processes.last?.terminated == true, "media: stop ends the process")
        processes.last?.die()
        check(timers.isEmpty && healthy.state == .stopped, "media: an exit after stop isn't restarted")
        healthy.start()
        check(healthy.state == .launching, "media: a stopped adapter starts again")

        // Silence at launch counts as a failure
        let count = processes.count
        guard let timeout = timers.last(where: { $0.delay == 0.5 }) else { check(false, "media: launch timeout"); return }
        timeout.work()
        check(processes.last?.terminated == true && processes.count == count, "media: a silent adapter is ended")

        // An error line means MediaRemote can't be used: no retries
        processes.removeAll(); timers.removeAll()
        let broken = MediaRemoteAdapter(makeProcess: {
            let process = FakeAdapterProcess()
            processes.append(process)
            return process
        }, launchTimeout: 0.5, schedule: { delay, work in timers.append((delay, work)) }, now: { clock })
        broken.start()
        processes[0].onLine?(.error("MediaRemote functions not found"))
        processes[0].die()
        check(broken.state == .failed && runRestart() == nil, "media: an adapter error is final")

        let missing = MediaRemoteAdapter(makeProcess: { nil }, schedule: { _, _ in }, now: { clock })
        missing.start()
        check(missing.state == .failed, "media: no adapter in the bundle means fallback")

        processes.removeAll(); timers.removeAll()
        let unstartable = MediaRemoteAdapter(makeProcess: {
            let process = FakeAdapterProcess()
            process.failsToStart = true
            processes.append(process)
            return process
        }, launchTimeout: 0.5, schedule: { delay, work in timers.append((delay, work)) }, now: { clock })
        unstartable.start()
        check(unstartable.state == .waitingToRestart, "media: a process that can't start is retried")
        _ = runRestart(); _ = runRestart(); _ = runRestart()
        check(unstartable.state == .failed && processes.count == 4, "media: and given up after three tries")
        _ = states
    }

    private static func mediaFeed(_ check: Check) {
        typealias R = NowPlayingRules
        check(!R.usesFallback(adapter: .live, systemHasTrack: true), "media: system track, apps aren't asked")
        check(R.usesFallback(adapter: .live, systemHasTrack: false), "media: system says nothing, apps are asked")
        check(R.usesFallback(adapter: .unavailable, systemHasTrack: false), "media: no adapter, apps are asked")
        check(!R.usesFallback(adapter: .starting, systemHasTrack: false), "media: apps wait while the adapter starts")
        check(R.feed(running: true, adapter: .live, showsFallbackTrack: false) == .system, "media: feed is the system")
        check(R.feed(running: true, adapter: .live, showsFallbackTrack: true) == .fallback,
              "media: feed is the fallback when it found the track")
        check(R.feed(running: true, adapter: .unavailable, showsFallbackTrack: false) == .fallback,
              "media: feed is the fallback without the adapter")
        check(R.feed(running: false, adapter: .live, showsFallbackTrack: false) == .off, "media: feed off")
    }

    /// The real adapter from the app bundle: Perl loads it and it answers. It only listens; no command is sent.
    private static func mediaBundledAdapter(_ check: Check) {
        guard let adapter = MediaRemoteAdapter.bundled() else {
            check(Bundle.main.bundleURL.pathExtension != "app", "media: the app bundle has the Now Playing adapter")
            return
        }
        var lines: [AdapterLine] = []
        adapter.onLine = { lines.append($0) }
        adapter.start()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !lines.contains(where: { if case .hello = $0 { return false }; return true }) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let state = adapter.state
        adapter.stop()
        check(state == .running && lines.first == .hello(version: 1), "media: the bundled adapter runs in Perl")
        check(lines.dropFirst().contains { if case .error = $0 { return false }; return true },
              "media: the bundled adapter reports the system state")
    }
}
