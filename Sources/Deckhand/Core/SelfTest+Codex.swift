import AppKit

extension SelfTest {
    /// Codex sessions and the Codex hook. Owned by the Codex workstream.
    /// Everything runs on temporary folders and fixture payloads shaped like Codex's generated hook
    /// schemas (codex-rs/hooks/schema/generated); nothing touches `~/.codex` or the user's settings.
    static func codex(_ check: Check) {
        codexStateMachine(check)
        codexHooksFile(check)
        codexHookScript(check)
    }

    /// A payload as Codex sends it on stdin, with canaries in every field Deckhand must drop.
    static func codexPayload(_ event: String, session: String = "019a0000-0000-7000-8000-000000000001", _ extra: [String: Any] = [:]) -> String {
        var json: [String: Any] = [
            "session_id": session, "transcript_path": "/Users/me/.codex/sessions/CANARY-path.jsonl", "cwd": "/Users/me/deckhand",
            "hook_event_name": event, "model": "CANARY-model", "permission_mode": "default",
        ]
        if !["SessionStart", "SessionEnd"].contains(event) { json["turn_id"] = "turn-1" }
        if event == "SessionEnd" { json["reason"] = "other"; json["model"] = nil; json["permission_mode"] = nil }
        if event == "SessionStart" { json["source"] = "startup" }
        if event == "UserPromptSubmit" { json["prompt"] = "CANARY-prompt" }
        if event == "Stop" { json["stop_hook_active"] = false; json["last_assistant_message"] = "CANARY-reply" }
        json.merge(extra) { $1 }
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func codexStateMachine(_ check: Check) {
        var sessions: [String: ClaudeSession] = [:]
        let t0 = Date()
        let id = "019a0000-0000-7000-8000-000000000001"
        // The real filter turns each fixture into what the script would save
        func filtered(_ payload: String) -> [String: Any]? {
            guard let out = try? ProcessRunner.runSync("/usr/bin/jq", ["-c", "--arg", "app", "com.apple.Terminal", "--arg", "ppid", "1", CodexHook.filter],
                                                       input: payload, timeout: 5), out.status == 0 else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any]
        }
        @discardableResult
        func event(_ name: String, _ extra: [String: Any] = [:], at seconds: Double, file: String = "1790000000-1-com.apple.Terminal.json") -> ClaudeStateMachine.Signal? {
            guard let json = filtered(codexPayload(name, extra)),
                  let e = CodexHookEvent(json: json, time: t0.addingTimeInterval(seconds), fileName: file) else { return nil }
            return CodexStateMachine.apply(e.agentEvent, to: &sessions)
        }
        func s() -> ClaudeSession? { sessions[ClaudeSession.key(.codex, id)] }
        let bash: [String: Any] = ["tool_name": "Bash", "tool_use_id": "call-1", "tool_input": ["command": "CARGO_TERM=1 swift build CANARY-input"]]
        let patch: [String: Any] = ["tool_name": "apply_patch", "tool_use_id": "call-2",
                                    "tool_input": ["command": "*** Begin Patch\n*** Update File: Sources/Deckhand/NotchView.swift\n@@\n-CANARY-code\n*** End Patch\n"]]
        let sub: [String: Any] = ["agent_id": "agent-7", "agent_type": "worker"]

        check(filtered(codexPayload("PreToolUse", bash))?["target"] as? String == "swift"
              && filtered(codexPayload("PreToolUse", patch))?["target"] as? String == "NotchView.swift"
              && filtered(codexPayload("PreToolUse", ["tool_name": "mcp__docs__search", "tool_input": ["q": "x"]]))?["target"] as? String == "search",
              "codex: the filter keeps the command's first word, the patched file and the MCP tool")
        let kept = Set((filtered(codexPayload("PostToolUse", bash.merging(["tool_response": "CANARY-out"]) { $1 })) ?? [:]).keys)
        check(kept == ["v", "provider", "session_id", "hook_event_name", "turn_id", "cwd", "subagent", "tool", "target", "permission_mode", "app", "ppid"],
              "codex: the filter keeps only the allow-listed fields \(kept.sorted())")

        event("SessionStart", at: 0)
        check(s()?.state == .idle && s()?.provider == .codex && s()?.project == "deckhand" && s()?.app == "com.apple.Terminal", "codex: session starts idle")
        event("UserPromptSubmit", at: 1)
        event("PreToolUse", bash, at: 2)
        check(s()?.state == .working && s()?.detail == "Bash · swift", "codex: working on a shell command")
        event("PreToolUse", bash.merging(sub) { $1 }.merging(["tool_input": ["command": "cat secrets"]]) { $1 }, at: 2.5)
        check(s()?.detail == "Bash · swift" && s()?.toolsInFlight == 1, "codex: subagent tools don't change the line")
        let ask = event("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"]], at: 3)
        check(ask == .needsYou(project: "deckhand") && s()?.state == .waiting && s()?.request?.id == "1790000000-1-com.apple.Terminal",
              "codex: a permission request needs you and can be answered")
        event("PostToolUse", bash.merging(sub) { $1 }, at: 3.5)
        check(s()?.state == .waiting, "codex: a subagent's event doesn't end the main agent's wait")
        event("PostToolUse", bash.merging(["tool_response": "ok"]) { $1 }, at: 4)
        check(s()?.state == .working && s()?.request == nil && s()?.waitingSince == nil, "codex: the next event of the session ends the wait")
        event("PermissionRequest", ["tool_name": "apply_patch", "tool_input": patch["tool_input"]!], at: 5)
        event("PreToolUse", patch, at: 5.2)
        check(s()?.state == .working && s()?.detail == "Edit · NotchView.swift", "codex: a tool starting after the request ends the wait")
        event("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "curl x"]].merging(sub) { $1 }, at: 6)
        check(s()?.state == .waiting, "codex: a subagent's request needs you too")
        event("PostToolUse", bash.merging(sub) { $1 }, at: 6.5)
        check(s()?.state == .working, "codex: the subagent's next event ends its wait")
        let done = event("Stop", at: 20)
        check(done == .finished(project: "deckhand", seconds: 19) && s()?.state == .idle && s()?.toolsInFlight == 0, "codex: finished after 19 s")
        event("UserPromptSubmit", at: 30)
        let interrupted = event("Interrupt", at: 40)
        check(interrupted == nil && s()?.state == .idle && s()?.workStarted == nil, "codex: an interrupt ends the turn without a notice")
        event("UserPromptSubmit", at: 50)
        event("PreToolUse", ["tool_name": "mcp__docs__search", "tool_use_id": "c3", "tool_input": ["q": "CANARY"]], at: 51)
        check(s()?.detail == "search", "codex: MCP tools show their own name")
        sessions[ClaudeSession.key(.claudeCode, id)] = ClaudeSession(id: id, cwd: "/c", state: .working, updated: t0)
        event("SessionEnd", at: 60)
        check(s() == nil && sessions[ClaudeSession.key(.claudeCode, id)]?.state == .working, "codex: session end removes only the Codex session")
        check(CodexHookEvent(json: ["v": 1, "session_id": "x", "hook_event_name": "Stop"], time: t0, fileName: "1-1-unknown.json") == nil,
              "codex: files without the Codex marker are ignored")
    }

    private static func codexHooksFile(_ check: Check) {
        let command = "\"/x/Deckhand/codex-hook.sh\""
        let user = """
        {
            "description": "My hooks",
            "hooks": {
                "PreToolUse": [
                    {
                        "matcher": "^Bash$",
                        "hooks": [{ "type": "command", "command": "/usr/local/bin/guard", "timeout": 5 }]
                    }
                ],
                "Stop": [
                    { "hooks": [{ "type": "command", "command": "say done", "statusMessage": "Saying it \\u00e9" }] }
                ]
            }
        }

        """
        guard let installed = try? CodexHooksFile.installing(into: user, command: command),
              let doc = try? JSONDocument(installed) else {
            check(false, "codex: hooks install")
            return
        }
        let parsed = (try? JSONSerialization.jsonObject(with: Data(installed.utf8))) as? [String: Any]
        let hooks = parsed?["hooks"] as? [String: [[String: Any]]] ?? [:]
        func commands(_ event: String) -> [String] {
            (hooks[event] ?? []).map { (($0["hooks"] as? [[String: Any]])?.first?["command"] as? String) ?? "" }
        }
        check(CodexHook.events.allSatisfy { hooks[$0] != nil } && commands("PreToolUse") == ["/usr/local/bin/guard", command]
              && commands("Stop") == ["say done", command], "codex: Deckhand's groups come after the user's in every event")
        check(doc.root.members?.map(\.key) == ["description", "hooks"], "codex: the top level keeps only description and hooks")
        check(installed.contains(#""statusMessage": "Saying it \u00e9""#) && installed.contains(#""matcher": "^Bash$""#), "codex: user's text stays as written")
        check(CodexHooksFile.isCurrent(installed, command: command) && !CodexHooksFile.isCurrent(user, command: command), "codex: an up-to-date install is recognized")
        check((try? CodexHooksFile.installing(into: installed, command: command)) == installed, "codex: installing twice changes nothing")
        check((try? CodexHooksFile.removing(from: installed, command: command)) == user, "codex: removing restores the file byte for byte")
        for original in ["", "{}", "{\"hooks\":{\"Stop\":[]}}", "{\n\t\"hooks\": {\n\t\t\"Stop\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"x\"}]}]\n\t}\n}\n"] {
            let back = (try? CodexHooksFile.installing(into: original, command: command)).flatMap { try? CodexHooksFile.removing(from: $0, command: command) }
            let ok = original.isEmpty ? back == "{}\n" : (original.contains("[]") ? back == "{\"hooks\":{}}" || back == "{}" : back == original)
            check(ok, "codex: round trip of \(original.debugDescription)")
        }

        // The frozen entries: any change makes Codex ask the user to review them again
        let frozen = (try? CodexHooksFile.installing(into: "{}", command: command))?
            .replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: "")
        let expected = #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"\"/x/Deckhand/codex-hook.sh\"","timeout":10}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"\"/x/Deckhand/codex-hook.sh\"","timeout":10}]}],"PreToolUse":[{"hooks":[{"type":"command","command":"\"/x/Deckhand/codex-hook.sh\"","timeout":10}]}],"PermissionRequest":[{"hooks":[{"type":"command","command":"\"/x/Deckhand/codex-hook.sh\"","timeout":125,"statusMessage":"Deckhand:answerinthenotchorwaitfortheprompt"}]}],"PostToolUse":[{"hooks":[{"type":"command","command":"\"/x/Deckhand/codex-hook.sh\"","timeout":10}]}],"Stop":[{"hooks":[{"type":"command","command":"\"/x/Deckhand/codex-hook.sh\"","timeout":10}]}],"Interrupt":[{"hooks":[{"type":"command","command":"\"/x/Deckhand/codex-hook.sh\"","timeout":3}]}],"SessionEnd":[{"hooks":[{"type":"command","command":"\"/x/Deckhand/codex-hook.sh\"","timeout":3}]}]}}"#
        check(frozen == expected, "codex: the hook entries are frozen (no async, no matcher, fixed timeouts)")

        // An outdated Deckhand group is replaced where it is; the user's groups around it don't move
        let outdated = """
        {"hooks": {"PreToolUse": [
          {"hooks": [{"type": "command", "command": "first"}]},
          {"matcher": "*", "hooks": [{"type": "command", "command": "\\"/x/Deckhand/codex-hook.sh\\"", "async": true}]},
          {"hooks": [{"type": "command", "command": "last"}]}
        ]}}
        """
        let upgraded = (try? CodexHooksFile.installing(into: outdated, command: command)) ?? ""
        let pre = ((try? JSONSerialization.jsonObject(with: Data(upgraded.utf8))) as? [String: Any]).flatMap { ($0["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] } ?? []
        let preCommands = pre.map { (($0["hooks"] as? [[String: Any]])?.first?["command"] as? String) ?? "" }
        check(preCommands == ["first", command, "last"] && (pre[safe: 1] as NSDictionary?) == (CodexHook.entry(for: "PreToolUse", command: command).foundation as? NSDictionary)
              && upgraded.hasPrefix("{\"hooks\": {\"PreToolUse\": [\n  {\"hooks\": [{\"type\": \"command\", \"command\": \"first\"}]},\n  ")
              && upgraded.contains("{\"hooks\": [{\"type\": \"command\", \"command\": \"last\"}]}\n]"),
              "codex: an outdated entry is replaced in place \(preCommands)")
        check((try? CodexHooksFile.installing(into: "{ not json", command: command)) == nil
              && (try? CodexHooksFile.installing(into: #"{"hooks": []}"#, command: command)) == nil
              && (try? CodexHooksFile.installing(into: #"{"hooks": {"Stop": {}}}"#, command: command)) == nil, "codex: invalid files are refused")
        let claudeScript = "/x/Deckhand/claude-hook.sh"
        check(CodexHooksFile.hasClaudeHook(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"/x/Deckhand/claude-hook.sh\""}]}]}}"#, claudeScript: claudeScript)
              && !CodexHooksFile.hasClaudeHook(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/other/claude-hook.sh"}]}]}}"#, claudeScript: claudeScript)
              && !CodexHooksFile.hasClaudeHook(installed, claudeScript: claudeScript), "codex: an imported Claude Code hook of Deckhand's is noticed")

        // Only Deckhand's own script counts: another tool's codex-hook.sh stays, and in a group shared
        // with the user's handler only Deckhand's handler goes
        let other = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"/Users/me/.other-app/codex-hook.sh\""}]}]}}"#
        let withOther = (try? CodexHooksFile.installing(into: other, command: command)) ?? ""
        check(withOther.contains("/Users/me/.other-app/codex-hook.sh") && (try? CodexHooksFile.removing(from: withOther, command: command)) == other
              && !CodexHooksFile.hasOurs(other, command: command), "codex: another tool's codex-hook.sh is never touched")
        let shared = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"},{"type":"command","command":"/x/Deckhand/./codex-hook.sh"}]}]}}"#
        let sharedRemoved = (try? CodexHooksFile.removing(from: shared, command: command)) ?? ""
        check(sharedRemoved == #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#,
              "codex: in a shared group only Deckhand's handler is removed \(sharedRemoved)")
        let sharedInstalled = (try? CodexHooksFile.installing(into: shared, command: command)) ?? ""
        check(CodexHooksFile.isCurrent(sharedInstalled, command: command) && sharedInstalled.hasPrefix(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}, "#),
              "codex: install moves Deckhand's handler out of a user's group into its own")

        // config.toml is only read
        func notes(_ text: String) -> CodexConfigNotes { CodexConfigNotes.read(text, claudeScript: claudeScript) }
        check(notes("model = \"o3\"\n[features]\nhooks = false # off\n").hooksDisabled
              && notes("features.codex_hooks = false\n").hooksDisabled
              && !notes("[features]\nhooks = true\n[other]\nhooks = false\n").hooksDisabled, "codex: hooks turned off in config.toml are noticed")
        check(notes("[[hooks.PreToolUse]]\nmatcher = \"Bash\"\n").inlineHooks
              && !notes("[hooks.state.\"/Users/me/.codex/hooks.json:stop:0:0\"]\ntrusted_hash = \"x\"\n").inlineHooks
              && notes("[[hooks.Stop.hooks]]\ncommand = \"/x/Deckhand/claude-hook.sh\"\n").claudeHook, "codex: inline hooks in config.toml are noticed")

        // On disk: a symlinked file stays a symlink, the first backup is kept, invalid JSON is left alone
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("deckhand-codex-hooks-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try? fm.createDirectory(at: dir.appendingPathComponent("dotfiles"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: dir.appendingPathComponent("home/.codex"), withIntermediateDirectories: true)
        let real = dir.appendingPathComponent("dotfiles/hooks.json")
        let codexHome = CodexHooksFile.homeDirectory(environment: [:], home: dir.appendingPathComponent("home"))
        let link = codexHome.appendingPathComponent("hooks.json")
        try? Data(user.utf8).write(to: real)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        try? fm.createSymbolicLink(at: link, withDestinationURL: real)
        let file = CodexHooksFile(url: link, command: command)
        let wrote = (try? file.update { try CodexHooksFile.installing(into: $0, command: command) }) ?? false
        let again = (try? file.update { try CodexHooksFile.installing(into: $0, command: command) }) ?? true
        let removed = (try? file.update { try CodexHooksFile.removing(from: $0, command: command) }) ?? false
        let isLink = (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil
        let perms = (try? fm.attributesOfItem(atPath: real.path))?[.posixPermissions] as? Int
        check(wrote && !again && removed && isLink && perms == 0o600 && (try? String(contentsOf: real, encoding: .utf8)) == user
              && (try? String(contentsOf: file.backup, encoding: .utf8)) == user,
              "codex: writes through the symlink, keeps permissions and the first backup; a second install is a no-op")
        try? Data("{ broken".utf8).write(to: real)
        check((try? file.update { try CodexHooksFile.installing(into: $0, command: command) }) == nil
              && (try? String(contentsOf: real, encoding: .utf8)) == "{ broken", "codex: an invalid file is left as is")

        // A hooks.json Deckhand created goes away again on Disconnect
        let fresh = CodexHooksFile(url: dir.appendingPathComponent("fresh/hooks.json"), command: command)
        try? fm.createDirectory(at: dir.appendingPathComponent("fresh"), withIntermediateDirectories: true)
        _ = try? fresh.update { try CodexHooksFile.installing(into: $0, command: command) }
        let created = fm.fileExists(atPath: fresh.url.path)
        _ = try? fresh.update { try CodexHooksFile.removing(from: $0, command: command) }
        check(created && !fm.fileExists(atPath: fresh.url.path), "codex: a file Deckhand created is removed on disconnect")
        check(CodexHooksFile.homeDirectory(environment: ["CODEX_HOME": "/tmp/cx"], home: dir).path == "/tmp/cx"
              && codexHome.lastPathComponent == ".codex", "codex: CODEX_HOME is honored")
    }

    private static func codexHookScript(_ check: Check) {
        let fm = FileManager.default
        let files = CodexHookFiles(dir: fm.temporaryDirectory.appendingPathComponent("deckhand-codex-hook-\(UUID().uuidString)"))
        defer { try? fm.removeItem(at: files.dir) }
        guard (try? CodexMonitor.writeScript(files)) != nil else { check(false, "codex: hook script written"); return }
        func inbox() -> [String] { ((try? fm.contentsOfDirectory(atPath: files.inbox.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted() }
        func clear() { for name in (try? fm.contentsOfDirectory(atPath: files.inbox.path)) ?? [] { try? fm.removeItem(at: files.inbox.appendingPathComponent(name)) } }
        let runHook: @Sendable (String) -> ProcessRunner.Output? = { payload in
            try? ProcessRunner.runSync("/bin/sh", ["-c", CodexHook.command(for: files)], input: payload, timeout: 10,
                                       env: ["__CFBundleIdentifier": "com.apple.Terminal"])
        }
        let bash: [String: Any] = ["tool_name": "Bash", "tool_use_id": "c1", "tool_input": ["command": "TOKEN=CANARY-env git push CANARY-arg"]]
        check(runHook(codexPayload("PreToolUse", bash))?.status == 0 && inbox().isEmpty, "codex: the hook writes nothing while Deckhand isn't running")
        try? String(getpid()).write(to: files.pidFile, atomically: true, encoding: .utf8)

        let payloads = [
            codexPayload("SessionStart"),
            codexPayload("UserPromptSubmit"),
            codexPayload("PreToolUse", bash),
            codexPayload("PreToolUse", ["tool_name": "apply_patch", "tool_use_id": "c2",
                                        "tool_input": ["command": "*** Begin Patch\n*** Add File: docs/notes.md\n+CANARY-code\n*** End Patch"]]),
            codexPayload("PostToolUse", bash.merging(["tool_response": ["stdout": "CANARY-output"]]) { $1 }),
            codexPayload("Stop"),
            codexPayload("Interrupt"),
            codexPayload("SessionEnd"),
        ]
        let outputs = payloads.map(runHook)
        let names = inbox()
        let texts = names.compactMap { try? String(contentsOf: files.inbox.appendingPathComponent($0), encoding: .utf8) }
        let events = zip(names, texts).compactMap { name, text in
            (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]).flatMap { CodexHookEvent(json: $0, time: Date(), fileName: name) }
        }
        check(outputs.allSatisfy { $0?.status == 0 && $0?.stdout.isEmpty == true } && events.count == payloads.count
              && names.allSatisfy { $0.hasSuffix("-com.apple.Terminal.json") },
              "codex: every event exits 0, prints nothing and is saved \(names.count)")
        check(events.contains { $0.summary == "Bash · git" } && events.contains { $0.summary == "Edit · notes.md" }
              && events.contains { $0.name == "SessionEnd" } && events.allSatisfy { $0.cwd == "/Users/me/deckhand" }, "codex: saved events read back")
        let leaked = texts.filter { $0.contains("CANARY") || $0.contains("transcript") || $0.contains("model") }
        let others = ((fm.enumerator(atPath: files.dir.path)?.allObjects as? [String]) ?? [])
            .filter { !$0.hasSuffix(".json") && $0 != CodexHook.marker }
            .compactMap { try? String(contentsOf: files.dir.appendingPathComponent($0), encoding: .utf8) }
        check(leaked.isEmpty && !others.contains { $0.contains("CANARY") }, "codex: no prompt, input, output, reply, path or model reaches the disk")
        clear()
        for i in 0..<CodexHook.inboxLimit { fm.createFile(atPath: files.inbox.appendingPathComponent("0-\(i)-x.json").path, contents: Data("{}".utf8)) }
        _ = runHook(payloads[1])
        check(inbox().count == CodexHook.inboxLimit, "codex: a full inbox drops events")
        clear()

        // Approvals: with a reply file the script prints the decision, without one it prints nothing
        let request = codexPayload("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf CANARY"]])
        func answered(_ word: String) -> [String: Any]? {
            let group = DispatchGroup()
            nonisolated(unsafe) var answer: ProcessRunner.Output?
            group.enter()
            DispatchQueue.global().async {
                answer = runHook(request)
                group.leave()
            }
            var waited = 0
            while inbox().isEmpty && waited < 60 { usleep(50_000); waited += 1 }
            if let name = inbox().first {
                try? word.write(to: files.replies.appendingPathComponent((name as NSString).deletingPathExtension), atomically: true, encoding: .utf8)
            }
            _ = group.wait(timeout: .now() + 8)
            clear()
            return answer.flatMap { try? JSONSerialization.jsonObject(with: Data($0.stdout.utf8)) as? [String: Any] }
        }
        func decision(_ json: [String: Any]?) -> [String: Any]? {
            (json?["hookSpecificOutput"] as? [String: Any]).flatMap { $0["hookEventName"] as? String == "PermissionRequest" ? $0["decision"] as? [String: Any] : nil }
        }
        CodexMonitor.writeApprovalFlag(files, on: true, wait: 5)
        check(decision(answered("allow"))?["behavior"] as? String == "allow", "codex: Allow from the notch reaches Codex")
        let deny = decision(answered("deny"))
        check(deny?["behavior"] as? String == "deny" && (deny?["message"] as? String)?.isEmpty == false, "codex: Deny from the notch reaches Codex with a message")
        try? "1".write(to: files.approvals, atomically: true, encoding: .utf8)
        var start = Date()
        let unanswered = runHook(request)
        let took = Date().timeIntervalSince(start)
        check(unanswered?.status == 0 && unanswered?.stdout.isEmpty == true && took > 0.8 && took < 4 && inbox().count == 1,
              "codex: without an answer the script ends quietly so Codex shows its own prompt")
        clear()
        CodexMonitor.writeApprovalFlag(files, on: false, wait: 5)
        start = Date()
        let off = runHook(request)
        check(off?.stdout.isEmpty == true && Date().timeIntervalSince(start) < 3 && inbox().count == 1 && !fm.fileExists(atPath: files.approvals.path),
              "codex: with approvals off the request is recorded and not held up")
        clear()
        check(runHook("not json")?.status == 0 && runHook("[1]")?.status == 0 && inbox().isEmpty, "codex: bad input leaves no file")

        let read = CodexMonitor.readInbox(files.inbox)
        check(read.isEmpty && inbox().isEmpty, "codex: reading an empty inbox is fine")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
