import AppKit
import Combine

/// Polls `NSPasteboard.changeCount` and saves new copies in `ClipboardStore`.
///
/// The main thread only reads the pasteboard; classifying, hashing, image encoding and the image
/// file write run on a serial background queue, so a 5K screenshot doesn't stutter the panel.
@MainActor
final class ClipboardWatcher: ObservableObject {
    static let shared = ClipboardWatcher()

    /// Recording is paused until this moment (`.distantFuture` until resumed). Not saved across launches.
    @Published private(set) var pausedUntil: Date?

    private var timer: Timer?
    private var pauseTimer: Timer?
    private let pasteboard: NSPasteboard
    private var lastChangeCount: Int
    /// Open `suspendCapture()` calls. Separate from the user's pause, and never shown.
    private var captureSuspensions = 0
    /// Change counts of Deckhand's own writes from the history; those are already in it.
    private var ownChangeCounts: Set<Int> = []
    private let queue = DispatchQueue(label: "deckhand.clipboard.capture", qos: .userInitiated)
    private var subscriptions = Set<AnyCancellable>()

    /// `pasteboard` is the general one except in the self-test, which uses a private one.
    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        stop()
        PasteService.startTracking()
        lastChangeCount = pasteboard.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        ClipboardStore.shared.removeOrphanImages()

        // Lowering the limit or the age trims right away, not on the next copy
        Settings.shared.$historyLimit.combineLatest(ClipboardSettings.shared.$historyMaxAgeDays)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { limit, days in ClipboardStore.shared.trim(limit: limit, maxAgeDays: days) }
            .store(in: &subscriptions)
        // Expire old items even when nothing new is copied
        Timer.publish(every: 3600, on: .main, in: .common).autoconnect()
            .sink { _ in
                ClipboardStore.shared.trim(limit: Settings.shared.historyLimit,
                                           maxAgeDays: ClipboardSettings.shared.historyMaxAgeDays)
            }
            .store(in: &subscriptions)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        subscriptions.removeAll()
    }

    // MARK: - Pause

    var isPaused: Bool { pausedUntil.map { $0 > Date() } ?? false }

    /// Pauses recording for `duration` seconds, or until resumed when nil.
    func pause(for duration: TimeInterval?) {
        pauseTimer?.invalidate()
        pausedUntil = duration.map { Date().addingTimeInterval($0) } ?? .distantFuture
        if let duration {
            pauseTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            }
        }
    }

    func resume() {
        pauseTimer?.invalidate()
        pauseTimer = nil
        pausedUntil = nil
        // What was copied during the pause stays out of the history
        lastChangeCount = pasteboard.changeCount
    }

    /// Stops recording while Deckhand itself uses the clipboard, e.g. the ⌘C that reads a selection
    /// and the restore after it. Calls nest; every call needs a matching `resumeCapture()`.
    /// This is not the user's pause: `isPaused` and `pausedUntil` don't change.
    func suspendCapture() {
        captureSuspensions += 1
    }

    /// Ends one `suspendCapture()`. After the last one, whatever is on the clipboard now counts as
    /// already seen, so the copy and the restore never reach the history.
    func resumeCapture() {
        guard captureSuspensions > 0 else { return }
        captureSuspensions -= 1
        if captureSuspensions == 0 { lastChangeCount = pasteboard.changeCount }
    }

    var isCaptureSuspended: Bool { captureSuspensions > 0 }

    /// Called after Deckhand wrote a history item back to the pasteboard.
    func noteOwnWrite(changeCount: Int) {
        ownChangeCounts.insert(changeCount)
    }

    // MARK: - Capture

    /// Whether the pasteboard holds a copy to record: it changed since the last look, not by
    /// Deckhand writing a history item back, and capture isn't suspended. Marks the change as seen.
    func takeNewChange() -> Bool {
        let count = pasteboard.changeCount
        // Left unseen while suspended: `resumeCapture()` skips it
        guard captureSuspensions == 0, count != lastChangeCount else { return false }
        lastChangeCount = count
        if ownChangeCounts.remove(count) != nil { return false }
        ownChangeCounts.removeAll()
        return true
    }

    private func tick() {
        let pb = pasteboard
        guard takeNewChange() else { return }
        guard ClipboardSettings.shared.recordHistory, !isPaused else { return }
        let types = Set((pb.types ?? []).map(\.rawValue))
        guard let snap = Self.snapshot(of: pb, source: currentSource(types: types), rules: .current) else { return }

        let imagesDir = ClipboardStore.shared.imagesDir
        let maxImageBytes = ClipboardSettings.shared.maxImageBytes
        queue.async {
            guard let entry = ClipboardCapture.prepare(snap, imagesDir: imagesDir, maxImageBytes: maxImageBytes) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    _ = ClipboardStore.shared.insert(entry, limit: Settings.shared.historyLimit,
                                 maxAgeDays: ClipboardSettings.shared.historyMaxAgeDays)
                }
            }
        }
    }

    /// Password managers mark their copies with this type (nspasteboard.org convention).
    nonisolated private static let concealedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "com.agilebits.onepassword",
    ]

    /// Copies meant to vanish: never saved, whatever the settings say.
    nonisolated private static let transientTypes: Set<String> = [
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
    ]

    /// Apps whose copies are passwords even when they do not set a concealed type,
    /// e.g. Apple's Passwords app.
    nonisolated static let passwordApps: Set<String> = [
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.bitwarden.desktop",
    ]

    /// A password manager marked the copy as concealed or transient, or it came from a password app.
    nonisolated static func isPassword(types: Set<String>, sourceApp: String?) -> Bool {
        if !types.isDisjoint(with: concealedTypes) || isTransient(types: types) { return true }
        return sourceApp.map(passwordApps.contains) ?? false
    }

    nonisolated static func isTransient(types: Set<String>) -> Bool {
        !types.isDisjoint(with: transientTypes)
    }

    /// What the settings allow to be saved.
    struct Rules {
        var savePasswords = false
        var excludedApps: [String] = []
        var saveImages = true
        var saveFiles = true
        var maxImageBytes = 0

        @MainActor static var current: Rules {
            Rules(savePasswords: Settings.shared.savePasswordsToHistory,
                  excludedApps: Settings.shared.excludedApps,
                  saveImages: ClipboardSettings.shared.saveImages,
                  saveFiles: ClipboardSettings.shared.saveFiles,
                  maxImageBytes: ClipboardSettings.shared.maxImageBytes)
        }
    }

    /// Reads what's needed from the pasteboard. File contents are never read: a copied file is
    /// saved as its URL. Image bytes are read only when the copy is an image.
    static func snapshot(of pb: NSPasteboard, source: (bundleId: String?, name: String?), rules: Rules) -> PasteboardSnapshot? {
        let types = Set((pb.types ?? []).map(\.rawValue))
        guard !types.isEmpty, !isTransient(types: types) else { return nil }

        var snap = PasteboardSnapshot(types: types)
        snap.sourceApp = source.bundleId
        snap.sourceAppName = source.name
        if let app = source.bundleId, rules.excludedApps.contains(app) { return nil }
        if isPassword(types: types, sourceApp: source.bundleId) {
            guard rules.savePasswords else {
                Log.info("clipboard: password skipped")
                return nil
            }
            snap.isSecret = true
        }

        let fileURLs = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        snap.fileURLs = fileURLs.filter(\.isFileURL)
        snap.string = pb.string(forType: .string)
        if snap.string == nil, types.contains(NSPasteboard.PasteboardType.URL.rawValue) {
            snap.urlString = pb.string(forType: .URL)
        }

        switch ClipboardCapture.classify(types: types, string: snap.string, fileURLs: snap.fileURLs, urlString: snap.urlString) {
        case .file?:
            guard rules.saveFiles else { return nil }
        case .image?:
            guard rules.saveImages else { return nil }
            let candidates = ClipboardCapture.imageTypes + [ClipboardCapture.pdfType]
            for type in candidates where types.contains(type) {
                if let data = pb.data(forType: NSPasteboard.PasteboardType(type)) {
                    snap.imageData = data
                    snap.imageType = type
                    break
                }
            }
            // Cheap early exit before any decoding: the PNG is rarely much smaller than its source
            let cap = rules.maxImageBytes
            if cap > 0, let size = snap.imageData?.count, size > cap * 4 { return nil }
        case .text?:
            for type in [ClipboardCapture.rtfType, ClipboardCapture.htmlType] where types.contains(type) {
                if let data = pb.data(forType: NSPasteboard.PasteboardType(type)), data.count <= ClipboardText.maxRichBytes {
                    snap.richType = type
                    snap.richData = data
                    break
                }
            }
        case .link?:
            break
        case nil:
            return nil
        }
        return snap
    }

    /// The app the copy came from. Copies made inside Deckhand (a prompt, a translation, a capture
    /// from the panel) are credited to Deckhand instead of the app in front.
    private func currentSource(types: Set<String>) -> (bundleId: String?, name: String?) {
        if types.contains(ClipboardCapture.ownType) || NSApp?.keyWindow != nil || NSApp?.isActive == true {
            return (Bundle.main.bundleIdentifier ?? AppPaths.bundleId, "Deckhand")
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return (nil, nil) }
        return (app.bundleIdentifier, app.localizedName)
    }
}
