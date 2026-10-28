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

@MainActor
final class PromptStore {
    static let shared = PromptStore()

    private let db: Connection
    private let t = Table("prompts")
    private let cId = SQLite.Expression<Int64>("id")
    private let cTitle = SQLite.Expression<String>("title")
    private let cBody = SQLite.Expression<String>("body")
    private let cCategory = SQLite.Expression<String>("category")
    private let cTags = SQLite.Expression<String>("tags")
    private let cFavorite = SQLite.Expression<Int64>("favorite")
    private let cUsageCount = SQLite.Expression<Int64>("usage_count")
    private let cCreatedAt = SQLite.Expression<Double>("created_at")
    private let cUpdatedAt = SQLite.Expression<Double>("updated_at")

    private init() {
        self.db = Database.shared.db
        seedIfEmpty()
    }

    func all(search: String = "", category: String? = nil) -> [Prompt] {
        var query = t.order(cFavorite.desc, cUsageCount.desc, cUpdatedAt.desc)
        if let category = category, !category.isEmpty, category != PromptsViewModel.allKey {
            query = query.filter(cCategory == category)
        }
        var rows: [Prompt] = []
        if let r = try? db.prepare(query) {
            for row in r { rows.append(map(row)) }
        }
        if search.isEmpty { return rows }
        // Simple substring match on title, body and tags
        let s = search.lowercased()
        return rows.filter {
            $0.title.lowercased().contains(s)
            || $0.body.lowercased().contains(s)
            || $0.tags.joined(separator: " ").lowercased().contains(s)
        }
    }

    func categories() -> [String] {
        var set = Set<String>()
        if let rows = try? db.prepare(t.select(cCategory)) {
            for row in rows { set.insert(row[cCategory]) }
        }
        return Array(set).sorted()
    }

    func create(title: String, body: String, category: String, tags: [String], favorite: Bool = false) -> Prompt? {
        let now = Date().timeIntervalSince1970
        if let rowId = try? db.run(t.insert(
            cTitle <- title,
            cBody <- body,
            cCategory <- category,
            cTags <- tags.joined(separator: ","),
            cFavorite <- favorite ? 1 : 0,
            cUsageCount <- 0,
            cCreatedAt <- now,
            cUpdatedAt <- now
        )) {
            return Prompt(
                id: rowId, title: title, body: body, category: category,
                tags: tags, favorite: favorite, usageCount: 0,
                createdAt: Date(timeIntervalSince1970: now),
                updatedAt: Date(timeIntervalSince1970: now)
            )
        }
        return nil
    }

    func update(_ p: Prompt) {
        let now = Date().timeIntervalSince1970
        try? db.run(t.filter(cId == p.id).update(
            cTitle <- p.title,
            cBody <- p.body,
            cCategory <- p.category,
            cTags <- p.tags.joined(separator: ","),
            cFavorite <- p.favorite ? 1 : 0,
            cUpdatedAt <- now
        ))
    }

    func delete(_ id: Int64) {
        try? db.run(t.filter(cId == id).delete())
    }

    func incrementUsage(_ id: Int64) {
        try? db.run(t.filter(cId == id).update(cUsageCount++))
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

    // MARK: - Seed

    private func seedIfEmpty() {
        let count = (try? db.scalar(t.count)) ?? 0
        guard count == 0 else { return }

        // Starter examples for new users
        let seeds: [(String, String, String, [String])] = [
            ("Product UGC video",
             "UGC-style try-on video of the product below. Natural hand movements, authentic daylight, handheld 50mm look, one continuous take.\nProduct: {{product}}",
             "Image & Video", ["ugc", "video"]),
            ("Hero product shot",
             "Hero shot of {{product}} on a dark seamless background, single soft key light from the left, subtle rim light, shallow depth of field, premium commercial look.",
             "Image & Video", ["product", "photo"]),
            ("Character sheet",
             "Character sheet of {{character}}: front, side, three-quarter and back views. Consistent proportions and lighting, neutral grey background.",
             "Image & Video", ["character"]),
            ("Explain this file",
             "Read this file and explain what it does as a short list. Point out the main functions and dependencies.",
             "Code", ["explain"]),
            ("Find bugs",
             "Check this code for bugs, race conditions, leaks and unhandled edge cases. Be brief and list the most serious first.",
             "Code", ["review"]),
            ("Refactor",
             "Refactor this code for readability without changing behavior. Explain each change in one line.",
             "Code", ["refactor"]),
            ("Key points",
             "Pull the 5 to 7 key points out of this text, one line each.",
             "Writing", ["summary"]),
            ("Explain like I'm ten",
             "Explain this so a ten-year-old would understand it, in simple words but without losing the point.",
             "Writing", ["explain"]),
        ]
        for (title, body, cat, tags) in seeds {
            _ = create(title: title, body: body, category: cat, tags: tags)
        }
    }
}
