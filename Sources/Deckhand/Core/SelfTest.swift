import AppKit

/// `Deckhand --selftest` checks editor logic without UI and exits.
/// Exists because the test frameworks are not available without Xcode.
@MainActor
enum SelfTest {
    static func run() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ name: String) {
            Log.info("selftest \(cond ? "ok  " : "FAIL") \(name)")
            print("\(cond ? "ok  " : "FAIL") \(name)")
            if !cond { ok = false }
        }

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 300,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = NSImage(size: NSSize(width: 200, height: 150))
        image.addRepresentation(rep)

        guard let model = EditorModel(image: image) else {
            check(false, "editor model init")
            return false
        }
        check(model.pixelScale == 2, "retina scale = 2")

        model.tool = .arrow
        model.dragChanged(start: CGPoint(x: 10, y: 10), current: CGPoint(x: 200, y: 150))
        model.dragEnded(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 200, y: 150))
        check(model.annotations.count == 1, "arrow added")

        model.tool = .text
        model.dragEnded(start: CGPoint(x: 30, y: 30), end: CGPoint(x: 30, y: 30))
        model.pendingText = "привет"
        model.commitText()
        check(model.annotations.count == 2, "text added")

        let flat = model.renderCGImage()
        check(flat?.width == 400 && flat?.height == 300, "export keeps pixel size")

        model.tool = .crop
        model.dragChanged(start: CGPoint(x: 50, y: 50), current: CGPoint(x: 250, y: 150))
        model.applyCrop()
        check(model.imageSize == CGSize(width: 200, height: 100), "crop size")
        check(model.annotations.isEmpty, "crop flattens annotations")

        model.undo()
        check(model.imageSize == CGSize(width: 400, height: 300), "undo crop size")
        check(model.annotations.count == 2, "undo restores annotations")

        model.redo()
        check(model.imageSize == CGSize(width: 200, height: 100), "redo crop")

        let out = model.renderNSImage()
        check(out?.size == NSSize(width: 100, height: 50), "nsimage point size after crop")

        // Only meaningful inside the .app, where the .lproj folders are bundled
        if let path = Bundle.main.path(forResource: "ru", ofType: "lproj"), let ru = Bundle(path: path) {
            check(ru.localizedString(forKey: "Settings", value: nil, table: nil) == "Настройки", "russian localization bundled")
        }

        let ocrImage = NSImage(size: NSSize(width: 600, height: 160))
        ocrImage.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 600, height: 160).fill()
        ("Deckhand reads text" as NSString).draw(at: NSPoint(x: 30, y: 60), withAttributes: [
            .font: NSFont.systemFont(ofSize: 40, weight: .medium), .foregroundColor: NSColor.black,
        ])
        ocrImage.unlockFocus()
        let ocrFile = FileManager.default.temporaryDirectory.appendingPathComponent("deckhand-selftest-ocr.png")
        if let tiff = ocrImage.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: ocrFile)
        }
        let recognized = TextRecognizer.recognize(at: ocrFile) ?? ""
        check(recognized.contains("Deckhand reads text"), "text recognition: \(recognized)")

        let sc = Shortcut(keyCode: 1, modifiers: UInt32(1 << 8 | 1 << 9)) // ⌘⇧S
        check(sc.display == "⇧⌘S", "shortcut display \(sc.display)")

        return ok
    }
}
