import AppKit
import Combine

/// Shows what Claude Code is doing, like Vibe Island and similar notch apps.
///
/// Deckhand adds a small hook to Claude Code's `settings.json`. While Deckhand runs, the hook
/// writes each event as a tiny file to `claude-events` with only the fields Deckhand shows
/// (see `ClaudeHook`); the monitor reads those files off the main thread, deletes them and keeps
/// one state per session. Nothing is sent anywhere, and prompts, code and tool output are never stored.
///
/// The Claude Code hook is the first provider adapter: it turns hook events into `AgentEvent`s
/// for `ClaudeStateMachine`. Another agent can feed `receive(_:at:)` the same way.
@MainActor
final class ClaudeCodeMonitor: ObservableObject {
    static let shared = ClaudeCodeMonitor()

    typealias Signal = ClaudeStateMachine.Signal

    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var hooksInstalled = false
    /// Claude Code's config folder, `~/.claude` unless `CLAUDE_CONFIG_DIR` says otherwise.
    @Published private(set) var configDirectory: URL

    var onSignal: (ClaudeSession, Signal) -> Void = { _, _ in }

    let files = ClaudeHookFiles(dir: AppPaths.supportDir)
    private var byKey: [String: ClaudeSession] = [:]
    private var source: DispatchSourceFileSystemObject?
    private var sweep: Timer?
    private var started = false
    private var subscriptions = Set<AnyCancellable>()
    private let reader = DispatchQueue(label: "deckhand.claude-events", qos: .utility)

    /// Events older than this when read are applied silently: they say nothing about now.
    nonisolated static let staleAfter: TimeInterval = 30
    /// Event files older than this at launch are deleted unread.
    nonisolated static let discardAfter: TimeInterval = 600

    private init() {
        configDirectory = ClaudeSettingsFile.configDirectory(environment: ProcessInfo.processInfo.environment,
                                                             home: FileManager.default.homeDirectoryForCurrentUser)
    }

    var settingsFile: ClaudeSettingsFile { ClaudeSettingsFile(url: configDirectory.appendingPathComponent("settings.json")) }

    var active: [ClaudeSession] { sessions.filter { $0.state != .idle } }
    var needsYou: ClaudeSession? { sessions.first { $0.state == .waiting } }

    func start() {
        guard !started else { return }
        started = true
        let fm = FileManager.default
        try? fm.createDirectory(at: files.inbox, withIntermediateDirectories: true)
        try? fm.createDirectory(at: files.replies, withIntermediateDirectories: true)
        try? String(ProcessInfo.processInfo.processIdentifier).write(to: files.pidFile, atomically: true, encoding: .utf8)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [files] _ in
            // Without a live Deckhand the hook writes nothing, so nothing piles up
            try? FileManager.default.removeItem(at: files.pidFile)
        }
        reader.async { [files] in Self.cleanUp(files, now: Date()) }

        let settings = ClaudeSettings.shared
        settings.$approveFromNotch.combineLatest(settings.$approvalWait)
            .sink { [files] on, wait in Self.writeApprovalFlag(files, on: on, wait: wait) }
            .store(in: &subscriptions)

        refreshConnection(upgrade: true)
        watch()
        drain()
        sweep = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expire(now: Date()) }
        }
    }

    /// Uses Claude Code's config folder as the login shell or Claude Code itself reports it.
    func setConfigDirectory(_ url: URL) {
        guard url.standardizedFileURL != configDirectory.standardizedFileURL else { return }
        configDirectory = url
        refreshConnection(upgrade: started)
    }

    /// Re-reads whether the hook is connected. With `upgrade`, entries from an older Deckhand
    /// are brought up to date, which changes only Deckhand's own lines in the file.
    func refreshConnection(upgrade: Bool = false) {
        let file = settingsFile, files = files
        reader.async {
            let text = (try? file.read()) ?? nil
            var present = text.map(ClaudeSettingsFile.hasOurs) ?? false
            if present, upgrade, let text {
                do {
                    try Self.writeScript(files)
                    if !ClaudeSettingsFile.isCurrent(text, command: ClaudeHook.command(for: files)) {
                        try file.update { try ClaudeSettingsFile.installing(into: $0, command: ClaudeHook.command(for: files)) }
                        Log.info("claude hooks updated")
                    }
                } catch {
                    Log.info("claude hooks update failed: \(error.localizedDescription)")
                }
                present = ((try? file.read()) ?? nil).map(ClaudeSettingsFile.hasOurs) ?? false
            }
            let connected = present
            Task { @MainActor in ClaudeCodeMonitor.shared.hooksInstalled = connected }
        }
    }

    // MARK: - Reading events

    private func watch() {
        let fd = open(files.inbox.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.drain() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    /// Reads new event files in the order they were written, deletes them, then applies them.
    private func drain() {
        reader.async { [files] in
            let events = Self.readInbox(files.inbox)
            guard !events.isEmpty else { return }
            Task { @MainActor in ClaudeCodeMonitor.shared.receive(events) }
        }
    }

    private func receive(_ events: [ClaudeHookEvent]) {
        let now = Date()
        for event in events {
            let signal = receive(event.agentEvent, process: event.parentPID.flatMap(Self.agentProcess))
            Log.info("claude event \(event.name) session=\(event.session.prefix(8))")
            if let signal, now.timeIntervalSince(event.time) < Self.staleAfter,
               let session = byKey[ClaudeSession.key(.claudeCode, event.session)] {
                onSignal(session, signal)
            }
        }
        publish()
    }

    /// Applies one event from any provider adapter and returns the signal it raises.
    @discardableResult
    func receive(_ event: AgentEvent, process: ClaudeProcess? = nil) -> Signal? {
        let signal = ClaudeStateMachine.apply(event, to: &byKey)
        if let process { byKey[ClaudeSession.key(event.provider, event.session)]?.process = process }
        return signal
    }

    nonisolated static func readInbox(_ inbox: URL) -> [ClaudeHookEvent] {
        let fm = FileManager.default
        let urls = ((try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()) }
            .sorted { $0.1 < $1.1 }
        return urls.compactMap { url, created in
            defer { try? fm.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url, options: .uncached), data.count < 64 * 1024,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return ClaudeHookEvent(json: json, time: created, fileName: url.lastPathComponent)
        }
    }

    /// Removes leftovers from earlier runs: events too old to matter and unanswered replies.
    nonisolated static func cleanUp(_ files: ClaudeHookFiles, now: Date) {
        let fm = FileManager.default
        for dir in [files.inbox, files.replies] {
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                if dir == files.replies || now.timeIntervalSince(created) > discardAfter { try? fm.removeItem(at: url) }
            }
        }
    }

    /// The Claude Code process behind a hook: the hook's parent, unless that is a shell in between.
    nonisolated static func agentProcess(parent pid: Int32) -> ClaudeProcess? {
        guard var details = ProcessRunner.details(pid: pid) else { return nil }
        var pid = pid
        if ["sh", "bash", "zsh", "dash", "fish"].contains(details.name) {
            guard let up = ProcessRunner.details(pid: details.parent) else { return nil }
            pid = details.parent
            details = up
        }
        return ClaudeProcess(pid: pid, started: details.started)
    }

    nonisolated static func isAlive(_ process: ClaudeProcess) -> Bool {
        guard let details = ProcessRunner.details(pid: process.pid) else { return false }
        return abs(details.started - process.started) < 1
    }

    private func publish() {
        let ordered = ClaudeSession.ordered(byKey.values)
        if ordered != sessions { sessions = ordered }
    }

    /// Ends states that never got their closing event, e.g. after Esc or a closed terminal.
    func expire(now: Date) {
        if ClaudeStateMachine.expire(&byKey, now: now, alive: Self.isAlive) { publish() }
    }

    // MARK: - Permission requests

    /// The request the notch can answer for this session, while the hook still waits for it.
    func pendingRequest(for session: ClaudeSession, now: Date = Date()) -> ClaudeRequest? {
        guard ClaudeSettings.shared.approveFromNotch, session.state == .waiting, let request = session.request,
              now.timeIntervalSince(request.time) < TimeInterval(ClaudeSettings.shared.approvalWait) - 1 else { return nil }
        return request
    }

    /// Sends the answer to the waiting hook. `nil` hands the question back to Claude Code's own prompt.
    func answer(_ session: ClaudeSession, allow: Bool?) {
        guard let request = session.request else { return }
        let reply = files.replies.appendingPathComponent(request.id)
        let word = allow.map { $0 ? "allow" : "deny" } ?? "ask"
        try? word.write(to: reply, atomically: true, encoding: .utf8)
        byKey[session.key]?.request = nil
        if allow != nil {
            byKey[session.key]?.state = .working
            byKey[session.key]?.waitingSince = nil
            byKey[session.key]?.waitingTool = nil
        }
        publish()
        Log.info("claude permission answered: \(word)")
    }

    nonisolated static func writeApprovalFlag(_ files: ClaudeHookFiles, on: Bool, wait: Int) {
        if on {
            try? String(max(5, min(wait, ClaudeHook.maxApprovalWait))).write(to: files.approvals, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: files.approvals)
        }
    }

    // MARK: - Installing the hook

    nonisolated static func writeScript(_ files: ClaudeHookFiles) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: files.inbox, withIntermediateDirectories: true)
        try fm.createDirectory(at: files.replies, withIntermediateDirectories: true)
        if (try? String(contentsOf: files.script, encoding: .utf8)) != ClaudeHook.script {
            try ClaudeHook.script.write(to: files.script, atomically: true, encoding: .utf8)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: files.script.path)
    }

    /// Adds Deckhand's hook next to any hooks the user already has.
    func installHooks() throws {
        try Self.writeScript(files)
        try settingsFile.update { try ClaudeSettingsFile.installing(into: $0, command: ClaudeHook.command(for: files)) }
        hooksInstalled = ((try? settingsFile.read()) ?? nil).map(ClaudeSettingsFile.hasOurs) ?? false
        Log.info("claude hooks installed")
    }

    /// Removes Deckhand's entries and the script; the rest of the file stays as it was.
    func removeHooks() throws {
        try settingsFile.update { try ClaudeSettingsFile.removing(from: $0) }
        try? FileManager.default.removeItem(at: files.script)
        hooksInstalled = ((try? settingsFile.read()) ?? nil).map(ClaudeSettingsFile.hasOurs) ?? false
        byKey.removeAll()
        publish()
        Log.info("claude hooks removed")
    }

    /// Fills in sample sessions for the snapshot run.
    func showForSnapshot(_ sample: [ClaudeSession]) {
        byKey = Dictionary(sample.map { ($0.key, $0) }) { a, _ in a }
        hooksInstalled = !sample.isEmpty || (((try? settingsFile.read()) ?? nil).map(ClaudeSettingsFile.hasOurs) ?? false)
        publish()
    }

    /// Brings the app that runs the session to the front.
    func reveal(_ session: ClaudeSession) {
        ClaudeReveal.reveal(session)
    }

    // MARK: - Labels

    /// "4:07" of work so far, "1h 02m" past an hour.
    nonisolated static func elapsed(since start: Date?, now: Date = Date()) -> String {
        guard let start else { return "" }
        let s = max(0, Int(now.timeIntervalSince(start)))
        if s >= 3600 { return String(format: String(localized: "%dh %02dm"), s / 3600, s % 3600 / 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
