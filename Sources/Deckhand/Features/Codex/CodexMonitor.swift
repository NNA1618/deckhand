import AppKit
import Combine
import os

/// Shows OpenAI Codex sessions in the notch, the same way as Claude Code sessions.
///
/// Deckhand adds a group per event to Codex's user-level `hooks.json`. Codex runs those hooks only
/// after the user reviews them in Codex. While Deckhand runs, the hook writes each event as a tiny
/// file to `codex-events` with only the fields Deckhand shows (see `CodexHook`); this monitor reads
/// them off the main thread, deletes them and hands them to `ClaudeCodeMonitor`, which keeps the
/// sessions of every agent. Deckhand never reads Codex's session files, history, databases or sign-in.
@MainActor
final class CodexMonitor: ObservableObject {
    static let shared = CodexMonitor()

    /// Whether Codex is on this Mac at all.
    struct Availability: Equatable, Sendable {
        var homeExists = false
        var cliPath: String?
        var appInstalled = false
        var isInstalled: Bool { homeExists || cliPath != nil || appInstalled }
    }

    /// Problems worth a row in Settings.
    struct Warnings: Equatable, Sendable {
        var hooksDisabled = false
        var inlineHooks = false
        var claudeHookImported = false
        var fileError: String?
    }

    @Published private(set) var hooksInstalled = false
    /// Codex's home folder, `~/.codex` unless `CODEX_HOME` says otherwise.
    @Published private(set) var homeDirectory: URL
    @Published private(set) var availability = Availability()
    @Published private(set) var warnings = Warnings()
    /// True once the availability check has run; until then Settings doesn't claim Codex is missing.
    @Published private(set) var checked = false

    let files = CodexHookFiles(dir: AppPaths.supportDir)
    private var source: DispatchSourceFileSystemObject?
    private var started = false
    private var subscriptions = Set<AnyCancellable>()
    private let reader = DispatchQueue(label: "deckhand.codex-events", qos: .utility)

    nonisolated static let appBundleId = "com.openai.codex"
    nonisolated static let installURL = URL(string: "https://developers.openai.com/codex")!

    private init() {
        homeDirectory = CodexHooksFile.homeDirectory(environment: ProcessInfo.processInfo.environment,
                                                     home: FileManager.default.homeDirectoryForCurrentUser)
    }

    var hooksFile: CodexHooksFile { CodexHooksFile(url: homeDirectory.appendingPathComponent("hooks.json"), command: CodexHook.command(for: files)) }
    var configFile: URL { homeDirectory.appendingPathComponent("config.toml") }

    /// Connected, but no event has arrived yet: the user still has to approve the hooks in Codex.
    var awaitingReview: Bool { hooksInstalled && !CodexSettings.shared.hooksSeen }

    func start() {
        guard !started else { return }
        started = true
        let fm = FileManager.default
        try? fm.createDirectory(at: files.inbox, withIntermediateDirectories: true)
        try? fm.createDirectory(at: files.replies, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: files.pidFile.path) {
            try? String(ProcessInfo.processInfo.processIdentifier).write(to: files.pidFile, atomically: true, encoding: .utf8)
        }
        reader.async { [files] in Self.cleanUp(files, now: Date()) }

        let settings = CodexSettings.shared
        settings.$approveFromNotch.combineLatest(settings.$approvalWait)
            .sink { [files] on, wait in Self.writeApprovalFlag(files, on: on, wait: wait) }
            .store(in: &subscriptions)

        refresh(upgrade: true)
        watch()
        drain()
    }

    /// Re-reads the connection, whether Codex is installed and what its config says. With `upgrade`,
    /// an outdated Deckhand group is replaced in place and the script is brought up to date.
    func refresh(upgrade: Bool = false) {
        let file = hooksFile, files = files, home = homeDirectory, config = configFile
        reader.async {
            var warnings = Warnings()
            var text: String?
            do { text = try file.read() } catch { warnings.fileError = error.localizedDescription }
            let command = CodexHook.command(for: files)
            var present = text.map { CodexHooksFile.hasOurs($0, command: command) } ?? false
            if present, upgrade, let current = text {
                do {
                    try Self.writeScript(files)
                    if !CodexHooksFile.isCurrent(current, command: CodexHook.command(for: files)) {
                        try file.update { try CodexHooksFile.installing(into: $0, command: CodexHook.command(for: files)) }
                        Log.info("codex hooks updated")
                    }
                } catch {
                    warnings.fileError = error.localizedDescription
                    Log.info("codex hooks update failed: \(error.localizedDescription)")
                }
                text = (try? file.read()) ?? nil
                present = text.map { CodexHooksFile.hasOurs($0, command: command) } ?? false
            }
            if let text, (try? JSONSerialization.jsonObject(with: Data(text.utf8))) == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                warnings.fileError = String(localized: "The Codex hooks file is not valid JSON, so it was left as is.")
            }
            let claudeScript = ClaudeHookFiles(dir: files.dir).script.path
            let notes = ((try? String(contentsOf: config, encoding: .utf8)) ?? nil).map { CodexConfigNotes.read($0, claudeScript: claudeScript) } ?? CodexConfigNotes()
            warnings.hooksDisabled = notes.hooksDisabled
            warnings.inlineHooks = notes.inlineHooks
            warnings.claudeHookImported = notes.claudeHook || (text.map { CodexHooksFile.hasClaudeHook($0, claudeScript: claudeScript) } ?? false)
            let availability = Self.findCodex(home: home)
            let connected = present, found = warnings
            Task { @MainActor in
                let monitor = CodexMonitor.shared
                monitor.hooksInstalled = connected
                monitor.warnings = found
                monitor.availability = availability
                monitor.checked = true
            }
        }
    }

    // MARK: - Finding Codex

    /// Looks for Codex's home folder, the `codex` program and the ChatGPT app (formerly the Codex app).
    /// Asks the login shell, so call it off the main thread.
    nonisolated static func findCodex(home: URL) -> Availability {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        var result = Availability()
        result.homeExists = fm.fileExists(atPath: home.path, isDirectory: &isDir) && isDir.boolValue
        result.appInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleId) != nil
        result.cliPath = CodexLocator.find()
        return result
    }

    /// Codex's home as the login shell sets it, for people who export CODEX_HOME in `.zshrc`.
    func useShellHome() {
        Task.detached(priority: .utility) {
            guard let dir = CodexLocator.shellHome() else { return }
            let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
            await MainActor.run {
                let monitor = CodexMonitor.shared
                guard url.standardizedFileURL != monitor.homeDirectory.standardizedFileURL else { return }
                monitor.homeDirectory = url
                monitor.refresh(upgrade: monitor.started)
            }
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

    private func drain() {
        reader.async { [files] in
            let events = Self.readInbox(files.inbox)
            guard !events.isEmpty else { return }
            let batch = events.map { ($0.agentEvent, $0.parentPID.flatMap(ClaudeCodeMonitor.agentProcess)) }
            Task { @MainActor in
                if !CodexSettings.shared.hooksSeen { CodexSettings.shared.hooksSeen = true }
                CodexMonitor.shared.objectWillChange.send()
                ClaudeCodeMonitor.shared.receive(batch)
                Log.info("codex events \(events.count)")
            }
        }
    }

    nonisolated static func readInbox(_ inbox: URL) -> [CodexHookEvent] {
        let fm = FileManager.default
        let urls = ((try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()) }
            .sorted { $0.1 < $1.1 }
        return urls.compactMap { url, created in
            defer { try? fm.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url, options: .uncached), data.count < 64 * 1024,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return CodexHookEvent(json: json, time: created, fileName: url.lastPathComponent)
        }
    }

    /// Removes leftovers from earlier runs: events too old to matter, unanswered replies and every
    /// half-written `.tmp` file. The same rules as Claude Code's inbox.
    nonisolated static func cleanUp(_ files: CodexHookFiles, now: Date) {
        ClaudeCodeMonitor.cleanUp(inbox: files.inbox, replies: files.replies, now: now)
    }

    // MARK: - Permission requests

    nonisolated static func writeApprovalFlag(_ files: CodexHookFiles, on: Bool, wait: Int) {
        if on {
            try? String(max(5, min(wait, CodexHook.maxApprovalWait))).write(to: files.approvals, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: files.approvals)
        }
    }

    // MARK: - Installing the hook

    nonisolated static func writeScript(_ files: CodexHookFiles) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: files.inbox, withIntermediateDirectories: true)
        try fm.createDirectory(at: files.replies, withIntermediateDirectories: true)
        if (try? String(contentsOf: files.script, encoding: .utf8)) != CodexHook.script {
            try CodexHook.script.write(to: files.script, atomically: true, encoding: .utf8)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: files.script.path)
    }

    /// Adds Deckhand's groups after any hooks the user already has. Codex then asks the user to review them.
    func installHooks() throws {
        guard availability.isInstalled || !checked else {
            throw CodexHooksFile.Failure(message: String(localized: "Codex isn't installed on this Mac."))
        }
        try Self.writeScript(files)
        try hooksFile.update { try CodexHooksFile.installing(into: $0, command: CodexHook.command(for: files)) }
        hooksInstalled = ((try? hooksFile.read()) ?? nil).map { CodexHooksFile.hasOurs($0, command: CodexHook.command(for: files)) } ?? false
        CodexSettings.shared.hooksSeen = false
        refresh()
        Log.info("codex hooks installed")
    }

    /// Removes Deckhand's groups and the script; the rest of the file stays as it was.
    func removeHooks() throws {
        try hooksFile.update { try CodexHooksFile.removing(from: $0, command: CodexHook.command(for: files)) }
        try? FileManager.default.removeItem(at: files.script)
        hooksInstalled = ((try? hooksFile.read()) ?? nil).map { CodexHooksFile.hasOurs($0, command: CodexHook.command(for: files)) } ?? false
        CodexSettings.shared.hooksSeen = false
        ClaudeCodeMonitor.shared.removeSessions(of: .codex)
        refresh()
        Log.info("codex hooks removed")
    }

    /// A fixed state for the snapshot run: connected or not, with Codex found or not.
    func showForSnapshot(connected: Bool, installed: Bool, warnings: Warnings = Warnings()) {
        hooksInstalled = connected
        availability = Availability(homeExists: installed, cliPath: installed ? "/opt/homebrew/bin/codex" : nil, appInstalled: false)
        self.warnings = warnings
        checked = true
    }
}

/// Finds the `codex` program the way Deckhand finds `claude`: the login shell first, then the usual folders.
enum CodexLocator {
    nonisolated static func find() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        if let found = shell().path { candidates.append(found) }
        candidates += standardCandidates(home: home)
        return candidates.lazy
            .map { ($0 as NSString).resolvingSymlinksInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `CODEX_HOME` as the login shell sets it, if it does.
    nonisolated static func shellHome() -> String? { shell().home }

    nonisolated static func standardCandidates(home: String) -> [String] {
        var list = [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex",
            "\(home)/.volta/bin/codex", "\(home)/.bun/bin/codex", "\(home)/Library/pnpm/codex",
            "\(home)/.local/share/pnpm/codex", "\(home)/.npm-global/bin/codex",
            "\(home)/.local/share/fnm/aliases/default/bin/codex", "\(home)/.asdf/shims/codex",
            "\(home)/.local/share/mise/shims/codex", "\(home)/.cargo/bin/codex",
        ]
        for (dir, tail) in [("\(home)/.nvm/versions/node", "bin/codex"), ("\(home)/.local/share/fnm/node-versions", "installation/bin/codex")] {
            let versions = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            list += versions.map { "\(dir)/\($0)/\(tail)" }
        }
        return list
    }

    private struct ShellResult: Sendable { var path: String?; var home: String? }

    /// The last answer of the login shell and when it came; asked again at most once a minute.
    private static let cache = OSAllocatedUnfairLock<(Date, ShellResult)?>(initialState: nil)

    nonisolated private static func shell() -> ShellResult {
        if let (time, result) = cache.withLock({ $0 }), Date().timeIntervalSince(time) < 60 { return result }
        let result = askShell()
        cache.withLock { $0 = (Date(), result) }
        return result
    }

    /// Asks the user's login shell, as an interactive shell so `.zshrc` runs, with a short timeout.
    nonisolated private static func askShell() -> ShellResult {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let script = "echo __DECKHAND_BEGIN__; command -v codex; echo \"CODEX_HOME=$CODEX_HOME\"; echo __DECKHAND_END__"
        guard let out = try? ProcessRunner.runSync(shell, ["-ilc", script], timeout: 6, env: ["DECKHAND_INTERNAL": "1"]),
              let begin = out.stdout.range(of: "__DECKHAND_BEGIN__\n") else { return ShellResult() }
        let body = out.stdout[begin.upperBound...]
        let lines = (body.range(of: "__DECKHAND_END__").map { body[..<$0.lowerBound] } ?? body).split(separator: "\n")
        var result = ShellResult()
        for line in lines {
            if line.hasPrefix("/"), result.path == nil { result.path = line.trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("CODEX_HOME="), line.count > 11 { result.home = String(line.dropFirst(11)) }
        }
        return result
    }
}
