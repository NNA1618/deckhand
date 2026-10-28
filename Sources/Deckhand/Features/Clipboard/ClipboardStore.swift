import Foundation
import AppKit
import SQLite
import CryptoKit

/// Clipboard history in SQLite: insert, search, pin and trim.
extension Notification.Name {
    static let clipboardHistoryChanged = Notification.Name("clipboardHistoryChanged")
}

@MainActor
final class ClipboardStore {
    static let shared = ClipboardStore()

    private let db: Connection

    private let t = Table("clipboard_items")
    private let cId = SQLite.Expression<Int64>("id")
    private let cKind = SQLite.Expression<String>("kind")
    private let cText = SQLite.Expression<String?>("text")
    private let cImagePath = SQLite.Expression<String?>("image_path")
    private let cFileUrl = SQLite.Expression<String?>("file_url")
    private let cHash = SQLite.Expression<String>("hash")
    private let cPinned = SQLite.Expression<Int64>("pinned")
    private let cSrcApp = SQLite.Expression<String?>("source_app")
    private let cSrcAppName = SQLite.Expression<String?>("source_app_name")
    private let cCreatedAt = SQLite.Expression<Double>("created_at")
    private let cLastUsedAt = SQLite.Expression<Double>("last_used_at")

    private init() {
        self.db = Database.shared.db
    }

    // MARK: - Insert

    /// Inserts an item, or bumps lastUsedAt of an existing one with the same hash.
    /// Returns true for a new item.
    @discardableResult
    func insert(kind: ClipboardKind,
                text: String? = nil,
                imageData: Data? = nil,
                fileURL: URL? = nil,
                source: (bundleId: String?, name: String?) = (nil, nil)) -> Bool {
        let hash = computeHash(kind: kind, text: text, imageData: imageData, fileURL: fileURL)
        let now = Date().timeIntervalSince1970

        if let existing = try? db.pluck(t.filter(cHash == hash)) {
            let id = existing[cId]
            try? db.run(t.filter(cId == id).update(cLastUsedAt <- now))
            return false
        }

        var imagePath: String? = nil
        if kind == .image, let data = imageData {
            let name = "img-\(UUID().uuidString).png"
            let url = AppPaths.clipboardImagesDir.appendingPathComponent(name)
            try? data.write(to: url)
            imagePath = url.path
        }

        let fileUrlStr = fileURL?.absoluteString

        _ = try? db.run(t.insert(
            cKind <- kind.rawValue,
            cText <- text,
            cImagePath <- imagePath,
            cFileUrl <- fileUrlStr,
            cHash <- hash,
            cPinned <- 0,
            cSrcApp <- source.bundleId,
            cSrcAppName <- source.name,
            cCreatedAt <- now,
            cLastUsedAt <- now
        ))

        trimOldItems()
        NotificationCenter.default.post(name: .clipboardHistoryChanged, object: nil)
        return true
    }

    // MARK: - Query

    func allItems(search: String = "", limit: Int = 1000) -> [ClipboardItem] {
        var query = t.order(cPinned.desc, cCreatedAt.desc).limit(limit)
        if !search.isEmpty {
            query = query.filter(cText.like("%\(search)%"))
                .order(cPinned.desc, cCreatedAt.desc)
                .limit(limit)
        }
        var items: [ClipboardItem] = []
        if let rows = try? db.prepare(query) {
            for row in rows {
                items.append(mapRow(row))
            }
        }
        return items
    }

    func togglePin(id: Int64) {
        guard let row = try? db.pluck(t.filter(cId == id)) else { return }
        let newPinned: Int64 = row[cPinned] == 1 ? 0 : 1
        try? db.run(t.filter(cId == id).update(cPinned <- newPinned))
    }

    func delete(id: Int64) {
        if let row = try? db.pluck(t.filter(cId == id)) {
            if let path = row[cImagePath] {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        try? db.run(t.filter(cId == id).delete())
    }

    func markUsed(id: Int64) {
        try? db.run(t.filter(cId == id).update(cLastUsedAt <- Date().timeIntervalSince1970))
    }

    func imageData(for item: ClipboardItem) -> Data? {
        guard let path = item.imagePath else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    // MARK: - Private

    private func mapRow(_ row: Row) -> ClipboardItem {
        let kind = ClipboardKind(rawValue: row[cKind]) ?? .text
        return ClipboardItem(
            id: row[cId],
            kind: kind,
            text: row[cText],
            imagePath: row[cImagePath],
            fileURL: row[cFileUrl],
            hash: row[cHash],
            pinned: row[cPinned] == 1,
            sourceApp: row[cSrcApp],
            sourceAppName: row[cSrcAppName],
            createdAt: Date(timeIntervalSince1970: row[cCreatedAt]),
            lastUsedAt: Date(timeIntervalSince1970: row[cLastUsedAt])
        )
    }

    private func computeHash(kind: ClipboardKind, text: String?, imageData: Data?, fileURL: URL?) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        if let t = text { hasher.update(data: Data(t.utf8)) }
        if let d = imageData { hasher.update(data: d) }
        if let u = fileURL { hasher.update(data: Data(u.absoluteString.utf8)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func trimOldItems() {
        // Drop the oldest unpinned items above the limit
        let maxItems = Settings.shared.historyLimit
        guard maxItems > 0 else { return }
        let count = (try? db.scalar(t.filter(cPinned == 0).count)) ?? 0
        if count > maxItems {
            let overLimit = count - maxItems
            if let old = try? db.prepare(
                t.filter(cPinned == 0).order(cCreatedAt.asc).limit(overLimit)
            ) {
                let ids = old.map { $0[cId] }
                for id in ids { delete(id: id) }
            }
        }
    }
}
