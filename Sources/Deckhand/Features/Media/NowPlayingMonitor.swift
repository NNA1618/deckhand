import AppKit
import Combine
import ImageIO

/// Knows what is playing, for the Music tab and the badge at the closed notch.
///
/// - Playing or not comes from facts, never guesses: Music and Spotify announce their state with
///   distributed notifications; for browsers and the Yandex Music app, CoreAudio says whether the app
///   is outputting sound (polled once a second while the monitor runs).
/// - Browsers are asked for their tab titles only while they output sound, and only with Automation
///   already allowed; Deckhand never causes a permission prompt without a click.
/// - It runs only while someone needs it: the badge is on, or the Music tab is open. It pauses
///   while the Mac sleeps or the screen is locked.
@MainActor
final class NowPlayingMonitor: ObservableObject {
    static let shared = NowPlayingMonitor()

    /// The source the badge shows: the one that started playing most recently.
    @Published private(set) var now: NowPlaying = .empty
    /// Whether the closed notch shows the track. The notch only reads this.
    @Published private(set) var showsInNotch = false
    /// Every source with something to show, newest first, for the Music tab's picker.
    @Published private(set) var sources: [NowPlaying] = []
    /// The source the user picked in the Music tab; nil follows `now`.
    @Published var pinned: MediaApp? { didSet { if pinned != oldValue { recompute() } } }
    @Published private(set) var artwork: [MediaApp: NSImage] = [:]
    /// Apps that play sound but whose track Deckhand can't read, and why.
    @Published private(set) var blocked: [MediaApp: Blocker] = [:]
    /// Set when the last control press couldn't be delivered.
    @Published private(set) var controlProblem: MediaController.Outcome?

    enum Blocker: Equatable { case automationNotAsked, automationDenied, accessibility }

    /// What the Music tab shows: the picked source, or the badge's.
    var selected: NowPlaying {
        if let pinned, let session = sessions[pinned] { return session.info }
        return now
    }

    var isRunning: Bool { loop != nil }

    private struct Session {
        var info: NowPlaying
        var startedAt: Date
        var stoppedAt: Date?
        var silentSince: Date?
        /// Music and Spotify: once the player itself has said whether it plays (a notification or a
        /// script answer), that beats the audio signal; Spotify keeps its audio running for seconds after a pause.
        var stateFromPlayer = false
        /// After a control press the new state shows at once; audio that disagrees is ignored until then.
        var holdUntil: Date?
        var trackKey = ""
        var tabURL: String?
        var lastTitleFetch: Date?
    }

    private var sessions: [MediaApp: Session] = [:]
    private var running: [MediaApp: pid_t] = [:]
    private var loop: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?
    private var wanted = false
    private var viewers = 0
    private var asleep = false
    private var frozen = false
    private var fetching = Set<MediaApp>()
    private var fetchAgain = Set<MediaApp>()
    /// Notifications received per player, to tell a stale script answer from a fresh one.
    private var reports: [MediaApp: Int] = [:]
    private var backoff: [MediaApp: Date] = [:]
    private var permissions: [MediaApp: (status: AutomationPermission, checked: Date)] = [:]
    private var lastLogged: [MediaApp: Int] = [:]
    private var artworkRequested: [MediaApp: String] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var workspaceObservers: [NSObjectProtocol] = []
    private let players = PlayerNotifications()

    private let settings = Settings.shared
    private let media = MediaSettings.shared

    private init() {
        guard !AppPaths.isSnapshot else { return }
        // @Published fires before the value changes, so read the new state on the next run-loop turn
        Publishers.Merge3(settings.$showPlayingInNotch.map { _ in () },
                          media.$enabled.map { _ in () },
                          media.$disabledSources.map { _ in () })
            .dropFirst(3)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.settingsChanged() }
            .store(in: &subscriptions)
        media.$hideDelay.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &subscriptions)
        observeSleep()
        players.onReport = { [weak self] app, info in self?.handle(app: app, info: info) }
    }

    // MARK: - Running

    /// Lets the monitor run for the badge. It actually runs only while now playing is on and either
    /// the badge is turned on or the Music tab is visible.
    func start() {
        wanted = true
        update()
    }

    /// Stops everything: polling, notifications and Apple Events.
    func stop() {
        wanted = false
        update()
    }

    /// The Music tab appeared or disappeared.
    func viewerAppeared() { viewers += 1; update() }
    func viewerDisappeared() { viewers = max(0, viewers - 1); update() }

    private var shouldRun: Bool {
        !AppPaths.isSnapshot && !frozen && media.enabled && !asleep
            && ((wanted && settings.showPlayingInNotch) || viewers > 0)
    }

    private func settingsChanged() {
        if settings.showPlayingInNotch { wanted = true }
        for app in sessions.keys where !media.isOn(app) { sessions[app] = nil; clearArtwork(app); setBlocked(app, nil) }
        update()
        recompute()
    }

    private func update() {
        if shouldRun, loop == nil {
            refreshRunningApps()
            players.start()
            primePlayers()
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    let outputting = await AudioActivity.shared.outputtingApps()
                    guard !Task.isCancelled, let self else { return }
                    self.apply(outputting: outputting)
                    try? await Task.sleep(for: .seconds(1), tolerance: .milliseconds(250))
                }
            }
        } else if !shouldRun, loop != nil {
            loop?.cancel()
            loop = nil
            players.stop()
            // Missed notifications would leave stale states behind, so start over next time
            sessions = [:]
            artwork = [:]
            artworkRequested = [:]
            blocked = [:]
            recompute()
        }
    }

    /// Asks for an immediate update, e.g. after Automation was allowed.
    func refresh() {
        guard isRunning else { return }
        permissions = [:]
        backoff = [:]
        for app in sessions.keys { sessions[app]?.lastTitleFetch = nil }
        for app in MediaApp.allCases where artwork[app] == nil { artworkRequested[app] = nil }
        primePlayers()
        Task {
            let outputting = await AudioActivity.shared.outputtingApps()
            apply(outputting: outputting)
        }
    }

    /// For `--snapshot` only: shows a fixed track and stops polling until cleared with nil.
    func showForSnapshot(_ value: NowPlaying?) {
        frozen = value != nil
        update()
        sessions = [:]
        if let value, let app = value.app {
            sessions[app] = Session(info: value, startedAt: Date())
        }
        now = value ?? .empty
        sources = value.map { [$0] } ?? []
        showsInNotch = value.map { $0.isPlaying && $0.isDisplayable } ?? false
    }

    // MARK: - Facts coming in

    private func apply(outputting: Set<MediaApp>) {
        let date = Date()
        for app in MediaApp.allCases where media.isOn(app) {
            guard running[app] != nil else {
                if sessions[app] != nil { sessions[app] = nil; clearArtwork(app) }
                setBlocked(app, nil)
                continue
            }
            let out = outputting.contains(app)
            if app.kind == .player {
                if var session = sessions[app] {
                    guard !session.stateFromPlayer else { continue }
                    applyAudio(&session, outputting: out, at: date)
                    sessions[app] = session
                } else if out {
                    // Playing since before the monitor started: the app is known, the track comes next
                    sessions[app] = Session(info: NowPlaying(title: "", artist: "", isPlaying: true, app: app), startedAt: date)
                    fetchPlayerDetails(app)
                }
                continue
            }
            guard out || sessions[app] != nil else { continue }
            var session = sessions[app] ?? Session(info: NowPlaying(title: "", artist: "", isPlaying: false, app: app),
                                                   startedAt: date)
            let wasPlaying = session.info.isPlaying
            applyAudio(&session, outputting: out, at: date)
            // A paused tab or app that stays silent for 10 minutes is forgotten
            if !session.info.isPlaying, let stopped = session.stoppedAt ?? session.silentSince,
               date.timeIntervalSince(stopped) > 600 {
                sessions[app] = nil
                setBlocked(app, nil)
                continue
            }
            sessions[app] = session
            if out, !wasPlaying || session.lastTitleFetch.map({ date.timeIntervalSince($0) >= 4 }) ?? true {
                fetchTitle(app)
            }
        }
        recompute()
    }

    private func applyAudio(_ session: inout Session, outputting: Bool, at date: Date) {
        if let hold = session.holdUntil, date < hold { return }
        session.holdUntil = nil
        let wasPlaying = session.info.isPlaying
        let state = NowPlayingRules.audioState(wasPlaying: wasPlaying, silentSince: session.silentSince,
                                               outputting: outputting, now: date)
        session.silentSince = state.silentSince
        if state.isPlaying, !wasPlaying {
            // A short stop (a seek, the next track) keeps the source's place in the order
            if session.stoppedAt.map({ date.timeIntervalSince($0) > 3 }) ?? true { session.startedAt = date }
            session.stoppedAt = nil
        } else if !state.isPlaying, wasPlaying {
            session.stoppedAt = state.silentSince ?? date
        }
        session.info.isPlaying = state.isPlaying
    }

    private func handle(app: MediaApp, info: [String: Any]) {
        guard isRunning, media.isOn(app), let report = PlayerReport.parse(info, app: app, at: Date()) else { return }
        guard report.state != .stopped else {
            sessions[app] = nil
            clearArtwork(app)
            recompute()
            return
        }
        reports[app, default: 0] += 1
        apply(report: report, app: app)
        // Music's notification has no position, Spotify's no artwork address: one script answers both
        fetchPlayerDetails(app)
    }

    private func apply(report: PlayerReport, app: MediaApp) {
        let date = Date()
        var session = sessions[app] ?? Session(info: report.track, startedAt: date)
        let wasPlaying = sessions[app]?.info.isPlaying ?? false
        var info = report.track
        // Music's notification has no position; carry on from the one a script found for the same track
        if info.position == nil, session.trackKey == report.key, let position = session.info.position(at: date) {
            info.position = position
            info.positionDate = date
        }
        if info.title.isEmpty, session.trackKey == report.key { info.title = session.info.title }
        session.info = info
        session.stateFromPlayer = true
        session.holdUntil = nil
        if info.isPlaying {
            if !wasPlaying { session.startedAt = date }
            session.stoppedAt = nil
        } else if wasPlaying {
            session.stoppedAt = date
        } else if session.stoppedAt == nil {
            // Found paused: it never played while Deckhand watched, so there is no badge to keep
            session.stoppedAt = .distantPast
        }
        if session.trackKey != report.key {
            session.trackKey = report.key
            clearArtwork(app)
        }
        sessions[app] = session
        if artwork[app] == nil { fetchArtwork(app, key: report.key, url: report.artworkURL) }
        recompute()
    }

    // MARK: - Asking apps

    /// Music and Spotify that were already playing or paused when the monitor started.
    private func primePlayers() {
        for app in MediaApp.allCases where app.kind == .player && media.isOn(app) && running[app] != nil {
            fetchPlayerDetails(app)
        }
    }

    private func fetchPlayerDetails(_ app: MediaApp) {
        guard !fetching.contains(app) else {
            // Asked again while a script runs: run once more afterwards, the answer in flight may be stale
            fetchAgain.insert(app)
            return
        }
        fetching.insert(app)
        let seen = reports[app, default: 0]
        Task {
            defer {
                fetching.remove(app)
                if fetchAgain.remove(app) != nil, isRunning { fetchPlayerDetails(app) }
            }
            guard await permission(app) == .allowed, isRunning,
                  let report = await MediaScripts.playerDetails(app), isRunning,
                  // A notification that arrived meanwhile is newer than this answer
                  reports[app, default: 0] == seen else { return }
            if report.state == .stopped {
                sessions[app] = nil
                recompute()
                return
            }
            apply(report: report, app: app)
        }
    }

    private func fetchTitle(_ app: MediaApp) {
        guard !fetching.contains(app), backoff[app].map({ Date() >= $0 }) ?? true else { return }
        fetching.insert(app)
        sessions[app]?.lastTitleFetch = Date()
        Task {
            defer { fetching.remove(app) }
            if app.kind == .yandexApp {
                await fetchYandexTitle()
            } else {
                await fetchBrowserTitle(app)
            }
            recompute()
        }
    }

    private func fetchYandexTitle() async {
        guard AXIsProcessTrusted() else { setBlocked(.yandexMusic, .accessibility); return }
        setBlocked(.yandexMusic, nil)
        guard let pid = running[.yandexMusic], let raw = await YandexMusicWindow.title(pid: pid),
              var session = sessions[.yandexMusic] else { return }
        let parsed = TrackTitle.parse(raw, site: nil)
        session.info.title = parsed?.title ?? ""
        session.info.artist = parsed?.artist ?? ""
        sessions[.yandexMusic] = session
    }

    private func fetchBrowserTitle(_ app: MediaApp) async {
        switch await permission(app) {
        case .allowed: setBlocked(app, nil)
        case .notAsked: setBlocked(app, .automationNotAsked); return
        case .denied: setBlocked(app, .automationDenied); return
        case .appNotRunning, .unknown: return
        }
        let result = await MediaScripts.browserTabs(app)
        guard var session = sessions[app] else { return }
        switch result {
        case .success(let tabs):
            lastLogged[app] = nil
            if let (tab, site) = BrowserTab.pick(tabs, previousURL: session.tabURL),
               let parsed = TrackTitle.parse(tab.title, site: site) {
                session.tabURL = tab.url
                session.info.site = site
                session.info.title = parsed.title
                session.info.artist = parsed.artist
            } else {
                session.tabURL = nil
                session.info.site = nil
                session.info.title = ""
                session.info.artist = ""
            }
            sessions[app] = session
        case .failure(let failure):
            if failure.notAllowed {
                permissions[app] = (.denied, Date())
                setBlocked(app, .automationDenied)
            } else {
                // A busy or hung browser is left alone for a while instead of being asked every few seconds
                backoff[app] = Date().addingTimeInterval(failure.timedOut ? 30 : 10)
            }
            if lastLogged[app] != failure.code {
                lastLogged[app] = failure.code
                Log.info("now playing: \(app.rawValue) tabs failed \(failure.code) \(failure.message)")
            }
        }
    }

    /// Automation status without ever prompting, cached briefly because it's asked every few seconds.
    private func permission(_ app: MediaApp) async -> AutomationPermission {
        if let cached = permissions[app], Date().timeIntervalSince(cached.checked) < 20 { return cached.status }
        let id = app.bundleID
        let status = await Task.detached(priority: .utility) { AutomationPermission.status(bundleId: id) }.value
        permissions[app] = (status, Date())
        return status
    }

    private func fetchArtwork(_ app: MediaApp, key: String, url: String?) {
        guard media.showArtwork, app.kind == .player, app == .music || url != nil,
              artworkRequested[app] != key else { return }
        artworkRequested[app] = key
        Task {
            guard await permission(app) == .allowed else { return }
            let data: Data?
            if app == .music {
                data = await MediaScripts.musicArtwork()
            } else if let url, let link = URL(string: url), link.scheme == "https",
                      let host = link.host, host.hasSuffix("scdn.co") || host.hasSuffix("spotifycdn.com") {
                data = try? await Artwork.session.data(from: link).0
            } else {
                data = nil
            }
            guard let data, let thumb = await Task.detached(priority: .utility, operation: { Artwork.thumbnail(data) }).value,
                  sessions[app]?.trackKey == key else { return }
            artwork[app] = NSImage(cgImage: thumb.image, size: NSSize(width: thumb.image.width, height: thumb.image.height))
        }
    }

    // MARK: - Controls

    func playPause() { control(.playPause) }
    func next() { control(.next) }
    func previous() { control(.previous) }

    private func control(_ command: MediaScripts.Command) {
        let app = selected.app
        let saved = app.flatMap { sessions[$0] }
        if command == .playPause, let app, var session = saved {
            let date = Date()
            session.info.isPlaying.toggle()
            session.info.position = session.info.position(at: date)
            session.info.positionDate = session.info.position == nil ? nil : date
            if session.info.isPlaying { session.stoppedAt = nil } else { session.stoppedAt = date }
            session.silentSince = nil
            session.holdUntil = date.addingTimeInterval(2.5)
            sessions[app] = session
            recompute()
        }
        Task {
            let outcome = await MediaController.send(command, to: app)
            controlProblem = outcome == .sent ? nil : outcome
            if outcome != .sent, let app, let saved {
                sessions[app] = saved
                recompute()
            }
            if outcome == .sent, let app, app.kind == .player, command != .playPause {
                try? await Task.sleep(for: .milliseconds(500))
                fetchPlayerDetails(app)
            }
        }
    }

    /// Shows the macOS Automation prompt for one app. Only call from a button the user clicked.
    func allowAutomation(_ app: MediaApp) {
        let id = app.bundleID
        Task {
            let status = await Task.detached { AutomationPermission.status(bundleId: id, ask: true) }.value
            permissions[app] = (status, Date())
            if status == .denied { setBlocked(app, .automationDenied) }
            refresh()
        }
    }

    func clearControlProblem() { controlProblem = nil }

    /// Published dictionaries notify on every write, and the notch observes this object:
    /// write only real changes so a poll that changes nothing redraws nothing.
    private func setBlocked(_ app: MediaApp, _ value: Blocker?) {
        if blocked[app] != value { blocked[app] = value }
    }

    private func clearArtwork(_ app: MediaApp) {
        artworkRequested[app] = nil
        if artwork[app] != nil { artwork[app] = nil }
    }

    // MARK: - Publishing

    private func recompute() {
        guard !frozen else { return }
        let date = Date()
        let entries = sessions.map { app, session in
            NowPlayingRules.Entry(app: app, isPlaying: session.info.isPlaying, isDisplayable: session.info.isDisplayable,
                                  startedAt: session.startedAt, stoppedAt: session.stoppedAt)
        }
        let current = NowPlayingRules.current(entries).flatMap { sessions[$0] }
        let info = current?.info ?? .empty
        if now != info { now = info }

        let list = sessions.values
            .filter { $0.info.isDisplayable }
            .sorted { $0.startedAt > $1.startedAt }
            .map(\.info)
        if sources != list { sources = list }
        if let pinned, sessions[pinned] == nil { self.pinned = nil }

        let shows = media.enabled && settings.showPlayingInNotch && isRunning && info.isDisplayable
            && NowPlayingRules.showsBadge(isPlaying: info.isPlaying, stoppedAt: current?.stoppedAt, now: date,
                                          hideDelay: media.hideDelay)
        if showsInNotch != shows { showsInNotch = shows }

        // Hide the badge exactly when the grace period ends, not at the next poll
        graceTask?.cancel()
        graceTask = nil
        if shows, !info.isPlaying, let stopped = current?.stoppedAt {
            let left = media.hideDelay - date.timeIntervalSince(stopped)
            graceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(left, 0) + 0.05))
                guard !Task.isCancelled else { return }
                self?.recompute()
            }
        }
    }

    // MARK: - System

    private func refreshRunningApps() {
        var found: [MediaApp: pid_t] = [:]
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            guard let id = app.bundleIdentifier, let media = MediaApp.owner(ofBundleID: id) else { continue }
            let isMain = media == .yandexMusic ? app.activationPolicy == .regular : id == media.bundleID
            if isMain { found[media] = app.processIdentifier }
        }
        running = found
    }

    private func observeSleep() {
        let workspace = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, Bool)] = [
            (NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false),
            (NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
        ]
        for (name, sleeping) in pairs {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAsleep(sleeping) }
            })
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isRunning else { return }
                    self.refreshRunningApps()
                }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            workspaceObservers.append(distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAsleep(locked) }
            })
        }
    }

    private func setAsleep(_ value: Bool) {
        guard asleep != value else { return }
        asleep = value
        update()
    }
}

/// Listens to the players' own announcements. Delivered immediately even while Deckhand is in the background.
@MainActor
private final class PlayerNotifications: NSObject {
    var onReport: ((MediaApp, [String: Any]) -> Void)?
    private var listening = false

    func start() {
        guard !listening else { return }
        listening = true
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(music(_:)), name: .init("com.apple.Music.playerInfo"),
                           object: nil, suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(spotify(_:)), name: .init("com.spotify.client.PlaybackStateChanged"),
                           object: nil, suspensionBehavior: .deliverImmediately)
    }

    func stop() {
        guard listening else { return }
        listening = false
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func music(_ note: Notification) { forward(.music, note) }
    @objc private func spotify(_ note: Notification) { forward(.spotify, note) }

    private func forward(_ app: MediaApp, _ note: Notification) {
        var info: [String: Any] = [:]
        for (key, value) in note.userInfo ?? [:] { if let key = key as? String { info[key] = value } }
        onReport?(app, info)
    }
}

/// Small artwork for the Music tab, decoded off the main thread.
enum Artwork {
    struct Thumbnail: @unchecked Sendable { let image: CGImage }

    /// Spotify's artwork comes from its image server; no cookies or cache on disk.
    static let session = URLSession(configuration: .ephemeral)

    static func thumbnail(_ data: Data, maxPixels: Int = 320) -> Thumbnail? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(Thumbnail.init)
    }
}
