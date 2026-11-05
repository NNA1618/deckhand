import AppKit

extension SelfTest {
    /// Claude Code sessions, the hook and quick actions. Owned by the Claude workstream.
    /// Everything runs on temporary folders and fake payloads; nothing touches `~/.claude`.
    static func claude(_ check: Check) {
        claudeStateMachine(check)
        claudeSettingsFile(check)
        claudeHookScript(check)
        claudeQuickActions(check)
    }

    private static func claudeStateMachine(_ check: Check) {
        var sessions: [String: ClaudeSession] = [:]
        let t0 = Date()
        @discardableResult
        func event(_ name: String, _ extra: [String: Any] = [:], at seconds: Double, session: String = "s1") -> ClaudeStateMachine.Signal? {
            var json: [String: Any] = ["v": 1, "session_id": session, "cwd": "/Users/me/deckhand", "hook_event_name": name, "app": "com.apple.Terminal"]
            json.merge(extra) { $1 }
            guard let e = ClaudeHookEvent(json: json, time: t0.addingTimeInterval(seconds), fileName: "1790000000-1-com.apple.Terminal.json") else { return nil }
            return ClaudeStateMachine.apply(e.agentEvent, to: &sessions)
        }
        func s1() -> ClaudeSession? { sessions[ClaudeSession.key(.claudeCode, "s1")] }

        event("SessionStart", at: 0)
        check(s1()?.state == .idle && s1()?.project == "deckhand" && s1()?.provider == .claudeCode, "claude: session starts idle")
        event("UserPromptSubmit", at: 1)
        event("PreToolUse", ["tool": "Edit", "target": "NotchView.swift"], at: 2)
        check(s1()?.state == .working && s1()?.detail == "Edit · NotchView.swift" && s1()?.toolsInFlight == 1, "claude: working on a tool")
        event("PreToolUse", ["tool": "Read", "target": "secret.txt", "subagent": true], at: 2.5)
        check(s1()?.detail == "Edit · NotchView.swift" && s1()?.toolsInFlight == 1, "claude: subagent tools don't change the line")
        event("PostToolUse", ["tool": "Edit"], at: 3)
        event("PreToolUse", ["tool": "Bash", "target": "git"], at: 4)
        event("PreToolUse", ["tool": "Read", "target": "a.swift"], at: 4)
        let ask = event("PermissionRequest", ["tool": "Bash", "target": "git"], at: 4.2)
        check(ask == .needsYou(project: "deckhand") && s1()?.state == .waiting && s1()?.request?.tool == "Bash"
              && s1()?.request?.id == "1790000000-1-com.apple.Terminal", "claude: permission request needs you at once")
        event("PostToolUse", ["tool": "Read"], at: 5)
        check(s1()?.state == .waiting, "claude: a parallel tool finishing doesn't clear the wait")
        check(event("Notification", ["notification_type": "permission_prompt"], at: 10) == .needsYou(project: "deckhand")
              && s1()?.detail == "Bash · git", "claude: the reminder repeats the signal and keeps the tool")
        event("PostToolUse", ["tool": "Bash"], at: 12)
        check(s1()?.state == .working && s1()?.request == nil && s1()?.waitingSince == nil, "claude: the tool's result ends the wait")
        let done = event("Stop", at: 20)
        check(done == .finished(project: "deckhand", seconds: 19) && s1()?.state == .idle && s1()?.toolsInFlight == 0, "claude: finished after 19 s")
        for type in ["auth_success", "agent_completed", "elicitation_complete", "quota_auto_resume_fired", "plugin_notification", "idle_prompt"] {
            if type == "quota_auto_resume_fired" { continue }
            check(event("Notification", ["notification_type": type], at: 30) == nil && s1()?.state == .idle, "claude: \(type) is not an alert")
        }
        for type in ["elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"] {
            event("UserPromptSubmit", at: 40)
            check(event("Notification", ["notification_type": type], at: 41) == .needsYou(project: "deckhand") && s1()?.state == .waiting,
                  "claude: \(type) needs you")
        }
        event("PreToolUse", ["tool": "mcp__docs__search"], at: 45)
        check(s1()?.state == .working && s1()?.detail == "search", "claude: a dialog ends when work goes on")
        let failed = event("StopFailure", ["error": "rate_limit"], at: 50)
        check(failed == .failed(project: "deckhand", message: ClaudeStateMachine.failureText("rate_limit")) && s1()?.state == .idle,
              "claude: an API error ends the turn")
        event("UserPromptSubmit", at: 60)
        event("PermissionRequest", ["tool": "AskUserQuestion"], at: 61)
        check(s1()?.state == .waiting && s1()?.request == nil, "claude: questions are answered in the terminal only")
        event("SessionEnd", at: 80)
        check(sessions.isEmpty, "claude: session end removes it")

        // Older Deckhand versions saved the whole payload; only the same few fields are taken from it
        let legacy = ClaudeHookEvent(json: ["session_id": "s", "hook_event_name": "PreToolUse", "tool_name": "Bash",
                                            "tool_input": ["command": "API_KEY=sk-1 /usr/bin/git push"], "prompt": "secret"],
                                     time: t0, fileName: "1790000000-123-com.googlecode.iterm2.json")
        check(legacy?.summary == "Bash · git" && legacy?.app == "com.googlecode.iterm2", "claude: old event files still read")
        check(ClaudeHookEvent.appId(fromFileName: "1790000000-123-unknown.json") == nil, "claude: no app from an unknown name")

        // Stuck states end; waiting sessions come first
        var stuck: [String: ClaudeSession] = [
            "a": ClaudeSession(id: "a", cwd: "/a", state: .working, workStarted: t0, updated: t0),
            "b": ClaudeSession(id: "b", cwd: "/b", state: .working, workStarted: t0, updated: t0, toolsInFlight: 1),
            "c": ClaudeSession(id: "c", cwd: "/c", state: .idle, updated: t0, process: ClaudeProcess(pid: 1, started: 0)),
        ]
        _ = ClaudeStateMachine.expire(&stuck, now: t0.addingTimeInterval(9 * 60), alive: { _ in false })
        check(stuck["a"]?.state == .idle && stuck["b"]?.state == .working && stuck["c"] == nil,
              "claude: a quiet session without a tool ends, a long tool keeps going, a gone process is dropped")
        let order = ClaudeSession.ordered([
            ClaudeSession(id: "i", cwd: "", state: .idle, updated: t0.addingTimeInterval(9)),
            ClaudeSession(id: "w", cwd: "", state: .working, updated: t0),
            ClaudeSession(id: "n", cwd: "", state: .waiting, updated: t0.addingTimeInterval(-100)),
        ]).map(\.id)
        check(order == ["n", "w", "i"], "claude: waiting, then working, then idle \(order)")
        check(ClaudeCodeMonitor.elapsed(since: t0, now: t0.addingTimeInterval(3720)) == String(format: String(localized: "%dh %02dm"), 1, 2)
              && ClaudeCodeMonitor.elapsed(since: t0, now: t0.addingTimeInterval(247)) == "4:07", "claude: elapsed labels")
        check(ClaudeCodeMonitor.agentProcess(parent: getpid())?.pid == getpid()
              && ClaudeCodeMonitor.isAlive(ClaudeCodeMonitor.agentProcess(parent: getpid())!)
              && !ClaudeCodeMonitor.isAlive(ClaudeProcess(pid: getpid(), started: 1)), "claude: processes are told apart by start time")
    }

    private static func claudeSettingsFile(_ check: Check) {
        let command = "\"/x/Deckhand/claude-hook.sh\""
        let user = """
        {
            "model": "opus",
            "zeta": 0.1,
            "alpha": [1, 2.50, 1e3],
            "hooks": {
                "Stop": [
                    {
                        "hooks": [{ "type": "command", "command": "say done" }]
                    }
                ]
            },
            "path": "a\\/b \\u00e9"
        }

        """
        guard let installed = try? ClaudeSettingsFile.installing(into: user, command: command) else {
            check(false, "claude: settings install")
            return
        }
        let parsed = (try? JSONSerialization.jsonObject(with: Data(installed.utf8))) as? [String: Any]
        let hooks = parsed?["hooks"] as? [String: Any] ?? [:]
        check(ClaudeHook.events.allSatisfy { hooks[$0] != nil } && (hooks["Stop"] as? [Any])?.count == 2,
              "claude: hook added to every event next to the user's")
        func before(_ a: String, _ b: String) -> Bool {
            guard let x = installed.range(of: a), let y = installed.range(of: b) else { return false }
            return x.lowerBound < y.lowerBound
        }
        check(installed.contains("\"zeta\": 0.1,") && installed.contains("[1, 2.50, 1e3]"), "claude: user's numbers stay as written")
        check(installed.contains(#""path": "a\/b \u00e9""#), "claude: user's escapes stay as written")
        check(before("\"model\"", "\"zeta\"") && before("\"zeta\"", "\"alpha\"") && before("\"alpha\"", "\"hooks\""),
              "claude: user's key order stays")
        check(installed.contains("\n        \"PreToolUse\": [\n            {\n                \"matcher\": \"*\""),
              "claude: new entries follow the file's indentation")
        check(ClaudeSettingsFile.isCurrent(installed, command: command) && !ClaudeSettingsFile.isCurrent(user, command: command),
              "claude: an up-to-date install is recognized")
        let twice = (try? ClaudeSettingsFile.installing(into: installed, command: command)) ?? ""
        check(twice == installed, "claude: installing twice changes nothing")
        check((try? ClaudeSettingsFile.removing(from: installed)) == user, "claude: removing restores the file byte for byte")
        for original in ["", "{}", "{\"a\":1}", "{\n\t\"a\": true\n}\n"] {
            let back = (try? ClaudeSettingsFile.installing(into: original, command: command)).flatMap { try? ClaudeSettingsFile.removing(from: $0) }
            let ok = original.isEmpty ? back == "{}\n" : back == original
            check(ok, "claude: round trip of \(original.debugDescription)")
        }
        // Only Deckhand's own entries go; an old 0.4 entry inside the user's list is replaced
        let mixed = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"/old/claude-hook.sh\"","timeout":5}]},{"hooks":[{"type":"command","command":"say"}]}]}}"#
        let cleaned = (try? ClaudeSettingsFile.removing(from: mixed)) ?? ""
        check(cleaned == #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say"}]}]}}"#, "claude: removes only Deckhand's entries")
        check((try? ClaudeSettingsFile.installing(into: "{ not json", command: command)) == nil
              && (try? ClaudeSettingsFile.installing(into: #"{"hooks": []}"#, command: command)) == nil, "claude: invalid files are refused")

        // On disk: a symlinked file stays a symlink, the first backup is kept, invalid JSON is left alone
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("deckhand-claude-settings-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try? fm.createDirectory(at: dir.appendingPathComponent("dotfiles"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let real = dir.appendingPathComponent("dotfiles/settings.json")
        let link = dir.appendingPathComponent(".claude/settings.json")
        try? Data(user.utf8).write(to: real)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        try? fm.createSymbolicLink(at: link, withDestinationURL: real)
        let file = ClaudeSettingsFile(url: link)
        let wrote = (try? file.update { try ClaudeSettingsFile.installing(into: $0, command: command) }) ?? false
        let removed = (try? file.update { try ClaudeSettingsFile.removing(from: $0) }) ?? false
        let isLink = (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil
        let perms = (try? fm.attributesOfItem(atPath: real.path))?[.posixPermissions] as? Int
        check(wrote && removed && isLink && perms == 0o600 && (try? String(contentsOf: real, encoding: .utf8)) == user
              && (try? String(contentsOf: file.backup, encoding: .utf8)) == user,
              "claude: writes through the symlink, keeps permissions and the first backup")
        try? Data("{ broken".utf8).write(to: real)
        check((try? file.update { try ClaudeSettingsFile.installing(into: $0, command: command) }) == nil
              && (try? String(contentsOf: real, encoding: .utf8)) == "{ broken"
              && (try? String(contentsOf: file.backup, encoding: .utf8)) == user, "claude: an invalid file is left as is")
        check(ClaudeSettingsFile.configDirectory(environment: ["CLAUDE_CONFIG_DIR": "/tmp/cc"], home: dir).path == "/tmp/cc"
              && ClaudeSettingsFile.configDirectory(environment: [:], home: dir).lastPathComponent == ".claude", "claude: CLAUDE_CONFIG_DIR is honored")
        check(ClaudeHook.entry(for: "PreToolUse", command: command).foundation as? NSDictionary
              == ["matcher": "*", "hooks": [["type": "command", "command": command, "async": true]]] as NSDictionary
              && (ClaudeHook.entry(for: "PermissionRequest", command: command).foundation as? [String: Any]).map { ($0["hooks"] as? [[String: Any]])?.first?["async"] == nil } == true,
              "claude: tool hooks run in the background, permission requests don't")
    }

    private static func claudeHookScript(_ check: Check) {
        let fm = FileManager.default
        let files = ClaudeHookFiles(dir: fm.temporaryDirectory.appendingPathComponent("deckhand-hook-\(UUID().uuidString)"))
        defer { try? fm.removeItem(at: files.dir) }
        guard (try? ClaudeCodeMonitor.writeScript(files)) != nil else { check(false, "claude: hook script written"); return }
        func inbox() -> [String] { ((try? fm.contentsOfDirectory(atPath: files.inbox.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted() }
        func clear() { for name in (try? fm.contentsOfDirectory(atPath: files.inbox.path)) ?? [] { try? fm.removeItem(at: files.inbox.appendingPathComponent(name)) } }
        let runHook: @Sendable (String, [String: String]) -> ProcessRunner.Output? = { payload, env in
            try? ProcessRunner.runSync("/bin/sh", ["-c", ClaudeHook.command(for: files)], input: payload, timeout: 10,
                                       env: ["__CFBundleIdentifier": "com.apple.Terminal"].merging(env) { $1 })
        }
        func run(_ payload: String, env: [String: String] = [:]) -> ProcessRunner.Output? { runHook(payload, env) }
        let secret = "SECRET-7f3a"
        let payload = """
        {"session_id":"s2","hook_event_name":"PreToolUse","cwd":"/Users/me/app","prompt":"\(secret)","transcript_path":"/x/\(secret).jsonl",
         "tool_name":"Bash","tool_input":{"command":"TOKEN=\(secret) git push --force \(secret)","description":"\(secret)"},
         "tool_response":{"stdout":"\(secret)"},"last_assistant_message":"\(secret)","error":"\(secret)","agent_id":null}
        """
        check(run(payload)?.status == 0 && inbox().isEmpty, "claude: the hook writes nothing while Deckhand isn't running")
        try? String(getpid()).write(to: files.pidFile, atomically: true, encoding: .utf8)
        let out = run(payload)
        let names = inbox()
        let text = names.first.flatMap { try? String(contentsOf: files.inbox.appendingPathComponent($0), encoding: .utf8) } ?? ""
        let event = names.first.flatMap { name in
            (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]).flatMap { ClaudeHookEvent(json: $0, time: Date(), fileName: name) }
        }
        check(out?.status == 0 && out?.stdout.isEmpty == true && names.count == 1 && names[0].hasSuffix("-com.apple.Terminal.json")
              && event?.summary == "Bash · git" && event?.cwd == "/Users/me/app" && event?.app == "com.apple.Terminal",
              "claude: the hook saves the event's few fields \(names)")
        check(!text.contains(secret) && !text.contains("prompt") && !text.contains("transcript"), "claude: no prompt, command, output or path in the file")
        clear()
        check(run(payload, env: ["DECKHAND_INTERNAL": "1"])?.status == 0 && inbox().isEmpty, "claude: Deckhand's own calls are ignored")
        try? "999999".write(to: files.pidFile, atomically: true, encoding: .utf8)
        check(run(payload)?.status == 0 && inbox().isEmpty, "claude: a stale pid file stops the hook")
        try? String(getpid()).write(to: files.pidFile, atomically: true, encoding: .utf8)
        check(run("not json")?.status == 0 && run("[1]")?.status == 0 && inbox().isEmpty
              && ((try? fm.contentsOfDirectory(atPath: files.inbox.path)) ?? []).isEmpty, "claude: bad input leaves no file")
        for i in 0..<ClaudeHook.inboxLimit { fm.createFile(atPath: files.inbox.appendingPathComponent("0-\(i)-x.json").path, contents: Data("{}".utf8)) }
        _ = run(payload)
        check(inbox().count == ClaudeHook.inboxLimit, "claude: a full inbox drops events")
        clear()

        // Approve from the notch: the script waits for the reply file and prints the decision
        ClaudeCodeMonitor.writeApprovalFlag(files, on: true, wait: 5)
        let request = #"{"session_id":"s3","hook_event_name":"PermissionRequest","cwd":"/a","tool_name":"Bash","tool_input":{"command":"rm -rf x"}}"#
        let group = DispatchGroup()
        nonisolated(unsafe) var answer: ProcessRunner.Output?
        group.enter()
        DispatchQueue.global().async {
            answer = runHook(request, [:])
            group.leave()
        }
        var waited = 0
        while inbox().isEmpty && waited < 60 { usleep(50_000); waited += 1 }
        if let name = inbox().first {
            try? "allow".write(to: files.replies.appendingPathComponent((name as NSString).deletingPathExtension), atomically: true, encoding: .utf8)
        }
        _ = group.wait(timeout: .now() + 8)
        let decision = answer.flatMap { try? JSONSerialization.jsonObject(with: Data($0.stdout.utf8)) as? [String: Any] }
        let behavior = ((decision?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])?["behavior"] as? String
        check(behavior == "allow", "claude: an answer from the notch reaches Claude Code")
        clear()
        ClaudeCodeMonitor.writeApprovalFlag(files, on: false, wait: 5)
        let start = Date()
        let unattended = run(request)
        check(unattended?.stdout.isEmpty == true && Date().timeIntervalSince(start) < 3 && !fm.fileExists(atPath: files.approvals.path),
              "claude: with approvals off the prompt is not held up")

        // Reading the inbox deletes what it read, in order
        clear()
        for (i, name) in ["UserPromptSubmit", "Stop"].enumerated() {
            let url = files.inbox.appendingPathComponent("17900000\(i)-1-unknown.json")
            try? Data(#"{"v":1,"session_id":"s","hook_event_name":"\#(name)"}"#.utf8).write(to: url)
            usleep(2000)
        }
        let read = ClaudeCodeMonitor.readInbox(files.inbox)
        check(read.map(\.name) == ["UserPromptSubmit", "Stop"] && inbox().isEmpty, "claude: events are read in order and removed")
    }

    private static func claudeQuickActions(_ check: Check) {
        let all = ClaudeCLI.Capabilities(safeMode: true, settings: true, effort: true)
        let args = ClaudeCLI.arguments(system: "Fix it", model: .haiku55, allowRead: false, capabilities: all)
        check(args.starts(with: ["-p", "--model", "haiku"]) && args.suffix(2) == ["--tools", ""] && args.contains("--no-session-persistence")
              && args.contains("--safe-mode") && args.contains(#"{"disableAllHooks":true}"#) && args.contains("low"),
              "claude code call runs without tools, hooks, plugins or CLAUDE.md")
        let old = ClaudeCLI.arguments(system: nil, model: .sonnet55, allowRead: true, capabilities: ClaudeCLI.Capabilities())
        check(!old.contains("--safe-mode") && !old.contains("--settings") && !old.contains("--effort") && old.suffix(4) == ["--tools", "Read", "--allowedTools", "Read"],
              "claude code call leaves out flags an older version lacks")
        check(ClaudeCLI.Capabilities.parse(help: "  --safe-mode   Start\n  --effort <level>") == ClaudeCLI.Capabilities(safeMode: true, settings: false, effort: true),
              "claude: flags read from --help")
        let search = ClaudeCLI.searchPath(binary: "/usr/bin/true", shellPath: "/nonexistent:/bin")
        check(search.hasPrefix("/usr/bin:/bin") && !search.contains("nonexistent"), "claude: the child's PATH starts with the binary's folder")
        check(ClaudeHookEvent.commandName("A=1 B=2 /usr/local/bin/npm test") == "npm" && ClaudeHookEvent.commandName("X=1") == nil,
              "claude: command names skip variable assignments")

        check(ClaudeErrors.friendly("Error: Invalid API key · Please run /login") == String(localized: "Claude Code is not signed in. Use Sign In in Settings → Claude.")
              && ClaudeErrors.friendly("API Error: 529 overloaded_error") == String(localized: "Claude is overloaded right now. Try again in a minute.")
              && ClaudeErrors.friendly("getaddrinfo ENOTFOUND api.anthropic.com") == String(localized: "Can't reach Claude. Check your internet connection.")
              && ClaudeErrors.friendly("Claude usage limit reached. Your limit resets 3pm (Europe/Moscow)")?.contains("3pm") == true,
              "claude: errors are worded for people")

        let body = ClaudeAPI.body(system: "s", messages: [], model: .haiku55, maxTokens: ClaudeAPI.maxTokens)
        check(body["max_tokens"] as? Int == 16000 && (body["output_config"] as? [String: String])?["effort"] == "low", "claude api: room to answer, low effort")
        func read(_ status: Int, _ json: String) -> Result<String, Error> { Result { try ClaudeAPI.read(status: status, data: Data(json.utf8)) } }
        check((try? read(200, #"{"content":[{"type":"thinking","thinking":"x"},{"type":"text","text":"Hi"}],"stop_reason":"end_turn"}"#).get()) == "Hi"
              && (try? read(200, #"{"content":[],"stop_reason":"refusal"}"#).get()) == nil
              && (try? read(200, #"{"content":[{"type":"text","text":"Long"}],"stop_reason":"max_tokens"}"#).get())?.hasPrefix("Long") == true
              && (try? read(429, #"{"type":"error","error":{"type":"rate_limit_error","message":"x"}}"#).get()) == nil,
              "claude api: stop reasons and errors are handled")
        check(ClaudeAPI.looksLikeKey("sk-ant-api03-abcdefghijklmnop") && !ClaudeAPI.looksLikeKey("sk-proj-123") && !ClaudeAPI.looksLikeKey("hello"),
              "claude api: key format check")
        let ordered = ClaudeSettings.ordered(Presets.all, order: ["fix", "missing", "rewrite"]).map(\.id)
        check(ordered.prefix(2) == ["fix", "rewrite"] && ordered.count == Presets.all.count, "claude: preset order keeps new presets")

        // A tool that exits without reading a large input must not take Deckhand down with SIGPIPE
        let big = String(repeating: "x", count: 512 * 1024)
        let early = try? ProcessRunner.runSync("/bin/sh", ["-c", "exit 3"], input: big, timeout: 5)
        check(early?.status == 3, "claude: early exit with unread input is survived")
        let started = Date()
        let slow = try? ProcessRunner.runSync("/bin/sleep", ["5"], timeout: 0.3)
        check(slow?.stopped == true && Date().timeIntervalSince(started) < 3, "claude: a slow tool is stopped at the timeout")
    }
}
