import Foundation
import SQLite

/// Shared SQLite connection used by all features.
@MainActor
final class Database {
    static let shared = Database()
    let db: Connection

    private init() {
        do {
            self.db = try Connection(AppPaths.databaseURL.path)
            try self.db.execute("PRAGMA foreign_keys = ON;")
            try self.db.execute("PRAGMA journal_mode = WAL;")
            try migrate()
            // Clipboard image paths are absolute: fix the prefix after moving from Fringe
            try self.db.execute("""
                UPDATE clipboard_items
                SET image_path = replace(image_path, '/Application Support/Fringe/', '/Application Support/Deckhand/')
                WHERE image_path LIKE '%/Application Support/Fringe/%';
            """)
        } catch {
            fatalError("Cannot open the database: \(error)")
        }
    }

    private func migrate() throws {
        // Clipboard items
        try db.execute("""
            CREATE TABLE IF NOT EXISTS clipboard_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind TEXT NOT NULL,          -- 'text' | 'image' | 'file'
                text TEXT,                   -- for text
                image_path TEXT,             -- file in clipboardImagesDir
                file_url TEXT,               -- file:// url
                hash TEXT NOT NULL,          -- dedupe key
                pinned INTEGER NOT NULL DEFAULT 0,
                source_app TEXT,             -- source app bundle id
                source_app_name TEXT,
                created_at REAL NOT NULL,
                last_used_at REAL NOT NULL
            );
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_clipboard_hash ON clipboard_items(hash);")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_clipboard_created ON clipboard_items(created_at DESC);")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_clipboard_pinned ON clipboard_items(pinned DESC, created_at DESC);")

        // Prompts library
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
}
