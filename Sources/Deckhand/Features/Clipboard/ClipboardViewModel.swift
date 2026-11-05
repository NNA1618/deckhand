import AppKit
import SwiftUI
import Combine

/// A message shown at the bottom of the Clipboard tab.
struct ClipboardNotice: Equatable {
    enum Kind: Equatable { case info, error, needsAccessibility }
    let id = UUID()
    let kind: Kind
    let text: String
}

/// The Clipboard tab's state. Long-lived, so search, filter and selection survive tab switches
/// and closing the panel.
@MainActor
final class ClipboardViewModel: ObservableObject {
    static let shared = ClipboardViewModel(store: .shared)

    @Published var search = ""
    @Published var filter: ClipboardFilter = .all
    @Published private(set) var pinned: [ClipboardItem] = []
    @Published private(set) var recent: [ClipboardItem] = []
    @Published private(set) var hasMore = false
    /// True when the history has nothing at all, whatever the search says.
    @Published private(set) var historyIsEmpty = true
    @Published var selectedId: Int64?
    @Published var previewItem: ClipboardItem?
    @Published var notice: ClipboardNotice?

    let store: ClipboardStore
    private let pageSize = 80
    private var noticeTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(store: ClipboardStore) {
        self.store = store
        reload()
        $search.removeDuplicates().dropFirst()
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload(resetPaging: true, resetSelection: true) }
            .store(in: &cancellables)
        $filter.removeDuplicates().dropFirst()
            .sink { [weak self] value in self?.reload(filter: value, resetPaging: true, resetSelection: true) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .clipboardHistoryChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    /// Pinned first, then the history: the order the arrow keys walk.
    var rows: [ClipboardItem] { pinned + recent }

    /// ⌘1–⌘9 go to the first nine unpinned items, so the latest copy is always ⌘1.
    func number(for item: ClipboardItem) -> Int? {
        guard !item.pinned, let i = recent.prefix(9).firstIndex(where: { $0.id == item.id }) else { return nil }
        return i + 1
    }

    var selectedItem: ClipboardItem? {
        selectedId.flatMap { id in rows.first { $0.id == id } }
    }

    // MARK: - Loading

    /// Reloads what's shown, keeping as many rows as were loaded so the scroll position holds.
    func reload(filter: ClipboardFilter? = nil, resetPaging: Bool = false, resetSelection: Bool = false) {
        let filter = filter ?? self.filter
        let count = resetPaging ? pageSize : max(pageSize, recent.count)
        pinned = store.pinnedItems(search: search, filter: filter)
        let page = store.recentItems(search: search, filter: filter, offset: 0, limit: count + 1)
        hasMore = page.count > count
        recent = Array(page.prefix(count))
        historyIsEmpty = rows.isEmpty && store.count() == 0
        // The latest copy is preselected, so Return pastes it right away
        if resetSelection || selectedItem == nil { selectedId = (recent.first ?? pinned.first)?.id }
        if let p = previewItem, !rows.contains(where: { $0.id == p.id }) { previewItem = nil }
    }

    /// Loads the next page when the last rows come into view.
    func loadMoreIfNeeded(after item: ClipboardItem) {
        guard hasMore, let i = recent.firstIndex(where: { $0.id == item.id }), i >= recent.count - 10 else { return }
        let page = store.recentItems(search: search, filter: filter, offset: recent.count, limit: pageSize + 1)
        hasMore = page.count > pageSize
        recent += page.prefix(pageSize)
    }

    func move(by step: Int) {
        let all = rows
        guard !all.isEmpty else { return }
        let current = selectedId.flatMap { id in all.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + step, 0), all.count - 1) } ?? 0
        selectedId = all[next].id
        if previewItem != nil { previewItem = all[next] }
    }

    // MARK: - Actions

    /// Puts the item on the clipboard, then calls `done` with true, or with false after saying why
    /// it can't be restored. Images are read and files checked off the main thread.
    func copy(_ item: ClipboardItem, plain: Bool = false, then done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch await ClipboardWriter.writeAsync(item, store: self.store, to: .general, plain: plain) {
            case .success(let changeCount):
                ClipboardWatcher.shared.noteOwnWrite(changeCount: changeCount)
                self.store.markUsed(id: item.id)
                done(true)
            case .failure(let failure):
                self.show(ClipboardNotice(kind: .error, text: failure.message))
                done(false)
            }
        }
    }

    /// Return, double-click and ⌘1–9: paste into the app you were using, or only copy,
    /// depending on Settings › Clipboard.
    func choose(_ item: ClipboardItem, plain: Bool = false, notch: NotchViewModel) {
        if ClipboardSettings.shared.pasteOnSelect {
            paste(item, plain: plain, notch: notch)
        } else {
            copy(item, plain: plain) { if $0 { notch.requestClose() } }
        }
    }

    /// Copies, closes the panel and sends ⌘V. Without Accessibility the panel stays open and says
    /// the item is copied and what to allow, instead of closing and silently doing nothing.
    /// The panel closes and ⌘V goes out only once the item is on the clipboard.
    func paste(_ item: ClipboardItem, plain: Bool = false, notch: NotchViewModel) {
        copy(item, plain: plain) { [weak self] copied in
            guard let self, copied else { return }
            guard PasteService.isTrusted else {
                self.show(ClipboardNotice(kind: .needsAccessibility,
                                          text: String(localized: "Copied. To paste automatically, allow Deckhand in Accessibility.")),
                          sticky: true)
                return
            }
            self.notice = nil
            self.previewItem = nil
            notch.requestClose()
            PasteService.pasteIntoFrontApp()
        }
    }

    /// Opens a link item. Uses the full address: the preview is cut at 300 characters.
    func openLink(_ item: ClipboardItem) {
        guard let url = Self.linkURL(store.text(id: item.id)) else { return }
        NSWorkspace.shared.open(url)
    }

    static func linkURL(_ text: String?) -> URL? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), ClipboardText.isLink(text) else { return nil }
        return URL(string: text)
    }

    func togglePin(_ item: ClipboardItem) {
        store.togglePin(id: item.id)
        reload()
    }

    func delete(_ item: ClipboardItem) {
        let all = rows
        let index = all.firstIndex(where: { $0.id == item.id })
        store.delete(id: item.id)
        if previewItem?.id == item.id { previewItem = nil }
        reload()
        // Keep the selection where it was instead of jumping to the top
        if selectedId == item.id || selectedItem == nil, let index {
            let now = rows
            selectedId = now.isEmpty ? nil : now[min(index, now.count - 1)].id
        }
    }

    func togglePreview(_ item: ClipboardItem? = nil) {
        if previewItem != nil { previewItem = nil; return }
        previewItem = item ?? selectedItem
    }

    func show(_ notice: ClipboardNotice, sticky: Bool = false) {
        self.notice = notice
        noticeTask?.cancel()
        guard !sticky else { return }
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// Called when the tab shows: picks up reorders made by copying from the open list and starts
    /// again from the latest copy. Search and filter stay as they were.
    func appeared() {
        if notice?.kind != .needsAccessibility || PasteService.isTrusted { notice = nil }
        previewItem = nil
        reload(resetSelection: true)
    }
}
