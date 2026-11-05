import Foundation

/// A coding agent session (Claude Code today) seen through its hooks.
struct ClaudeSession: Identifiable, Equatable {
    enum State: Equatable { case working, waiting, idle }

    let id: String
    var cwd: String
    /// Bundle id of the app the session runs in (Terminal, Claude, an editor), if known.
    var app: String?
    var state: State = .idle
    /// What it is doing right now, e.g. "Edit · NotchView.swift", or why it waits or stopped.
    var detail: String?
    /// Since when it has been working on the current prompt.
    var workStarted: Date?
    var updated: Date
    /// The Claude Code process, to notice when it quits without saying so.
    var process: ClaudeProcess?
    /// Tools the main agent started and hasn't finished; a quiet session with none is not working.
    var toolsInFlight = 0
    /// Since when it has been waiting for the user.
    var waitingSince: Date?
    /// The tool a permission request is about; its result means the user answered.
    var waitingTool: String?
    /// A permission request the notch can answer: the event file's name and when it arrived.
    var request: ClaudeRequest?
    /// Which coding agent runs the session.
    var provider: AgentProvider = .claudeCode

    /// Sessions are keyed by provider and id, so two agents can never mix up their sessions.
    static func key(_ provider: AgentProvider, _ id: String) -> String { "\(provider.rawValue):\(id)" }
    var key: String { Self.key(provider, id) }

    var project: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? provider.name : name
    }

    /// The order lists use: waiting first, then working, then idle; newest first within each.
    static func ordered(_ sessions: some Sequence<ClaudeSession>) -> [ClaudeSession] {
        func rank(_ s: State) -> Int { s == .waiting ? 0 : s == .working ? 1 : 2 }
        return sessions.sorted { a, b in
            rank(a.state) != rank(b.state) ? rank(a.state) < rank(b.state) : (a.updated, a.id) > (b.updated, b.id)
        }
    }
}

/// A permission request waiting in the hook script for an answer.
struct ClaudeRequest: Equatable {
    let id: String
    let tool: String
    let time: Date
}

/// A process, identified by its id and start time so a reused id doesn't count as the same process.
struct ClaudeProcess: Equatable {
    let pid: Int32
    let started: TimeInterval
}

/// One hook event as the script wrote it: only the fields Deckhand shows.
struct ClaudeHookEvent: Equatable, Sendable {
    var session: String
    var name: String
    var cwd = ""
    var subagent = false
    var tool: String?
    /// The file name or the first word of a command.
    var target: String?
    var notificationType: String?
    var error: String?
    var app: String?
    var parentPID: Int32?
    /// When the hook ran: the event file's creation date.
    var time: Date
    /// The event file's name without extension; names the reply to a permission request.
    var fileId = ""

    /// "Edit · NotchView.swift", "Bash · git", or the tool alone.
    var summary: String? {
        guard let tool else { return nil }
        var short = tool
        if tool.hasPrefix("mcp__"), let last = tool.split(separator: "_").last { short = String(last) }
        guard let target, !target.isEmpty else { return short }
        return "\(short) · \(target)"
    }

    /// Reads an event file. Also accepts the full payload an older Deckhand's script saved,
    /// and keeps only the same fields from it.
    init?(json: [String: Any], time: Date, fileName: String) {
        guard let session = json["session_id"] as? String, !session.isEmpty,
              let name = json["hook_event_name"] as? String, !name.isEmpty else { return nil }
        self.session = session
        self.name = name
        self.time = time
        fileId = (fileName as NSString).deletingPathExtension
        cwd = json["cwd"] as? String ?? ""
        notificationType = json["notification_type"] as? String
        if json["v"] != nil {
            subagent = json["subagent"] as? Bool ?? false
            tool = json["tool"] as? String
            target = json["target"] as? String
            error = json["error"] as? String
            app = json["app"] as? String
            parentPID = (json["ppid"] as? String).flatMap { Int32($0) }
        } else {
            subagent = !((json["agent_id"] as? String) ?? "").isEmpty
            tool = json["tool_name"] as? String
            let input = json["tool_input"] as? [String: Any]
            if let path = (input?["file_path"] ?? input?["notebook_path"]) as? String {
                target = (path as NSString).lastPathComponent
            } else if tool == "Bash", let command = input?["command"] as? String {
                target = Self.commandName(command)
            }
            error = name == "StopFailure" ? json["error"] as? String : nil
        }
        if app == nil || app?.isEmpty == true { app = Self.appId(fromFileName: fileName) }
    }

    init(session: String, name: String, time: Date) {
        self.session = session
        self.name = name
        self.time = time
    }

    /// The first word of a command without leading `VAR=value` assignments, as a bare name.
    static func commandName(_ command: String) -> String? {
        let words = command.split(whereSeparator: { " \t\n;&|()<>".contains($0) })
        guard let word = words.first(where: { $0.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) == nil }) else { return nil }
        return (String(word) as NSString).lastPathComponent
    }

    /// File names are "<time>-<pid>-<bundle id>.json"; the bundle id says which app runs the session.
    static func appId(fromFileName name: String) -> String? {
        let base = (name as NSString).deletingPathExtension
        let parts = base.split(separator: "-", maxSplits: 2)
        guard parts.count == 3, parts[2] != "unknown", !parts[2].isEmpty else { return nil }
        return String(parts[2])
    }
}

/// What happened in a session, in terms every coding agent shares. Provider adapters
/// (the Claude Code hook today, Codex next) turn their own events into these.
struct AgentEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case sessionStarted
        case sessionEnded
        /// The user sent a prompt, or the agent started a turn by itself.
        case promptSubmitted
        case toolStarted
        case toolFinished
        /// The agent waits for the user to allow a tool. `answerable` when the notch may answer it.
        case permissionRequested(answerable: Bool)
        /// A permission was refused without the user (an automatic denial).
        case permissionDenied
        /// The agent waits for the user in some other way; the text says how.
        case needsInput(String?)
        /// The agent is done and idles, e.g. a reminder long after the last reply.
        case idle
        /// Work goes on without a new prompt, e.g. after a usage limit reset.
        case resumed
        case turnFinished
        /// The turn ended with an error, worded for the user.
        case turnFailed(String)
        /// Nothing Deckhand shows; still refreshes the session.
        case other
    }

    var provider: AgentProvider
    var session: String
    var kind: Kind
    var time: Date
    var cwd = ""
    var app: String?
    /// The event came from a subagent; it doesn't change what the session's line shows.
    var subagent = false
    var tool: String?
    /// "Edit · NotchView.swift": the tool and file or command name, never the full input.
    var summary: String?
    /// Identifies a permission request so an answer can be sent back to the adapter.
    var requestId: String?
}

extension ClaudeHookEvent {
    /// The Claude Code hook adapter: maps hook event names to the shared events.
    var agentEvent: AgentEvent {
        let kind: AgentEvent.Kind
        switch name {
        case "SessionStart": kind = .sessionStarted
        case "SessionEnd": kind = .sessionEnded
        case "UserPromptSubmit": kind = .promptSubmitted
        case "PreToolUse": kind = .toolStarted
        case "PostToolUse", "PostToolUseFailure": kind = .toolFinished
        case "PermissionRequest": kind = .permissionRequested(answerable: !ClaudeStateMachine.interactiveTools.contains(tool ?? ""))
        case "PermissionDenied": kind = .permissionDenied
        case "Stop": kind = .turnFinished
        case "StopFailure": kind = .turnFailed(ClaudeStateMachine.failureText(error))
        case "Notification":
            let type = notificationType ?? ""
            if ClaudeStateMachine.needsYouTypes.contains(type) {
                kind = .needsInput(ClaudeStateMachine.waitingText(type))
            } else if ["idle_prompt", "quota_auto_resume_disabled", "quota_auto_resume_stale"].contains(type) {
                kind = .idle
            } else if type == "quota_auto_resume_fired" {
                kind = .resumed
            } else {
                kind = .other
            }
        default: kind = .other
        }
        return AgentEvent(provider: .claudeCode, session: session, kind: kind, time: time, cwd: cwd, app: app,
                          subagent: subagent, tool: tool, summary: summary, requestId: fileId)
    }
}

/// How agent events change sessions. Pure and provider-neutral, so the self-test can drive it.
enum ClaudeStateMachine {
    enum Signal: Equatable {
        /// A prompt finished after this many seconds of work.
        case finished(project: String, seconds: Int)
        /// The agent asks for a permission or an answer. Repeats when the agent reminds the user.
        case needsYou(project: String)
        /// The turn ended with an API error, already worded for the user.
        case failed(project: String, message: String)
    }

    /// Claude Code notification types that mean Claude is blocked on the user. Every other type is informational.
    static let needsYouTypes: Set<String> = ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"]

    /// Tools whose prompt only the terminal can answer, so the notch never offers Allow for them.
    static let interactiveTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    static func apply(_ e: AgentEvent, to sessions: inout [String: ClaudeSession]) -> Signal? {
        let key = ClaudeSession.key(e.provider, e.session)
        if e.kind == .sessionEnded {
            sessions[key] = nil
            return nil
        }
        var s = sessions[key] ?? ClaudeSession(id: e.session, cwd: e.cwd, app: e.app, updated: e.time, provider: e.provider)
        if !e.cwd.isEmpty { s.cwd = e.cwd }
        if let app = e.app { s.app = app }
        s.updated = max(s.updated, e.time)
        var signal: Signal?

        func startWork() {
            s.state = .working
            s.workStarted = s.workStarted ?? e.time
        }
        func stopWaiting() {
            s.state = .working
            s.waitingSince = nil
            s.waitingTool = nil
            s.request = nil
            s.workStarted = s.workStarted ?? e.time
        }
        func enterWaiting(detail: String?) {
            if s.state != .waiting { s.waitingSince = e.time }
            s.state = .waiting
            if let detail { s.detail = detail }
            signal = .needsYou(project: s.project)
        }
        func end() {
            s.state = .idle
            s.workStarted = nil
            s.toolsInFlight = 0
            s.waitingSince = nil
            s.waitingTool = nil
            s.request = nil
        }

        switch e.kind {
        case .sessionStarted, .sessionEnded, .other:
            break
        case .promptSubmitted:
            end()
            s.state = .working
            s.workStarted = e.time
            s.detail = nil
        case .toolStarted:
            // Subagents report their own tools; the session's line follows the main agent
            guard !e.subagent else { break }
            s.toolsInFlight += 1
            if s.state == .waiting {
                // Waiting without a tool means a dialog, which this tool call shows was answered
                if s.waitingTool == nil { stopWaiting(); s.detail = e.summary }
            } else {
                startWork()
                s.detail = e.summary
            }
        case .toolFinished:
            if !e.subagent { s.toolsInFlight = max(0, s.toolsInFlight - 1) }
            let answered = s.waitingTool == nil ? !e.subagent : s.waitingTool == e.tool
            if s.state == .waiting && answered { stopWaiting() }
        case .permissionRequested(let answerable):
            enterWaiting(detail: e.summary)
            s.waitingTool = e.tool
            if answerable, let tool = e.tool, let id = e.requestId, !id.isEmpty {
                s.request = ClaudeRequest(id: id, tool: tool, time: e.time)
            } else {
                s.request = nil
            }
        case .permissionDenied:
            if s.state == .waiting, s.waitingTool == e.tool { stopWaiting() }
        case .needsInput(let text):
            enterWaiting(detail: s.waitingTool == nil ? text : nil)
        case .idle:
            if s.state != .waiting { end(); s.detail = nil }
        case .resumed:
            startWork()
            s.detail = nil
        case .turnFinished:
            guard !e.subagent else { break }
            if s.state != .idle, let started = s.workStarted {
                let seconds = Int(e.time.timeIntervalSince(started))
                if seconds >= 5 { signal = .finished(project: s.project, seconds: seconds) }
            }
            end()
            s.detail = nil
        case .turnFailed(let message):
            end()
            s.detail = message
            signal = .failed(project: s.project, message: message)
        }
        sessions[key] = s
        return signal
    }

    /// What the row says while a dialog other than a tool permission waits.
    static func waitingText(_ type: String) -> String {
        switch type {
        case "elicitation_dialog": return String(localized: "Asks you to fill in a form")
        case "elicitation_url_dialog": return String(localized: "Asks you to open a link")
        case "agent_needs_input": return String(localized: "Waits for your input")
        default: return String(localized: "Needs your permission")
        }
    }

    /// The `error` of a StopFailure event in the user's words.
    static func failureText(_ error: String?) -> String {
        switch error {
        case "rate_limit": return String(localized: "Usage limit reached")
        case "overloaded": return String(localized: "Claude is overloaded")
        case "authentication_failed", "oauth_org_not_allowed": return String(localized: "Not signed in")
        case "billing_error", "account_on_hold": return String(localized: "Billing problem")
        case "max_output_tokens": return String(localized: "Reply too long")
        default: return String(localized: "Stopped with an error")
        }
    }

    /// Ends states that never got their closing event. Esc during a reply sends no Stop, so a
    /// working session with no tool running ends after a few quiet minutes; one with a tool
    /// running (a long build) gets hours. `alive` says whether a session's process still runs.
    static func expire(_ sessions: inout [String: ClaudeSession], now: Date, alive: (ClaudeProcess) -> Bool) -> Bool {
        var changed = false
        for (id, s) in sessions {
            let quiet = now.timeIntervalSince(s.updated)
            if let process = s.process, !alive(process) {
                sessions[id] = nil
                changed = true
            } else if s.state == .idle {
                if quiet > 2 * 3600 { sessions[id] = nil; changed = true }
            } else if s.state == .working && (quiet > (s.toolsInFlight == 0 ? 8 * 60 : 3 * 3600)) {
                sessions[id]?.state = .idle
                sessions[id]?.workStarted = nil
                sessions[id]?.toolsInFlight = 0
                sessions[id]?.detail = nil
                changed = true
            } else if s.state == .waiting && quiet > 12 * 3600 {
                sessions[id]?.state = .idle
                sessions[id]?.request = nil
                changed = true
            }
        }
        return changed
    }
}
