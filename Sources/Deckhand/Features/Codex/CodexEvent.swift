import Foundation

/// One Codex hook event as the script wrote it: only the fields Deckhand shows.
struct CodexHookEvent: Equatable, Sendable {
    var session: String
    var name: String
    var turn: String?
    var cwd = ""
    var subagent = false
    var tool: String?
    /// The file name, the first word of a command, or an MCP tool's name.
    var target: String?
    var source: String?
    var app: String?
    var parentPID: Int32?
    /// When the hook ran: the event file's creation date.
    var time: Date
    /// The event file's name without extension; names the reply to a permission request.
    var fileId = ""

    /// Reads an event file. Only files the Codex script wrote count: they carry `"provider":"codex"`.
    init?(json: [String: Any], time: Date, fileName: String) {
        guard json["provider"] as? String == "codex",
              let session = json["session_id"] as? String, !session.isEmpty,
              let name = json["hook_event_name"] as? String, !name.isEmpty else { return nil }
        self.session = session
        self.name = name
        self.time = time
        fileId = (fileName as NSString).deletingPathExtension
        turn = json["turn_id"] as? String
        cwd = json["cwd"] as? String ?? ""
        subagent = json["subagent"] as? Bool ?? false
        tool = json["tool"] as? String
        target = json["target"] as? String
        source = json["source"] as? String
        app = (json["app"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ClaudeHookEvent.appId(fromFileName: fileName)
        parentPID = (json["ppid"] as? String).flatMap { Int32($0) }
    }

    /// "Bash · git", "Edit · NotchView.swift", "search" for an MCP tool, or the tool alone.
    var summary: String? {
        guard let tool else { return nil }
        if tool.hasPrefix("mcp__") { return target ?? tool }
        let short = ["apply_patch", "Write"].contains(tool) ? "Edit" : (["shell", "exec_command", "local_shell"].contains(tool) ? "Bash" : tool)
        guard let target, !target.isEmpty else { return short }
        return "\(short) · \(target)"
    }

    /// The Codex hook adapter: maps Codex's hook events to the shared ones.
    var agentEvent: AgentEvent {
        let kind: AgentEvent.Kind
        switch name {
        case "SessionStart": kind = .sessionStarted
        case "UserPromptSubmit": kind = .promptSubmitted
        case "PreToolUse": kind = .toolStarted
        case "PostToolUse": kind = .toolFinished
        case "PermissionRequest": kind = .permissionRequested(answerable: true)
        case "Stop": kind = .turnFinished
        case "Interrupt": kind = .idle
        case "SessionEnd": kind = .sessionEnded
        default: kind = .other
        }
        // Codex reports the session's folder, which a command's `cd` doesn't change
        return AgentEvent(provider: .codex, session: session, kind: kind, time: time, cwd: cwd, project: cwd.isEmpty ? nil : cwd, app: app,
                          subagent: subagent, tool: tool, summary: summary, requestId: fileId)
    }
}

/// Codex's differences from Claude Code on top of the shared state machine.
///
/// Codex sends no event when a permission prompt is answered, so a wait ends with the next event
/// of the same session. A subagent's events don't end the main agent's wait, and subagent tools
/// don't change the session's line.
enum CodexStateMachine {
    /// Marks a wait a subagent started, so that subagent's next event can end it.
    static let subagentMark = "subagent:"

    static func apply(_ e: AgentEvent, to sessions: inout [String: ClaudeSession]) -> ClaudeStateMachine.Signal? {
        let key = ClaudeSession.key(e.provider, e.session)
        if var s = sessions[key], s.state == .waiting {
            let isRequest: Bool
            if case .permissionRequested = e.kind { isRequest = true } else { isRequest = false }
            let subagentWait = s.waitingTool?.hasPrefix(subagentMark) == true
            if !isRequest && (!e.subagent || subagentWait) {
                s.state = .working
                s.waitingSince = nil
                s.waitingTool = nil
                s.request = nil
                s.workStarted = s.workStarted ?? e.time
                sessions[key] = s
            } else if !isRequest && (e.kind == .toolStarted || e.kind == .toolFinished) {
                // A subagent works on while the main agent waits: only the time moves
                s.updated = max(s.updated, e.time)
                sessions[key] = s
                return nil
            }
        }
        let signal = ClaudeStateMachine.apply(e, to: &sessions)
        if case .permissionRequested = e.kind, e.subagent {
            sessions[key]?.waitingTool = subagentMark + (e.tool ?? "")
        }
        return signal
    }
}
