import AppKit
import SQLite

extension SelfTest {
    /// Prompts, the Shelf and Recents. Owned by the prompts, shelf and recents workstream.
    /// Uses in-memory databases and temporary folders only.
    static func prompts(_ check: Check) {
        promptVariables(check)
        promptSeeding(check)
        promptCategoriesAndSort(check)
        promptArchive(check)
        promptSearchOrder(check)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("deckhand-selftest-prompts-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        shelfFiles(check, root: root)
        recentsScan(check, root: root)
        try? FileManager.default.removeItem(at: root)
        check(RecentsSettings.webURL(from: "higgsfield.ai")?.absoluteString == "https://higgsfield.ai", "recents link without scheme")
        check(RecentsSettings.webURL(from: "") == nil && RecentsSettings.webURL(from: "ftp://a.b") == nil
              && RecentsSettings.webURL(from: "not a site") == nil, "recents link rejects empty, ftp and words")
    }

    private static func promptVariables(_ check: Check) {
        let body = "Shot of {{product}} in {{ size }}, again {{product}}; {{}} {{a\nb}} {{{x}}}"
        check(PromptTemplate.variables(in: body) == ["product", "size"], "prompt variables: order, trim, no duplicates, no junk")
        let filled = PromptTemplate.fill("A {{product}} for {{who}}", values: ["product": "mug"])
        check(filled == "A mug for {{who}}", "prompt fill keeps variables without a value: \(filled)")
        check(PromptTemplate.variables(in: "no variables {here}") == [], "prompt without variables")
        check(PromptTemplate.fill("{{x}}{{x}}", values: ["x": "1"]) == "11", "prompt fill replaces every occurrence")
    }

    private static func promptSeeding(_ check: Check) {
        guard let db = try? Connection(.inMemory) else { check(false, "in-memory database"); return }
        let fresh = PromptStore(db: db)
        let starters = StarterPrompts.all.count
        check(fresh.count == starters, "starter prompts seeded in a new library: \(fresh.count)")
        fresh.deleteAll()
        let reopened = PromptStore(db: db)
        check(reopened.count == 0, "deleted starter prompts stay deleted after relaunch")
        check(reopened.addStarters() == starters && reopened.addStarters() == 0, "restore starters adds only missing ones")

        // A 0.4 library (prompts, no seeding mark) gets no extra starters
        guard let old = try? Connection(.inMemory) else { return }
        _ = try? old.execute("CREATE TABLE prompts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, body TEXT NOT NULL, category TEXT NOT NULL DEFAULT 'General', tags TEXT NOT NULL DEFAULT '', favorite INTEGER NOT NULL DEFAULT 0, usage_count INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, updated_at REAL NOT NULL);")
        _ = try? old.execute("INSERT INTO prompts (title, body, created_at, updated_at) VALUES ('Mine', 'x', 0, 0);")
        let upgraded = PromptStore(db: old)
        check(upgraded.count == 1 && upgraded.metaValue(PromptStore.seededKey) != nil, "existing library is not re-seeded")

        // An existing user who deleted every starter: clipboard history shows it's not a new install
        guard let emptied = try? Connection(.inMemory) else { return }
        _ = try? emptied.execute("CREATE TABLE clipboard_items (id INTEGER PRIMARY KEY);")
        _ = try? emptied.execute("INSERT INTO clipboard_items (id) VALUES (1);")
        check(PromptStore(db: emptied).count == 0, "user with history and no prompts gets no starters back")
    }

    private static func prompt(_ id: Int64, _ title: String, category: String = "Code", favorite: Bool = false,
                               uses: Int64 = 0, edited: Double = 0) -> Prompt {
        Prompt(id: id, title: title, body: "body \(title)", category: category, tags: [], favorite: favorite,
               usageCount: uses, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: edited))
    }

    private static func promptCategoriesAndSort(_ check: Check) {
        check(PromptLibrary.normalizedCategory("  Image   & Video ") == "Image & Video", "category spaces collapsed")
        check(PromptLibrary.normalizedCategory("   ") == PromptLibrary.defaultCategory, "blank category becomes the default")
        let list = [prompt(1, "a", category: "code"), prompt(2, "b", category: "Code"), prompt(3, "c", category: "Code "),
                    prompt(4, "d", category: "Writing"), prompt(5, "e", category: "")]
        let cats = PromptLibrary.categories(of: list)
        check(cats == ["Code", PromptLibrary.defaultCategory, "Writing"].sorted { $0.localizedStandardCompare($1) == .orderedAscending },
              "categories merged by case and sorted: \(cats)")
        check(PromptLibrary.canonicalCategory("CODE", existing: cats) == "Code", "typed category joins the existing spelling")
        check(PromptLibrary.filter(list, category: "code", search: "").count == 3, "filter by category ignores case")
        check(PromptLibrary.filter(list, category: nil, search: "BODY D").map(\.id) == [4], "search ignores case")
        check(PromptLibrary.normalizedTags([" UGC", "ugc", "", "Video "]) == ["ugc", "video"], "tags normalized")

        let ranked = [prompt(1, "b", uses: 5), prompt(2, "a", favorite: true), prompt(3, "c", uses: 9, edited: 2)]
        check(PromptLibrary.sorted(ranked, by: .favoritesAndUsage).map(\.id) == [2, 3, 1], "sort: favorites, then most used")
        check(PromptLibrary.sorted(ranked, by: .name).map(\.id) == [2, 1, 3], "sort by name")
        check(PromptLibrary.sorted(ranked, by: .recentlyEdited).first?.id == 3, "sort by recently edited")
        // After a click bumps prompt 1 to the top of the ranking, the rows on screen stay put
        let shown = PromptLibrary.sorted(ranked, by: .favoritesAndUsage)
        var bumped = ranked
        bumped[0].usageCount = 99
        let fresh = PromptLibrary.sorted(bumped, by: .favoritesAndUsage) + [prompt(4, "new")]
        check(PromptLibrary.keepingOrder(of: shown, fresh: fresh).map(\.id) == [2, 3, 1, 4], "click keeps the order on screen")
        check(PromptLibrary.title(fromBody: "  First line here\nsecond") == "First line here", "title from the first line")
    }

    /// Narrowing a search and clearing it again shows the library in the chosen order.
    private static func promptSearchOrder(_ check: Check) {
        guard let db = try? Connection(.inMemory) else { return }
        let store = PromptStore(db: db)
        store.deleteAll()
        for (title, body) in [("Alpha", "first"), ("Bravo", "second"), ("Charlie", "third")] {
            store.create(title: title, body: body, category: "Code", tags: [])
        }
        let vm = PromptsViewModel(store: store)
        let sorted = vm.prompts.map(\.id)
        guard sorted.count == 3, let last = vm.prompts.last else { check(false, "search order library: \(sorted)"); return }
        vm.searchChanged(to: last.title)
        let narrowed = vm.prompts.map(\.id)
        vm.searchChanged(to: "")
        check(narrowed == [last.id] && vm.prompts.map(\.id) == sorted,
              "clearing a search restores the chosen order: \(vm.prompts.map(\.title))")
    }

    private static func promptArchive(_ check: Check) {
        guard let a = try? Connection(.inMemory), let b = try? Connection(.inMemory) else { return }
        let source = PromptStore(db: a)
        source.create(title: "Mine", body: "Text with {{x}}", category: "Code", tags: ["one"], favorite: true)
        guard let data = try? source.exportJSON() else { check(false, "prompt export"); return }
        let target = PromptStore(db: b)
        target.deleteAll()
        let first = try? target.importJSON(data)
        check(first?.added == source.count && first?.skipped == 0, "prompt import adds every prompt")
        let again = try? target.importJSON(data)
        check(again?.added == 0 && again?.skipped == source.count, "prompt import skips duplicates")
        let mine = target.all().first { $0.title == "Mine" }
        check(mine?.favorite == true && mine?.tags == ["one"] && mine?.category == "Code", "prompt import keeps fields")
        let bare = Data(#"[{"body": "Only a body\nsecond line"}]"#.utf8)
        check((try? PromptArchive.decode(bare))?.first?.title == "Only a body", "bare JSON array imports with a title")
        check((try? PromptArchive.decode(Data("{}".utf8))) == nil, "unrelated JSON is refused")
    }

    private static func shelfFiles(_ check: Check, root: URL) {
        let fm = FileManager.default
        check(ShelfFiles.isTemporary(fm.temporaryDirectory.appendingPathComponent("x.png").path), "temporary folder detected")
        check(!ShelfFiles.isTemporary(fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/x.png").path),
              "Desktop is not temporary")

        let file = root.appendingPathComponent("Report.txt")
        try? "hello".write(to: file, atomically: true, encoding: .utf8)
        let copies = root.appendingPathComponent("copies", isDirectory: true)
        guard let item = ShelfFiles.prepare(file, copyingInto: copies) else { check(false, "shelf prepare"); return }
        check(item.isCopy && item.path.hasPrefix(copies.path) && item.bookmark != nil, "file from a temporary folder is copied and bookmarked")

        // A file the user moves or renames is found again through its bookmark
        let moved = root.appendingPathComponent("Report (final).txt")
        try? fm.moveItem(at: URL(fileURLWithPath: item.path), to: moved)
        let r = ShelfFiles.resolve(item)
        let real = { (path: String) in (path as NSString).resolvingSymlinksInPath }
        check(r.reachable && real(r.path) == real(moved.path), "moved shelf file is followed: \(r.path)")

        try? fm.removeItem(at: moved)
        check(!ShelfFiles.resolve(ShelfItem(path: moved.path, bookmark: nil)).reachable, "deleted shelf file is unreachable")

        let keep = copies.appendingPathComponent("keep", isDirectory: true)
        let drop = copies.appendingPathComponent("drop", isDirectory: true)
        try? fm.createDirectory(at: keep, withIntermediateDirectories: true)
        try? fm.createDirectory(at: drop, withIntermediateDirectories: true)
        ShelfFiles.purgeCopies(keeping: [keep.appendingPathComponent("a.png").path], in: copies)
        check(fm.fileExists(atPath: keep.path) && !fm.fileExists(atPath: drop.path), "unused shelf copies are purged")

        let old = Data(#"[{"id":"5D6C7F7E-6C1B-4F77-9B39-1D0B7F1C2E11","path":"/tmp/a.png","addedAt":0}]"#.utf8)
        let decoded = try? JSONDecoder().decode([ShelfItem].self, from: old)
        check(decoded?.first?.bookmark == nil && decoded?.first?.isCopy == false, "0.4 shelf.json still loads")
    }

    private static func recentsScan(_ check: Check, root: URL) {
        let fm = FileManager.default
        let folder = root.appendingPathComponent("Downloads", isDirectory: true)
        let sub = folder.appendingPathComponent("Sub", isDirectory: true)
        try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        for name in ["a.png", "b.mov", "notes.txt"] { fm.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data([1])) }
        fm.createFile(atPath: sub.appendingPathComponent("c.jpg").path, contents: Data([1]))

        var q = RecentsQuery(folders: [folder], days: 14, kinds: .all, includeSubfolders: true, limit: 40)
        let all = RecentsScanner.scan(q)
        check(Set(all.files.map(\.name)) == ["a.png", "b.mov", "c.jpg"] && all.problems.isEmpty, "recents finds images and videos in subfolders")
        check(all.files.first { $0.name == "b.mov" }?.isVideo == true, "recents marks videos")
        q.includeSubfolders = false
        check(Set(RecentsScanner.scan(q).files.map(\.name)) == ["a.png", "b.mov"], "recents without subfolders")
        q.kinds = .images
        check(RecentsScanner.scan(q).files.map(\.name) == ["a.png"], "recents images only")
        q.kinds = .all
        q.includeSubfolders = true
        q.limit = 2
        check(RecentsScanner.scan(q).files.count == 2, "recents limit")
        check(RecentsScanner.scan(q, now: Date().addingTimeInterval(30 * 24 * 3600)).files.isEmpty, "recents period cutoff")
        q.folders = [root.appendingPathComponent("Missing")]
        check(RecentsScanner.scan(q).problems.first?.kind == .missing, "recents reports a missing folder")
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        check(RecentsScanner.isPermissionError(denied), "recents tells no access apart")
    }
}
