import Foundation

/// Adds and removes Deckhand's entries in Claude Code's `settings.json` without touching
/// anything else in it: key order, spacing and numbers stay exactly as the user wrote them.
struct ClaudeSettingsFile {
    /// `settings.json` in Claude Code's config folder. May be a symlink (dotfiles setups).
    let url: URL

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Claude Code's config folder: `CLAUDE_CONFIG_DIR` when set, otherwise `~/.claude`.
    static func configDirectory(environment: [String: String], home: URL) -> URL {
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent(".claude", isDirectory: true)
    }

    /// The first copy of the file from before Deckhand changed it. Never overwritten afterwards.
    var backup: URL { url.appendingPathExtension("deckhand-backup") }

    /// The path for messages: `~/.claude/settings.json`.
    var displayPath: String { (url.path as NSString).abbreviatingWithTildeInPath }

    // MARK: - Pure edits

    // Deckhand's handlers are recognized by the exact path of Deckhand's own script, compared as a
    // path (`HookCommand`), never by the file name alone, so another tool's `claude-hook.sh` is never
    // touched. A matcher group is Deckhand's when it holds only Deckhand's handler.

    /// The text with Deckhand's entry added to every event, after any hooks the user already has.
    /// Entries from an older Deckhand are replaced.
    static func installing(into text: String, command: String) throws -> String {
        var doc = try document(removing(from: text, command: command))
        guard doc.root.members != nil else { throw invalid }
        for event in ClaudeHook.events {
            let entry = ClaudeHook.entry(for: event, command: command)
            if let hooks = doc.root.member("hooks")?.value {
                guard hooks.members != nil else { throw invalid }
                if let list = hooks.member(event)?.value {
                    guard list.elements != nil else { throw invalid }
                    try doc.append(entry, to: list)
                } else {
                    try doc.add(event, .array([entry]), to: hooks)
                }
            } else {
                try doc.add("hooks", .object([(event, .array([entry]))]), to: doc.root)
            }
        }
        return doc.text
    }

    /// The text without Deckhand's handlers. A matcher group goes only when Deckhand's handlers were
    /// all it held; in a group the user shares, only Deckhand's handler is taken out. Event lists and
    /// the `hooks` object are removed only when that leaves them empty.
    static func removing(from text: String, command: String) throws -> String {
        let script = HookCommand.scriptPath(command)
        var doc = try document(text)
        while let found = firstHandler(in: doc, script: script) {
            if (found.handlers.elements?.count ?? 0) > 1 {
                try doc.removeElement(found.handler, of: found.handlers)
                continue
            }
            try doc.removeElement(found.group, of: found.list)
            guard let after = doc.root.member("hooks")?.value else { break }
            if after.member(found.event)?.value.elements?.isEmpty == true { try doc.removeMember(found.event, of: after) }
            if let emptied = doc.root.member("hooks")?.value, emptied.members?.isEmpty == true {
                try doc.removeMember("hooks", of: doc.root)
            }
        }
        return doc.text
    }

    /// Whether any of Deckhand's handlers is present.
    static func hasOurs(_ text: String, command: String) -> Bool {
        guard let doc = try? document(text) else { return false }
        return firstHandler(in: doc, script: HookCommand.scriptPath(command)) != nil
    }

    /// Whether the file holds exactly the entries this version of Deckhand would add,
    /// so an update can bring older entries up to date without rewriting a current file.
    static func isCurrent(_ text: String, command: String) -> Bool {
        let script = HookCommand.scriptPath(command)
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else { return false }
        for (event, value) in hooks {
            let groups = value as? [[String: Any]] ?? []
            // Deckhand's handler inside a user's group: rewrite so it stands in its own group
            if groups.contains(where: { holdsOurs($0, script: script) && !isOurs($0, script: script) }) { return false }
            let ours = groups.filter { isOurs($0, script: script) }
            if ClaudeHook.events.contains(event) {
                guard ours.count == 1,
                      (ours[0] as NSDictionary).isEqual(ClaudeHook.entry(for: event, command: command).foundation) else { return false }
            } else if !ours.isEmpty {
                return false
            }
        }
        return ClaudeHook.events.allSatisfy { hooks[$0] != nil }
    }

    private static let invalid = Failure(message: String(localized: "The Claude Code settings file has an unexpected layout, so it was left as is."))

    private static func document(_ text: String) throws -> JSONDocument {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return try JSONDocument(trimmed.isEmpty ? "{}\n" : text)
        } catch {
            throw Failure(message: String(localized: "The Claude Code settings file is not valid JSON, so it was left as is."))
        }
    }

    private struct Found {
        let event: String
        /// The event's list of matcher groups and the group's index in it.
        let list: JSONDocument.Node
        let group: Int
        /// The group's handler array and the handler's index in it.
        let handlers: JSONDocument.Node
        let handler: Int
    }

    /// The first handler that runs `script`.
    private static func firstHandler(in doc: JSONDocument, script: String) -> Found? {
        guard let events = doc.root.member("hooks")?.value.members else { return nil }
        for member in events {
            for (g, group) in (member.value.elements ?? []).enumerated() {
                guard let handlers = group.member("hooks")?.value, let items = handlers.elements else { continue }
                if let index = items.firstIndex(where: { $0.member("command")?.value.string.map { HookCommand.runs($0, script: script) } ?? false }) {
                    return Found(event: member.key, list: member.value, group: g, handlers: handlers, handler: index)
                }
            }
        }
        return nil
    }

    private static func handlers(_ group: [String: Any]) -> [[String: Any]] { group["hooks"] as? [[String: Any]] ?? [] }

    private static func isHandler(_ handler: [String: Any], script: String) -> Bool {
        (handler["command"] as? String).map { HookCommand.runs($0, script: script) } ?? false
    }

    /// A group with at least one of Deckhand's handlers.
    private static func holdsOurs(_ group: [String: Any], script: String) -> Bool {
        handlers(group).contains { isHandler($0, script: script) }
    }

    /// A group that holds Deckhand's handler and nothing else.
    private static func isOurs(_ group: [String: Any], script: String) -> Bool {
        let list = handlers(group)
        return !list.isEmpty && list.allSatisfy { isHandler($0, script: script) }
    }

    // MARK: - Reading and writing

    /// The file's text, or nil when it doesn't exist.
    func read() throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw Failure(message: String(localized: "The Claude Code settings file is not valid JSON, so it was left as is."))
        }
        return text
    }

    /// Writes through a symlink to the real file, keeps its permissions, and saves a backup of the
    /// original the first time only, so a later Connect or Disconnect never replaces it.
    func write(_ text: String, original: String?) throws {
        let fm = FileManager.default
        if let original, !fm.fileExists(atPath: backup.path) {
            try Data(original.utf8).write(to: backup, options: .atomic)
        }
        let target = url.resolvingSymlinksInPath()
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let permissions = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions]
        try Data(text.utf8).write(to: target, options: .atomic)
        if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
    }

    /// Applies an edit and writes only when something changed.
    @discardableResult
    func update(_ edit: (String) throws -> String) throws -> Bool {
        let original = try read()
        let updated = try edit(original ?? "")
        guard updated != (original ?? "") else { return false }
        try write(updated, original: original)
        return true
    }
}
