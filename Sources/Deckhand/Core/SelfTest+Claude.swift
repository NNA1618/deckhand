import AppKit

extension SelfTest {
    /// Claude Code sessions, the hook and quick actions. Owned by the Claude workstream.
    /// Everything runs on temporary folders and fake payloads; nothing touches `~/.claude`.
    static func claude(_ check: Check) {
        claudeStateMachine(check)
        claudeSettingsFile(check)
        claudeHookScript(check)
        claudeQuickActions(check)
        claudeHookPaths(check)
        claudeOwnerUpgrade(check)
        claudeLeftovers(check)
        claudeProcessRunner(check)
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

        // A denial or Esc at the terminal prompt sends nothing; idle_prompt a minute later ends the wait
        event("UserPromptSubmit", at: 100)
        event("PreToolUse", ["tool": "Bash", "target": "rm"], at: 101)
        event("PermissionRequest", ["tool": "Bash", "target": "rm"], at: 101.2)
        event("Notification", ["notification_type": "idle_prompt"], at: 161)
        check(s1()?.state == .idle && s1()?.request == nil && s1()?.waitingSince == nil && s1()?.waitingTool == nil,
              "claude: idle_prompt ends a wait nobody answered in the notch")
        // "No" with feedback: Claude goes on with other tools; one started well after the request ends the wait
        event("UserPromptSubmit", at: 200)
        event("PreToolUse", ["tool": "Bash", "target": "rm"], at: 201)
        event("PermissionRequest", ["tool": "Bash", "target": "rm"], at: 201.1)
        event("PreToolUse", ["tool": "Read", "target": "a.swift"], at: 201.3)
        check(s1()?.state == .waiting, "claude: a tool started alongside the request doesn't end the wait")
        event("PostToolUse", ["tool": "Bash", "subagent": true], at: 205)
        check(s1()?.state == .waiting, "claude: a subagent finishing a tool of the same name doesn't end the main wait")
        event("PreToolUse", ["tool": "Read", "target": "b.swift", "subagent": true], at: 206)
        check(s1()?.state == .waiting, "claude: a subagent's tool doesn't end the main wait")
        event("PreToolUse", ["tool": "Edit", "target": "c.swift"], at: 215)
        check(s1()?.state == .working && s1()?.detail == "Edit · c.swift" && s1()?.request == nil,
              "claude: a main-agent tool well after the request means it was answered")
        // A subagent's own permission request: only that subagent's events end it
        event("PermissionRequest", ["tool": "Bash", "target": "make", "subagent": true], at: 220)
        event("PreToolUse", ["tool": "Grep"], at: 230)
        check(s1()?.state == .waiting, "claude: the main agent working on doesn't end a subagent's wait")
        event("PostToolUse", ["tool": "Bash", "subagent": true], at: 240)
        check(s1()?.state == .working, "claude: the subagent's tool result ends its wait")
        event("SessionEnd", at: 250)

        // The project follows CLAUDE_PROJECT_DIR, not the shell's `cd`
        event("SessionStart", ["project": "/Users/me/repo", "cwd": "/Users/me/repo"], at: 300)
        event("PreToolUse", ["tool": "Bash", "target": "npm", "project": "/Users/me/repo", "cwd": "/Users/me/repo/packages/web"], at: 301)
        check(s1()?.project == "repo" && s1()?.cwd == "/Users/me/repo", "claude: cd inside the session keeps the project name")
        event("SessionEnd", at: 302)
        // Event files from before 0.5 have no project: the first folder seen names it
        event("SessionStart", ["cwd": "/Users/me/app"], at: 310)
        event("PreToolUse", ["tool": "Bash", "cwd": "/Users/me/app/sub"], at: 311)
        check(s1()?.project == "app", "claude: without a project folder the first cwd names the session")
        event("SessionEnd", at: 312)

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
        check((try? ClaudeSettingsFile.removing(from: installed, command: command)) == user, "claude: removing restores the file byte for byte")
        for original in ["", "{}", "{\"a\":1}", "{\n\t\"a\": true\n}\n"] {
            let back = (try? ClaudeSettingsFile.installing(into: original, command: command)).flatMap { try? ClaudeSettingsFile.removing(from: $0, command: command) }
            let ok = original.isEmpty ? back == "{}\n" : back == original
            check(ok, "claude: round trip of \(original.debugDescription)")
        }
        // Only Deckhand's own entries go; an old 0.4 entry inside the user's list is replaced
        let mixed = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"/x/Deckhand/claude-hook.sh\"","timeout":5}]},{"hooks":[{"type":"command","command":"say"}]}]}}"#
        let cleaned = (try? ClaudeSettingsFile.removing(from: mixed, command: command)) ?? ""
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
        let removed = (try? file.update { try ClaudeSettingsFile.removing(from: $0, command: command) }) ?? false
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
        check(event?.project == "/Users/me/app" || event?.project == ProcessInfo.processInfo.environment["CLAUDE_PROJECT_DIR"],
              "claude: the project folder is saved")
        clear()
        _ = run(payload, env: ["CLAUDE_PROJECT_DIR": "/Users/me"])
        let projectEvent = inbox().first.flatMap { name in
            (try? Data(contentsOf: files.inbox.appendingPathComponent(name))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { ClaudeHookEvent(json: $0, time: Date(), fileName: name) }
        }
        check(projectEvent?.project == "/Users/me" && projectEvent?.cwd == "/Users/me/app", "claude: CLAUDE_PROJECT_DIR names the project, cwd stays the shell's folder")
        clear()
        _ = run(payload, env: ["CLAUDE_PROJECT_DIR": ""])
        let fallback = inbox().first.flatMap { name in
            (try? Data(contentsOf: files.inbox.appendingPathComponent(name))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        check(fallback?["project"] as? String == "/Users/me/app", "claude: without CLAUDE_PROJECT_DIR the project is the cwd")
        clear()
        check(run(payload, env: ["DECKHAND_INTERNAL": "1"])?.status == 0 && inbox().isEmpty, "claude: Deckhand's own calls are ignored")
        try? "999999".write(to: files.pidFile, atomically: true, encoding: .utf8)
        check(run(payload)?.status == 0 && inbox().isEmpty, "claude: a stale pid file stops the hook")
        // After a crash the id may belong to another program: a live process that isn't Deckhand
        if let other = try? Process.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"]) {
            try? String(other.processIdentifier).write(to: files.pidFile, atomically: true, encoding: .utf8)
            check(run(payload)?.status == 0 && inbox().isEmpty, "claude: a reused pid of another program stops the hook")
            other.terminate()
        }
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

        // Turning approvals off mid-wait hands the question back at once
        clear()
        ClaudeCodeMonitor.writeApprovalFlag(files, on: true, wait: 30)
        nonisolated(unsafe) var handedBack: ProcessRunner.Output?
        nonisolated(unsafe) var waitedFor: TimeInterval = 0
        group.enter()
        DispatchQueue.global().async {
            let begin = Date()
            handedBack = runHook(request, [:])
            waitedFor = Date().timeIntervalSince(begin)
            group.leave()
        }
        waited = 0
        while inbox().isEmpty && waited < 60 { usleep(50_000); waited += 1 }
        usleep(300_000)
        let switchedOff = Date()
        ClaudeCodeMonitor.writeApprovalFlag(files, on: false, wait: 30)
        _ = group.wait(timeout: .now() + 8)
        check(handedBack?.stdout.isEmpty == true && waitedFor < 5 && Date().timeIntervalSince(switchedOff) < 2,
              "claude: approvals turned off mid-wait end the wait")

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

    /// Deckhand's entries are told apart by the script's full path, never by its file name.
    private static func claudeHookPaths(_ check: Check) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let script = "\(home)/Library/Application Support/Deckhand/claude-hook.sh"
        let command = "\"\(script)\""
        for written in [command, script, "'\(script)'", "  \(command) ", "~/Library/Application Support/Deckhand/claude-hook.sh",
                        "\"~/Library/Application Support/Deckhand/claude-hook.sh\"", "~/Library/Application\\ Support/Deckhand/claude-hook.sh",
                        "\"$HOME/Library/Application Support/Deckhand/claude-hook.sh\"", "\(home)/Library/Application Support/Deckhand/./claude-hook.sh"] {
            check(HookCommand.runs(written, script: command), "claude: \(written.replacingOccurrences(of: home, with: "~home")) is Deckhand's")
        }
        for foreign in ["~/.other-app/claude-hook.sh", "\"\(home)/.other-notch-app/claude-hook.sh\"", "claude-hook.sh",
                        "\(home)/Library/Application Support/Fringe/claude-hook.sh", "\(command) --other", "say claude-hook.sh"] {
            check(!HookCommand.runs(foreign, script: command), "claude: \(foreign.replacingOccurrences(of: home, with: "~home")) is not Deckhand's")
        }
        // Another tool's claude-hook.sh stays on install, launch and Disconnect
        let other = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"~/.other-app/claude-hook.sh"}]}]}}"#
        let withOurs = (try? ClaudeSettingsFile.installing(into: other, command: command)) ?? ""
        check(!ClaudeSettingsFile.hasOurs(other, command: command)
              && (try? ClaudeSettingsFile.removing(from: other, command: command)) == other
              && withOurs.contains("~/.other-app/claude-hook.sh") && ClaudeSettingsFile.isCurrent(withOurs, command: command)
              && (try? ClaudeSettingsFile.removing(from: withOurs, command: command)) == other,
              "claude: another tool's claude-hook.sh is never touched")
        // Deckhand's handler inside a user's matcher group: only that handler goes
        let shared = """
        {"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"say hi"},{"type":"command","command":\(JSONValue.string(command).render(indent: "", unit: "", pretty: false)),"timeout":5}]}]}}
        """
        let sharedRemoved = (try? ClaudeSettingsFile.removing(from: shared, command: command)) ?? ""
        check(sharedRemoved == #"{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"say hi"}]}]}}"#,
              "claude: removing keeps the user's handlers in a shared group \(sharedRemoved)")
        let sharedInstalled = (try? ClaudeSettingsFile.installing(into: shared, command: command)) ?? ""
        let sharedJSON = (try? JSONSerialization.jsonObject(with: Data(sharedInstalled.utf8))) as? [String: Any]
        let pre = ((sharedJSON?["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]) ?? []
        check(!ClaudeSettingsFile.isCurrent(shared, command: command) && ClaudeSettingsFile.isCurrent(sharedInstalled, command: command)
              && pre.count == 2 && (pre[0]["hooks"] as? [[String: Any]])?.count == 1,
              "claude: an install moves Deckhand's handler out of the user's group")
    }

    /// The owner's 0.4.1 settings.json, shape only: two-space indent, " : " separators, no final
    /// newline, other keys first, seven entries with timeout 5, one written with `~`.
    private static func claudeOwnerUpgrade(_ check: Check) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let files = ClaudeHookFiles(dir: URL(fileURLWithPath: "\(home)/Library/Application Support/Deckhand", isDirectory: true))
        let command = ClaudeHook.command(for: files)
        func old(_ written: String, matcher: Bool) -> String {
            let quoted = JSONValue.string(written).render(indent: "", unit: "", pretty: false)
            return """
            [ {
                  \(matcher ? "\"matcher\" : \"*\",\n          " : "")"hooks" : [ {
                    "command" : \(quoted),
                    "timeout" : 5,
                    "type" : "command"
                  } ]
                } ]
            """
        }
        let events: [(String, Bool)] = [("Notification", false), ("PostToolUse", true), ("PreToolUse", true), ("SessionEnd", false),
                                        ("SessionStart", false), ("Stop", false), ("UserPromptSubmit", false)]
        let entries = events.enumerated().map { i, item in
            "    \"\(item.0)\" : " + old(i == 3 ? "\"~/Library/Application Support/Deckhand/claude-hook.sh\"" : command, matcher: item.1)
        }
        let original = "{\n  \"agentPushNotifEnabled\" : true,\n  \"env\" : {\n    \"EXAMPLE_FLAG\" : \"1\"\n  },\n  \"hooks\" : {\n"
            + entries.joined(separator: ",\n") + "\n  }\n}"
        let dir = fm.temporaryDirectory.appendingPathComponent("deckhand-claude-owner-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = ClaudeSettingsFile(url: dir.appendingPathComponent("settings.json"))
        try? Data(original.utf8).write(to: file.url)
        let parsedOriginal = (try? JSONSerialization.jsonObject(with: Data(original.utf8))) as? [String: Any]
        check(parsedOriginal != nil && ClaudeSettingsFile.hasOurs(original, command: command) && !ClaudeSettingsFile.isCurrent(original, command: command),
              "claude upgrade: the 0.4.1 entries are recognized as Deckhand's and outdated")
        let wrote = (try? file.update { try ClaudeSettingsFile.installing(into: $0, command: command) }) ?? false
        let upgraded = ((try? file.read()) ?? nil) ?? ""
        let json = (try? JSONSerialization.jsonObject(with: Data(upgraded.utf8))) as? [String: Any]
        let hooks = json?["hooks"] as? [String: Any] ?? [:]
        let exact = ClaudeHook.events.allSatisfy { event in
            guard let list = hooks[event] as? [[String: Any]], list.count == 1 else { return false }
            return (list[0] as NSDictionary).isEqual(ClaudeHook.entry(for: event, command: command).foundation)
        }
        check(wrote && exact && hooks.count == ClaudeHook.events.count && !upgraded.contains("\"timeout\" : 5") && !upgraded.contains("~/Library"),
              "claude upgrade: exactly one current Deckhand entry per event")
        check(json?["agentPushNotifEnabled"] as? Bool == true && (json?["env"] as? NSDictionary) == (parsedOriginal?["env"] as? NSDictionary)
              && upgraded.hasPrefix("{\n  \"agentPushNotifEnabled\" : true,\n  \"env\" : {\n    \"EXAMPLE_FLAG\" : \"1\"\n  },\n"),
              "claude upgrade: the other keys stay as written")
        check(ClaudeSettingsFile.isCurrent(upgraded, command: command)
              && (try? file.update { try ClaudeSettingsFile.installing(into: $0, command: command) }) == false,
              "claude upgrade: a second launch writes nothing")
        check((try? String(contentsOf: file.backup, encoding: .utf8)) == original, "claude upgrade: the backup holds the 0.4.1 file")
        let removed = (try? ClaudeSettingsFile.removing(from: upgraded, command: command)) ?? ""
        let removedJSON = (try? JSONSerialization.jsonObject(with: Data(removed.utf8))) as? [String: Any]
        check(removedJSON?["hooks"] == nil && removedJSON?["agentPushNotifEnabled"] as? Bool == true && removedJSON?.count == 2,
              "claude upgrade: Disconnect afterwards leaves only the user's keys")
    }

    /// What a previous run or a crash leaves behind.
    private static func claudeLeftovers(_ check: Check) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("deckhand-claude-leftovers-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let files = ClaudeHookFiles(dir: dir)
        let codex = CodexHookFiles(dir: dir)
        for folder in [files.inbox, files.replies, codex.inbox, codex.replies] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }

        // Quitting releases only a pid file this instance owns, and then the approval switches too
        ClaudeCodeMonitor.writeApprovalFlag(files, on: true, wait: 30)
        CodexMonitor.writeApprovalFlag(codex, on: true, wait: 30)
        try? "4242".write(to: files.pidFile, atomically: true, encoding: .utf8)
        let foreign = ClaudeCodeMonitor.release(files, pid: getpid())
        check(!foreign && fm.fileExists(atPath: files.pidFile.path) && fm.fileExists(atPath: files.approvals.path)
              && fm.fileExists(atPath: codex.approvals.path), "claude: quitting leaves another instance's pid file and switches")
        try? "\(getpid())\n".write(to: files.pidFile, atomically: true, encoding: .utf8)
        let own = ClaudeCodeMonitor.release(files, pid: getpid())
        check(own && !fm.fileExists(atPath: files.pidFile.path) && !fm.fileExists(atPath: files.approvals.path)
              && !fm.fileExists(atPath: codex.approvals.path), "claude: quitting removes its own pid file and both approval switches")

        // Launch cleanup: every .tmp goes however new; fresh events stay; old events and replies go
        let now = Date()
        for inbox in [files.inbox, codex.inbox] {
            for name in ["fresh.tmp", "fresh.json", "old.json"] { fm.createFile(atPath: inbox.appendingPathComponent(name).path, contents: Data("{}".utf8)) }
            try? fm.setAttributes([.creationDate: now.addingTimeInterval(-3600)], ofItemAtPath: inbox.appendingPathComponent("old.json").path)
        }
        fm.createFile(atPath: files.replies.appendingPathComponent("r").path, contents: Data("allow".utf8))
        fm.createFile(atPath: codex.replies.appendingPathComponent("r").path, contents: Data("allow".utf8))
        ClaudeCodeMonitor.cleanUp(files, now: now)
        CodexMonitor.cleanUp(codex, now: now)
        for (name, inbox, replies) in [("claude", files.inbox, files.replies), ("codex", codex.inbox, codex.replies)] {
            let left = ((try? fm.contentsOfDirectory(atPath: inbox.path)) ?? []).sorted()
            check(left == ["fresh.json"] && ((try? fm.contentsOfDirectory(atPath: replies.path)) ?? []).isEmpty,
                  "\(name): launch cleanup removes every .tmp, old events and replies \(left)")
        }
    }

    private static func claudeProcessRunner(_ check: Check) {
        // A tool that leaves a background child holding its pipes still answers promptly
        var started = Date()
        let detached = try? ProcessRunner.runSync("/bin/sh", ["-c", "echo hi; sleep 20 &"], timeout: 5)
        check(detached?.stdout == "hi\n" && detached?.status == 0 && detached?.stopped == false && Date().timeIntervalSince(started) < 2,
              "claude: a backgrounded grandchild doesn't hold up the answer")
        started = Date()
        let semaphore = DispatchSemaphore(value: 0)
        // A box rather than a captured var: the task is sent to another isolation domain (Swift 6.2 checks that)
        final class Box: @unchecked Sendable { var output: ProcessRunner.Output? }
        let box = Box()
        Task.detached {
            box.output = try? await ProcessRunner.run("/bin/sh", ["-c", "echo hi; sleep 20 &"], timeout: 5)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 6)
        let asyncOut = box.output
        check(asyncOut?.stdout == "hi\n" && asyncOut?.stopped == false && Date().timeIntervalSince(started) < 2,
              "claude: the async runner returns promptly too")
        // Stopping ends the background children as well, through the process group
        let stopped = try? ProcessRunner.runSync("/bin/sh", ["-c", "sleep 30 & echo $!; wait"], timeout: 0.5)
        let child = Int32((stopped?.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        var gone = false
        for _ in 0..<40 where !gone {
            gone = child > 0 && kill(child, 0) != 0
            if !gone { usleep(50_000) }
        }
        check(stopped?.stopped == true && child > 0 && gone, "claude: stopping a tool ends its background children")
        if child > 0 && !gone { kill(child, SIGKILL) }

        // CLAUDE_CONFIG_DIR from the login shell reaches every claude call
        let location = ClaudeCLI.Location(path: "/usr/bin/true", searchPath: "/usr/bin", configDirectory: "~/cc")
        let env = ClaudeCLI.environment(for: location, ["DECKHAND_INTERNAL": "1"])
        let plain = ClaudeCLI.environment(for: ClaudeCLI.Location(path: "/usr/bin/true", searchPath: "/usr/bin", configDirectory: nil))
        check(env["CLAUDE_CONFIG_DIR"] == FileManager.default.homeDirectoryForCurrentUser.path + "/cc" && env["PATH"] == "/usr/bin"
              && env["DECKHAND_INTERNAL"] == "1" && plain["CLAUDE_CONFIG_DIR"] == nil,
              "claude: the shell's CLAUDE_CONFIG_DIR is passed to claude")
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
