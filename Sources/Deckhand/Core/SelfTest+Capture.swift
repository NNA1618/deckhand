import AppKit
import Carbon.HIToolbox
import CoreImage

extension SelfTest {
    /// Editor, blur, export, text recognition, capture options and shortcuts.
    /// Owned by the capture and hotkeys workstream. Pure logic and temporary files only.
    static func capture(_ check: Check) {
        editor(check)
        editorKeys(check)
        recognition(check)
        captureOptions(check)
        shortcuts(check)
    }

    // MARK: - Editor

    private static func editor(_ check: Check) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 300,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = NSImage(size: NSSize(width: 200, height: 150))
        image.addRepresentation(rep)

        guard let model = EditorModel(image: image) else {
            check(false, "editor model init")
            return
        }
        check(model.pixelScale == 2, "retina scale = 2")
        check(model.tool == .arrow, "editor starts with the arrow")

        model.tool = .arrow
        model.dragChanged(start: CGPoint(x: 10, y: 10), current: CGPoint(x: 200, y: 150))
        model.dragEnded(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 200, y: 150))
        check(model.annotations.count == 1, "arrow added")

        model.tool = .text
        model.textSizeLevel = 2
        model.dragEnded(start: CGPoint(x: 30, y: 30), end: CGPoint(x: 30, y: 30))
        model.pendingText = "привет"
        model.commitText()
        check(model.annotations.count == 2, "text added")
        check(model.annotations.last?.fontSize == 48 * 2, "text size is separate from stroke width")

        let flat = model.renderCGImage()
        check(flat?.width == 400 && flat?.height == 300, "export keeps pixel size")

        // A click with the crop tool must not start a crop
        model.tool = .crop
        model.dragChanged(start: CGPoint(x: 50, y: 50), current: CGPoint(x: 51, y: 51))
        model.dragEnded(start: CGPoint(x: 50, y: 50), end: CGPoint(x: 51, y: 51))
        check(model.cropRect == nil, "tiny crop ignored")

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

        // Select, move and delete
        model.undo()
        model.tool = .select
        model.dragChanged(start: CGPoint(x: 40, y: 40), current: CGPoint(x: 40, y: 40))
        check(model.selection == model.annotations.last?.id, "select hits the topmost annotation (the text)")
        model.dragChanged(start: CGPoint(x: 40, y: 40), current: CGPoint(x: 80, y: 60))
        model.dragEnded(start: CGPoint(x: 40, y: 40), end: CGPoint(x: 80, y: 60))
        if case .text(let at, _)? = model.annotations.last?.kind {
            check(at == CGPoint(x: 70, y: 50), "move offsets the text: \(at)")
        } else {
            check(false, "text still last after move")
        }
        check(model.perform(.delete) && model.annotations.count == 1, "delete removes the selection")
        model.undo()
        check(model.annotations.count == 2, "undo restores a deleted annotation")

        // Export orientation and redaction: a black box in the top left corner of a white image
        let white = solidImage(width: 200, height: 100, color: .white)
        if let redact = EditorModel(image: white) {
            redact.tool = .redact
            redact.dragChanged(start: .zero, current: CGPoint(x: 40, y: 40))
            redact.dragEnded(start: .zero, end: CGPoint(x: 40, y: 40))
            if let cg = redact.renderCGImage() {
                check(brightness(cg, x: 10, y: 10) < 0.1, "redact is black at the top left")
                check(brightness(cg, x: 150, y: 80) > 0.9, "export is not flipped")
            } else {
                check(false, "redact export")
            }
        }

        // Blur changes pixels inside the region and none outside it
        let stripes = NSImage(size: NSSize(width: 200, height: 100))
        stripes.lockFocus()
        for x in stride(from: 0, to: 200, by: 4) {
            (x % 8 == 0 ? NSColor.black : NSColor.white).setFill()
            NSRect(x: x, y: 0, width: 4, height: 100).fill()
        }
        stripes.unlockFocus()
        if let blurModel = EditorModel(image: stripes), let before = blurModel.renderCGImage() {
            blurModel.tool = .blur
            let w = CGFloat(before.width), h = CGFloat(before.height)
            blurModel.dragChanged(start: CGPoint(x: 0, y: 0), current: CGPoint(x: w / 2, y: h))
            blurModel.dragEnded(start: CGPoint(x: 0, y: 0), end: CGPoint(x: w / 2, y: h))
            if let after = blurModel.renderCGImage() {
                check(!pixelsEqual(after, before), "blur changes pixels")
                let right = CGRect(x: w / 2 + 2, y: 0, width: w / 2 - 2, height: h)
                check(after.cropping(to: right).flatMap { a in before.cropping(to: right).map { pixelsEqual(rgba($0), rgba(a)) } } ?? false,
                      "blur leaves pixels outside the region alone")
            }
        }
        check(EditorModel.blockSize(for: CGRect(x: 0, y: 0, width: 600, height: 40), pixelScale: 2) == 20, "blur block for a line of text")
        check(EditorModel.blockSize(for: CGRect(x: 0, y: 0, width: 600, height: 600), pixelScale: 2) == 100, "blur block scales with the region")

        if let big = CGContext(data: nil, width: 6000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage(),
           let png = EditorModel.pngForUpload(big), let rep = NSBitmapImageRep(data: png) {
            check(rep.pixelsWide == 2576 && rep.pixelsHigh == 429, "upload image downscaled to 2576: \(rep.pixelsWide)x\(rep.pixelsHigh)")
        }

        // Extended color spaces can't back an 8-bit context; rendering falls back to sRGB
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        if let p3 = CGColorSpace(name: CGColorSpace.displayP3) {
            check(EditorModel.exportColorSpace(for: p3).name == CGColorSpace.displayP3, "editor keeps Display P3")
        }
        for name in [CGColorSpace.extendedSRGB, CGColorSpace.extendedLinearSRGB, CGColorSpace.extendedDisplayP3] {
            guard let space = CGColorSpace(name: name) else { continue }
            check(EditorModel.exportColorSpace(for: space).name == srgb.name, "editor renders \(name) as sRGB")
        }
        if let extended = CGColorSpace(name: CGColorSpace.extendedSRGB),
           let ctx = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 16, bytesPerRow: 0, space: extended,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                   | CGBitmapInfo.byteOrder16Little.rawValue) {
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            if let cg = ctx.makeImage(), let model = EditorModel(image: NSImage(cgImage: cg, size: NSSize(width: 20, height: 10))) {
                check(model.renderCGImage() != nil, "editor renders an extended-sRGB image")
            } else {
                check(false, "extended-sRGB editor fixture")
            }
        }

        // PNG keeps the Retina size and the color space
        if let p3 = CGColorSpace(name: CGColorSpace.displayP3),
           let ctx = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: p3,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
           let cg = ctx.makeImage(), let png = try? ImageExport.encode(cg, as: .png, pixelScale: 2) {
            check(NSImage(data: png)?.size == NSSize(width: 20, height: 10), "png keeps the Retina point size")
            let source = CGImageSourceCreateWithData(png as CFData, nil)
            let space = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }?.colorSpace?.name as String?
            check(space?.contains("P3") == true, "png keeps Display P3: \(space ?? "nil")")
            check(((try? ImageExport.convert(png, to: .jpeg))?.count ?? 0) > 0, "jpeg conversion")
            check(((try? ImageExport.convert(png, to: .heic))?.count ?? 0) > 0, "heic conversion")
        }

        let origin0 = PinnedImageWindow.origin(for: NSSize(width: 300, height: 200), in: NSRect(x: 0, y: 0, width: 1440, height: 900), index: 0)
        let origin1 = PinnedImageWindow.origin(for: NSSize(width: 300, height: 200), in: NSRect(x: 0, y: 0, width: 1440, height: 900), index: 1)
        check(origin0 != origin1 && origin1.x < origin0.x && origin1.y < origin0.y, "new pins are offset")
    }

    private static func editorKeys(_ check: Check) {
        let cmd = Shortcut.command, shift = Shortcut.shift
        check(EditorCommand.from(keyCode: kVK_ANSI_C, modifiers: 0, textFocused: false) == .tool(.crop),
              "C key picks crop with any layout (Russian «с»)")
        check(EditorCommand.from(keyCode: kVK_ANSI_C, modifiers: 0, textFocused: true) == nil, "letters type in text fields")
        check(EditorCommand.from(keyCode: kVK_ANSI_C, modifiers: cmd, textFocused: false) == .copy, "⌘C copies the image")
        check(EditorCommand.from(keyCode: kVK_ANSI_C, modifiers: cmd, textFocused: true) == nil, "⌘C in the Ask field copies text")
        check(EditorCommand.from(keyCode: kVK_ANSI_Z, modifiers: cmd, textFocused: true) == nil, "⌘Z in the Ask field undoes typing")
        check(EditorCommand.from(keyCode: kVK_ANSI_Z, modifiers: cmd | shift, textFocused: false) == .redo, "⇧⌘Z redo")
        check(EditorCommand.from(keyCode: kVK_ANSI_Equal, modifiers: cmd, textFocused: false) == .zoomIn, "⌘= zooms in")
        check(EditorCommand.from(keyCode: kVK_ANSI_W, modifiers: cmd, textFocused: false) == nil, "⌘W goes to the menu")
        let keys = EditorTool.allCases.map(\.keyCode)
        check(Set(keys).count == keys.count, "editor tool keys are unique")
    }

    // MARK: - Text recognition

    private static func recognition(_ check: Check) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("deckhand-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let ocrImage = NSImage(size: NSSize(width: 600, height: 160))
        ocrImage.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 600, height: 160).fill()
        ("Deckhand reads text" as NSString).draw(at: NSPoint(x: 30, y: 60), withAttributes: [
            .font: NSFont.systemFont(ofSize: 40, weight: .medium), .foregroundColor: NSColor.black,
        ])
        ocrImage.unlockFocus()
        let ocrFile = folder.appendingPathComponent("ocr.png")
        if let tiff = ocrImage.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: ocrFile)
        }
        let options = OCROptions(languages: ["ru-RU", "en-US"], autoDetect: false, languageCorrection: true, keepLineBreaks: true)
        let recognized = TextRecognizer.read(at: ocrFile, options: options).payload ?? ""
        check(recognized.contains("Deckhand reads text"), "text recognition: \(recognized)")

        if let filter = CIFilter(name: "CIQRCodeGenerator") {
            filter.setValue(Data("https://example.com/deckhand".utf8), forKey: "inputMessage")
            if let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)).composited(over: CIImage(color: .white).cropped(to: CGRect(x: -40, y: -40, width: 400, height: 400))),
               let cg = CIContext().createCGImage(output, from: CGRect(x: -40, y: -40, width: 400, height: 400)) {
                let result = TextRecognizer.read(cg, options: options)
                check(result == .qrCode("https://example.com/deckhand"), "QR code is copied as its content: \(result)")
            }
        }
    }

    private static func captureOptions(_ check: Check) {
        let picked = ScreenColorPicker.pixel(at: CGPoint(x: 0, y: 900), in: CGSize(width: 1440, height: 900),
                                             pixels: CGSize(width: 2880, height: 1800))
        check(picked.x == 0 && picked.y == 0, "picker top left is the first pixel")
        let corner = ScreenColorPicker.pixel(at: CGPoint(x: 1440, y: 0), in: CGSize(width: 1440, height: 900),
                                             pixels: CGSize(width: 2880, height: 1800))
        check(corner.x == 2879 && corner.y == 1799, "picker bottom right stays inside the image")
        let mid = ScreenColorPicker.pixel(at: CGPoint(x: 10.6, y: 899.2), in: CGSize(width: 1440, height: 900),
                                          pixels: CGSize(width: 2880, height: 1800))
        check(mid.x == 21 && mid.y == 1, "picker maps points to retina pixels")
        check(ScreenColorPicker.timeout <= 120, "picker gives up by itself")
        check(OCROptions.join(["Hello", "  world  ", ""], keepLineBreaks: true) == "Hello\nworld", "ocr keeps line breaks")
        check(OCROptions.join(["Some exam-", "ple text", "Next"], keepLineBreaks: false) == "Some example text Next", "ocr joins lines and hyphenation")
        check(OCROptions.defaultLanguages(preferred: ["ru-RU", "en-GB"]) == ["ru-RU", "en-US"], "ocr default languages from the system")
        check(OCROptions.defaultLanguages(preferred: ["de"]) == ["de-DE", "en-US"], "ocr default adds English")
        check(OCROptions.bestMatch(for: "zh-Hant-TW", in: OCROptions.knownLanguages) == "zh-Hant", "ocr script match")
        let opts = OCROptions(languages: ["xx-XX", "uk-UA"], autoDetect: true, languageCorrection: false, keepLineBreaks: true)
        check(opts.recognitionLanguages(supported: OCROptions.knownLanguages) == ["uk-UA"], "unsupported ocr languages are dropped")
        check(OCROptions(languages: [], autoDetect: false, languageCorrection: true, keepLineBreaks: true)
            .recognitionLanguages(supported: ["en-US"]) == ["en-US"], "ocr never gets an empty language list")

        let qr = TextCaptureResult.Code(payload: "https://a.b", isQR: true, area: 0.5)
        let smallQR = TextCaptureResult.Code(payload: "https://a.b", isQR: true, area: 0.02)
        check(TextCaptureResult.decide(text: "Scan me", codes: [qr]) == .qrCode("https://a.b"), "big QR wins over its caption")
        check(TextCaptureResult.decide(text: "A long paragraph", codes: [smallQR]) == .text("A long paragraph"), "text wins over a small code")
        check(TextCaptureResult.decide(text: nil, codes: [smallQR]) == .qrCode("https://a.b"), "a code alone is used")
        check(TextCaptureResult.decide(text: "  ", codes: []) == .nothing, "nothing found")

        let (r, g, b) = (26.0 / 255, 43.0 / 255, 60.0 / 255)
        check(ColorFormat.hexUpper.string(red: r, green: g, blue: b) == "#1A2B3C", "color hex")
        check(ColorFormat.hexLower.string(red: r, green: g, blue: b) == "1a2b3c", "color hex lower")
        check(ColorFormat.rgb.string(red: r, green: g, blue: b) == "rgb(26, 43, 60)", "color rgb")
        let hsl = ColorFormat.hsl.string(red: r, green: g, blue: b)
        check(hsl == "hsl(210 40% 17%)", "color hsl: \(hsl)")
        check(ColorFormat.swiftUI.string(red: r, green: g, blue: b) == "Color(red: 0.102, green: 0.169, blue: 0.235)", "color SwiftUI")
        check(ColorFormat.hsl.string(red: 1, green: 1, blue: 1) == "hsl(0 0% 100%)", "color hsl white")

        check(ScreenshotService.arguments(for: .area, sound: false, screen: nil) == ["-i", "-x", "-t", "png"], "area capture allows window mode, silent")
        check(ScreenshotService.arguments(for: .area, sound: true, screen: nil) == ["-i", "-t", "png"], "shutter sound drops -x")
        check(ScreenshotService.arguments(for: .window, sound: false, screen: nil).starts(with: ["-i", "-w"]), "window capture")
        check(ScreenshotService.arguments(for: .screen, sound: false, screen: 2).starts(with: ["-D", "2"]), "screen capture of the pointer's display")
        check(ScreenshotService.arguments(for: .text, sound: true, screen: nil).contains("-x"), "text capture is always silent")

        let folder = URL(fileURLWithPath: "/tmp/x")
        let taken: Set<String> = ["/tmp/x/Shot.png", "/tmp/x/Shot 2.png"]
        check(ImageExport.uniqueURL(in: folder, baseName: "Shot", fileExtension: "png", exists: { taken.contains($0.path) }).lastPathComponent
              == "Shot 3.png", "saved screenshots never overwrite")
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 14, minute: 3, second: 22))!
        check(ImageExport.baseName(date: date).contains("2026-11-05") && ImageExport.baseName(date: date).contains("14.03.22"), "screenshot file name")
    }

    // MARK: - Shortcuts

    private static func shortcuts(_ check: Check) {
        let c = Shortcut.control, o = Shortcut.option, s = Shortcut.shift, m = Shortcut.command

        // Defaults: unique, and clear of macOS, Rectangle and ⇧⌘ menus
        let defaults = HotkeyAction.allCases.compactMap(\.defaultShortcut)
        check(Set(defaults).count == defaults.count, "default shortcuts are unique")
        let rectangle = KnownAppShortcuts.all.filter { ["Rectangle", "Magnet", "Things", "1Password", "Maccy", "Raycast", "Alfred"].contains($0.name) }
        let inputSource = SymbolicHotKeys.Entry(keyCode: UInt32(kVK_Space), modifiers: c | o)
        let clean = defaults.allSatisfy { ShortcutConflict.find(for: $0, system: [inputSource], apps: rectangle) == nil }
        check(clean, "default shortcuts don't collide with input sources, Rectangle or ⇧⌘ menus")
        check(defaults.allSatisfy { ShortcutRules.verdict(for: $0) == .ok }, "default shortcuts pass the recorder rules")

        // Conflicts
        let space = Shortcut(kVK_Space, c | o)
        check(ShortcutConflict.find(for: space, system: [inputSource], apps: []) == .system(name: SymbolicHotKeys.name(for: space)),
              "⌃⌥Space is the input source switch")
        check(SymbolicHotKeys.name(for: space) != nil, "input source shortcut has a name")
        check(ShortcutConflict.find(for: Shortcut(kVK_ANSI_C, c | o), system: [], apps: rectangle) == .app(name: "Rectangle"), "Rectangle's ⌃⌥C")
        check(ShortcutConflict.find(for: Shortcut(kVK_ANSI_S, s | m), system: [], apps: []) == .manyApps, "⇧⌘S warns")
        check(ShortcutConflict.find(for: Shortcut(kVK_ANSI_5, s | m), system: [], apps: []) == nil, "⇧⌘5 is not a letter")
        let fnArrow = SymbolicHotKeys.Entry(keyCode: UInt32(kVK_LeftArrow), modifiers: c | SymbolicHotKeys.Entry.fnBit)
        check(fnArrow.matches(Shortcut(kVK_LeftArrow, c)), "fn bit on arrows is ignored")
        let fnLetter = SymbolicHotKeys.Entry(keyCode: UInt32(kVK_ANSI_C), modifiers: SymbolicHotKeys.Entry.fnBit)
        check(!fnLetter.matches(Shortcut(kVK_ANSI_C, 0)), "Globe shortcuts don't match plain keys")

        // Recorder rules
        check(ShortcutRules.verdict(for: Shortcut(kVK_ANSI_Q, m)) == .reserved, "⌘Q reserved")
        check(ShortcutRules.verdict(for: Shortcut(kVK_Space, c)) == .reserved, "⌃Space reserved")
        check(ShortcutRules.verdict(for: Shortcut(kVK_Tab, m)) == .reserved, "⌘Tab reserved")
        check(ShortcutRules.verdict(for: Shortcut(kVK_ANSI_C, m | s)) == .ok, "⇧⌘C allowed")
        check(ShortcutRules.verdict(for: Shortcut(kVK_ANSI_A, o)) == .needsModifier, "⌥A refused")
        check(ShortcutRules.verdict(for: Shortcut(kVK_ANSI_A, o | s)) == .needsModifier, "⌥⇧A refused")
        check(ShortcutRules.verdict(for: Shortcut(kVK_F5, 0)) == .ok, "F5 alone allowed")
        check(ShortcutRules.verdict(for: Shortcut(kVK_ANSI_S, c | o | s)) == .ok, "⌃⌥⇧S allowed")

        check(ShortcutConflict.find(for: Shortcut(kVK_ANSI_S, m), system: [], apps: []) == .everyApp, "⌘S warns")
        check(ShortcutConflict.find(for: Shortcut(kVK_ANSI_1, m), system: [], apps: []) == nil, "⌘1 is not a letter")

        // Migration from 0.4 defaults. A real 0.4 store has exactly the 12 actions 0.4 knew.
        let actions04: [HotkeyAction] = [.toggle, .screenshot, .captureText, .colorPicker, .keepAwake, .clipboard,
                                         .translator, .claude, .prompts, .media, .shelf, .recents]
        var legacy: [String: Shortcut?] = [:]
        for action in actions04 { legacy[action.rawValue] = .some(action.legacyDefaultShortcut) }
        check(legacy.count == 12 && legacy.values.allSatisfy { $0 != nil }, "0.4 store fixture has 12 shortcuts")
        let migrated = HotkeyMigration.migrate(legacy)
        check(actions04.allSatisfy { action in
            guard let new = action.defaultShortcut else { return true }
            return migrated[action.rawValue] == .some(new)
        }, "old defaults move to the new family")
        var custom = legacy
        custom[HotkeyAction.clipboard.rawValue] = .some(Shortcut(kVK_ANSI_S, c | o | s))   // the new screenshot default
        custom[HotkeyAction.toggle.rawValue] = .some(Shortcut(kVK_ANSI_N, c | m))
        custom[HotkeyAction.media.rawValue] = .some(nil)
        let kept = HotkeyMigration.migrate(custom)
        check(kept[HotkeyAction.toggle.rawValue] == .some(Shortcut(kVK_ANSI_N, c | m)), "custom shortcuts stay")
        check(kept[HotkeyAction.media.rawValue] == .some(nil), "removed shortcuts stay removed")
        check(kept[HotkeyAction.screenshot.rawValue] == .some(HotkeyAction.screenshot.legacyDefaultShortcut),
              "migration never duplicates a shortcut the user took")
        check(kept[HotkeyAction.captureText.rawValue] == .some(HotkeyAction.captureText.defaultShortcut), "others still migrate")

        // Loading: an action 0.4 didn't have gets its default only if no stored shortcut uses it
        let fresh = HotkeyMigration.resolve(HotkeyMigration.migrate(legacy))
        check(HotkeyAction.allCases.allSatisfy { fresh[$0] == $0.defaultShortcut }, "an untouched 0.4 store loads every 0.5 default")
        var rectangleUser = legacy
        rectangleUser[HotkeyAction.translator.rawValue] = .some(Shortcut(kVK_ANSI_T, c | o | s))
        let moved = HotkeyMigration.resolve(HotkeyMigration.migrate(rectangleUser))
        check(moved[.translator] == Shortcut(kVK_ANSI_T, c | o | s), "a custom ⌃⌥⇧T stays on Translate")
        check(moved[.translateSelection] == nil, "a new action doesn't get a default the user already uses")
        check(Set(moved.values).count == moved.count, "loading never gives two actions the same shortcut")
        let removedStore: [String: Shortcut?] = [HotkeyAction.clipboard.rawValue: Shortcut?.none]
        let removed = HotkeyMigration.resolve(removedStore)
        check(removed[HotkeyAction.clipboard] == nil && removed[HotkeyAction.toggle] == HotkeyAction.toggle.defaultShortcut,
              "a removed shortcut stays removed and missing ones get defaults")

        // Settings search finds Shortcuts by the 0.5 action names
        for query in ["capture an area", "capture a window", "translate selected"] {
            check(SettingsSearch.results(for: query).contains { $0.section == .shortcuts }, "settings search: “\(query)” finds Shortcuts")
        }

        // Display
        check(Shortcut(kVK_ANSI_D, c | o | s).modifierSymbols == "⌃⌥⇧", "modifier order ⌃⌥⇧⌘")
        check(Shortcut(kVK_Space, c | o).display == "⌃⌥" + String(localized: "Space"), "space is named in the app's language")
        if let path = Bundle.main.path(forResource: "ru", ofType: "lproj"), let ru = Bundle(path: path) {
            check(ru.localizedString(forKey: "Space", value: nil, table: nil) == "Пробел", "Russian key name for Space")
        }
    }

    // MARK: - Helpers

    static func pixelsEqual(_ a: CGImage, _ b: CGImage) -> Bool {
        guard let da = a.dataProvider?.data, let db = b.dataProvider?.data else { return false }
        return (da as Data) == (db as Data)
    }

    /// Redraws into a known RGBA layout, so crops of different images compare byte for byte.
    private static func rgba(_ image: CGImage) -> CGImage {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    /// Brightness 0…1 of the pixel at (x, y), y counted from the top.
    private static func brightness(_ image: CGImage, x: Int, y: Int) -> CGFloat {
        let img = rgba(image)
        guard let data = img.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return -1 }
        let i = y * img.bytesPerRow + x * 4
        return (CGFloat(ptr[i]) + CGFloat(ptr[i + 1]) + CGFloat(ptr[i + 2])) / (3 * 255)
    }

    private static func solidImage(width: CGFloat, height: CGFloat, color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return image
    }
}
