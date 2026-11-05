import AppKit
import Combine

/// A file on the Shelf. Files stay where they are and are found again through a bookmark,
/// so moving or renaming one in Finder doesn't lose it. Files dropped from temporary
/// locations (a browser or Mail drag) are copied into Deckhand's folder first, because macOS
/// deletes those soon.
struct ShelfItem: Identifiable, Codable, Hashable {
    let id: UUID
    var path: String
    var bookmark: Data?
    let addedAt: Date
    /// The file is Deckhand's own copy in `ShelfFiles.copiesDir`, removed when no item uses it.
    var isCopy: Bool

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }

    init(id: UUID = UUID(), path: String, bookmark: Data?, addedAt: Date = Date(), isCopy: Bool = false) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.addedAt = addedAt
        self.isCopy = isCopy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        isCopy = try c.decodeIfPresent(Bool.self, forKey: .isCopy) ?? false
    }
}

@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [ShelfItem] = []
    /// Items whose file can't be found right now (moved to the Trash, deleted, or on a disconnected drive).
    /// They stay on the shelf, greyed out, instead of being removed.
    @Published private(set) var unreachable: Set<UUID> = []
    @Published var selection: Set<UUID> = []
    /// Items removed by the last Remove or Clear, for Undo.
    @Published private(set) var lastRemoved: [ShelfItem] = []
    /// Items being dragged out of the shelf, so dropping them back on the shelf does nothing.
    var draggingOut: Set<UUID> = []

    private let fileURL = AppPaths.supportDir.appendingPathComponent("shelf.json")
    private var undoTask: Task<Void, Never>?

    private init() {
        if AppPaths.isSnapshot {
            items = SampleMedia.shelfFiles().map { ShelfItem(path: $0.path, bookmark: nil) }
            return
        }
        // Only tidy up copies when the list was read: a damaged shelf.json must not cost the user files
        if load() {
            let referenced = Set(items.filter(\.isCopy).map(\.path))
            Task.detached(priority: .background) { ShelfFiles.purgeCopies(keeping: referenced) }
        }
        refresh()
    }

    // MARK: - Adding

    /// Adds files in the order given, newest block on top. Bookmarks and copies are made off the main thread.
    func add(_ urls: [URL]) {
        let known = Set(items.map(\.path))
        let fresh = urls.filter { $0.isFileURL && !known.contains($0.standardizedFileURL.path) }
        guard !fresh.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            let prepared = fresh.compactMap { ShelfFiles.prepare($0) }
            await MainActor.run { ShelfStore.shared.insert(prepared) }
        }
    }

    private func insert(_ new: [ShelfItem]) {
        let known = Set(items.map(\.path))
        let unique = new.filter { !known.contains($0.path) }
        guard !unique.isEmpty else { return }
        items.insert(contentsOf: unique, at: 0)
        save()
    }

    // MARK: - Removing

    func remove(_ ids: Set<UUID>) {
        let removed = items.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        offerUndo(removed)
        save()
    }

    func clear() { remove(Set(items.map(\.id))) }

    func undoRemove() {
        let back = lastRemoved.filter { r in !items.contains { $0.id == r.id } }
        lastRemoved = []
        undoTask?.cancel()
        items.insert(contentsOf: back, at: 0)
        items.sort { $0.addedAt > $1.addedAt }
        save()
    }

    private func offerUndo(_ removed: [ShelfItem]) {
        lastRemoved = removed
        undoTask?.cancel()
        undoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self else { return }
            self.lastRemoved = []
            // Copies nobody uses any more can go now that Undo is gone
            let referenced = Set(self.items.filter(\.isCopy).map(\.path))
            Task.detached(priority: .background) { ShelfFiles.purgeCopies(keeping: referenced) }
        }
    }

    // MARK: - Finding files again

    /// Re-resolves every bookmark off the main thread: follows moved and renamed files and
    /// marks the ones that can't be reached. Drives are never mounted and no UI is shown.
    func refresh() {
        guard !AppPaths.isSnapshot else { return }
        let snapshot = items
        Task.detached(priority: .utility) {
            let resolved = snapshot.map { ($0.id, ShelfFiles.resolve($0)) }
            await MainActor.run { ShelfStore.shared.apply(resolved) }
        }
    }

    private func apply(_ resolved: [(UUID, ShelfFiles.Resolution)]) {
        var changed = false
        var missing = Set<UUID>()
        for (id, r) in resolved {
            guard let i = items.firstIndex(where: { $0.id == id }) else { continue }
            if !r.reachable { missing.insert(id) }
            if r.path != items[i].path || (r.bookmark != nil && r.bookmark != items[i].bookmark) {
                items[i].path = r.path
                if let b = r.bookmark { items[i].bookmark = b }
                changed = true
            }
        }
        if unreachable != missing { unreachable = missing }
        if changed { save() }
    }

    func urls(for ids: Set<UUID>) -> [URL] {
        items.filter { ids.contains($0.id) && !unreachable.contains($0.id) }.map(\.url)
    }

    /// What dragging or acting on `item` covers: the whole selection when the item is part of it.
    func targetIds(for item: ShelfItem) -> Set<UUID> {
        selection.contains(item.id) ? selection : [item.id]
    }

    // MARK: - Storage

    /// Returns false when shelf.json exists but can't be read.
    private func load() -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else { return !FileManager.default.fileExists(atPath: fileURL.path) }
        guard let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) else {
            Log.info("shelf: shelf.json can't be read, keeping it as it is")
            return false
        }
        items = decoded
        return true
    }

    private func save() {
        guard !AppPaths.isSnapshot, let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// File work for the Shelf that runs off the main thread. Pure enough for the self-test,
/// which runs it on temporary folders.
enum ShelfFiles {
    struct Resolution: Equatable {
        var path: String
        var bookmark: Data?
        var reachable: Bool
    }

    static var copiesDir: URL { AppPaths.supportDir.appendingPathComponent("shelf-files", isDirectory: true) }

    /// Folders macOS empties on its own, where browser and Mail drags put their files.
    static func isTemporary(_ path: String) -> Bool {
        let tmp = (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath
        let prefixes = [tmp, "/private/var/folders/", "/var/folders/", "/private/tmp/", "/tmp/"]
        let resolved = (path as NSString).resolvingSymlinksInPath
        return prefixes.contains { !$0.isEmpty && (resolved.hasPrefix($0) || path.hasPrefix($0)) }
    }

    /// Makes a shelf item for a dropped file: copies temporary files, then bookmarks the file.
    static func prepare(_ url: URL, copyingInto dir: URL? = nil) -> ShelfItem? {
        var source = url.standardizedFileURL
        var isCopy = false
        if isTemporary(source.path) {
            let folder = (dir ?? copiesDir).appendingPathComponent(UUID().uuidString, isDirectory: true)
            let target = folder.appendingPathComponent(source.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: target)
                source = target
                isCopy = true
            } catch {
                Log.info("shelf: could not copy a temporary file: \(error)")
            }
        }
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let bookmark = try? source.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return ShelfItem(path: source.path, bookmark: bookmark, isCopy: isCopy)
    }

    /// Where the item's file is now. Follows the bookmark if the file moved; never mounts drives.
    static func resolve(_ item: ShelfItem) -> Resolution {
        let fm = FileManager.default
        if let data = item.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                let path = url.standardizedFileURL.path
                // Moved to the Trash counts as gone, even though the bookmark still finds it
                let trashed = path.contains("/.Trash/") || path.contains("/.Trashes/")
                let exists = fm.fileExists(atPath: path)
                let fresh = stale && exists ? try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) : nil
                return Resolution(path: path, bookmark: fresh, reachable: exists && !trashed)
            }
        }
        // No bookmark (shelves from 0.4) or it can't be resolved: check the path, and add a bookmark when possible
        let exists = fm.fileExists(atPath: item.path)
        let bookmark = exists && item.bookmark == nil
            ? try? item.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) : nil
        return Resolution(path: item.path, bookmark: bookmark, reachable: exists)
    }

    /// Deletes Deckhand's copies that no shelf item uses.
    static func purgeCopies(keeping referenced: Set<String>, in dir: URL? = nil) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: dir ?? copiesDir, includingPropertiesForKeys: nil) else { return }
        let keep = Set(referenced.map { URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL.path })
        for folder in folders where !keep.contains(folder.standardizedFileURL.path) {
            try? fm.removeItem(at: folder)
        }
    }
}
