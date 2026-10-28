import AppKit
import SwiftUI
import Combine

@MainActor
final class ClipboardViewModel: ObservableObject {
    @Published var items: [ClipboardItem] = []
    @Published var search: String = ""
    @Published var selectedId: Int64?

    private let store = ClipboardStore.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        reload()
        $search
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .clipboardHistoryChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    func reload() {
        items = store.allItems(search: search, limit: 500)
    }

    func copy(_ item: ClipboardItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            if let t = item.text { pb.setString(t, forType: .string) }
        case .image:
            if let data = store.imageData(for: item), let img = NSImage(data: data) {
                pb.writeObjects([img])
            }
        case .file:
            if let f = item.fileURL, let url = URL(string: f) {
                pb.writeObjects([url as NSURL])
            }
        }
        store.markUsed(id: item.id)
    }

    func togglePin(_ item: ClipboardItem) {
        store.togglePin(id: item.id)
        reload()
    }

    func delete(_ item: ClipboardItem) {
        store.delete(id: item.id)
        reload()
    }
}
