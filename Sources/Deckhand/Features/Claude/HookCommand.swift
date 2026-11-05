import Foundation

/// Recognizes Deckhand's own hook in an agent's settings by the script's full path, never by its
/// file name alone, so another tool's `claude-hook.sh` or `codex-hook.sh` is never touched.
/// Shared by the Claude Code and Codex settings files.
enum HookCommand {
    /// The script path a command line runs: the command without surrounding whitespace and one pair
    /// of quotes. Unquoted, backslash escapes (`Application\ Support`) are undone; a leading `$HOME`
    /// or `${HOME}` stands for the home folder, as the shell would read it.
    static func scriptPath(_ command: String) -> String {
        var text = command.trimmingCharacters(in: .whitespaces)
        var quoted = false
        for quote in ["\"", "'"] where text.count >= 2 && text.hasPrefix(quote) && text.hasSuffix(quote) {
            text = String(text.dropFirst().dropLast())
            quoted = true
            break
        }
        if !quoted && text.contains("\\") {
            var out = ""
            var escaping = false
            for ch in text {
                if escaping { out.append(ch); escaping = false } else if ch == "\\" { escaping = true } else { out.append(ch) }
            }
            text = out
        }
        for variable in ["${HOME}", "$HOME"] where text.hasPrefix(variable + "/") {
            text = FileManager.default.homeDirectoryForCurrentUser.path + text.dropFirst(variable.count)
            break
        }
        return text
    }

    /// Whether two paths name the same file, after `~` and `.`/`..` are resolved.
    static func samePath(_ a: String, _ b: String) -> Bool {
        func normal(_ p: String) -> String {
            URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL.path
        }
        return !a.isEmpty && !b.isEmpty && normal(a) == normal(b)
    }

    /// Whether a hook's command line runs exactly `script`.
    static func runs(_ command: String, script: String) -> Bool {
        samePath(scriptPath(command), scriptPath(script))
    }
}
