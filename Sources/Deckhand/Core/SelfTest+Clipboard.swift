import AppKit
import Carbon.HIToolbox
import SQLite

extension SelfTest {
    /// Clipboard history and pasting. Owned by the clipboard workstream.
    /// Uses only private named pasteboards, in-memory or temporary databases and temporary folders.
    static func clipboard(_ check: Check) {
        clipboardPasswords(check)
        clipboardClassification(check)
        clipboardText(check)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("deckhand-selftest-clip-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        clipboardStore(check, temp: temp)
        clipboardMigration(check, temp: temp)
        clipboardPasteboards(check, temp: temp)
        clipboardKeyboard(check)
    }

    private static func clipboardPasswords(_ check: Check) {
        check(ClipboardWatcher.isPassword(types: ["public.utf8-plain-text"], sourceApp: "com.apple.Passwords"),
              "copies from Apple Passwords count as passwords")
        check(ClipboardWatcher.isPassword(types: ["org.nspasteboard.ConcealedType"], sourceApp: nil),
              "concealed type counts as password")
        check(!ClipboardWatcher.isPassword(types: ["public.utf8-plain-text"], sourceApp: "com.microsoft.edgemac"),
              "plain copy is not a password")
        check(ClipboardWatcher.isTransient(types: ["org.nspasteboard.TransientType"]), "transient copies are never saved")

        check("Translate this sentence".looksLikeProse && "привет".looksLikeProse, "prose is prefilled")
        check(!"77.88.8.8".looksLikeProse && !"me@example.com".looksLikeProse && !"https://a.b/c".looksLikeProse,
              "addresses and links are not prefilled")
    }

    private static func clipboardClassification(_ check: Check) {
        let text = NSPasteboard.PasteboardType.string.rawValue
        let png = NSPasteboard.PasteboardType.png.rawValue
        let tiff = NSPasteboard.PasteboardType.tiff.rawValue
        let html = NSPasteboard.PasteboardType.html.rawValue
        let pdf = NSPasteboard.PasteboardType.pdf.rawValue
        func kind(_ types: Set<String>, _ string: String? = nil, files: [URL] = [], url: String? = nil) -> ClipboardKind? {
            ClipboardCapture.classify(types: types, string: string, fileURLs: files, urlString: url)
        }
        check(kind(["public.file-url", text], "report.pdf", files: [URL(fileURLWithPath: "/tmp/report.pdf")]) == .file,
              "a Finder copy is a file")
        check(kind([text, "public.url"], "https://example.com/watch?v=1") == .link, "a copied web address is a link, not a file")
        check(kind([text, html, png, pdf], "Q1\t120\nQ2\t140") == .text, "spreadsheet cells keep their text, not the picture")
        check(kind([tiff, text, "public.url"], "https://example.com/cat.jpg") == .image, "Safari's Copy Image stays an image")
        check(kind([png]) == .image && kind([pdf]) == .image, "image-only copies are images")
        check(kind([text], "  \n\t ") == nil, "whitespace-only copies are skipped")
        check(kind(["public.url"], url: "https://example.com") == .link, "a bare URL flavor is a link")
        check(kind([text], "see https://example.com today") == .text, "text with a link inside stays text")
    }

    private static func clipboardText(_ check: Check) {
        check(ClipboardText.isLink("https://example.com/a?b=c") && ClipboardText.isLink("mailto:me@example.com"),
              "web and mail addresses are links")
        check(!ClipboardText.isLink("/Users/me/file.txt") && !ClipboardText.isLink("example.com")
              && !ClipboardText.isLink("https://") && !ClipboardText.isLink("javascript:alert(1)"),
              "paths, bare hosts and scripts are not links")
        check(ClipboardText.fold("Москва ЁЛКА Café") == ClipboardText.fold("москва елка cafe"),
              "search folding ignores case and accents in every language")
        check(ClipboardText.likePatterns(for: "a_b 100%") == ["%a\\_b%", "%100\\%%"], "LIKE wildcards are escaped per word")
        check(ClipboardText.preview("  Hello\n\n  world\t!  ") == "Hello world !", "previews collapse whitespace")
        check(ClipboardText.fileTitle([URL(fileURLWithPath: "/a/one.pdf"), URL(fileURLWithPath: "/a/two.pdf")]) == "one.pdf + 1",
              "several files show as one title")
        let now = Date()
        check(ClipboardTime.relative(now.addingTimeInterval(-5), now: now) != ClipboardTime.relative(now.addingTimeInterval(-600), now: now),
              "fresh items say now, older ones show a time")
    }

    private static func entry(_ text: String, app: String? = "com.apple.Notes", name: String? = "Notes") -> ClipboardEntry {
        let snap = PasteboardSnapshot(types: [NSPasteboard.PasteboardType.string.rawValue], string: text,
                                      sourceApp: app, sourceAppName: name)
        return ClipboardCapture.prepare(snap, imagesDir: FileManager.default.temporaryDirectory, maxImageBytes: 0)!
    }

    private static func clipboardStore(_ check: Check, temp: URL) {
        let images = temp.appendingPathComponent("images")
        try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let store = ClipboardStore(db: Database(url: nil).db, imagesDir: images)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func titles() -> [String] { store.recentItems().map(\.preview) }

        store.insert(entry("A"), limit: 0, maxAgeDays: 0, now: t0)
        store.insert(entry("B"), limit: 0, maxAgeDays: 0, now: t0.addingTimeInterval(1))
        let again = store.insert(entry("A"), limit: 0, maxAgeDays: 0, now: t0.addingTimeInterval(2))
        check(titles() == ["A", "B"], "copying an item again moves it to the top: \(titles())")
        if case .movedToTop = again { check(store.count() == 2, "a repeated copy adds no row") } else { check(false, "a repeated copy adds no row") }

        let b = store.recentItems().first { $0.preview == "B" }!
        store.markUsed(id: b.id, now: t0.addingTimeInterval(3))
        check(titles() == ["B", "A"], "pasting from the history moves the item to the top")

        // Trimming removes the least recently used, never pinned items
        store.togglePin(id: store.recentItems().first { $0.preview == "A" }!.id)
        store.insert(entry("C"), limit: 0, maxAgeDays: 0, now: t0.addingTimeInterval(4))
        store.insert(entry("D"), limit: 2, maxAgeDays: 0, now: t0.addingTimeInterval(5))
        check(titles() == ["D", "C"] && store.pinnedItems().map(\.preview) == ["A"],
              "trimming keeps pinned items and the most recent ones: \(titles())")
        store.insert(entry("C"), limit: 2, maxAgeDays: 0, now: t0.addingTimeInterval(6))
        store.insert(entry("E"), limit: 2, maxAgeDays: 0, now: t0.addingTimeInterval(7))
        check(titles() == ["E", "C"], "trimming follows recency, not creation time: \(titles())")
        store.trim(limit: 0, maxAgeDays: 1, now: t0.addingTimeInterval(7 + 86_400 + 1))
        check(store.recentItems().isEmpty && store.pinnedItems().count == 1, "old items expire, pinned ones stay")

        // Search
        store.insert(entry("Встреча в Москве"), limit: 0, maxAgeDays: 0)
        store.insert(entry("axb"), limit: 0, maxAgeDays: 0)
        store.insert(entry("a_b and 50%"), limit: 0, maxAgeDays: 0)
        store.insert(entry("https://example.com/docs", app: "com.apple.Safari", name: "Safari"), limit: 0, maxAgeDays: 0)
        let files = PasteboardSnapshot(fileURLs: [URL(fileURLWithPath: "/Users/me/Отчёт за май.pdf")],
                                       sourceApp: "com.apple.finder", sourceAppName: "Finder")
        store.insert(ClipboardCapture.prepare(files, imagesDir: images, maxImageBytes: 0)!, limit: 0, maxAgeDays: 0)
        func found(_ q: String, _ filter: ClipboardFilter = .all) -> [String] { store.recentItems(search: q, filter: filter).map(\.preview) }
        check(found("москве") == ["Встреча в Москве"], "search is case-insensitive in Russian")
        check(found("a_b") == ["a_b and 50%"] && found("%") == ["a_b and 50%"], "search treats % and _ literally")
        check(found("отчет") == ["Отчёт за май.pdf"], "search finds file names, ё and е alike")
        check(found("safari") == ["https://example.com/docs"], "search finds the source app")
        check(found("москве встреча") == ["Встреча в Москве"] && found("москве nothing").isEmpty, "every word must match")
        check(found("", .links) == ["https://example.com/docs"] && found("", .files).count == 1, "filters by kind")

        // Copying the same content again updates what the search sees
        store.insert(entry("https://example.com/docs", app: "com.google.Chrome", name: "Chrome"), limit: 0, maxAgeDays: 0)
        check(found("chrome") == ["https://example.com/docs"] && found("safari").isEmpty, "a repeated copy is found by its new app")
        var fromPasswords = entry("axb", app: "com.apple.Passwords", name: "Passwords")
        fromPasswords.isSecret = true
        fromPasswords.searchText = ""
        store.insert(fromPasswords, limit: 0, maxAgeDays: 0)
        store.insert(entry("axb"), limit: 0, maxAgeDays: 0)
        let hidden = store.recentItems(filter: .text).first { $0.sourceApp == "com.apple.Notes" && $0.isSecret }
        check(found("axb").isEmpty && hidden != nil && store.secretCount() == 1,
              "text copied again from a password app becomes a password and stays one")
        if let hidden { store.delete(id: hidden.id) }

        // Paging: no fixed cap
        for i in 0..<250 { store.insert(entry("item \(i)"), limit: 0, maxAgeDays: 0) }
        let total = store.count(pinned: false)
        var paged = 0
        var offset = 0
        while case let page = store.recentItems(offset: offset, limit: 100), !page.isEmpty {
            paged += page.count
            offset += page.count
        }
        check(total > 250 && paged == total, "the list pages through all \(total) items, no 500 cap")

        check(store.clearHistory() == total && store.pinnedItems().count == 1 && store.recentItems().isEmpty,
              "Clear History keeps pinned items")

        // Secrets
        var secret = entry("hunter2")
        secret.isSecret = true
        secret.hash = "secret-hash"
        store.insert(secret, limit: 0, maxAgeDays: 0)
        check(store.secretCount() == 1 && store.deleteSecrets() == 1 && store.secretCount() == 0, "saved passwords can be removed")
        check(found("hunter2").isEmpty, "saved passwords are not searchable")

        // Images: written once, removed with the item
        if let png = sampleImage(),
           let image = ClipboardCapture.prepare(PasteboardSnapshot(types: [NSPasteboard.PasteboardType.png.rawValue], imageData: png,
                                                                   imageType: NSPasteboard.PasteboardType.png.rawValue),
                                                imagesDir: images, maxImageBytes: 0),
           case let .inserted(id) = store.insert(image, limit: 0, maxAgeDays: 0),
           let item = store.item(id: id), let url = store.imageURL(for: item) {
            check(FileManager.default.fileExists(atPath: url.path) && item.preview == "8 × 6", "images are stored as PNG with their size")
            check(ClipboardCapture.prepare(PasteboardSnapshot(types: [NSPasteboard.PasteboardType.png.rawValue], imageData: png,
                                                              imageType: NSPasteboard.PasteboardType.png.rawValue),
                                           imagesDir: images, maxImageBytes: 10) == nil, "images over the size limit are skipped")
            // A 0.4 row with the same picture under another name: the new copy's file is dropped
            var again = image
            again.imageName = "img-duplicate.png"
            try? png.write(to: images.appendingPathComponent("img-duplicate.png"))
            store.insert(again, limit: 0, maxAgeDays: 0)
            check(!FileManager.default.fileExists(atPath: images.appendingPathComponent("img-duplicate.png").path),
                  "a repeated image leaves no extra file")
            store.delete(id: id)
            check(!FileManager.default.fileExists(atPath: url.path), "deleting an image removes its file")

            let orphan = images.appendingPathComponent("img-orphan.png")
            try? png.write(to: orphan)
            try? FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: orphan.path)
            store.removeOrphanImages()
            for _ in 0..<50 where FileManager.default.fileExists(atPath: orphan.path) { Thread.sleep(forTimeInterval: 0.02) }
            check(!FileManager.default.fileExists(atPath: orphan.path), "image files without an item are cleaned up")
        } else {
            check(false, "images are stored as PNG")
        }
    }

    private static func sampleImage() -> Data? {
        guard let ctx = CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        return ctx.makeImage().flatMap(ClipboardCapture.encodePNG)
    }

    /// A 0.4 database opens as version 2 with its rows converted and the prompts untouched;
    /// a damaged file is moved aside instead of crashing.
    private static func clipboardMigration(_ check: Check, temp: URL) {
        let url = temp.appendingPathComponent("old.sqlite")
        do {
            let old = try Connection(url.path)
            try old.execute("""
                CREATE TABLE clipboard_items (id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, text TEXT,
                    image_path TEXT, file_url TEXT, hash TEXT NOT NULL, pinned INTEGER NOT NULL DEFAULT 0,
                    source_app TEXT, source_app_name TEXT, created_at REAL NOT NULL, last_used_at REAL NOT NULL);
                CREATE TABLE prompts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, body TEXT NOT NULL,
                    category TEXT NOT NULL DEFAULT 'General', tags TEXT NOT NULL DEFAULT '', favorite INTEGER NOT NULL DEFAULT 0,
                    usage_count INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, updated_at REAL NOT NULL);
                INSERT INTO prompts (title, body, created_at, updated_at) VALUES ('Keep me', 'Body', 1, 1);
                INSERT INTO clipboard_items (kind, text, file_url, hash, pinned, created_at, last_used_at)
                    VALUES ('file', NULL, 'https://github.com/owner/repo', 'h1', 0, 1, 1);
                INSERT INTO clipboard_items (kind, image_path, hash, pinned, created_at, last_used_at)
                    VALUES ('image', '/Users/old/Library/Application Support/Fringe/clipboard-images/img-1.png', 'h2', 1, 2, 2);
                INSERT INTO clipboard_items (kind, text, hash, pinned, created_at, last_used_at)
                    VALUES ('text', 'Привет, Мир', 'h3', 0, 3, 3);
                INSERT INTO clipboard_items (kind, text, hash, pinned, source_app, source_app_name, created_at, last_used_at)
                    VALUES ('text', 'hunter2-old', 'h4', 0, 'com.apple.Passwords', 'Passwords', 4, 4);
                INSERT INTO clipboard_items (kind, text, file_url, hash, pinned, created_at, last_used_at)
                    VALUES ('file', NULL, 'https://example.org/page', 'h5', 1, 5, 5);
                INSERT INTO clipboard_items (kind, text, hash, pinned, created_at, last_used_at)
                    VALUES ('text', 'https://example.org/page', 'h6', 0, 6, 6);
            """)
        } catch {
            check(false, "old database created: \(error)")
            return
        }
        let database = Database(url: url)
        let version = (try? database.db.scalar("PRAGMA user_version") as? Int64) ?? 0
        check(version == Database.currentVersion && database.movedAside == nil, "an old database is upgraded to version \(version)")
        let store = ClipboardStore(db: database.db, imagesDir: temp)
        let link = store.recentItems(filter: .links).first
        check(link?.preview == "https://github.com/owner/repo" && store.text(id: link?.id ?? 0) == "https://github.com/owner/repo",
              "0.4 web-link \"files\" become links")
        check(store.pinnedItems(filter: .images).first?.imageName == "img-1.png", "image paths become relative")
        check(store.recentItems(search: "мир").count == 1, "old rows become searchable")
        let prompts = (try? database.db.scalar("SELECT count(*) FROM prompts WHERE title = 'Keep me'") as? Int64) ?? 0
        check(prompts == 1, "the prompts table is untouched by the migration")

        // Passwords from password apps are hidden and not searchable, as new copies are
        let password = store.recentItems().first { $0.sourceApp == "com.apple.Passwords" }
        check(password?.isSecret == true && password?.title == "••••••••" && store.recentItems(search: "hunter2").isEmpty,
              "0.4 copies from password apps become hidden passwords")
        // A 0.4 link "file" and the same address copied as text merge into one pinned link
        let merged = store.pinnedItems(filter: .links)
        check(merged.count == 1 && merged.first?.id == 6 && store.recentItems(filter: .links).count == 1
              && merged.first?.createdAt == Date(timeIntervalSince1970: 5),
              "duplicate 0.4 links merge into the newer one, keeping the pin: \(merged.map(\.id))")
        check(store.count() == 5, "the migration drops only duplicates: \(store.count()) rows")

        func dump(_ db: Connection) -> [String] {
            let sql = "SELECT id, kind, text, hash, pinned, pinned_at, is_secret, search_text, image_path, created_at FROM clipboard_items ORDER BY id"
            return ((try? db.prepare(sql).map { row in row.map { "\($0 ?? "nil")" }.joined(separator: "|") }) ?? [])
        }
        let before = dump(database.db)
        do {
            try Database.migrate(database.db)
            check(true, "migrations can run twice")
        } catch {
            check(false, "migrations can run twice: \(error)")
        }
        let reopened = Database(url: url)
        check(!before.isEmpty && dump(reopened.db) == before && dump(database.db) == before, "opening the migrated database again changes nothing")
        do {
            try ClipboardSchema.upgradeToV2(reopened.db)
            check(dump(reopened.db) == before, "running the version 2 step again changes nothing")
        } catch {
            check(false, "running the version 2 step again: \(error)")
        }

        let broken = temp.appendingPathComponent("broken.sqlite")
        try? Data(repeating: 0x42, count: 8192).write(to: broken)
        let recovered = Database(url: broken)
        let works = (try? recovered.db.scalar("SELECT count(*) FROM clipboard_items") as? Int64) == 0
        check(recovered.movedAside != nil && works && FileManager.default.fileExists(atPath: recovered.movedAside?.path ?? ""),
              "a damaged database is moved aside and replaced")
    }

    /// Reading and restoring, on private named pasteboards only.
    private static func clipboardPasteboards(_ check: Check, temp: URL) {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.nna1618.deckhand.selftest.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let rules = ClipboardWatcher.Rules()
        let source: (bundleId: String?, name: String?) = ("com.example.app", "Example")

        // A copied file is saved as its URL; its contents are never read
        let file = temp.appendingPathComponent("big.bin")
        try? Data(count: 1024).write(to: file)
        pb.clearContents()
        pb.writeObjects([file as NSURL])
        let fileSnap = ClipboardWatcher.snapshot(of: pb, source: source, rules: rules)
        check(fileSnap?.fileURLs == [file] && fileSnap?.imageData == nil, "a copied file is saved by reference")

        // A web link written as an NSURL stays a link
        pb.clearContents()
        pb.writeObjects([URL(string: "https://example.com/reset?token=1")! as NSURL])
        let linkSnap = ClipboardWatcher.snapshot(of: pb, source: source, rules: rules)
        let linkKind = linkSnap.flatMap { ClipboardCapture.classify(types: $0.types, string: $0.string, fileURLs: $0.fileURLs, urlString: $0.urlString) }
        check(linkSnap?.fileURLs.isEmpty == true && linkKind == .link, "a copied web link is not a file and is never downloaded")

        // Excel-like: text, HTML and a picture
        pb.clearContents()
        pb.declareTypes([.string, .html, .png], owner: nil)
        pb.setString("A1\tB1", forType: .string)
        pb.setString("<table><tr><td>A1</td></tr></table>", forType: .html)
        pb.setData(sampleImage() ?? Data(), forType: .png)
        let cells = ClipboardWatcher.snapshot(of: pb, source: source, rules: rules)
        check(cells?.imageData == nil && cells?.richType == NSPasteboard.PasteboardType.html.rawValue,
              "spreadsheet copies keep text and formatting, no image")

        // Ignored apps and passwords
        pb.clearContents()
        pb.setString("secret", forType: .string)
        check(ClipboardWatcher.snapshot(of: pb, source: source, rules: .init(excludedApps: ["com.example.app"])) == nil,
              "ignored apps are not saved")
        check(ClipboardWatcher.snapshot(of: pb, source: ("com.apple.Passwords", "Passwords"), rules: rules) == nil,
              "passwords are not saved by default")

        // Restoring
        let images = temp.appendingPathComponent("restore")
        try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let store = ClipboardStore(db: Database(url: nil).db, imagesDir: images)
        var rich = entry("Bold")
        rich.richType = NSPasteboard.PasteboardType.rtf.rawValue
        rich.richData = Data("{\\rtf1 {\\b Bold}}".utf8)
        guard case let .inserted(richId) = store.insert(rich, limit: 0, maxAgeDays: 0), let richItem = store.item(id: richId),
              case let .inserted(linkId) = store.insert(entry("https://example.com"), limit: 0, maxAgeDays: 0),
              let linkItem = store.item(id: linkId) else {
            check(false, "restore items inserted")
            return
        }
        _ = ClipboardWriter.write(richItem, store: store, to: pb)
        check(pb.string(forType: .string) == "Bold" && pb.data(forType: .rtf) != nil, "text is restored with its formatting")
        _ = ClipboardWriter.write(richItem, store: store, to: pb, plain: true)
        check(pb.string(forType: .string) == "Bold" && pb.data(forType: .rtf) == nil, "paste as plain text drops formatting")
        _ = ClipboardWriter.write(linkItem, store: store, to: pb)
        check(pb.string(forType: .string) == "https://example.com" && pb.string(forType: .URL) == "https://example.com",
              "links are restored with a plain-text flavor")

        let png = PasteboardSnapshot(types: [NSPasteboard.PasteboardType.png.rawValue], imageData: sampleImage(),
                                     imageType: NSPasteboard.PasteboardType.png.rawValue)
        if let imageEntry = ClipboardCapture.prepare(png, imagesDir: images, maxImageBytes: 0),
           case let .inserted(imageId) = store.insert(imageEntry, limit: 0, maxAgeDays: 0), let imageItem = store.item(id: imageId) {
            _ = ClipboardWriter.write(imageItem, store: store, to: pb)
            check(pb.data(forType: .png) != nil && pb.types?.contains(.tiff) == true, "images are restored as PNG, TIFF on demand")
            try? FileManager.default.removeItem(at: store.imageURL(for: imageItem)!)
            pb.clearContents()
            pb.setString("keep me", forType: .string)
            let result = ClipboardWriter.write(imageItem, store: store, to: pb)
            check(result == .failure(.missingImage) && pb.string(forType: .string) == "keep me",
                  "a missing image fails clearly and leaves the clipboard alone")
        } else {
            check(false, "image item for restore")
        }
        let gone = PasteboardSnapshot(fileURLs: [temp.appendingPathComponent("gone.txt")])
        if let goneEntry = ClipboardCapture.prepare(gone, imagesDir: images, maxImageBytes: 0),
           case let .inserted(goneId) = store.insert(goneEntry, limit: 0, maxAgeDays: 0), let goneItem = store.item(id: goneId) {
            let result = ClipboardWriter.write(goneItem, store: store, to: pb)
            check(result == .failure(.missingFiles) && pb.string(forType: .string) == "keep me",
                  "a moved file fails clearly and leaves the clipboard alone")
        }
    }

    /// ⌘V uses the key that types "v" in the layout, not a fixed key code.
    private static func clipboardKeyboard(_ check: Check) {
        func layout(_ id: String) -> TISInputSource? {
            let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
            guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else { return nil }
            return list.first
        }
        if let us = layout("com.apple.keylayout.US") {
            check(PasteService.keyCode(for: "v", in: us) == UInt16(kVK_ANSI_V), "V on the US layout")
        }
        if let dvorak = layout("com.apple.keylayout.Dvorak") {
            check(PasteService.keyCode(for: "v", in: dvorak) == UInt16(kVK_ANSI_Period), "V on Dvorak is the period key")
        }
    }
}
