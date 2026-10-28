import SwiftUI
import Combine

@MainActor
final class PromptsViewModel: ObservableObject {
    /// Sentinel for "all categories", shown as All in the UI.
    static let allKey = "__all__"

    @Published var prompts: [Prompt] = []
    @Published var categories: [String] = [PromptsViewModel.allKey]
    @Published var selectedCategory: String = PromptsViewModel.allKey
    @Published var search: String = ""
    @Published var editing: Prompt?

    private let store = PromptStore.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        reload()
        $search
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
        $selectedCategory
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    func reload() {
        prompts = store.all(search: search, category: selectedCategory == PromptsViewModel.allKey ? nil : selectedCategory)
        var cats = [PromptsViewModel.allKey]
        cats.append(contentsOf: store.categories())
        categories = cats
    }

    func copy(_ p: Prompt) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(p.body, forType: .string)
        store.incrementUsage(p.id)
        reload()
    }

    func toggleFavorite(_ p: Prompt) {
        var copy = p
        copy.favorite.toggle()
        store.update(copy)
        reload()
    }

    func delete(_ p: Prompt) {
        store.delete(p.id)
        reload()
    }

    func create() {
        if let p = store.create(
            title: String(localized: "New Prompt"),
            body: "...",
            category: selectedCategory == PromptsViewModel.allKey ? String(localized: "General") : selectedCategory,
            tags: []
        ) {
            reload()
            editing = p
        }
    }

    func save(_ p: Prompt) {
        store.update(p)
        reload()
    }
}
