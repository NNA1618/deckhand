import Foundation
import SQLite

/// Shared SQLite connection used by all features (clipboard history and the prompts library).
///
/// The schema is versioned with `PRAGMA user_version`. Every step is additive and safe to run twice
/// (`CREATE … IF NOT EXISTS`, columns added only when missing), so an older or newer copy of the app
/// can open the same file. Add new steps at the end of `migrations`; never edit a released step.
@MainActor
final class Database {
    static let shared = Database(url: AppPaths.databaseURL)

    let db: Connection
    /// Where a damaged database was moved, when it had to be replaced by a fresh one on this launch.
    private(set) var movedAside: URL?

    /// The schema version this build writes.
    static let currentVersion: Int64 = 2

    /// Opens the database at `url`, or an in-memory one when `url` is nil (self-test).
    ///
    /// A damaged file is moved aside and replaced, so a bad file can't crash the app on every launch.
    /// Any other failure (disk full, no permission) leaves the file alone and runs this session in memory.
    init(url: URL?) {
        guard let url else {
            db = Self.openInMemory()
            return
        }
        do {
            db = try Self.open(url)
            return
        } catch {
            Log.info("database: cannot open \(url.lastPathComponent): \(error)")
            guard Self.isDamaged(error) else {
                db = Self.openInMemory()
                return
            }
        }
        movedAside = Self.moveAside(url)
        do {
            db = try Self.open(url)
        } catch {
            Log.info("database: fresh database failed too: \(error)")
            db = Self.openInMemory()
        }
    }

    private static func open(_ url: URL) throws -> Connection {
        let db = try Connection(url.path)
        db.busyTimeout = 3
        try db.execute("PRAGMA foreign_keys = ON;")
        try db.execute("PRAGMA journal_mode = WAL;")
        try migrate(db)
        return db
    }

    private static func openInMemory() -> Connection {
        do {
            let db = try Connection(.inMemory)
            try migrate(db)
            return db
        } catch {
            // An in-memory database only fails when SQLite itself is unusable
            fatalError("Cannot create an in-memory database: \(error)")
        }
    }

    /// SQLITE_CORRUPT (11) and SQLITE_NOTADB (26): the file itself is bad.
    private static func isDamaged(_ error: Error) -> Bool {
        switch error as? SQLite.Result {
        case let .error(_, code)?: return code == 11 || code == 26
        case let .extendedError(_, code)?: return code & 0xFF == 11 || code & 0xFF == 26
        default: return false
        }
    }

    /// Renames the file and its WAL/SHM companions to `deckhand-damaged-<date>.sqlite…`.
    private static func moveAside(_ url: URL) -> URL? {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let base = url.deletingPathExtension().lastPathComponent + "-damaged-" + stamp
        let target = url.deletingLastPathComponent().appendingPathComponent(base + "." + url.pathExtension)
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: from.path) else { continue }
            try? fm.moveItem(at: from, to: URL(fileURLWithPath: target.path + suffix))
        }
        Log.info("database: damaged file moved to \(target.lastPathComponent)")
        return target
    }

    // MARK: - Migrations

    nonisolated private static var migrations: [(version: Int64, run: (Connection) throws -> Void)] {
        [
            (1, createBaseTables),
            (2, ClipboardSchema.upgradeToV2),
        ]
    }

    nonisolated static func migrate(_ db: Connection) throws {
        let version = (try db.scalar("PRAGMA user_version") as? Int64) ?? 0
        // The base tables are cheap to re-check and protect against a file whose version
        // was set by a build that created them differently
        try createBaseTables(db)
        for step in migrations where step.version > version {
            try db.transaction {
                try step.run(db)
                try db.execute("PRAGMA user_version = \(step.version);")
            }
        }
    }

    /// The tables as Deckhand 0.4 created them.
    nonisolated private static func createBaseTables(_ db: Connection) throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS clipboard_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind TEXT NOT NULL,          -- 'text' | 'image' | 'file' | 'link'
                text TEXT,                   -- for text and links
                image_path TEXT,             -- file name in clipboardImagesDir (absolute before v2)
                file_url TEXT,               -- first file:// url
                hash TEXT NOT NULL,          -- dedupe key
                pinned INTEGER NOT NULL DEFAULT 0,
                source_app TEXT,             -- source app bundle id
                source_app_name TEXT,
                created_at REAL NOT NULL,
                last_used_at REAL NOT NULL   -- last copied or pasted; the list is sorted by it
            );
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_clipboard_hash ON clipboard_items(hash);")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_clipboard_created ON clipboard_items(created_at DESC);")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_clipboard_pinned ON clipboard_items(pinned DESC, created_at DESC);")

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
        try db.execute("CREATE INDEX IF NOT EXISTS idx_prompts_category ON prompts(category);")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_prompts_favorite ON prompts(favorite DESC, usage_count DESC);")
    }

    /// Adds a column unless the table already has it, so a step can run twice.
    nonisolated static func addColumn(_ db: Connection, table: String, _ name: String, _ definition: String) throws {
        var exists = false
        for row in try db.prepare("PRAGMA table_info(\(table))") where (row[1] as? String) == name {
            exists = true
        }
        if !exists { try db.execute("ALTER TABLE \(table) ADD COLUMN \(name) \(definition);") }
    }
}
