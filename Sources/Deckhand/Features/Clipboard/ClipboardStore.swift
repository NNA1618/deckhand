import AppKit
import SQLite

extension Notification.Name {
    static let clipboardHistoryChanged = Notification.Name("clipboardHistoryChanged")
}

/// Columns of `clipboard_items`, shared by the store and the migration.
enum ClipboardSchema {
    static let table = Table("clipboard_items")
    static let id = SQLite.Expression<Int64>("id")
    static let kind = SQLite.Expression<String>("kind")
    static let text = SQLite.Expression<String?>("text")
    static let imagePath = SQLite.Expression<String?>("image_path")
    static let fileUrl = SQLite.Expression<String?>("file_url")
    static let hash = SQLite.Expression<String>("hash")
    static let pinned = SQLite.Expression<Int64>("pinned")
    static let sourceApp = SQLite.Expression<String?>("source_app")
    static let sourceAppName = SQLite.Expression<String?>("source_app_name")
    static let createdAt = SQLite.Expression<Double>("created_at")
    static let lastUsedAt = SQLite.Expression<Double>("last_used_at")
    // Added in schema version 2
    static let preview = SQLite.Expression<String?>("preview")
    static let searchText = SQLite.Expression<String?>("search_text")
    static let fileUrls = SQLite.Expression<String?>("file_urls")
    static let richType = SQLite.Expression<String?>("rich_type")
    static let richData = SQLite.Expression<SQLite.Blob?>("rich_data")
    static let isSecret = SQLite.Expression<Int64>("is_secret")
    static let pinnedAt = SQLite.Expression<Double?>("pinned_at")

    /// Version 2: previews and a folded search column, links as their own kind, several files per
    /// item, rich text, secrets, pin order, image paths relative to the images folder.
    static func upgradeToV2(_ db: Connection) throws {
        let name = "clipboard_items"
        try Database.addColumn(db, table: name, "preview", "TEXT")
        try Database.addColumn(db, table: name, "search_text", "TEXT")
        try Database.addColumn(db, table: name, "file_urls", "TEXT")
        try Database.addColumn(db, table: name, "rich_type", "TEXT")
        try Database.addColumn(db, table: name, "rich_data", "BLOB")
        try Database.addColumn(db, table: name, "is_secret", "INTEGER NOT NULL DEFAULT 0")
        try Database.addColumn(db, table: name, "pinned_at", "REAL")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_clipboard_recent ON clipboard_items(pinned, last_used_at DESC);")

        // Read everything first: updating rows while a statement walks them is undefined
        for row in Array(try db.prepare(table)) {
            var kind = ClipboardKind(rawValue: row[self.kind]) ?? .text
            var text = row[self.text]
            var fileURLs: [URL] = []
            if let s = row[fileUrl], let url = URL(string: s) {
                if url.isFileURL {
                    fileURLs = [url]
                } else {
                    // 0.4 stored copied web links as "files"
                    kind = .link
                    text = s
                }
            }
            if kind == .text, let t = text, ClipboardText.isLink(t) { kind = .link }
            let preview: String
            switch kind {
            case .text, .link: preview = ClipboardText.preview(text ?? "")
            case .file: preview = ClipboardText.fileTitle(fileURLs)
            case .image: preview = ""
            }
            let newHash: String
            switch kind {
            case .text, .link: newHash = ClipboardCapture.hash(kind, text ?? "")
            default: newHash = row[hash]
            }
            // The same rule as new copies: text from a password app is a password, hidden and not searchable
            let secret = (kind == .text || kind == .link) && row[sourceApp].map(ClipboardWatcher.passwordApps.contains) == true
            try db.run(table.filter(id == row[id]).update(
                self.kind <- kind.rawValue,
                self.text <- text,
                self.fileUrl <- (kind == .link ? nil : row[fileUrl]),
                fileUrls <- fileURLs.map(\.absoluteString).joined(separator: "\n"),
                self.preview <- preview,
                self.hash <- newHash,
                searchText <- (secret ? "" : ClipboardText.searchText(text: text, fileURLs: fileURLs, appName: row[sourceAppName])),
                isSecret <- (secret ? 1 : 0),
                // Absolute paths broke after a move to another Mac or user name; keep the file name only
                imagePath <- row[imagePath].map { URL(fileURLWithPath: $0).lastPathComponent },
                pinnedAt <- (row[pinned] == 1 ? row[createdAt] : nil)
            ))
        }
        try mergeDuplicates(db)
    }

    /// 0.4 saved a web link as a "file" and the same address copied as text as a separate row;
    /// both are now the same link with the same hash. Keeps one row per hash: the most recently
    /// used, pinned when any of them was, with the earliest creation time.
    static func mergeDuplicates(_ db: Connection) throws {
        struct Entry { let id: Int64; let pinned: Bool; let pinnedAt: Double?; let created: Double; let used: Double }
        var groups: [String: [Entry]] = [:]
        let dupes = table.select(hash).group(hash, having: id.count > 1)
        let wanted = Set(try db.prepare(dupes).map { $0[hash] })
        guard !wanted.isEmpty else { return }
        for row in try db.prepare(table.select(id, hash, pinned, pinnedAt, createdAt, lastUsedAt).filter(wanted.contains(hash))) {
            groups[row[hash], default: []].append(Entry(id: row[id], pinned: row[pinned] == 1, pinnedAt: row[pinnedAt],
                                                        created: row[createdAt], used: row[lastUsedAt]))
        }
        for entries in groups.values where entries.count > 1 {
            guard let keep = entries.max(by: { ($0.used, $0.id) < ($1.used, $1.id) }) else { continue }
            let pins = entries.filter(\.pinned)
            try db.run(table.filter(id == keep.id).update(
                pinned <- (pins.isEmpty ? 0 : 1),
                pinnedAt <- pins.compactMap(\.pinnedAt).min(),
                createdAt <- entries.map(\.created).min() ?? keep.created
            ))
            // Image files left without a row are removed by the regular orphan cleanup
            try db.run(table.filter(entries.map(\.id).filter { $0 != keep.id }.contains(id)).delete())
        }
    }
}

/// Clipboard history in SQLite: insert, list, search, pin, trim.
///
/// The list is ordered by `last_used_at`: copying something that is already in the history, or
/// copying or pasting it from the history, moves it to the top. Trimming removes the least recently
/// used items. Pinned items are never trimmed or expired.
@MainActor
final class ClipboardStore {
    static let shared: ClipboardStore = {
        let database = Database.shared
        if let damaged = database.movedAside { keepImages(AppPaths.clipboardImagesDir, of: damaged) }
        let store = ClipboardStore(db: database.db, imagesDir: AppPaths.clipboardImagesDir)
        // Without its file this session knows no items, so every saved image would look left over
        store.removesOrphans = !database.inMemory
        if AppPaths.isSnapshot { store.addSnapshotSamples() }
        return store
    }()

    /// A damaged database was replaced: its images move next to it, so the fresh history starts empty
    /// and nothing the old file refers to is deleted as left over.
    static func keepImages(_ images: URL, of damaged: URL) {
        try? FileManager.default.moveItem(at: images, to: keptImagesDir(of: damaged))
    }

    static func keptImagesDir(of damaged: URL) -> URL {
        damaged.deletingLastPathComponent()
            .appendingPathComponent(damaged.deletingPathExtension().lastPathComponent + "-images", isDirectory: true)
    }

    private typealias S = ClipboardSchema
    private let db: Connection
    let imagesDir: URL
    /// False while the session has no database file: then no image may be treated as left over.
    var removesOrphans = true

    init(db: Connection, imagesDir: URL) {
        self.db = db
        self.imagesDir = imagesDir
    }

    // MARK: - Insert

    enum InsertResult: Equatable {
        case inserted(Int64)
        /// The same content was already there; it moved to the top instead.
        case movedToTop(Int64)
        case failed
    }

    /// Inserts a processed copy, or moves the existing item with the same content to the top.
    /// `limit` 0 means no limit, `maxAgeDays` 0 means forever.
    @discardableResult
    func insert(_ entry: ClipboardEntry, limit: Int, maxAgeDays: Int, now: Date = Date()) -> InsertResult {
        let time = now.timeIntervalSince1970
        if let existing = try? db.pluck(S.table.select(S.id, S.imagePath, S.isSecret).filter(S.hash == entry.hash)) {
            let id = existing[S.id]
            // Rows from 0.4 name their image differently; drop the copy just written for this one
            if let name = entry.imageName, existing[S.imagePath].map({ URL(fileURLWithPath: $0).lastPathComponent }) != name {
                try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(name))
            }
            // The search covers the new source app. Once a password, always one: copying the same
            // text again from another app doesn't reveal it
            let secret = entry.isSecret || existing[S.isSecret] == 1
            _ = try? db.run(S.table.filter(S.id == id).update(
                S.lastUsedAt <- time,
                S.sourceApp <- entry.sourceApp,
                S.sourceAppName <- entry.sourceAppName,
                S.searchText <- (secret ? "" : entry.searchText),
                S.isSecret <- (secret ? 1 : 0)))
            NotificationCenter.default.post(name: .clipboardHistoryChanged, object: nil)
            return .movedToTop(id)
        }
        do {
            let id = try db.run(S.table.insert(
                S.kind <- entry.kind.rawValue,
                S.text <- entry.text,
                S.imagePath <- entry.imageName,
                S.fileUrl <- entry.fileURLs.first?.absoluteString,
                S.fileUrls <- entry.fileURLs.map(\.absoluteString).joined(separator: "\n"),
                S.hash <- entry.hash,
                S.pinned <- 0,
                S.sourceApp <- entry.sourceApp,
                S.sourceAppName <- entry.sourceAppName,
                S.createdAt <- time,
                S.lastUsedAt <- time,
                S.preview <- entry.preview,
                S.searchText <- entry.searchText,
                S.richType <- entry.richType,
                S.richData <- entry.richData.map { Blob(bytes: [UInt8]($0)) },
                S.isSecret <- entry.isSecret ? 1 : 0
            ))
            trim(limit: limit, maxAgeDays: maxAgeDays, now: now)
            NotificationCenter.default.post(name: .clipboardHistoryChanged, object: nil)
            return .inserted(id)
        } catch {
            Log.info("clipboard: insert failed: \(error)")
            if let name = entry.imageName { try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(name)) }
            return .failed
        }
    }

    // MARK: - Query

    /// Columns the list needs; the full text and rich data stay in the database.
    private var listColumns: [any Expressible] {
        [S.id, S.kind, S.preview, S.imagePath, S.fileUrl, S.fileUrls, S.pinned, S.isSecret, S.richType,
         S.sourceApp, S.sourceAppName, S.createdAt, S.lastUsedAt]
    }

    private func filtered(search: String, filter: ClipboardFilter) -> Table {
        var query = S.table.select(listColumns)
        if let kind = filter.kind { query = query.filter(S.kind == kind.rawValue) }
        for pattern in ClipboardText.likePatterns(for: search) {
            query = query.filter(S.searchText.like(pattern, escape: "\\"))
        }
        return query
    }

    /// Pinned items, the most recently pinned first.
    func pinnedItems(search: String = "", filter: ClipboardFilter = .all) -> [ClipboardItem] {
        let query = filtered(search: search, filter: filter)
            .filter(S.pinned == 1)
            .order(S.pinnedAt.desc, S.lastUsedAt.desc)
        return map(query)
    }

    /// One page of unpinned items, the most recently used first.
    func recentItems(search: String = "", filter: ClipboardFilter = .all, offset: Int = 0, limit: Int = 100) -> [ClipboardItem] {
        let query = filtered(search: search, filter: filter)
            .filter(S.pinned == 0)
            .order(S.lastUsedAt.desc, S.id.desc)
            .limit(limit, offset: offset)
        return map(query)
    }

    func item(id: Int64) -> ClipboardItem? {
        map(S.table.select(listColumns).filter(S.id == id)).first
    }

    func count(pinned: Bool? = nil) -> Int {
        var query = S.table
        if let pinned { query = query.filter(S.pinned == (pinned ? 1 : 0)) }
        return (try? db.scalar(query.count)) ?? 0
    }

    /// The full text of a text item or a link.
    func text(id: Int64) -> String? {
        (try? db.pluck(S.table.select(S.text).filter(S.id == id))).flatMap { $0[S.text] }
    }

    /// RTF or HTML stored next to the plain text.
    func richText(id: Int64) -> (type: String, data: Data)? {
        guard let row = try? db.pluck(S.table.select(S.richType, S.richData).filter(S.id == id)),
              let type = row[S.richType], let blob = row[S.richData] else { return nil }
        return (type, Data(blob.bytes))
    }

    func imageURL(for item: ClipboardItem) -> URL? {
        item.imageName.map { imagesDir.appendingPathComponent($0) }
    }

    // MARK: - Change

    /// Copying or pasting from the history moves the item to the top. No notification: the open
    /// list keeps its order so nothing jumps under the pointer; it reorders the next time it shows.
    func markUsed(id: Int64, now: Date = Date()) {
        _ = try? db.run(S.table.filter(S.id == id).update(S.lastUsedAt <- now.timeIntervalSince1970))
    }

    func togglePin(id: Int64) {
        guard let row = try? db.pluck(S.table.select(S.pinned).filter(S.id == id)) else { return }
        let pin = row[S.pinned] == 0
        let now = Date().timeIntervalSince1970
        if pin {
            _ = try? db.run(S.table.filter(S.id == id).update(S.pinned <- 1, S.pinnedAt <- now))
        } else {
            // An unpinned item returns at the top instead of deep in the history
            _ = try? db.run(S.table.filter(S.id == id).update(S.pinned <- 0, S.pinnedAt <- nil, S.lastUsedAt <- now))
        }
    }

    func delete(id: Int64) {
        delete(ids: [id])
    }

    private func delete(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        var images: [String] = []
        if let rows = try? db.prepare(S.table.select(S.imagePath).filter(ids.contains(S.id))) {
            images = rows.compactMap { $0[S.imagePath] }
        }
        _ = try? db.run(S.table.filter(ids.contains(S.id)).delete())
        for name in images {
            try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent))
        }
    }

    /// Removes every unpinned item. Returns how many were removed.
    @discardableResult
    func clearHistory() -> Int {
        let ids = ids(S.table.filter(S.pinned == 0))
        delete(ids: ids)
        NotificationCenter.default.post(name: .clipboardHistoryChanged, object: nil)
        return ids.count
    }

    /// Drops the least recently used unpinned items above `limit` and those older than `maxAgeDays`.
    func trim(limit: Int, maxAgeDays: Int, now: Date = Date()) {
        var doomed: [Int64] = []
        if maxAgeDays > 0 {
            let cutoff = now.timeIntervalSince1970 - Double(maxAgeDays) * 86_400
            doomed += ids(S.table.filter(S.pinned == 0 && S.lastUsedAt < cutoff))
        }
        if limit > 0 {
            doomed += ids(S.table.filter(S.pinned == 0).order(S.lastUsedAt.desc, S.id.desc).limit(-1, offset: limit))
        }
        guard !doomed.isEmpty else { return }
        delete(ids: Array(Set(doomed)))
        NotificationCenter.default.post(name: .clipboardHistoryChanged, object: nil)
    }

    /// Removes unpinned items copied from the given apps. Returns how many were removed.
    @discardableResult
    func deleteItems(fromApps apps: Set<String>) -> Int {
        let ids = ids(S.table.filter(S.pinned == 0 && Array(apps).contains(S.sourceApp)))
        delete(ids: ids)
        if !ids.isEmpty { NotificationCenter.default.post(name: .clipboardHistoryChanged, object: nil) }
        return ids.count
    }

    /// Saved passwords: copies marked concealed and copies from password apps, pinned or not.
    func secretCount() -> Int {
        (try? db.scalar(secrets.count)) ?? 0
    }

    @discardableResult
    func deleteSecrets() -> Int {
        let ids = ids(secrets)
        delete(ids: ids)
        if !ids.isEmpty { NotificationCenter.default.post(name: .clipboardHistoryChanged, object: nil) }
        return ids.count
    }

    private var secrets: Table {
        S.table.filter(S.isSecret == 1 || Array(ClipboardWatcher.passwordApps).contains(S.sourceApp))
    }

    /// Deletes image files no item refers to, e.g. left by a crash between saving and inserting.
    /// Files younger than a minute are skipped: a capture may be on its way in.
    func removeOrphanImages() {
        guard removesOrphans,
              let rows = try? db.prepare(S.table.select(S.imagePath).filter(S.imagePath != nil)) else { return }
        let known = Set(rows.compactMap { $0[S.imagePath].map { URL(fileURLWithPath: $0).lastPathComponent } })
        let dir = imagesDir
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
            for url in files where !known.contains(url.lastPathComponent) {
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                if created < Date().addingTimeInterval(-60) { try? fm.removeItem(at: url) }
            }
        }
    }

    // MARK: - Private

    private func ids(_ query: Table) -> [Int64] {
        guard let rows = try? db.prepare(query.select(S.id)) else { return [] }
        return rows.map { $0[S.id] }
    }

    private func map(_ query: Table) -> [ClipboardItem] {
        guard let rows = try? db.prepare(query) else { return [] }
        return rows.map { row in
            let kind = ClipboardKind(rawValue: row[S.kind]) ?? .text
            var urls = (row[S.fileUrls] ?? "").split(separator: "\n").compactMap { URL(string: String($0)) }
            if urls.isEmpty, kind == .file, let s = row[S.fileUrl], let url = URL(string: s) { urls = [url] }
            return ClipboardItem(
                id: row[S.id],
                kind: kind,
                preview: row[S.preview] ?? "",
                imageName: row[S.imagePath].map { URL(fileURLWithPath: $0).lastPathComponent },
                fileURLs: urls,
                pinned: row[S.pinned] == 1,
                isSecret: row[S.isSecret] == 1,
                hasRichText: row[S.richType] != nil,
                sourceApp: row[S.sourceApp],
                sourceAppName: row[S.sourceAppName],
                createdAt: Date(timeIntervalSince1970: row[S.createdAt]),
                lastUsedAt: Date(timeIntervalSince1970: row[S.lastUsedAt]))
        }
    }

    // MARK: - Snapshot samples

    /// `--snapshot` starts with an empty temporary database; a few realistic items make the
    /// Clipboard tab screenshot meaningful.
    private func addSnapshotSamples() {
        guard count() == 0 else { return }
        let now = Date()
        func add(_ snap: PasteboardSnapshot, minutesAgo: Double, pin: Bool = false) {
            guard let entry = ClipboardCapture.prepare(snap, imagesDir: imagesDir, maxImageBytes: 0),
                  case let .inserted(id) = insert(entry, limit: 0, maxAgeDays: 0, now: now.addingTimeInterval(-minutesAgo * 60))
            else { return }
            if pin { togglePin(id: id) }
        }
        // Real copies carry the app's name as the system shows it
        func appName(_ bundleId: String, _ fallback: String) -> String {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? fallback
        }
        let text = NSPasteboard.PasteboardType.string.rawValue
        add(PasteboardSnapshot(types: [text], string: String(localized: "clipboard.sample.address",
                                                               defaultValue: "1 Infinite Loop, Cupertino, CA 95014"),
                               sourceApp: "com.apple.Notes", sourceAppName: appName("com.apple.Notes", "Notes")), minutesAgo: 600, pin: true)
        add(PasteboardSnapshot(fileURLs: [URL(fileURLWithPath: "/Users/me/Documents/Quarterly report.pdf"),
                                          URL(fileURLWithPath: "/Users/me/Documents/Budget.numbers")],
                               sourceApp: "com.apple.finder", sourceAppName: appName("com.apple.finder", "Finder")), minutesAgo: 95)
        if let image = Self.sampleImagePNG() {
            add(PasteboardSnapshot(types: [NSPasteboard.PasteboardType.png.rawValue], imageData: image,
                                   imageType: NSPasteboard.PasteboardType.png.rawValue,
                                   sourceApp: "com.apple.Preview", sourceAppName: appName("com.apple.Preview", "Preview")), minutesAgo: 40)
        }
        add(PasteboardSnapshot(types: [text], string: "git rebase -i HEAD~3",
                               sourceApp: "com.apple.Terminal", sourceAppName: appName("com.apple.Terminal", "Terminal")), minutesAgo: 12)
        add(PasteboardSnapshot(types: [text], string: "https://developer.apple.com/documentation/appkit/nspasteboard",
                               sourceApp: "com.apple.Safari", sourceAppName: appName("com.apple.Safari", "Safari")), minutesAgo: 3)
        add(PasteboardSnapshot(types: [text], string: String(localized: "clipboard.sample.note",
                                                               defaultValue: "The meeting moved to Thursday at 3 pm, room 4.2. Bring the printed slides."),
                               sourceApp: "com.apple.mail", sourceAppName: appName("com.apple.mail", "Mail")), minutesAgo: 0)
    }

    private static func sampleImagePNG() -> Data? {
        let width = 480, height = 300
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(red: 0.35, green: 0.3, blue: 0.85, alpha: 1), CGColor(red: 0.2, green: 0.75, blue: 0.8, alpha: 1)]
        if let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        return ctx.makeImage().flatMap(ClipboardCapture.encodePNG)
    }
}
