import AppKit
import Combine

/// Recent images and videos from the watched folders (Downloads by default).
///
/// Long-lived: the last results stay on screen while a rescan runs, and a rescan happens only
/// when the folders changed (FSEvents), the settings changed, or the results are old.
/// Each scan cancels the one before it, and only the newest result is applied.
@MainActor
final class RecentsViewModel: ObservableObject {
    static let shared = RecentsViewModel()

    @Published private(set) var files: [MediaFile] = []
    @Published private(set) var problems: [FolderProblem] = []
    @Published private(set) var scanning = false
    /// False until the first scan finished, so the tab shows a spinner instead of "nothing new".
    @Published private(set) var hasScanned = false

    private let settings = RecentsSettings.shared
    private var scanTask: Task<Void, Never>?
    private var generation = 0
    private var lastQuery: RecentsQuery?
    private var lastScan: Date?
    private var dirty = true
    private var visible = false
    private var rescanSoon: Task<Void, Never>?
    private var watcher: FolderWatcher?
    private var cancellables = Set<AnyCancellable>()

    /// Results older than this are refreshed on the next open even without a change notice
    /// (FSEvents can miss changes on network volumes).
    private let maxAge: TimeInterval = 600

    private init() {
        // Any change to what is shown rescans; the values are read on the next turn, after they are stored
        Publishers.MergeMany(
            settings.$days.map { _ in () }.eraseToAnyPublisher(),
            settings.$kinds.map { _ in () }.eraseToAnyPublisher(),
            settings.$includeSubfolders.map { _ in () }.eraseToAnyPublisher(),
            settings.$limit.map { _ in () }.eraseToAnyPublisher(),
            Settings.shared.$watchedFolders.map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst(5)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.settingsChanged() }
        .store(in: &cancellables)
    }

    var query: RecentsQuery {
        let folders = AppPaths.isSnapshot
            ? [SampleMedia.recentsFolder()]
            : Settings.shared.watchedFolders.map { URL(fileURLWithPath: $0) }
        return RecentsQuery(folders: folders, days: settings.days, kinds: settings.kinds,
                            includeSubfolders: settings.includeSubfolders, limit: settings.limit)
    }

    var hasFolders: Bool { AppPaths.isSnapshot || !Settings.shared.watchedFolders.isEmpty }

    // MARK: - Lifecycle

    func appeared() {
        visible = true
        startWatching()
        let current = query
        let old = lastScan.map { Date().timeIntervalSince($0) > maxAge } ?? true
        if dirty || old || current != lastQuery { scan() }
    }

    func disappeared() {
        visible = false
    }

    func scan() {
        let current = query
        dirty = false
        generation += 1
        let mine = generation
        scanTask?.cancel()
        scanning = true
        scanTask = Task.detached(priority: .utility) {
            let result = RecentsScanner.scan(current)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                let vm = RecentsViewModel.shared
                guard mine == vm.generation else { return }   // a newer scan started meanwhile
                vm.files = result.files
                vm.problems = result.problems
                vm.lastQuery = current
                vm.lastScan = Date()
                vm.scanning = false
                vm.hasScanned = true
            }
        }
    }

    private func settingsChanged() {
        dirty = true
        startWatching(force: true)
        if visible { scan() }
    }

    // MARK: - Watching

    private var watchedPaths: [String] = []

    private func startWatching(force: Bool = false) {
        guard !AppPaths.isSnapshot else { return }
        let paths = Settings.shared.watchedFolders
        guard force || watcher == nil || paths != watchedPaths else { return }
        if watcher == nil {
            watcher = FolderWatcher { Task { @MainActor in RecentsViewModel.shared.folderChanged() } }
        }
        watcher?.watch(paths)
        watchedPaths = paths
    }

    /// Something changed in a watched folder: rescan shortly if the tab shows, otherwise on the next open.
    private func folderChanged() {
        dirty = true
        guard visible else { return }
        rescanSoon?.cancel()
        rescanSoon = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self, self.visible else { return }
            self.scan()
        }
    }

    // MARK: - File actions

    func copy(_ file: MediaFile) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([file.url as NSURL])
    }
}

/// The prompt field next to Recents with "Improve with Claude". Long-lived, so a draft or an
/// answer that arrives after the panel closed is still there when it opens again.
@MainActor
final class PromptHelper: ObservableObject {
    static let shared = PromptHelper()

    @Published var prompt = ""
    @Published private(set) var improving = false
    /// Claude's version, shown next to the prompt; nothing is replaced until the user says so.
    @Published private(set) var suggestion: String?
    @Published var error: String?
    /// The prompt before Replace, for Undo.
    @Published private(set) var replaced: String?

    private var task: Task<Void, Never>?
    private var prefilledChangeCount = -1

    /// Generation prompts are usually for images and video, so the instruction says so.
    static let system = """
        The input is a prompt for an AI image or video generator (sometimes for a text model). \
        Rewrite it into a stronger prompt: specific subject, composition, camera and lens, lighting, mood and style; \
        for video also motion and pacing. For a text model add role, output format and constraints instead. \
        Keep the prompt's language and every concrete detail the user gave. Return only the improved prompt, no preamble.
        """

    /// Starts with copied text when the field is empty and the clipboard changed since the last time.
    func prefillFromClipboard() {
        let pb = NSPasteboard.general
        guard Settings.shared.prefillFromClipboard, prompt.isEmpty, pb.changeCount != prefilledChangeCount else { return }
        prefilledChangeCount = pb.changeCount
        if let text = pb.prefillText { prompt = text }
    }

    func improve() {
        let input = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, ClaudeEngine.isAvailable else { return }
        task?.cancel()
        improving = true
        error = nil
        suggestion = nil
        replaced = nil
        task = Task { [weak self] in
            do {
                let answer = try await ClaudeEngine.complete(system: Self.system, input: input, model: .sonnet55)
                guard !Task.isCancelled, let self else { return }
                self.suggestion = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.error = error.localizedDescription
            }
            self?.improving = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        improving = false
    }

    func replace() {
        guard let suggestion else { return }
        replaced = prompt
        prompt = suggestion
        self.suggestion = nil
    }

    func undoReplace() {
        guard let replaced else { return }
        prompt = replaced
        self.replaced = nil
    }

    func dismissSuggestion() { suggestion = nil }

    func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        prefilledChangeCount = pb.changeCount   // our own copy is not something to prefill from
    }
}
