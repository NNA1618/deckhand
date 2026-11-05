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

    /// The text with Deckhand's entry added to every event, after any hooks the user already has.
    /// Entries from an older Deckhand are replaced.
    static func installing(into text: String, command: String) throws -> String {
        var doc = try document(removing(from: text))
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

    /// The text without any of Deckhand's entries. Event lists and the `hooks` object are removed
    /// only when Deckhand's entries were all they held.
    static func removing(from text: String) throws -> String {
        var doc = try document(text)
        while let hooks = doc.root.member("hooks")?.value, let events = hooks.members {
            guard let (event, list, index) = firstOurs(in: events) else { break }
            try doc.removeElement(index, of: list)
            guard let after = doc.root.member("hooks")?.value else { break }
            if after.member(event)?.value.elements?.isEmpty == true { try doc.removeMember(event, of: after) }
            if let emptied = doc.root.member("hooks")?.value, emptied.members?.isEmpty == true {
                try doc.removeMember("hooks", of: doc.root)
            }
        }
        return doc.text
    }

    /// Whether Deckhand's entries are present at all.
    static func hasOurs(_ text: String) -> Bool {
        guard let doc = try? document(text), let events = doc.root.member("hooks")?.value.members else { return false }
        return firstOurs(in: events) != nil
    }

    /// Whether the file holds exactly the entries this version of Deckhand would add,
    /// so an update can bring older entries up to date without rewriting a current file.
    static func isCurrent(_ text: String, command: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else { return false }
        for (event, value) in hooks {
            let ours = (value as? [[String: Any]] ?? []).filter(isOurs)
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

    /// The first matcher group of Deckhand's, as (event name, the event's list, index in the list).
    private static func firstOurs(in events: [JSONDocument.Member]) -> (String, JSONDocument.Node, Int)? {
        for member in events {
            guard let groups = member.value.elements else { continue }
            if let index = groups.firstIndex(where: isOurs) { return (member.key, member.value, index) }
        }
        return nil
    }

    private static func isOurs(_ group: JSONDocument.Node) -> Bool {
        group.member("hooks")?.value.elements?.contains { $0.member("command")?.value.string?.contains(ClaudeHook.marker) == true } == true
    }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains(ClaudeHook.marker) ?? false } ?? false
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
