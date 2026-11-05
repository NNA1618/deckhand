import Foundation
import SQLite

struct Prompt: Identifiable, Hashable {
    let id: Int64
    var title: String
    var body: String
    var category: String
    var tags: [String]
    var favorite: Bool
    var usageCount: Int64
    let createdAt: Date
    var updatedAt: Date
}

/// The prompt library in the shared SQLite database.
///
/// The `prompts` table is created by `Database` as well; the store repeats the guarded
/// `CREATE TABLE IF NOT EXISTS` so it also works on its own connection (the self-test uses an
/// in-memory one). Its own bookkeeping lives in `prompt_meta`, never in the clipboard tables.
@MainActor
final class PromptStore {
    static let shared = PromptStore(db: Database.shared.db)

    private let db: Connection
    private let t = Table("prompts")
    private let meta = Table("prompt_meta")
    private let cId = SQLite.Expression<Int64>("id")
    private let cTitle = SQLite.Expression<String>("title")
    private let cBody = SQLite.Expression<String>("body")
    private let cCategory = SQLite.Expression<String>("category")
    private let cTags = SQLite.Expression<String>("tags")
    private let cFavorite = SQLite.Expression<Int64>("favorite")
    private let cUsageCount = SQLite.Expression<Int64>("usage_count")
    private let cCreatedAt = SQLite.Expression<Double>("created_at")
    private let cUpdatedAt = SQLite.Expression<Double>("updated_at")
    private let cKey = SQLite.Expression<String>("key")
    private let cValue = SQLite.Expression<String>("value")

    /// Set once the starter prompts were offered, so deleting them is final.
    static let seededKey = "starters_seeded"

    init(db: Connection) {
        self.db = db
        ensureSchema()
        seedOnce()
    }

    private func ensureSchema() {
        do {
            try db.execute("""
                CREATE TABLE IF NOT EXISTS prompts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    title TEXT NOT NULL,
                    body TEXT NOT NULL,
                    category TEXT NOT NULL DEFAULT 'General',
                    tags TEXT NOT NULL DEFAULT '',
                    favorite INTEGER NOT NULL DEFAULT 0,
                    usage_count INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );
            """)
            try db.execute("CREATE TABLE IF NOT EXISTS prompt_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        } catch {
            Log.info("prompts schema: \(error)")
        }
    }

    // MARK: - Reading

    /// Every prompt, unsorted; the view model filters and sorts in memory (libraries are small).
    func all() -> [Prompt] {
        guard let rows = try? db.prepare(t) else { return [] }
        return rows.map(map)
    }

    var count: Int { (try? db.scalar(t.count)) ?? 0 }

    // MARK: - Writing

    @discardableResult
    func create(title: String, body: String, category: String, tags: [String], favorite: Bool = false) -> Prompt? {
        let now = Date().timeIntervalSince1970
        let category = PromptLibrary.normalizedCategory(category)
        let tags = PromptLibrary.normalizedTags(tags)
        guard let rowId = try? db.run(t.insert(
            cTitle <- title,
            cBody <- body,
            cCategory <- category,
            cTags <- tags.joined(separator: ","),
            cFavorite <- favorite ? 1 : 0,
            cUsageCount <- 0,
            cCreatedAt <- now,
            cUpdatedAt <- now
        )) else { return nil }
        return Prompt(id: rowId, title: title, body: body, category: category, tags: tags,
                      favorite: favorite, usageCount: 0,
                      createdAt: Date(timeIntervalSince1970: now), updatedAt: Date(timeIntervalSince1970: now))
    }

    /// Saves an edit. Changes the "recently edited" time, unlike `setFavorite`.
    func update(_ p: Prompt) {
        _ = try? db.run(t.filter(cId == p.id).update(
            cTitle <- p.title,
            cBody <- p.body,
            cCategory <- PromptLibrary.normalizedCategory(p.category),
            cTags <- PromptLibrary.normalizedTags(p.tags).joined(separator: ","),
            cFavorite <- p.favorite ? 1 : 0,
            cUpdatedAt <- Date().timeIntervalSince1970
        ))
    }

    func setFavorite(_ id: Int64, _ favorite: Bool) {
        _ = try? db.run(t.filter(cId == id).update(cFavorite <- favorite ? 1 : 0))
    }

    func delete(_ id: Int64) {
        _ = try? db.run(t.filter(cId == id).delete())
    }

    func deleteAll() {
        _ = try? db.run(t.delete())
    }

    /// Puts a deleted prompt back with its id, counts and dates, for Undo.
    func restore(_ p: Prompt) {
        _ = try? db.run(t.insert(or: .replace,
            cId <- p.id,
            cTitle <- p.title,
            cBody <- p.body,
            cCategory <- p.category,
            cTags <- p.tags.joined(separator: ","),
            cFavorite <- p.favorite ? 1 : 0,
            cUsageCount <- p.usageCount,
            cCreatedAt <- p.createdAt.timeIntervalSince1970,
            cUpdatedAt <- p.updatedAt.timeIntervalSince1970
        ))
    }

    func incrementUsage(_ id: Int64) {
        _ = try? db.run(t.filter(cId == id).update(cUsageCount++))
    }

    // MARK: - Starter prompts

    /// Offers the starter prompts exactly once per database. Deleted starters stay deleted.
    /// A library that has prompts, or had some (0.4 added the starters on first use, and a user may have
    /// deleted every one since), only records that seeding happened. Clipboard history says nothing here:
    /// it fills up from launch, long before Prompts is first opened.
    private func seedOnce() {
        guard metaValue(Self.seededKey) == nil else { return }
        let lastId = (try? db.scalar("SELECT seq FROM sqlite_sequence WHERE name = 'prompts'") as? Int64) ?? 0
        if count == 0 && lastId == 0 { _ = addStarters() }
        setMeta(Self.seededKey, "1")
    }

    /// Adds the starter prompts whose title isn't in the library yet. Returns how many were added.
    @discardableResult
    func addStarters() -> Int {
        let titles = Set(all().map { $0.title.lowercased() })
        var added = 0
        for s in StarterPrompts.all where !titles.contains(s.title.lowercased()) {
            if create(title: s.title, body: s.body, category: s.category, tags: s.tags) != nil { added += 1 }
        }
        return added
    }

    func metaValue(_ key: String) -> String? {
        (try? db.pluck(meta.filter(cKey == key)))?[cValue]
    }

    private func setMeta(_ key: String, _ value: String) {
        _ = try? db.run(meta.insert(or: .replace, cKey <- key, cValue <- value))
    }

    // MARK: - Import and export

    /// Writes the whole library as JSON (see `PromptArchive`).
    func exportJSON() throws -> Data {
        try PromptArchive.encode(all())
    }

    /// Adds the prompts from a JSON export, skipping ones already in the library (same title and text).
    func importJSON(_ data: Data) throws -> (added: Int, skipped: Int) {
        let incoming = try PromptArchive.decode(data)
        var known = Set(all().map { PromptArchive.identity(title: $0.title, body: $0.body) })
        var added = 0, skipped = 0
        for p in incoming {
            let key = PromptArchive.identity(title: p.title, body: p.body)
            if known.contains(key) { skipped += 1; continue }
            if create(title: p.title, body: p.body, category: p.category, tags: p.tags, favorite: p.favorite) != nil {
                known.insert(key)
                added += 1
            }
        }
        return (added, skipped)
    }

    private func map(_ row: Row) -> Prompt {
        Prompt(
            id: row[cId],
            title: row[cTitle],
            body: row[cBody],
            category: row[cCategory],
            tags: row[cTags].split(separator: ",").map { String($0) },
            favorite: row[cFavorite] == 1,
            usageCount: row[cUsageCount],
            createdAt: Date(timeIntervalSince1970: row[cCreatedAt]),
            updatedAt: Date(timeIntervalSince1970: row[cUpdatedAt])
        )
    }
}

/// The JSON file Import… and Export… read and write:
/// `{"format": "deckhand-prompts", "version": 1, "prompts": [{"title", "body", "category", "tags", "favorite"}]}`.
/// Import also accepts a bare array of such objects.
enum PromptArchive {
    struct Entry: Codable, Equatable {
        var title: String
        var body: String
        var category: String
        var tags: [String]
        var favorite: Bool

        init(title: String, body: String, category: String, tags: [String], favorite: Bool) {
            self.title = title
            self.body = body
            self.category = category
            self.tags = tags
            self.favorite = favorite
        }

        // Only the text is required, so hand-written files import too
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            body = try c.decode(String.self, forKey: .body)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
            tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
            favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { title = PromptLibrary.title(fromBody: body) }
        }
    }

    private struct File: Codable {
        var format = "deckhand-prompts"
        var version = 1
        var prompts: [Entry]
    }

    struct Unreadable: LocalizedError {
        var errorDescription: String? { String(localized: "This file doesn't contain Deckhand prompts.") }
    }

    static func encode(_ prompts: [Prompt]) throws -> Data {
        let entries = prompts
            .sorted { $0.createdAt < $1.createdAt }
            .map { Entry(title: $0.title, body: $0.body, category: $0.category, tags: $0.tags, favorite: $0.favorite) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(File(prompts: entries))
    }

    static func decode(_ data: Data) throws -> [Entry] {
        let decoder = JSONDecoder()
        if let file = try? decoder.decode(File.self, from: data) { return file.prompts }
        if let list = try? decoder.decode([Entry].self, from: data) { return list }
        throw Unreadable()
    }

    /// Two prompts with the same title and text are the same prompt.
    static func identity(title: String, body: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "\u{1F}" +
            body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
