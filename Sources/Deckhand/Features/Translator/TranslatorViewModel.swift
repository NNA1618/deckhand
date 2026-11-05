import AppKit
import Combine

/// The Translate tab's state. One shared instance, so text, languages and the result survive
/// switching tabs and closing the panel.
@MainActor
final class TranslatorViewModel: ObservableObject {
    static let shared = TranslatorViewModel()

    enum SourceMode: Equatable {
        case detect
        case fixed(String)
    }

    enum Phase: Equatable {
        case idle, translating, done, downloading
        case failed(TranslationFailure)
    }

    /// A hint under the text, about where it came from or a missing permission.
    enum Notice: Equatable {
        case usedClipboard, nothingSelected, selectionNeedsAccessibility, pasteNeedsAccessibility
    }

    @Published var input = "" {
        didSet { if input != oldValue { inputChanged() } }
    }
    @Published private(set) var output = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var detected: String?
    /// A source the user picked in the tab (or set by Swap); nil follows the settings.
    @Published private(set) var sourceOverride: SourceMode?
    /// A target the user picked in the tab (or set by Swap); nil follows the settings.
    @Published private(set) var pinnedTarget: String?
    @Published var notice: Notice?
    @Published private(set) var justCopied = false

    let settings = TranslateSettings.shared
    let speaker = TranslationSpeaker()

    /// Swap chose the source: it lasts until the text is cleared, then detection takes over again.
    private var sourceFromSwap = false
    private var lastRequest: TranslatorRules.Request?
    private var work: Task<Void, Never>?
    private var typing: Task<Void, Never>?
    private var copiedReset: Task<Void, Never>?
    /// The clipboard state last used to fill the field, or written by the tab itself.
    private var lastClipboardChange: Int?
    private var subscriptions = Set<AnyCancellable>()

    private init() {
        // Settings changes (other languages, detection on or off) apply to the text already in the tab
        settings.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.languagesChanged() } }
            .store(in: &subscriptions)
        speaker.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        if AppPaths.isSnapshot { showSample() }
    }

    // MARK: - Languages

    var sourceMode: SourceMode {
        sourceOverride ?? (settings.autoDetect ? .detect : .fixed(settings.source))
    }

    /// The language the text is in: the chosen one, or the detected one.
    var source: String? {
        if case .fixed(let code) = sourceMode { return code }
        return detected
    }

    var target: String {
        TranslatorRules.target(source: source, pinned: pinnedTarget, preferred: settings.target,
                               second: settings.secondLanguage)
    }

    func chooseSource(_ mode: SourceMode) {
        let defaultMode: SourceMode = settings.autoDetect ? .detect : .fixed(settings.source)
        // Picking the target's language as the source swaps them, as in Apple's Translate
        if case .fixed(let code) = mode, code == target, let previous = source, previous != code {
            pinnedTarget = previous
        }
        sourceOverride = mode == defaultMode ? nil : mode
        sourceFromSwap = false
        if mode == .detect { detect() }
        translate()
    }

    func chooseTarget(_ code: String) {
        if case .fixed(let src) = sourceMode, src == code {
            // The fixed source can't also be the target: swap them
            sourceOverride = .fixed(target)
        }
        pinnedTarget = code
        translate()
    }

    /// Swaps the languages, and the text with its translation. The swapped languages stick while typing.
    func swap() {
        let oldTarget = target
        let oldSource = source ?? TranslatorRules.target(source: oldTarget, pinned: nil, preferred: settings.target,
                                                         second: settings.secondLanguage)
        sourceOverride = .fixed(oldTarget)
        sourceFromSwap = true
        pinnedTarget = oldSource
        if phase == .done, !output.isEmpty {
            let translation = output
            output = input.trimmingCharacters(in: .whitespacesAndNewlines)
            input = translation
        }
        translate()
    }

    private func languagesChanged() {
        guard !input.isEmpty else { return }
        if settings.autoDetect, sourceOverride == nil { detect() }
        if settings.translateAsYouType { translate() }
    }

    private func detect() {
        guard sourceMode == .detect else { return }
        let supported = Set(TranslationCatalog.shared.codes)
        let (hypotheses, letters) = TranslatorRules.hypotheses(for: input, supported: supported)
        detected = TranslatorRules.detectedLanguage(
            hypotheses: hypotheses, letters: letters, previous: detected,
            preferred: [settings.target, settings.secondLanguage] + settings.favorites, supported: supported)
    }

    private func resetLanguages() {
        sourceOverride = nil
        pinnedTarget = nil
        sourceFromSwap = false
        detected = nil
    }

    // MARK: - Text

    private func inputChanged() {
        notice = nil
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            typing?.cancel()
            work?.cancel()
            speaker.stop()
            output = ""
            phase = .idle
            lastRequest = nil
            detected = nil
            if sourceFromSwap {
                sourceOverride = nil
                sourceFromSwap = false
            }
            return
        }
        typing?.cancel()
        typing = Task { [weak self] in
            // Recognize the language soon, translate a moment later
            try? await Task.sleep(for: .seconds(0.25))
            guard !Task.isCancelled, let self else { return }
            self.detect()
            guard self.settings.translateAsYouType else { return }
            try? await Task.sleep(for: .seconds(TranslatorRules.typingDelay - 0.25))
            guard !Task.isCancelled else { return }
            self.translate()
        }
    }

    /// Fills the empty field with copied text when the tab opens, at most once per clipboard change.
    func prefillIfNeeded() {
        guard !AppPaths.isSnapshot else { return }
        let pb = NSPasteboard.general
        guard TranslatorRules.shouldPrefill(enabled: Settings.shared.prefillFromClipboard, inputEmpty: input.isEmpty,
                                            changeCount: pb.changeCount, lastUsedChangeCount: lastClipboardChange)
        else { return }
        lastClipboardChange = pb.changeCount
        guard let text = pb.prefillText else { return }
        resetLanguages()
        input = text
        if settings.translateAsYouType { translate() }
    }

    /// Text from outside the tab (the shortcut): new text, so languages start from the settings again.
    func receive(_ result: SelectionReader.Result) {
        let text: String?
        let newNotice: Notice?
        switch result {
        case .selection(let s): text = s; newNotice = nil
        case .clipboard(let s): text = s; newNotice = s == nil ? .nothingSelected : .usedClipboard
        case .noPermission(let s): text = s; newNotice = .selectionNeedsAccessibility
        }
        lastClipboardChange = NSPasteboard.general.changeCount
        if let text {
            resetLanguages()
            input = text
            translate(force: true)
        }
        notice = newNotice
    }

    // MARK: - Translating

    /// Translates now. Without `force`, the same text and languages don't run twice.
    func translate(force: Bool = false) {
        typing?.cancel()
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        detect()
        guard let source else {
            work?.cancel()
            lastRequest = nil
            phase = .failed(.unrecognized)
            return
        }
        let target = self.target
        let request = TranslatorRules.Request(text: text, source: source, target: target)
        let current = phase == .done || phase == .translating
        guard force || TranslatorRules.needsRun(request, last: lastRequest, lastSucceededOrRunning: current) else { return }
        work?.cancel()
        speaker.stop()
        lastRequest = request
        phase = .translating
        work = Task { [weak self] in
            do {
                let result = try await TranslationEngine.shared.translate(text, from: source, to: target)
                guard let self, !Task.isCancelled, self.lastRequest == request else { return }
                self.output = result
                self.phase = .done
                self.settings.noteUsed(target: target)
            } catch {
                guard let self, !Task.isCancelled, self.lastRequest == request else { return }
                self.phase = .failed(error as? TranslationFailure ?? .failed)
            }
        }
    }

    /// Shows Apple's download prompt for the current languages, then translates.
    func downloadLanguages(then reopen: @escaping @MainActor () -> Void) {
        guard let source else { return }
        let target = self.target
        phase = .downloading
        Task { [weak self] in
            let ready = await TranslationDownloader.download(source: source, target: target)
            guard let self else { return }
            if ready {
                self.translate(force: true)
                reopen()
            } else {
                self.phase = .failed(.needsDownload)
            }
        }
    }

    // MARK: - Result actions

    var canSpeak: Bool { !output.isEmpty && TranslationSpeaker.canSpeak(target) }

    func speak() { speaker.toggle(output, language: target) }

    func copyOutput() {
        guard !output.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(output, forType: .string)
        // The tab's own copy must not come back as the next prefill
        lastClipboardChange = pb.changeCount
        justCopied = true
        copiedReset?.cancel()
        copiedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.justCopied = false
        }
    }

    /// Copies the translation and pastes it into the app the user was working in.
    func pasteOutput(closePanel: () -> Void) {
        guard !output.isEmpty else { return }
        guard PasteService.isTrusted else {
            notice = .pasteNeedsAccessibility
            return
        }
        copyOutput()
        closePanel()
        PasteService.pasteIntoFrontApp()
    }

    // MARK: - Snapshot

    private func showSample() {
        input = "Deckhand keeps everything you copied right under the notch, ready when you need it."
        detected = "en"
        pinnedTarget = "de"
        output = "Deckhand bewahrt alles, was du kopiert hast, direkt unter der Notch auf – bereit, wenn du es brauchst."
        typing?.cancel()
        phase = .done
    }
}
