import AppKit

/// Made-up files for `--snapshot` runs, so the Shelf and Recents screenshots show content without
/// reading the user's shelf or Downloads. They live in the snapshot's temporary data folder.
@MainActor
enum SampleMedia {
    private static var folder: URL {
        let dir = AppPaths.supportDir.appendingPathComponent("samples", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The folder Recents scans in snapshot runs.
    static func recentsFolder() -> URL {
        let names: [(String, NSColor, NSColor)] = [
            ("hero-shot-v3.png", .systemIndigo, .systemTeal),
            ("ugc-try-on-frame.png", .systemOrange, .systemPink),
            ("character-sheet.png", .systemGreen, .systemBlue),
            ("product-on-dark.png", NSColor(white: 0.15, alpha: 1), .systemPurple),
            ("moodboard-sunset.png", .systemRed, .systemYellow),
            ("neon-street.png", .systemBlue, .systemPink),
        ]
        let dir = folder.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, (name, a, b)) in names.enumerated() {
            let url = dir.appendingPathComponent(name)
            writeImage(to: url, from: a, to: b)
            // Spread the dates so the order is visible
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(-i) * 3600)],
                                                   ofItemAtPath: url.path)
        }
        return dir
    }

    /// Files the Shelf shows in snapshot runs.
    static func shelfFiles() -> [URL] {
        let dir = folder.appendingPathComponent("Shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let image = dir.appendingPathComponent("Launch poster.png")
        writeImage(to: image, from: .systemIndigo, to: .systemPink)
        let second = dir.appendingPathComponent("Screenshot 2026-11-05.png")
        writeImage(to: second, from: .systemTeal, to: .systemGreen)
        let text = dir.appendingPathComponent("Brief.txt")
        try? "Launch brief".write(to: text, atomically: true, encoding: .utf8)
        let notes = dir.appendingPathComponent("Release notes for version 0.5 final.md")
        try? "# Notes".write(to: notes, atomically: true, encoding: .utf8)
        return [image, second, text, notes]
    }

    private static func writeImage(to url: URL, from a: NSColor, to b: NSColor) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let size = NSSize(width: 480, height: 360)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(starting: a, ending: b)?.draw(in: NSRect(origin: .zero, size: size), angle: 35)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
