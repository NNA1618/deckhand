import Foundation

/// The files Deckhand shares with its Claude Code hook script, all in one folder
/// (Deckhand's support folder; a temporary one in the self-test).
struct ClaudeHookFiles: Sendable {
    let dir: URL

    var script: URL { dir.appendingPathComponent("claude-hook.sh") }
    /// One small JSON file per event, written by the script and deleted by Deckhand once read.
    var inbox: URL { dir.appendingPathComponent("claude-events", isDirectory: true) }
    /// Answers to permission requests, one file per request, named after the request's event file.
    var replies: URL { dir.appendingPathComponent("claude-replies", isDirectory: true) }
    /// Deckhand's process id while it runs. Without a live Deckhand the script writes nothing.
    var pidFile: URL { dir.appendingPathComponent("deckhand.pid") }
    /// Present while "Approve from the notch" is on; holds how many seconds the script waits.
    var approvals: URL { dir.appendingPathComponent("claude-approvals") }
}

/// What Deckhand adds to Claude Code: a shell script and one entry per hook event.
///
/// Privacy: the script pipes the event through `/usr/bin/jq` (part of macOS since 15) and keeps
/// only the session id, event name, project folder, tool name with the file name or the first word
/// of a command, the notification type, the error type, the permission mode, the app and the
/// process id. Prompts, file contents, commands, tool output and Claude's messages never reach the disk.
enum ClaudeHook {
    /// Part of the command line, so Deckhand recognizes its own entries in settings.json.
    static let marker = "claude-hook.sh"

    /// The most event files waiting at once. Deckhand reads them within a second, so a full inbox
    /// means it is stuck or gone; the script then drops events instead of filling the disk.
    static let inboxLimit = 300

    /// Seconds the script may wait for an answer from the notch, and the hook timeout above it.
    static let maxApprovalWait = 120

    /// Events Deckhand listens to. All but two run in the background so Claude Code never waits for Deckhand.
    static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PermissionDenied",
        "PostToolUse", "PostToolUseFailure", "Notification", "Stop", "StopFailure", "SessionEnd",
    ]

    /// The settings.json entry for one event.
    /// `PermissionRequest` runs in the foreground so the notch can answer it; without an answer
    /// the script ends at once and Claude Code shows its own prompt. `SessionEnd` runs in the
    /// foreground so the last event is written before Claude Code exits.
    static func entry(for event: String, command: String) -> JSONValue {
        var handler: [(String, JSONValue)] = [("type", .string("command")), ("command", .string(command))]
        switch event {
        case "PermissionRequest":
            handler.append(("timeout", .int(maxApprovalWait + 5)))
            handler.append(("statusMessage", .string("Deckhand: answer in the notch or wait for the prompt")))
        case "SessionEnd":
            break
        default:
            handler.append(("async", .bool(true)))
        }
        var entry: [(String, JSONValue)] = []
        if ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PermissionDenied"].contains(event) {
            entry.append(("matcher", .string("*")))
        }
        entry.append(("hooks", .array([.object(handler)])))
        return .object(entry)
    }

    /// The command line for the script: its quoted path.
    static func command(for files: ClaudeHookFiles) -> String {
        "\"\(files.script.path)\""
    }

    /// Keeps only what Deckhand shows. Runs inside the hook, so it must never print the input.
    static let filter = #"""
    def clip($n): if type == "string" then .[0:$n] else null end;
    def base: if type == "string" and length > 0 then (sub("/+$"; "") | split("/") | last) else null end;
    def word: if type == "string" then
        ([splits("[\\s;&|()<>]+")] | map(select(length > 0 and (test("^[A-Za-z_][A-Za-z0-9_]*=") | not))) | .[0]) as $w
        | if $w then ($w | base) else null end
      else null end;
    if type != "object" then empty else
    {
      v: 1,
      session_id: (.session_id | clip(128)),
      hook_event_name: (.hook_event_name | clip(64)),
      cwd: (.cwd | clip(1024)),
      subagent: ((.agent_id // "") != ""),
      tool: (.tool_name | clip(96)),
      target: ((.tool_input.file_path // .tool_input.notebook_path // .tool_input.path | base)
               // (if .tool_name == "Bash" or .tool_name == "PowerShell" then (.tool_input.command | word) else null end)
               | clip(96)),
      notification_type: (.notification_type | clip(64)),
      error: (if .hook_event_name == "StopFailure" then (.error | clip(64)) else null end),
      source: (if .hook_event_name == "SessionStart" then (.source | clip(32)) else null end),
      permission_mode: (.permission_mode | clip(32)),
      app: $app,
      ppid: $ppid
    } | with_entries(select(.value != null and .value != ""))
    end
    """#

    /// The hook script. It finds its folder from its own path, so the self-test can run a copy anywhere.
    static var script: String {
        """
        #!/bin/sh
        # Deckhand: shows Claude Code sessions in the notch. Remove it in Deckhand: Settings > Claude > Disconnect.
        # Keeps only the session, event, project folder, tool and file or command name; never prompts, code or output.
        [ -n "$DECKHAND_INTERNAL" ] && exit 0
        dir=$(dirname "$0")
        inbox="$dir/claude-events"
        [ -d "$inbox" ] || exit 0
        pid=$(cat "$dir/deckhand.pid" 2>/dev/null)
        { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; } || exit 0
        set -- "$inbox"/*.json
        [ "$#" -lt \(inboxLimit) ] || exit 0
        [ -x /usr/bin/jq ] || exit 0
        app=$(printf '%s' "${__CFBundleIdentifier:-}" | tr -cd 'A-Za-z0-9.-')
        name="$inbox/$(date +%s)-$$-${app:-unknown}"
        if ! /usr/bin/jq -c --arg app "$app" --arg ppid "$PPID" '\(filter)' >"$name.tmp" 2>/dev/null || [ ! -s "$name.tmp" ]; then
            rm -f "$name.tmp"
            exit 0
        fi
        mv "$name.tmp" "$name.json"
        [ -f "$dir/claude-approvals" ] || exit 0
        grep -q '"hook_event_name":"PermissionRequest"' "$name.json" || exit 0
        grep -q -E '"tool":"(AskUserQuestion|ExitPlanMode)"' "$name.json" && exit 0
        wait=$(tr -cd '0-9' <"$dir/claude-approvals")
        [ -n "$wait" ] || wait=30
        [ "$wait" -le \(maxApprovalWait) ] || wait=\(maxApprovalWait)
        reply="$dir/claude-replies/$(basename "$name")"
        i=0
        while [ "$i" -lt $((wait * 4)) ]; do
            if [ -f "$reply" ]; then
                answer=$(cat "$reply")
                rm -f "$reply"
                case "$answer" in
                    allow) printf '%s\\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}' ;;
                    deny) printf '%s\\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"The user denied this in Deckhand."}}}' ;;
                esac
                exit 0
            fi
            kill -0 "$pid" 2>/dev/null || exit 0
            sleep 0.25
            i=$((i + 1))
        done
        exit 0

        """
    }
}
