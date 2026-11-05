import AppKit

extension SelfTest {
    /// Claude Code sessions, the hook and quick actions. Owned by the Claude workstream.
    static func claude(_ check: Check) {
        // Claude Code: one session through its hook events
        var sessions: [String: ClaudeSession] = [:]
        let t0 = Date()
        func event(_ name: String, _ extra: [String: Any] = [:], at seconds: Double) -> ClaudeCodeMonitor.Signal? {
            var e: [String: Any] = ["session_id": "s1", "cwd": "/Users/me/deckhand", "hook_event_name": name]
            e.merge(extra) { $1 }
            return ClaudeCodeMonitor.apply(event: e, app: "com.apple.Terminal", now: t0.addingTimeInterval(seconds), to: &sessions)
        }
        _ = event("SessionStart", at: 0)
        check(sessions["s1"]?.state == .idle && sessions["s1"]?.project == "deckhand", "claude: session starts idle")
        _ = event("UserPromptSubmit", ["prompt": "secret"], at: 1)
        _ = event("PreToolUse", ["tool_name": "Edit", "tool_input": ["file_path": "/a/NotchView.swift", "old_string": "x"]], at: 2)
        check(sessions["s1"]?.state == .working && sessions["s1"]?.detail == "Edit · NotchView.swift", "claude: working on a tool")
        let ask = event("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"], at: 3)
        check(ask == .needsYou(project: "deckhand") && sessions["s1"]?.state == .waiting, "claude: permission prompt needs you")
        _ = event("PostToolUse", ["tool_name": "Bash"], at: 4)
        check(sessions["s1"]?.state == .working, "claude: back to work after the answer")
        let done = event("Stop", at: 12)
        check(done == .finished(project: "deckhand", seconds: 11) && sessions["s1"]?.state == .idle, "claude: finished after 11 s")
        check(event("Notification", ["notification_type": "idle_prompt"], at: 70) == nil && sessions["s1"]?.state == .idle,
              "claude: idle reminder is not an alert")
        _ = event("SessionEnd", at: 80)
        check(sessions.isEmpty, "claude: session end removes it")
        check(ClaudeCodeMonitor.toolSummary(name: "Bash", input: ["command": "/usr/bin/git status --short"]) == "Bash · git"
              && ClaudeCodeMonitor.toolSummary(name: "mcp__github__create_issue", input: nil) == "issue",
              "claude: tool labels never show the full input")
        check(ClaudeCodeMonitor.appId(fromFileName: "1790000000-123-com.googlecode.iterm2.json") == "com.googlecode.iterm2"
              && ClaudeCodeMonitor.appId(fromFileName: "1790000000-123-unknown.json") == nil, "claude: app from event file name")

        // Installing keeps the user's own hooks and settings, removing restores them
        let userSettings: [String: Any] = [
            "env": ["A": "1"],
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]],
        ]
        let installed = ClaudeCodeMonitor.withHooks(userSettings, command: "\"/x/claude-hook.sh\"")
        let hooks = installed["hooks"] as? [String: Any] ?? [:]
        check(ClaudeCodeMonitor.events.allSatisfy { hooks[$0] != nil } && (hooks["Stop"] as? [Any])?.count == 2,
              "claude: hook added to every event next to the user's")
        let twice = ClaudeCodeMonitor.withHooks(installed, command: "\"/x/claude-hook.sh\"")
        check(((twice["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count == 2, "claude: installing twice adds it once")
        func json(_ o: [String: Any]) -> Data? { try? JSONSerialization.data(withJSONObject: o, options: .sortedKeys) }
        check(json(ClaudeCodeMonitor.withoutHooks(installed)) == json(userSettings), "claude: removing restores the settings")

        // The hook script writes the event to the folder with the app in the name
        let fakeHome = FileManager.default.temporaryDirectory.appendingPathComponent("deckhand-hook-\(UUID().uuidString)")
        let inbox = fakeHome.appendingPathComponent("Library/Application Support/Deckhand/claude-events")
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let script = fakeHome.appendingPathComponent("claude-hook.sh")
        try? ClaudeCodeMonitor.scriptBody.write(to: script, atomically: true, encoding: .utf8)
        let payload = #"{"session_id":"s2","hook_event_name":"Stop"}"#
        let hookRun = try? ClaudeCLI.run(executable: "/bin/sh", arguments: [script.path], input: payload, timeout: 5,
                                         env: ["HOME": fakeHome.path, "__CFBundleIdentifier": "com.apple.Terminal"])
        let written = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []
        let content = written.first.flatMap { try? String(contentsOf: inbox.appendingPathComponent($0), encoding: .utf8) }
        check(hookRun?.status == 0 && hookRun?.stdout.isEmpty == true && written.count == 1
              && written[0].hasSuffix("-com.apple.Terminal.json") && content == payload,
              "claude: hook script saves the event \(written)")
        let internalRun = try? ClaudeCLI.run(executable: "/bin/sh", arguments: [script.path], input: payload, timeout: 5,
                                             env: ["HOME": fakeHome.path, "DECKHAND_INTERNAL": "1"])
        check(internalRun?.status == 0 && ((try? FileManager.default.contentsOfDirectory(atPath: inbox.path))?.count ?? 0) == 1,
              "claude: Deckhand's own calls are ignored")
        try? FileManager.default.removeItem(at: fakeHome)

        let cliArgs = ClaudeCLI.arguments(system: "Fix it", model: .haiku55, allowRead: false)
        check(cliArgs.starts(with: ["-p", "--model", "haiku"]) && cliArgs.suffix(2) == ["--tools", ""]
              && cliArgs.contains("--no-session-persistence"), "claude code call has no tools and no saved session")
    }
}
