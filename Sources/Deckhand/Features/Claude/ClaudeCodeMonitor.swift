import AppKit
import Combine

/// A Claude Code session seen through its hooks.
struct ClaudeSession: Identifiable, Equatable {
    enum State: Equatable { case working, waiting, idle }

    let id: String
    var cwd: String
    /// Bundle id of the app the session runs in (Terminal, Claude, an editor), if known.
    var app: String?
    var state: State = .idle
    /// What it is doing right now, e.g. "Edit · NotchView.swift".
    var detail: String?
    /// Since when it has been working on the current prompt.
    var workStarted: Date?
    var updated: Date

    var project: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "Claude Code" : name
    }
}

/// Shows what Claude Code is doing, like Vibe Island and similar notch apps.
///
/// Deckhand adds a small hook to `~/.claude/settings.json` that saves each event as a file
/// in `claude-events`. The monitor reads those files and keeps one state per session.
/// Nothing is sent anywhere, and prompts and tool output are never stored.
@MainActor
final class ClaudeCodeMonitor: ObservableObject {
    static let shared = ClaudeCodeMonitor()

    enum Signal: Equatable {
        /// A prompt finished after this many seconds of work.
        case finished(project: String, seconds: Int)
        /// Claude asks for a permission or an answer.
        case needsYou(project: String)
    }

    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var hooksInstalled = false

    var onSignal: (ClaudeSession, Signal) -> Void = { _, _ in }

    private var byId: [String: ClaudeSession] = [:]
    private var source: DispatchSourceFileSystemObject?
    private var sweep: Timer?

    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"]
    static var eventsDir: URL { AppPaths.supportDir.appendingPathComponent("claude-events", isDirectory: true) }
    static var hookScript: URL { AppPaths.supportDir.appendingPathComponent("claude-hook.sh") }
    static var settingsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    private init() {}

    var active: [ClaudeSession] { sessions.filter { $0.state != .idle } }
    var needsYou: ClaudeSession? { sessions.first { $0.state == .waiting } }

    func start() {
        hooksInstalled = Self.hooksPresent()
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.eventsDir, withIntermediateDirectories: true)
        // Events from while Deckhand was not running say nothing about now
        for url in (try? fm.contentsOfDirectory(at: Self.eventsDir, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if Date().timeIntervalSince(created) > 600 { try? fm.removeItem(at: url) }
        }
        if hooksInstalled { try? Self.writeScript() }   // keeps the script current after an update
        watch()
        drain()
        sweep = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expire(now: Date()) }
        }
    }

    // MARK: - Reading events

    private func watch() {
        let fd = open(Self.eventsDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.drain() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    /// Applies new event files in the order they were written, then deletes them.
    private func drain() {
        let fm = FileManager.default
        let urls = ((try? fm.contentsOfDirectory(at: Self.eventsDir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            .sorted { $0.1 < $1.1 }
        guard !urls.isEmpty else { return }
        for (url, _) in urls {
            defer { try? fm.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let signal = Self.apply(event: event, app: Self.appId(fromFileName: url.lastPathComponent), now: Date(), to: &byId)
            if let signal, let id = event["session_id"] as? String, let session = byId[id] {
                onSignal(session, signal)
            }
        }
        publish()
    }

    private func publish() {
        sessions = byId.values.sorted { $0.updated > $1.updated }
    }

    /// Ends states that never got their closing event, e.g. after a crash.
    func expire(now: Date) {
        var changed = false
        for (id, s) in byId {
            let age = now.timeIntervalSince(s.updated)
            if s.state == .idle && age > 2 * 3600 { byId[id] = nil; changed = true }
            else if s.state != .idle && age > 30 * 60 { byId[id]?.state = .idle; byId[id]?.workStarted = nil; changed = true }
        }
        if changed { publish() }
    }

    /// File names are "<time>-<pid>-<bundle id>.json"; the bundle id says which app runs the session.
    nonisolated static func appId(fromFileName name: String) -> String? {
        let base = (name as NSString).deletingPathExtension
        let parts = base.split(separator: "-", maxSplits: 2)
        guard parts.count == 3, parts[2] != "unknown" else { return nil }
        return String(parts[2])
    }

    /// Updates the sessions for one hook event. Pure, so the self-test can drive it.
    static func apply(event: [String: Any], app: String?, now: Date, to sessions: inout [String: ClaudeSession]) -> Signal? {
        guard let id = event["session_id"] as? String, let name = event["hook_event_name"] as? String else { return nil }
        let cwd = event["cwd"] as? String ?? ""
        if name == "SessionEnd" {
            sessions[id] = nil
            return nil
        }
        var s = sessions[id] ?? ClaudeSession(id: id, cwd: cwd, app: app, updated: now)
        if !cwd.isEmpty { s.cwd = cwd }
        if let app { s.app = app }
        s.updated = now
        var signal: Signal?

        switch name {
        case "UserPromptSubmit":
            s.state = .working
            s.workStarted = now
            s.detail = nil
        case "PreToolUse", "PostToolUse":
            if s.state != .working { s.state = .working; s.workStarted = s.workStarted ?? now }
            if name == "PreToolUse" { s.detail = toolSummary(name: event["tool_name"] as? String, input: event["tool_input"] as? [String: Any]) }
        case "Notification":
            // An idle reminder means it already finished and waits for the next prompt
            if event["notification_type"] as? String == "idle_prompt" {
                s.state = .idle
                s.workStarted = nil
            } else {
                if s.state != .waiting { signal = .needsYou(project: s.project) }
                s.state = .waiting
                s.detail = (event["message"] as? String).map { String($0.prefix(80)) }
            }
        case "Stop":
            if let started = s.workStarted {
                let seconds = Int(now.timeIntervalSince(started))
                if seconds >= 5 { signal = .finished(project: s.project, seconds: seconds) }
            }
            s.state = .idle
            s.workStarted = nil
            s.detail = nil
        default:
            break
        }
        sessions[id] = s
        return signal
    }

    /// A short, safe label: the tool and the file or command name, never the full input.
    static func toolSummary(name: String?, input: [String: Any]?) -> String? {
        guard let name else { return nil }
        let short: String
        if name.hasPrefix("mcp__") { short = name.split(separator: "_").last.map(String.init) ?? name } else { short = name }
        if let path = (input?["file_path"] ?? input?["notebook_path"]) as? String {
            return "\(short) · \((path as NSString).lastPathComponent)"
        }
        if name == "Bash", let command = input?["command"] as? String,
           let first = command.split(whereSeparator: { $0 == " " || $0 == "\n" }).first {
            return "Bash · \((String(first) as NSString).lastPathComponent)"
        }
        return short
    }

    // MARK: - Installing the hook

    static let hookMarker = "claude-hook.sh"

    static let scriptBody = """
    #!/bin/sh
    # Deckhand: passes Claude Code hook events to the notch. Remove it in Deckhand Settings > Claude.
    [ -n "$DECKHAND_INTERNAL" ] && exit 0
    dir="$HOME/Library/Application Support/Deckhand/claude-events"
    [ -d "$dir" ] || exit 0
    app=$(printf '%s' "${__CFBundleIdentifier:-unknown}" | tr -cd 'A-Za-z0-9.-')
    name="$dir/$(date +%s)-$$-${app:-unknown}"
    cat > "$name.tmp" && mv "$name.tmp" "$name.json"
    exit 0

    """

    private static func writeScript() throws {
        try scriptBody.write(to: hookScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScript.path)
    }

    private static func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsFile.path) else { return [:] }
        let data = try Data(contentsOf: settingsFile)
        if data.isEmpty { return [:] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeCLI.Failure(message: String(localized: "~/.claude/settings.json is not valid JSON, so it was left as is."))
        }
        return json
    }

    private static func writeSettings(_ json: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: settingsFile.path) {
            let backup = settingsFile.appendingPathExtension("deckhand-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsFile, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsFile, options: .atomic)
    }

    static func hooksPresent() -> Bool {
        guard let json = try? readSettings(), let hooks = json["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { entries in
            (entries as? [[String: Any]])?.contains(where: isOurs) ?? false
        }
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains(hookMarker) ?? false } ?? false
    }

    /// Adds Deckhand's hook to every event it reads, next to any hooks the user already has.
    /// The previous file is kept as settings.json.deckhand-backup.
    static func withHooks(_ json: [String: Any], command: String) -> [String: Any] {
        var json = withoutHooks(json)
        var hooks = json["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            var entry: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
            if event == "PreToolUse" || event == "PostToolUse" { entry["matcher"] = "*" }
            entries.append(entry)
            hooks[event] = entries
        }
        json["hooks"] = hooks
        return json
    }

    static func withoutHooks(_ json: [String: Any]) -> [String: Any] {
        var json = json
        guard var hooks = json["hooks"] as? [String: Any] else { return json }
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter { !isOurs($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        json["hooks"] = hooks.isEmpty ? nil : hooks
        return json
    }

    func installHooks() throws {
        try Self.writeScript()
        let command = "\"\(Self.hookScript.path)\""
        try Self.writeSettings(Self.withHooks(try Self.readSettings(), command: command))
        hooksInstalled = Self.hooksPresent()
        Log.info("claude hooks installed")
    }

    func removeHooks() throws {
        try Self.writeSettings(Self.withoutHooks(try Self.readSettings()))
        try? FileManager.default.removeItem(at: Self.hookScript)
        hooksInstalled = Self.hooksPresent()
        byId.removeAll()
        publish()
        Log.info("claude hooks removed")
    }

    /// Brings the app that runs the session to the front.
    func reveal(_ session: ClaudeSession) {
        guard let app = session.app,
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: app).first else { return }
        running.activate()
    }

    /// Fills in sample sessions for the snapshot run.
    func showForSnapshot(_ sample: [ClaudeSession]) {
        byId = Dictionary(uniqueKeysWithValues: sample.map { ($0.id, $0) })
        hooksInstalled = !sample.isEmpty || Self.hooksPresent()
        publish()
    }

    // MARK: - Labels

    /// "4:07" of work so far.
    static func elapsed(since start: Date?, now: Date = Date()) -> String {
        guard let start else { return "" }
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
