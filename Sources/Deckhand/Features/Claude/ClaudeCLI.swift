import AppKit

/// Runs quick actions through the Claude Code command line tool, so they use the
/// user's Claude subscription and need no API key.
///
/// Calls run in a temporary folder with no tools, no MCP servers and no saved session,
/// and with `DECKHAND_INTERNAL` set so Deckhand's own hook ignores them.
enum ClaudeCLI {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Where the `claude` binary is, resolved through symlinks.
    /// Apps started from Finder get a short PATH, so common install places are checked first,
    /// then the login shell is asked once.
    static let path: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.local/share/fnm/aliases/default/bin/claude",
            "\(home)/.volta/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        if let shellPath = shellLookup() { candidates.insert(shellPath, at: 0) }
        for c in candidates {
            let resolved = (c as NSString).resolvingSymlinksInPath
            if FileManager.default.isExecutableFile(atPath: resolved) { return resolved }
        }
        return nil
    }()

    static var isInstalled: Bool { path != nil }

    private static func shellLookup() -> String? {
        let out = try? run(executable: "/bin/zsh", arguments: ["-lc", "command -v claude"], input: nil, timeout: 5)
        // Shell startup files may print something first; the path is the last line
        let line = out?.stdout.split(separator: "\n").last.map(String.init) ?? ""
        return line.hasPrefix("/") ? line.trimmingCharacters(in: .whitespaces) : nil
    }

    /// Whether Claude Code is signed in. Runs `claude auth status`.
    static func isSignedIn() async -> Bool {
        guard let path else { return false }
        return await Task.detached {
            guard let out = try? run(executable: path, arguments: ["auth", "status", "--json"], input: nil, timeout: 15),
                  let data = out.stdout.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return json["loggedIn"] as? Bool ?? false
        }.value
    }

    /// Opens Terminal with `claude auth login`. A .command file needs no Automation permission.
    @MainActor
    static func openSignIn() {
        guard let path else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("deckhand-claude-login.command")
        let script = "#!/bin/sh\n'\(path.replacingOccurrences(of: "'", with: "'\\''"))' auth login\n"
        try? script.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
    }

    /// The model aliases the CLI accepts.
    static func alias(_ model: ClaudeModel) -> String {
        switch model {
        case .haiku55: return "haiku"
        case .sonnet55: return "sonnet"
        case .opus55: return "opus"
        }
    }

    /// The arguments for one call; split out so the self-test can check them.
    static func arguments(system: String?, model: ClaudeModel, allowRead: Bool) -> [String] {
        var args = ["-p", "--model", alias(model), "--output-format", "text",
                    "--no-session-persistence", "--strict-mcp-config", "--disable-slash-commands"]
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

    private static func call(system: String?, input: String, model: ClaudeModel, files: [String: Data]) async throws -> String {
        guard let path else {
            throw Failure(message: String(localized: "Claude Code is not installed. Install it or add an API key in Settings → Claude."))
        }
        let args = arguments(system: system, model: model, allowRead: !files.isEmpty)
        return try await Task.detached {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deckhand-claude-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            for (name, data) in files { try data.write(to: dir.appendingPathComponent(name)) }

            let out = try run(executable: path, arguments: args, input: input, timeout: 180, cwd: dir,
                              env: ["DECKHAND_INTERNAL": "1"])
            let text = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if out.status == 0, !text.isEmpty { return text }
            let message = (text + "\n" + out.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            if message.localizedCaseInsensitiveContains("not logged in") || message.contains("/login") {
                throw Failure(message: String(localized: "Claude Code is not signed in. Use Sign In in Settings → Claude."))
            }
            throw Failure(message: message.isEmpty ? String(localized: "Claude Code returned nothing") : String(message.prefix(400)))
        }.value
    }

    // MARK: - Process

    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    nonisolated static func run(executable: String, arguments: [String], input: String?, timeout: TimeInterval,
                                cwd: URL? = nil, env: [String: String] = [:]) throws -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let cwd { p.currentDirectoryURL = cwd }
        var environment = ProcessInfo.processInfo.environment
        // A Claude Code session that launched Deckhand must not leak into these calls
        for key in environment.keys where key.hasPrefix("CLAUDE_CODE_") || key == "CLAUDECODE" {
            environment[key] = nil
        }
        environment.merge(env) { $1 }
        p.environment = environment

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = inPipe
        try p.run()
        if let input { inPipe.fileHandleForWriting.write(Data(input.utf8)) }
        try? inPipe.fileHandleForWriting.close()

        // Read both pipes while waiting so a large reply cannot fill a pipe and stall the process
        nonisolated(unsafe) var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            throw Failure(message: String(localized: "Claude Code did not answer in time"))
        }
        p.waitUntilExit()
        return Output(status: p.terminationStatus,
                      stdout: String(data: outData, encoding: .utf8) ?? "",
                      stderr: String(data: errData, encoding: .utf8) ?? "")
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
