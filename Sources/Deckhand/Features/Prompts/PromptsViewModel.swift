import SwiftUI
import Combine

/// A prompt being written or edited. The database row is only created or changed on Save,
/// so Cancel leaves nothing behind.
struct PromptDraft: Equatable {
    /// nil for a new prompt.
    var id: Int64?
    var title = ""
    var body = ""
    var category = ""
    var tagsText = ""
    var favorite = false

    var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A new prompt with nothing typed yet (the category alone comes from the filter).
    var isBlank: Bool {
        id == nil && [title, body, tagsText].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// Values for a prompt's `{{variables}}`, asked for before it is copied or pasted.
struct PromptFill: Equatable {
    let prompt: Prompt
    let names: [String]
    var values: [String: String]
    let action: PromptClickAction
    var text: String { PromptTemplate.fill(prompt.body, values: values.filter { !$0.value.isEmpty }) }
}

/// The Prompts tab. Long-lived, so a draft, the search and the category survive closing the panel.
@MainActor
final class PromptsViewModel: ObservableObject {
    static let shared = PromptsViewModel()

    /// The prompts shown, in screen order.
    @Published private(set) var prompts: [Prompt] = []
    @Published private(set) var categories: [String] = []
    /// nil shows every category.
    @Published var selectedCategory: String? { didSet { if oldValue != selectedCategory { refresh(resort: true) } } }
    @Published var search = ""
    /// The row ↑/↓ picked; Return uses it.
    @Published var selectedId: Int64?
    @Published var draft: PromptDraft?
    /// Text sent from another tab ("Save as Prompt") while a draft with content was open.
    /// The draft is kept; the editor offers to replace it.
    @Published private(set) var pendingDraftBody: String?
    @Published var fill: PromptFill?
    /// A short confirmation on one row, such as "Copied".
    @Published private(set) var flash: (id: Int64, text: String)?
    /// The last deleted prompt, offered for Undo for a few seconds.
    @Published private(set) var deleted: Prompt?
    /// A message under the list, e.g. when pasting needs Accessibility.
    @Published var notice: String?

    var libraryIsEmpty: Bool { all.isEmpty }

    private let store: PromptStore
    private let settings = PromptSettings.shared
    private var all: [Prompt] = []
    private var lastValues: [String: String] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var flashTask: Task<Void, Never>?
    private var undoTask: Task<Void, Never>?

    init(store: PromptStore = .shared) {
        self.store = store
        refresh(resort: true)
        // Combine delivers the new value before the property is stored, so use the value it passes
        $search
            .removeDuplicates()
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] text in self?.searchChanged(to: text) }
            .store(in: &cancellables)
        settings.$sort
            .dropFirst()
            .sink { [weak self] sort in self?.refresh(resort: true, sort: sort) }
            .store(in: &cancellables)
    }

    /// Reads the library again. `resort` false keeps rows where they are (after a click), true
    /// applies the chosen order (on opening the tab, after a save or a filter change).
    func refresh(resort: Bool, search: String? = nil, sort: PromptSort? = nil) {
        all = store.all()
        categories = PromptLibrary.categories(of: all)
        if let selected = selectedCategory, !categories.contains(where: { PromptLibrary.sameCategory($0, selected) }) {
            selectedCategory = nil   // the last prompt of that category moved or was deleted
            return
        }
        let matching = PromptLibrary.filter(all, category: selectedCategory, search: search ?? self.search)
        let ordered = PromptLibrary.sorted(matching, by: sort ?? settings.sort)
        prompts = resort ? ordered : PromptLibrary.keepingOrder(of: prompts, fresh: ordered)
        if let id = selectedId, !prompts.contains(where: { $0.id == id }) { selectedId = nil }
    }

    /// A new search applies the chosen order. Keeping the order on screen here would leave the
    /// matches of a narrower search on top once it is cleared.
    func searchChanged(to text: String) {
        refresh(resort: true, search: text)
    }

    // MARK: - Using a prompt

    /// The main action: copy or paste, after asking for `{{variables}}` when the prompt has them.
    /// `close` closes the panel before pasting.
    func activate(_ p: Prompt, action: PromptClickAction? = nil, close: @escaping () -> Void) {
        let action = action ?? settings.clickAction
        let names = PromptTemplate.variables(in: p.body)
        if settings.fillVariables, !names.isEmpty {
            let values = Dictionary(uniqueKeysWithValues: names.map { ($0, lastValues[$0] ?? "") })
            fill = PromptFill(prompt: p, names: names, values: values, action: action)
            return
        }
        deliver(p.body, from: p, action: action, close: close)
    }

    func finishFill(close: @escaping () -> Void) {
        guard let fill else { return }
        for (name, value) in fill.values where !value.isEmpty { lastValues[name] = value }
        self.fill = nil
        deliver(fill.text, from: fill.prompt, action: fill.action, close: close)
    }

    private func deliver(_ text: String, from p: Prompt, action: PromptClickAction, close: @escaping () -> Void) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        store.incrementUsage(p.id)
        refresh(resort: false)
        selectedId = p.id
        switch action {
        case .copy:
            show(String(localized: "Copied"), on: p.id)
        case .paste:
            guard PasteService.isTrusted else {
                show(String(localized: "Copied"), on: p.id)
                notice = String(localized: "The prompt is copied. To paste it for you, Deckhand needs Accessibility.")
                return
            }
            close()
            PasteService.pasteIntoFrontApp()
        }
    }

    func toggleFavorite(_ p: Prompt) {
        store.setFavorite(p.id, !p.favorite)
        refresh(resort: false)
    }

    func delete(_ p: Prompt) {
        store.delete(p.id)
        deleted = p
        refresh(resort: false)
        undoTask?.cancel()
        undoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.deleted = nil
        }
    }

    func undoDelete() {
        guard let p = deleted else { return }
        store.restore(p)
        deleted = nil
        undoTask?.cancel()
        refresh(resort: false)
        selectedId = p.id
    }

    private func show(_ text: String, on id: Int64) {
        flash = (id, text)
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.3))
            guard !Task.isCancelled else { return }
            self?.flash = nil
        }
    }

    // MARK: - Editing

    /// Starts a new prompt. A draft with content is never replaced silently: it stays open and the
    /// new text waits until the user chooses to replace it. Returns false when the draft was kept.
    @discardableResult
    func newDraft(body: String = "") -> Bool {
        if let current = draft, !current.isBlank {
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body != current.body { pendingDraftBody = body }
            return false
        }
        fill = nil
        pendingDraftBody = nil
        draft = PromptDraft(body: body, category: selectedCategory ?? "")
        return true
    }

    /// Replaces the open draft with the text that arrived while it was open.
    func replaceDraftWithPending() {
        guard let body = pendingDraftBody else { return }
        pendingDraftBody = nil
        fill = nil
        draft = PromptDraft(body: body, category: selectedCategory ?? "")
    }

    func keepDraft() { pendingDraftBody = nil }

    func edit(_ p: Prompt) {
        fill = nil
        draft = PromptDraft(id: p.id, title: p.title, body: p.body, category: p.category,
                            tagsText: p.tags.joined(separator: ", "), favorite: p.favorite)
    }

    func cancelDraft() {
        draft = nil
        pendingDraftBody = nil
    }

    func saveDraft() {
        guard let d = draft, d.canSave else { return }
        let title = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = title.isEmpty ? PromptLibrary.title(fromBody: d.body) : title
        let category = PromptLibrary.canonicalCategory(d.category, existing: categories)
        let tags = PromptLibrary.tags(fromText: d.tagsText)
        var savedId = d.id
        if let id = d.id, var p = all.first(where: { $0.id == id }) {
            p.title = finalTitle
            p.body = d.body
            p.category = category
            p.tags = tags
            p.favorite = d.favorite
            store.update(p)
        } else {
            savedId = store.create(title: finalTitle, body: d.body, category: category, tags: tags, favorite: d.favorite)?.id
        }
        draft = nil
        pendingDraftBody = nil
        // Show the saved prompt even if the filter would hide it
        if let selected = selectedCategory, !PromptLibrary.sameCategory(selected, category) { selectedCategory = nil }
        if !search.isEmpty { search = "" }
        refresh(resort: true, search: "")
        selectedId = savedId
    }

    /// Category names to pick from in the editor, the current filter first.
    var categoryChoices: [String] {
        let defaults = StarterPrompts.all.map(\.category) + [PromptLibrary.defaultCategory]
        var seen = Set<String>()
        return (categories + defaults).filter { seen.insert($0.lowercased()).inserted }
    }
}
