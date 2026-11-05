import AppKit
import os

/// Runs quick actions through the Claude Code command line tool, so they use the
/// user's Claude subscription and need no API key.
///
/// Calls run in an empty temporary folder with no tools, no MCP servers, no saved session and,
/// where the installed version allows it, without the user's hooks, plugins and CLAUDE.md
/// (`--safe-mode`, `disableAllHooks`). `DECKHAND_INTERNAL` makes Deckhand's own hook ignore them.
enum ClaudeCLI {
    typealias Failure = ProcessRunner.Failure

    /// Where `claude` is and what it needs to run.
    struct Location: Equatable, Sendable {
        /// The binary, symlinks resolved (version managers point at short-lived folders).
        let path: String
        /// PATH for the child: the binary's folder first, so `#!/usr/bin/env node` finds the right Node.
        let searchPath: String
        /// `CLAUDE_CONFIG_DIR` from the login shell, when set there.
        let configDirectory: String?
    }

    /// Flags this `claude` lists in `--help`. Older versions reject flags they don't know.
    struct Capabilities: Equatable, Sendable {
        var safeMode = false
        var settings = false
        var effort = false

        static func parse(help: String) -> Capabilities {
            Capabilities(safeMode: help.contains("--safe-mode"), settings: help.contains("--settings"), effort: help.contains("--effort"))
        }
    }

    private struct Cache {
        var location: Location?
        var checked: Date?
        var capabilities: [String: Capabilities] = [:]
    }
    private static let cache = OSAllocatedUnfairLock(initialState: Cache())

    /// Where the `claude` binary is; nil until `resolve()` has run or when it is missing.
    /// Never looks anything up itself: asking the login shell can take seconds.
    static var path: String? {
        let location = cache.withLock { $0.location }
        guard let location else {
            refreshInBackground()
            return nil
        }
        if !FileManager.default.isExecutableFile(atPath: location.path) {
            // Removed or updated to another version: look again
            refreshInBackground()
            return nil
        }
        return location.path
    }

    static var isInstalled: Bool { path != nil }

    static var location: Location? { cache.withLock { $0.location } }

    /// Looks again later when the binary was missing, at most every 30 seconds.
    private static func refreshInBackground() {
        let due = cache.withLock { state -> Bool in
            guard let checked = state.checked, Date().timeIntervalSince(checked) > 30 else { return false }
            state.checked = Date()
            return true
        }
        if due { Task.detached(priority: .utility) { resolve(force: true) } }
    }

    /// Finds the binary. A path chosen in Settings wins; then the user's login shell is asked
    /// (apps started from Finder get a short PATH, and fnm, nvm and others set PATH in `.zshrc`);
    /// then the usual install folders and version manager folders are searched.
    /// Blocks for up to 6 s: call it off the main thread.
    @discardableResult
    nonisolated static func resolve(force: Bool = false) -> String? {
        if !force, let known = cache.withLock({ $0.checked != nil ? $0.location : nil }) { return known.path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let manual = UserDefaults.standard.string(forKey: "claudeCLIPath") ?? ""
        let shell = shellLookup()
        var candidates: [String] = []
        if !manual.isEmpty { candidates.append((manual as NSString).expandingTildeInPath) }
        if let found = shell.path { candidates.append(found) }
        candidates += standardCandidates(home: home)
        let found = candidates.lazy
            .map { ($0 as NSString).resolvingSymlinksInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        let location = found.map {
            Location(path: $0, searchPath: searchPath(binary: $0, shellPath: shell.searchPath), configDirectory: shell.configDirectory)
        }
        cache.withLock {
            $0.location = location
            $0.checked = Date()
        }
        Log.info("claude cli: \(location?.path ?? "not found")")
        return location?.path
    }

    /// Install places in order of likelihood, newest version first within a version manager.
    nonisolated static func standardCandidates(home: String) -> [String] {
        var list = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.volta/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/Library/pnpm/claude",
            "\(home)/.local/share/pnpm/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.local/share/fnm/aliases/default/bin/claude",
            "\(home)/.asdf/shims/claude",
            "\(home)/.local/share/mise/shims/claude",
        ]
        let managers: [(String, String)] = [
            ("\(home)/.local/share/fnm/node-versions", "installation/bin/claude"),
            ("\(home)/Library/Application Support/fnm/node-versions", "installation/bin/claude"),
            ("\(home)/.fnm/node-versions", "installation/bin/claude"),
            ("\(home)/.nvm/versions/node", "bin/claude"),
            ("\(home)/.asdf/installs/nodejs", "bin/claude"),
            ("\(home)/.local/share/mise/installs/node", "bin/claude"),
            ("\(home)/.n/bin", "claude"),
        ]
        for (dir, tail) in managers {
            let versions = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            list += versions.map { "\(dir)/\($0)/\(tail)" }
        }
        return list
    }

    /// The binary's folder, then the login shell's PATH entries that still exist, then the system's.
    nonisolated static func searchPath(binary: String, shellPath: String?) -> String {
        var parts = [(binary as NSString).deletingLastPathComponent]
        parts += (shellPath ?? "").split(separator: ":").map(String.init)
        parts += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return parts.filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    private struct ShellResult { var path: String?; var searchPath: String?; var configDirectory: String? }

    /// Asks the user's login shell, as an interactive shell so `.zshrc` and `config.fish` run.
    nonisolated private static func shellLookup() -> ShellResult {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let script = "echo __DECKHAND_BEGIN__; command -v claude; /usr/bin/env; echo __DECKHAND_END__"
        guard let out = try? ProcessRunner.runSync(shell, ["-ilc", script], timeout: 6, env: ["DECKHAND_INTERNAL": "1"]) else {
            return ShellResult()
        }
        return parseShellOutput(out.stdout)
    }

    /// Reads what the probe printed between its markers; startup files may print around it.
    nonisolated private static func parseShellOutput(_ text: String) -> ShellResult {
        guard let begin = text.range(of: "__DECKHAND_BEGIN__\n") else { return ShellResult() }
        let body = text[begin.upperBound...]
        let lines = (body.range(of: "__DECKHAND_END__").map { body[..<$0.lowerBound] } ?? body).split(separator: "\n")
        var result = ShellResult()
        for line in lines {
            if line.hasPrefix("/"), result.path == nil, !line.contains("=") { result.path = line.trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("PATH=") { result.searchPath = String(line.dropFirst(5)) }
            if line.hasPrefix("CLAUDE_CONFIG_DIR=") { result.configDirectory = String(line.dropFirst(18)) }
        }
        return result
    }

    /// The environment additions for running `claude`: its PATH and, when the login shell sets it,
    /// `CLAUDE_CONFIG_DIR`, so calls and the sign-in check use the same config folder whose
    /// settings.json Deckhand edits.
    nonisolated static func environment(for location: Location, _ extra: [String: String] = [:]) -> [String: String] {
        var env = ["PATH": location.searchPath]
        if let dir = location.configDirectory, !dir.isEmpty { env["CLAUDE_CONFIG_DIR"] = (dir as NSString).expandingTildeInPath }
        env.merge(extra) { $1 }
        return env
    }

    /// The flags the installed version lists, read once per binary.
    nonisolated static func capabilities(for location: Location) -> Capabilities {
        if let known = cache.withLock({ $0.capabilities[location.path] }) { return known }
        let help = (try? ProcessRunner.runSync(location.path, ["--help"], timeout: 10, env: environment(for: location)))?.stdout ?? ""
        let found = Capabilities.parse(help: help)
        if !help.isEmpty { cache.withLock { $0.capabilities[location.path] = found } }
        return found
    }

    // MARK: - Sign-in

    struct AuthStatus: Equatable, Sendable {
        var loggedIn: Bool
        var email: String?
        var configDirectory: String?
    }

    /// Runs `claude auth status --json`; nil when Claude Code is missing or the answer can't be read.
    static func authStatus() async -> AuthStatus? {
        guard let location = await Task.detached(operation: { resolve().flatMap { _ in ClaudeCLI.location } }).value,
              let out = try? await ProcessRunner.run(location.path, ["auth", "status", "--json"], timeout: 15,
                                                     env: environment(for: location, ["DECKHAND_INTERNAL": "1"])),
              let data = out.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return AuthStatus(loggedIn: json["loggedIn"] as? Bool ?? false,
                          email: json["email"] as? String,
                          configDirectory: json["configDirectory"] as? String)
    }

    static func isSignedIn() async -> Bool { await authStatus()?.loggedIn ?? false }

    /// Opens Terminal with `claude auth login`. A .command file needs no Automation permission.
    @MainActor
    static func openSignIn() {
        guard let location else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("deckhand-claude-login.command")
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let config = environment(for: location)["CLAUDE_CONFIG_DIR"].map { "export CLAUDE_CONFIG_DIR=\(quote($0))\n" } ?? ""
        let script = "#!/bin/sh\nexport PATH=\(quote(location.searchPath))\n\(config)\(quote(location.path)) auth login\n"
        try? script.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
    }

    // MARK: - Calls

    /// The model aliases the CLI accepts.
    static func alias(_ model: ClaudeModel) -> String {
        switch model {
        case .haiku55: return "haiku"
        case .sonnet55: return "sonnet"
        case .opus55: return "opus"
        }
    }

    /// The arguments for one call; split out so the self-test can check them.
    static func arguments(system: String?, model: ClaudeModel, allowRead: Bool, capabilities: Capabilities) -> [String] {
        var args = ["-p", "--model", alias(model), "--output-format", "text",
                    "--no-session-persistence", "--strict-mcp-config", "--disable-slash-commands"]
        if capabilities.safeMode { args.append("--safe-mode") }
        if capabilities.settings { args += ["--settings", #"{"disableAllHooks":true}"#] }
        if capabilities.effort { args += ["--effort", "low"] }
        if let system, !system.isEmpty { args += ["--system-prompt", system] }
        args += allowRead ? ["--tools", "Read", "--allowedTools", "Read"] : ["--tools", ""]
        return args
    }

    static func complete(system: String?, input: String, model: ClaudeModel) async throws -> String {
        try await call(system: system, input: input, model: model, files: [:])
    }

    /// Asks about an image. The PNG is written next to the call and read by Claude's Read tool.
    static func ask(about png: Data, question: String, model: ClaudeModel) async throws -> String {
        let prompt = "Read the screenshot in the file screenshot.png in the current folder, then answer: \(question)"
        return try await call(
            system: "You look at screenshots for the user. Answer in the language of the question. Be concise and specific. Do not mention the file.",
            input: prompt, model: model, files: ["screenshot.png": png])
    }

    /// Runs one call. Cancelling the task stops `claude`.
    private static func call(system: String?, input: String, model: ClaudeModel, files: [String: Data]) async throws -> String {
        let found = await Task.detached { () -> (Location, Capabilities)? in
            resolve()
            if let known = ClaudeCLI.location, !FileManager.default.isExecutableFile(atPath: known.path) { resolve(force: true) }
            guard let location = ClaudeCLI.location else { return nil }
            return (location, capabilities(for: location))
        }.value
        guard let (location, capabilities) = found else {
            throw Failure(message: String(localized: "Claude Code is not installed. Install it or add an API key in Settings → Claude."))
        }
        let args = arguments(system: system, model: model, allowRead: !files.isEmpty, capabilities: capabilities)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deckhand-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, data) in files { try data.write(to: dir.appendingPathComponent(name)) }

        let out = try await ProcessRunner.run(location.path, args, input: input, timeout: 180, cwd: dir,
                                              env: environment(for: location, ["DECKHAND_INTERNAL": "1"]))
        if out.stopped { throw Failure(message: String(localized: "Claude Code did not answer in time")) }
        let text = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.status == 0, !text.isEmpty { return text }
        let message = (text + "\n" + out.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        throw Failure(message: ClaudeErrors.friendly(message) ?? String(localized: "Claude Code returned nothing"))
    }
}

/// Turns raw error text from Claude Code or the API into a sentence for the user.
enum ClaudeErrors {
    static func friendly(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        func has(_ words: String...) -> Bool { words.contains { lower.contains($0) } }
        if has("not logged in", "/login", "please log in", "invalid api key", "authentication_error", "oauth token") {
            return String(localized: "Claude Code is not signed in. Use Sign In in Settings → Claude.")
        }
        if has("usage limit", "rate limit", "rate_limit", "limit reached", "429") {
            if let reset = text.range(of: #"resets? (at )?[^.\n|]+"#, options: [.regularExpression, .caseInsensitive]) {
                return String(localized: "You've reached your Claude usage limit (\(String(text[reset]).trimmingCharacters(in: .whitespaces))).")
            }
            return String(localized: "You've reached your Claude usage limit. Try again later.")
        }
        if has("overloaded", "529") {
            return String(localized: "Claude is overloaded right now. Try again in a minute.")
        }
        if has("enotfound", "econnrefused", "econnreset", "etimedout", "getaddrinfo", "fetch failed", "network", "unable to connect", "offline") {
            return String(localized: "Can't reach Claude. Check your internet connection.")
        }
        if has("env: node", "node: no such file", "command not found") {
            return String(localized: "Claude Code could not start: Node.js was not found.")
        }
        return String(text.prefix(300))
    }
}

/// Where quick actions go: Claude Code (the subscription) or the API with a key.
enum ClaudeBackend: String, CaseIterable, Identifiable {
    case claudeCode, apiKey
    var id: String { rawValue }
}

/// The single entry point the tabs use for Claude.
@MainActor
enum ClaudeEngine {
    static var backend: ClaudeBackend { Settings.shared.claudeBackend }

    /// Whether quick actions can run at all with the chosen backend.
    static var isAvailable: Bool {
        backend == .claudeCode ? ClaudeCLI.isInstalled : ClaudeAPI.shared.hasAPIKey
    }

    /// Runs one quick action. Cancelling the calling task stops it.
    static func complete(system: String?, input: String, model: ClaudeModel) async throws -> String {
        switch backend {
        case .claudeCode:
            return try await ClaudeCLI.complete(system: system, input: input, model: model)
        case .apiKey:
            return try await ClaudeAPI.shared.complete(system: system, messages: [.init(role: .user, content: input)], model: model)
        }
    }

    static func ask(about png: Data, question: String) async throws -> String {
        switch backend {
        case .claudeCode: return try await ClaudeCLI.ask(about: png, question: question, model: .sonnet55)
        case .apiKey: return try await ClaudeAPI.shared.ask(about: png, question: question)
        }
    }

    /// Opens the Claude desktop app, or claude.ai when it is not installed.
    static func openClaudeApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else if let web = URL(string: "https://claude.ai/new") {
            NSWorkspace.shared.open(web)
        }
    }
}
