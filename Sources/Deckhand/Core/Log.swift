import Foundation

/// Writes diagnostics to ~/Library/Logs/Deckhand/deckhand.log. Self-test and snapshot runs, and check builds,
/// write to deckhand-test.log next to it, so the app's own log stays about the app.
enum Log {
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Deckhand", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let args = CommandLine.arguments
        let test = AppPaths.bundleId != "com.nna1618.deckhand" || args.contains("--selftest") || args.contains("--snapshot")
        return dir.appendingPathComponent(test ? "deckhand-test.log" : "deckhand.log")
    }()

    private static let queue = DispatchQueue(label: "deckhand.log")

    static func info(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
