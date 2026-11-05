import Foundation

enum AppPaths {
    /// The running bundle's id: `com.nna1618.deckhand`, or the separate id check builds use so their
    /// settings and Keychain items stay apart from the installed app's.
    static let bundleId = Bundle.main.bundleIdentifier ?? "com.nna1618.deckhand"

    /// `--snapshot` runs keep their data in a fresh temporary folder, apart from the user's.
    static let isSnapshot = CommandLine.arguments.contains("--snapshot")

    static let supportDir: URL = {
        let fm = FileManager.default
        if isSnapshot {
            let dir = fm.temporaryDirectory.appendingPathComponent("deckhand-snapshot-\(ProcessInfo.processInfo.processIdentifier)")
            try? fm.removeItem(at: dir)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
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
