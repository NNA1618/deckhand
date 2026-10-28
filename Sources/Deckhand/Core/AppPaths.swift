import Foundation

enum AppPaths {
    static let bundleId = "com.nna1618.deckhand"

    static let supportDir: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Deckhand", isDirectory: true)
        migrateFromFringe(base: base, to: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var databaseURL: URL { supportDir.appendingPathComponent("deckhand.sqlite") }

    static var clipboardImagesDir: URL { subdir("clipboard-images") }

    private static func subdir(_ name: String) -> URL {
        let dir = supportDir.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The app was called Fringe during development. Move its data over once.
    private static func migrateFromFringe(base: URL, to dir: URL) {
        let fm = FileManager.default
        let old = base.appendingPathComponent("Fringe", isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: dir.path) else { return }
        do {
            try fm.moveItem(at: old, to: dir)
            for ext in ["", "-wal", "-shm"] {
                let from = dir.appendingPathComponent("fringe.sqlite" + ext)
                if fm.fileExists(atPath: from.path) {
                    try fm.moveItem(at: from, to: dir.appendingPathComponent("deckhand.sqlite" + ext))
                }
            }
            UserDefaults.standard.set(true, forKey: "migratedFromFringe")
        } catch {
            Log.info("migration failed: \(error)")
        }
    }
}
