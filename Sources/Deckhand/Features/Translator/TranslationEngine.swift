import AppKit
import SwiftUI
@preconcurrency import Translation

/// Why a translation produced no text, in terms the tab can explain.
enum TranslationFailure: Error, Equatable {
    /// Translation supports the pair, but its languages aren't on this Mac yet.
    case needsDownload
    /// Apple Translation can't translate between these languages.
    case unsupported
    case sameLanguage
    /// The language of the text couldn't be recognized.
    case unrecognized
    case timedOut
    case failed
}

/// Runs translations with Apple Translation without tying them to the notch panel.
///
/// Apple's sessions are fragile in an app like this one: using a session after the SwiftUI view that
/// made it disappears is a fatalError, and `.translationTask` only runs again when its configuration
/// changes. The panel closes all the time, so no session ever lives in it:
/// - on macOS 26 installed language pairs use `TranslationSession(installedSource:target:)`, which
///   needs no view;
/// - on macOS 15 sessions come from small invisible windows the engine owns and never closes
///   (`TranslationHost`), re-run with `invalidate()`;
/// - downloads go through `TranslationDownloader`, a normal window with Apple's prompt.
///
/// Every run, and every availability check, has a timeout; runs go one at a time and stop waiting as
/// soon as their task is cancelled.
@MainActor
final class TranslationEngine {
    static let shared = TranslationEngine()

    private var installedPairs = Set<String>()
    private let gate = SerialGate()
    /// The macOS 26 session for the last language pair (a `TranslationSession`).
    private var direct: (pair: String, session: AnyObject)?
    private var hosts: [TranslationHost] = []
    private static let maxHosts = 3

    private init() {}

    /// Whether the pair can be translated now, needs a download, or isn't available.
    /// Throws `timedOut` when Translation doesn't answer in time, or `CancellationError`.
    func status(from source: String, to target: String) async throws -> LanguageAvailability.Status {
        let pair = "\(source)>\(target)"
        if installedPairs.contains(pair) { return .installed }
        let status = try await Self.race(seconds: TranslatorRules.timeout, onAbandon: { _ in }) {
            await LanguageAvailability().status(from: Locale.Language(identifier: source),
                                                to: Locale.Language(identifier: target))
        }
        if status == .installed { installedPairs.insert(pair) }
        return status
    }

    /// Languages were downloaded or removed: ask `LanguageAvailability` again.
    func forgetStatus() {
        installedPairs.removeAll()
        direct = nil
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        guard source != target else { throw TranslationFailure.sameLanguage }
        switch try await status(from: source, to: target) {
        case .installed: break
        case .supported: throw TranslationFailure.needsDownload
        default: throw TranslationFailure.unsupported
        }
        await gate.enter()
        defer { gate.leave() }
        try Task.checkCancellation()
        do {
            if #available(macOS 26.0, *) {
                return try await translateDirectly(text, from: source, to: target)
            }
            return try await translateInHost(text, from: source, to: target)
        } catch {
            throw Self.failure(for: error)
        }
    }

    // MARK: - macOS 26: no view needed

    @available(macOS 26.0, *)
    private func translateDirectly(_ text: String, from source: String, to target: String) async throws -> String {
        let pair = "\(source)>\(target)"
        let session: TranslationSession
        if let cached = direct, cached.pair == pair, let s = cached.session as? TranslationSession {
            session = s
        } else {
            session = TranslationSession(installedSource: Locale.Language(identifier: source),
                                         target: Locale.Language(identifier: target))
            direct = (pair, session)
        }
        return try await Self.race(seconds: TranslatorRules.timeout, onAbandon: { [weak self] reason in
            // Newer typing replaced the run: keep the session warm for the next one, which usually
            // has the same languages. Its unfinished call just returns into nothing.
            if reason is CancellationError { return }
            // Timed out: the session looks stuck. A cancelled session can't be used again
            session.cancel()
            if self?.direct?.pair == pair { self?.direct = nil }
        }) {
            try await session.translate(text).targetText
        }
    }

    // MARK: - macOS 15: sessions from hidden windows

    private func translateInHost(_ text: String, from source: String, to target: String) async throws -> String {
        // Waiting for a free host counts toward the same limit as the translation itself
        let deadline = Date().addingTimeInterval(TranslatorRules.timeout)
        let host = try await freeHost(before: deadline)
        return try await Self.race(seconds: max(deadline.timeIntervalSinceNow, 0), onAbandon: { _ in host.abandon() }) {
            try await host.translate(text, from: source, to: target)
        }
    }

    /// A host that can take a run now. Runs cancelled by typing keep their host busy until Apple's
    /// call returns, so with all of them busy this waits for one to free up.
    private func freeHost(before deadline: Date) async throws -> TranslationHost {
        while true {
            switch TranslatorRules.hostChoice(busy: hosts.map(\.isBusy), max: Self.maxHosts) {
            case .use(let index):
                return hosts[index]
            case .create:
                let host = TranslationHost()
                hosts.append(host)
                return host
            case .wait:
                guard Date() < deadline else { throw TranslationFailure.timedOut }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: - Helpers

    static func failure(for error: Error) -> Error {
        if error is CancellationError || error is TranslationFailure { return error }
        if TranslationError.unsupportedLanguagePairing ~= error
            || TranslationError.unsupportedSourceLanguage ~= error
            || TranslationError.unsupportedTargetLanguage ~= error {
            return TranslationFailure.unsupported
        }
        if TranslationError.unableToIdentifyLanguage ~= error { return TranslationFailure.unrecognized }
        if #available(macOS 26.0, *) {
            if TranslationError.notInstalled ~= error { return TranslationFailure.needsDownload }
            if TranslationError.alreadyCancelled ~= error { return CancellationError() }
        }
        Log.info("translate failed: \(error)")
        return TranslationFailure.failed
    }

    /// Returns the body's result, or throws `timedOut` or `CancellationError`, whichever comes first.
    /// `onAbandon` runs with that error when the body is left running after a timeout or a cancel.
    private static func race<Value: Sendable>(seconds: Double, onAbandon: @escaping @MainActor (Error) -> Void,
                                              _ body: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let race = Race<Value>(onAbandon: onAbandon)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(continuation, seconds: seconds, body)
            }
        } onCancel: {
            Task { @MainActor in race.abandon(with: CancellationError()) }
        }
    }
}

/// One answer for a continuation: from the work, a timer, or a cancel.
@MainActor
private final class Race<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var timer: Task<Void, Never>?
    private var abandoned = false
    private let onAbandon: @MainActor (Error) -> Void

    init(onAbandon: @escaping @MainActor (Error) -> Void) { self.onAbandon = onAbandon }

    func start(_ continuation: CheckedContinuation<Value, Error>, seconds: Double,
               _ body: @escaping @MainActor () async throws -> Value) {
        guard !abandoned else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.abandon(with: TranslationFailure.timedOut)
        }
        Task {
            do { self.finish(.success(try await body())) } catch { self.finish(.failure(error)) }
        }
    }

    func abandon(with error: Error) {
        guard !abandoned else { return }
        abandoned = true
        // Not started yet (`start` answers then) or already answered
        guard continuation != nil else { return }
        finish(.failure(error))
        onAbandon(error)
    }

    private func finish(_ result: Result<Value, Error>) {
        timer?.cancel()
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

/// Lets async work on the main actor run one at a time, in order.
@MainActor
private final class SerialGate {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}

/// An invisible window whose SwiftUI view owns a `.translationTask`, for macOS before 26.
///
/// The window is never closed, so its sessions never outlive their view. A host takes one run at a
/// time; the engine uses another host while this one waits for a run that timed out.
@MainActor
final class TranslationHost: ObservableObject {
    @Published fileprivate var configuration: TranslationSession.Configuration?
    private(set) var isBusy = false
    private var pair: (source: String, target: String)?
    private var pending: (text: String, continuation: CheckedContinuation<String, Error>)?
    private var window: NSWindow?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isExcludedFromWindowsMenu = true
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: TranslationHostView(host: self))
        // SwiftUI runs `.translationTask` only for a view in a window that is on screen
        window.orderFrontRegardless()
        self.window = window
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        isBusy = true
        return try await withCheckedThrowingContinuation { continuation in
            pending = (text, continuation)
            switch TranslatorRules.hostUpdate(current: pair, source: source, target: target) {
            case .invalidate:
                configuration?.invalidate()
            case .replace:
                pair = (source, target)
                configuration = TranslationSession.Configuration(source: Locale.Language(identifier: source),
                                                                 target: Locale.Language(identifier: target))
            }
        }
    }

    /// Called by the view with a fresh session.
    fileprivate func run(_ session: TranslationSession) async {
        guard let job = pending else { return }
        pending = nil
        do {
            job.continuation.resume(returning: try await session.translate(job.text).targetText)
        } catch {
            job.continuation.resume(throwing: error)
        }
        isBusy = false
    }

    /// The engine stopped waiting. If the session never started, the host is free again;
    /// otherwise it stays busy until the running translation returns.
    func abandon() {
        guard let job = pending else { return }
        pending = nil
        job.continuation.resume(throwing: TranslationFailure.timedOut)
        isBusy = false
    }
}

private struct TranslationHostView: View {
    @ObservedObject var host: TranslationHost

    var body: some View {
        Color.clear
            .frame(width: 2, height: 2)
            .translationTask(host.configuration) { session in
                await host.run(session)
            }
    }
}
