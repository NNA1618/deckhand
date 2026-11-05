import Foundation

/// The files Deckhand shares with its Codex hook script, next to the Claude Code ones in
/// Deckhand's support folder (a temporary folder in the self-test). Both scripts use the same
/// `deckhand.pid`, so neither writes anything while Deckhand isn't running.
struct CodexHookFiles: Sendable {
    let dir: URL

    var script: URL { dir.appendingPathComponent("codex-hook.sh") }
    /// One small JSON file per event, written by the script and deleted by Deckhand once read.
    var inbox: URL { dir.appendingPathComponent("codex-events", isDirectory: true) }
    /// Answers to permission requests, one file per request, named after the request's event file.
    var replies: URL { dir.appendingPathComponent("codex-replies", isDirectory: true) }
    /// Deckhand's process id while it runs; shared with the Claude Code hook.
    var pidFile: URL { dir.appendingPathComponent("deckhand.pid") }
    /// Present while "Approve from the notch" is on for Codex; holds how many seconds the script waits.
    var approvals: URL { dir.appendingPathComponent("codex-approvals") }
}

/// What Deckhand adds to Codex: a shell script and one matcher group per hook event in
/// `$CODEX_HOME/hooks.json`.
///
/// The entries are frozen. Codex runs a hook it didn't create only after the user reviews it, and
/// the review is a hash of the event, matcher, command, timeout, async flag and status message,
/// keyed by the group's position. Changing any of them, or moving a group, asks the user to review
/// again, so switches like approvals live in Deckhand's own files and only the script changes.
///
/// Version safety (checked in openai/codex at every release tag from rust-v0.124.0 to rust-v0.166.0):
/// - The event map and the handler fields never use `deny_unknown_fields`, so a Codex that doesn't
///   know `SessionEnd` (0.145) or `Interrupt` (0.150) ignores those lists instead of rejecting the file.
/// - Before 0.148 a handler with `"async": true` is skipped with a warning, so every entry is synchronous.
/// - `SessionEnd` and `Interrupt` cap the timeout at 3 s; 3 is used so no version warns.
/// - No matcher: a missing matcher matches every tool and session source in every version.
///
/// Privacy: the script pipes the event through `/usr/bin/jq` and keeps only the session id, event
/// name, turn id, project folder, whether a subagent sent it, the tool name with a file name, the first
/// word of a command or an MCP tool name, the permission mode, the session source, the app and the
/// process id. Prompts, tool input and output, Codex's messages, the transcript path and the model never reach the disk.
enum CodexHook {
    /// The script's file name. Deckhand recognizes its entries by the script's full path, never by this name alone.
    static let marker = "codex-hook.sh"

    /// The most event files waiting at once; beyond it the script drops events instead of filling the disk.
    static let inboxLimit = 300

    /// Seconds the script may wait for an answer from the notch. The frozen PermissionRequest timeout is above it.
    static let maxApprovalWait = 120

    /// The frozen timeouts. The script takes milliseconds; the margin covers a slow login shell.
    static let observeTimeout = 10
    static let permissionTimeout = 125
    static let endTimeout = 3

    /// Shown by Codex while the PermissionRequest hook runs.
    static let statusMessage = "Deckhand: answer in the notch or wait for the prompt"

    /// Events Deckhand listens to, in the order they are written. `SessionEnd` and `Interrupt`
    /// are ignored by versions older than 0.145 and 0.150.
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop", "Interrupt", "SessionEnd"]

    /// The hooks.json group for one event. Never change the output for an existing event:
    /// every change makes Codex ask the user to review Deckhand's hooks again.
    static func entry(for event: String, command: String) -> JSONValue {
        var handler: [(String, JSONValue)] = [("type", .string("command")), ("command", .string(command))]
        switch event {
        case "PermissionRequest":
            handler.append(("timeout", .int(permissionTimeout)))
            handler.append(("statusMessage", .string(statusMessage)))
        case "Interrupt", "SessionEnd":
            handler.append(("timeout", .int(endTimeout)))
        default:
            handler.append(("timeout", .int(observeTimeout)))
        }
        return .object([("hooks", .array([.object(handler)]))])
    }

    /// The command line for the script: its quoted path.
    static func command(for files: CodexHookFiles) -> String {
        "\"\(files.script.path)\""
    }

    /// Keeps only what Deckhand shows. Runs inside the hook, so it must never print the input,
    /// and it holds no single quote because the script passes it in single quotes.
    static let filter = #"""
    def clip($n): if type == "string" then .[0:$n] else null end;
    def str: if type == "string" then . else null end;
    def base: if type == "string" and length > 0 then (sub("/+$"; "") | split("/") | last) else null end;
    def word: if type == "string" then
        ([splits("[\\s;&|()<>]+")] | map(select(length > 0 and (test("^[A-Za-z_][A-Za-z0-9_]*=") | not))) | .[0]) as $w
        | if $w then ($w | base) else null end
      else null end;
    def argv: if type == "array" then
        (map(select(type == "string"))) as $a
        | if ($a | length) >= 3 and (($a[0] | base) | test("^(ba|z|da|fi)?sh$")) and ($a[1] | test("^-[a-z]*c$")) then ($a[2] | word)
          elif ($a | length) > 0 then ($a[0] | word) else null end
      else word end;
    def patchfile: if type == "string" then
        (first(splits("\n") | capture("^\\*\\*\\* (?:Add|Update|Delete) File: (?<f>.*[^\\s])") | .f) // null) | base
      else null end;
    def field($k): if type == "object" then .[$k] elif type == "string" then . else null end;
    if type != "object" then empty else
    (.tool_name | str) as $tool
    | (.tool_input) as $in
    | {
      v: 1,
      provider: "codex",
      session_id: (.session_id | clip(128)),
      hook_event_name: (.hook_event_name | clip(64)),
      turn_id: (.turn_id | clip(128)),
      cwd: (.cwd | clip(1024)),
      subagent: (((.agent_id // "") | tostring) != ""),
      tool: ($tool | clip(96)),
      target: ((if $tool == null then null
                elif ($tool | startswith("mcp__")) then ($tool | split("__") | if length >= 3 then (.[2:] | join("__")) else null end)
                elif $tool == "apply_patch" or $tool == "Edit" or $tool == "Write" then
                    (($in | field("command")) // ($in | field("patch")) // ($in | field("input")) | patchfile)
                    // ($in | field("file_path") | base)
                elif $tool == "Bash" or $tool == "shell" or $tool == "exec_command" or $tool == "local_shell" then
                    (($in | if type == "object" then (.command // .cmd) else . end) | argv)
                else null end) | clip(96)),
      permission_mode: (.permission_mode | clip(32)),
      source: (if .hook_event_name == "SessionStart" then (.source | clip(32)) else null end),
      app: $app,
      ppid: $ppid
    } | with_entries(select(.value != null and .value != ""))
    end
    """#

    /// The hook script. It finds its folder from its own path, so the self-test can run a copy anywhere.
    /// It always exits 0 and prints nothing except a PermissionRequest decision from the notch.
    static var script: String {
        """
        #!/bin/sh
        # Deckhand: shows Codex sessions in the notch. Remove it in Deckhand: Settings > Codex > Disconnect.
        # Keeps only the session, event, project folder, tool and file or command name; never prompts, code or output.
        [ -n "$DECKHAND_INTERNAL" ] && exit 0
        dir=$(dirname "$0")
        inbox="$dir/codex-events"
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
        [ -f "$dir/codex-approvals" ] || exit 0
        grep -q '"hook_event_name":"PermissionRequest"' "$name.json" || exit 0
        wait=$(tr -cd '0-9' <"$dir/codex-approvals")
        [ -n "$wait" ] || wait=30
        [ "$wait" -le \(maxApprovalWait) ] || wait=\(maxApprovalWait)
        reply="$dir/codex-replies/$(basename "$name")"
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
