import AppKit
import Combine

/// Shelf: references to files dropped on the notch. Files are not copied,
/// so large videos are not duplicated. The list is stored in shelf.json.
struct ShelfItem: Identifiable, Codable, Hashable {
    let id: UUID
    let path: String
    let addedAt: Date

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [ShelfItem] = []
    private let fileURL = AppPaths.supportDir.appendingPathComponent("shelf.json")

    private init() {
        load()
    }

    func add(_ urls: [URL]) {
        let known = Set(items.map(\.path))
        let fresh = urls
            .filter { $0.isFileURL && !known.contains($0.path) }
            .map { ShelfItem(id: UUID(), path: $0.path, addedAt: Date()) }
        guard !fresh.isEmpty else { return }
        items.insert(contentsOf: fresh, at: 0)
        save()
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    func pruneMissing() {
        let before = items.count
        items.removeAll { !$0.exists }
        if items.count != before { save() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        items = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
