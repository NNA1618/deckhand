import Foundation

/// Adds and removes Deckhand's groups in Codex's `hooks.json` without touching anything else:
/// key order, spacing, numbers and, above all, the position of every other group stay as they were,
/// because Codex keys its hook review by position.
struct CodexHooksFile {
    /// `hooks.json` in Codex's home folder. May be a symlink (dotfiles setups).
    let url: URL
    /// The command line of Deckhand's hook, which identifies Deckhand's handlers.
    let command: String

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Codex's home folder: `CODEX_HOME` when set, otherwise `~/.codex`.
    static func homeDirectory(environment: [String: String], home: URL) -> URL {
        if let dir = environment["CODEX_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }

    /// The first copy of the file from before Deckhand changed it. Never overwritten afterwards.
    var backup: URL { url.appendingPathExtension("deckhand-backup") }

    /// The path for messages: `~/.codex/hooks.json`.
    var displayPath: String { (url.path as NSString).abbreviatingWithTildeInPath }

    // MARK: - Pure edits
    //
    // Deckhand's handlers are recognized by the exact path of Deckhand's own script, compared as a path,
    // never by a file name alone, so another tool's `codex-hook.sh` is never touched. A group is
    // Deckhand's when it holds only Deckhand's handler.

    /// The text with Deckhand's group at the end of every event's list. A current group stays
    /// where it is, an outdated one is replaced in place, a missing one is appended; nothing else moves.
    static func installing(into text: String, command: String) throws -> String {
        let script = scriptPath(command)
        var doc = try document(text)
        guard doc.root.members != nil else { throw invalid }
        if let hooks = doc.root.member("hooks")?.value, hooks.members == nil { throw invalid }
        // A hand edit may have put Deckhand's handler into a user's group; take it out of there only
        while let found = firstHandler(in: doc, script: script, mixedOnly: true) {
            try doc.removeElement(found.handler, of: found.handlers)
        }
        for event in CodexHook.events {
            let entry = CodexHook.entry(for: event, command: command)
            guard let hooks = doc.root.member("hooks")?.value else {
                try doc.add("hooks", .object([(event, .array([entry]))]), to: doc.root)
                continue
            }
            guard let list = hooks.member(event)?.value else {
                try doc.add(event, .array([entry]), to: hooks)
                continue
            }
            guard let groups = list.elements else { throw invalid }
            let ours = groups.indices.filter { isOurs(groups[$0], script: script) }
            guard let first = ours.first else {
                try doc.append(entry, to: list)
                continue
            }
            // Duplicates can only come from a hand edit; drop them from the end so earlier positions hold
            for index in ours.dropFirst().reversed() {
                guard let current = doc.root.member("hooks")?.value.member(event)?.value else { break }
                try doc.removeElement(index, of: current)
            }
            guard let group = doc.root.member("hooks")?.value.member(event)?.value.elements?[first] else { continue }
            if !matches(group, entry, in: doc) { try doc.replaceValue(group, with: entry) }
        }
        return doc.text
    }

    /// The text without Deckhand's handlers. A group goes only when Deckhand's handler was all it held;
    /// an event list or the `hooks` object goes only when it is left empty by that.
    static func removing(from text: String, command: String) throws -> String {
        let script = scriptPath(command)
        var doc = try document(text)
        while let found = firstHandler(in: doc, script: script, mixedOnly: false) {
            guard found.handlers.elements?.count == 1 else {
                try doc.removeElement(found.handler, of: found.handlers)
                continue
            }
            let event = found.event
            try doc.removeElement(found.group, of: found.list)
            guard let after = doc.root.member("hooks")?.value else { break }
            if after.member(event)?.value.elements?.isEmpty == true { try doc.removeMember(event, of: after) }
            if let emptied = doc.root.member("hooks")?.value, emptied.members?.isEmpty == true {
                try doc.removeMember("hooks", of: doc.root)
            }
        }
        return doc.text
    }

    /// Whether any of Deckhand's handlers is present.
    static func hasOurs(_ text: String, command: String) -> Bool {
        guard let doc = try? document(text) else { return false }
        return firstHandler(in: doc, script: scriptPath(command), mixedOnly: false) != nil
    }

    /// Whether the file holds exactly the groups this version of Deckhand writes, once per event.
    static func isCurrent(_ text: String, command: String) -> Bool {
        let script = scriptPath(command)
        guard let doc = try? document(text), let hooks = doc.root.member("hooks")?.value, let events = hooks.members,
              firstHandler(in: doc, script: script, mixedOnly: true) == nil else { return false }
        for member in events {
            let ours = (member.value.elements ?? []).filter { isOurs($0, script: script) }
            if CodexHook.events.contains(member.key) {
                guard ours.count == 1, matches(ours[0], CodexHook.entry(for: member.key, command: command), in: doc) else { return false }
            } else if !ours.isEmpty {
                return false
            }
        }
        return CodexHook.events.allSatisfy { hooks.member($0) != nil }
    }

    /// Whether Deckhand's own Claude Code hook script shows up among Codex's hooks, e.g. after Codex
    /// imported Claude Code's hooks. Codex sessions would then show as Claude Code sessions.
    static func hasClaudeHook(_ text: String, claudeScript: String) -> Bool {
        guard let doc = try? document(text) else { return false }
        return firstHandler(in: doc, script: claudeScript, mixedOnly: false) != nil
    }

    /// The script path a command line runs (see `HookCommand.scriptPath`).
    static func scriptPath(_ command: String) -> String { HookCommand.scriptPath(command) }

    /// Whether two paths name the same file, after `~` and `.`/`..` are resolved.
    static func samePath(_ a: String, _ b: String) -> Bool { HookCommand.samePath(a, b) }

    private static let invalid = Failure(message: String(localized: "The Codex hooks file has an unexpected layout, so it was left as is."))
    private static let notJSON = Failure(message: String(localized: "The Codex hooks file is not valid JSON, so it was left as is."))

    private static func document(_ text: String) throws -> JSONDocument {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return try JSONDocument(trimmed.isEmpty ? "{}\n" : text)
        } catch {
            throw notJSON
        }
    }

    /// Compares a group in the file with the frozen entry, ignoring layout.
    private static func matches(_ group: JSONDocument.Node, _ entry: JSONValue, in doc: JSONDocument) -> Bool {
        let bytes = Array(doc.text.utf8)[group.range]
        guard let found = try? JSONSerialization.jsonObject(with: Data(bytes)) as? NSDictionary else { return false }
        return found.isEqual(entry.foundation)
    }

    private static func isHandler(_ handler: JSONDocument.Node, script: String) -> Bool {
        handler.member("command")?.value.string.map { samePath(scriptPath($0), script) } ?? false
    }

    /// A group that holds Deckhand's handler and nothing else.
    private static func isOurs(_ group: JSONDocument.Node, script: String) -> Bool {
        guard let handlers = group.member("hooks")?.value.elements, !handlers.isEmpty else { return false }
        return handlers.allSatisfy { isHandler($0, script: script) }
    }

    private struct Found {
        let event: String
        /// The event's list of groups and the group's index in it.
        let list: JSONDocument.Node
        let group: Int
        /// The group's handler array and the handler's index in it.
        let handlers: JSONDocument.Node
        let handler: Int
    }

    /// The first handler running `script`. With `mixedOnly`, only one in a group that also holds other handlers.
    private static func firstHandler(in doc: JSONDocument, script: String, mixedOnly: Bool) -> Found? {
        guard let events = doc.root.member("hooks")?.value.members else { return nil }
        for member in events {
            for (g, group) in (member.value.elements ?? []).enumerated() {
                guard let handlers = group.member("hooks")?.value, let items = handlers.elements else { continue }
                if mixedOnly && isOurs(group, script: script) { continue }
                if let index = items.firstIndex(where: { isHandler($0, script: script) }) {
                    return Found(event: member.key, list: member.value, group: g, handlers: handlers, handler: index)
                }
            }
        }
        return nil
    }

    // MARK: - Reading and writing

    /// The file's text, or nil when it doesn't exist.
    func read() throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { throw Self.notJSON }
        return text
    }

    /// Writes through a symlink to the real file, keeps its permissions, and saves a backup of the
    /// user's original the first time only. An empty backup means there was no file before Deckhand.
    func write(_ text: String, original: String?) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: backup.path), !(original.map { Self.hasOurs($0, command: command) } ?? false) {
            try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((original ?? "").utf8).write(to: backup, options: .atomic)
        }
        let target = url.resolvingSymlinksInPath()
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let permissions = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions]
        try Data(text.utf8).write(to: target, options: .atomic)
        if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
    }

    /// Applies an edit and writes only when something changed. When Deckhand created the file and
    /// its groups were all it held, removing them removes the file again.
    @discardableResult
    func update(_ edit: (String) throws -> String) throws -> Bool {
        let original = try read()
        let updated = try edit(original ?? "")
        guard updated != (original ?? "") else { return false }
        let createdByDeckhand = (try? Data(contentsOf: backup))?.isEmpty == true
        if original != nil, createdByDeckhand, updated.trimmingCharacters(in: .whitespacesAndNewlines) == "{}" {
            try FileManager.default.removeItem(at: url.resolvingSymlinksInPath())
            return true
        }
        try write(updated, original: original)
        return true
    }
}

/// What Codex's `config.toml` says about hooks, read only, never written.
struct CodexConfigNotes: Equatable {
    /// `[features] hooks = false` (or the older `codex_hooks`): Codex runs no hooks at all.
    var hooksDisabled = false
    /// Inline `[hooks]` tables next to hooks.json; Codex warns about two places at every start.
    var inlineHooks = false
    /// Deckhand's own Claude Code hook script appears in the inline hooks.
    var claudeHook = false

    /// A small line-based reader: enough for these three facts, without a TOML parser.
    static func read(_ text: String, claudeScript: String) -> CodexConfigNotes {
        var notes = CodexConfigNotes()
        var table = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !line.isEmpty else { continue }
            if line.hasPrefix("[") {
                table = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                // Trust state lives under [hooks.state."…"]; that isn't a hook definition
                if table == "hooks" || (table.hasPrefix("hooks.") && !table.hasPrefix("hooks.state")) { notes.inlineHooks = true }
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0], value = parts[1]
            if table == "features", key == "hooks" || key == "codex_hooks", value == "false" { notes.hooksDisabled = true }
            if table.isEmpty, key == "features.hooks" || key == "features.codex_hooks", value == "false" { notes.hooksDisabled = true }
            if table.isEmpty, key == "hooks" { notes.inlineHooks = true }
            if (table == "hooks" || table.hasPrefix("hooks.")) && value.contains(claudeScript) { notes.claudeHook = true }
        }
        return notes
    }
}

extension JSONDocument {
    /// Replaces a value in place, laid out at the indentation of the line it starts on.
    mutating func replaceValue(_ node: Node, with value: JSONValue) throws {
        let bytes = Array(text.utf8)
        var start = node.range.lowerBound
        while start > 0 && bytes[start - 1] != UInt8(ascii: "\n") { start -= 1 }
        var end = start
        while end < bytes.count && (bytes[end] == UInt8(ascii: " ") || bytes[end] == UInt8(ascii: "\t")) { end += 1 }
        let indent = String(decoding: bytes[start..<end], as: UTF8.self)
        let pretty = bytes[node.range].contains(UInt8(ascii: "\n"))
        try replace(node.range, with: value.render(indent: indent, unit: indentUnit, pretty: pretty))
    }
}
