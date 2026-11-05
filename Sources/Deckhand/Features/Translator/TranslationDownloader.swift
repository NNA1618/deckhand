import AppKit
import SwiftUI
@preconcurrency import Translation

/// Downloads translation languages with Apple's own prompt.
///
/// The prompt is a sheet on the window that owns the session. Shown from the notch panel it would be
/// cut off or vanish with the panel, and a vanished prompt looks exactly like the user saying no.
/// So it gets a normal, active window of its own, and a "no" is never remembered: the next try asks again.
@MainActor
enum TranslationDownloader {
    private static var current: DownloadWindow?

    /// Asks macOS to download what translating `source` → `target` needs. True when the pair is ready.
    static func download(source: String, target: String) async -> Bool {
        if let current {
            current.window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return false
        }
        let window = DownloadWindow(source: source, target: target)
        current = window
        let finished = await window.run()
        current = nil
        TranslationEngine.shared.forgetStatus()
        guard finished else { return false }
        return (try? await TranslationEngine.shared.status(from: source, to: target)) == .installed
    }
}

@MainActor
private final class DownloadWindow {
    let window: NSWindow
    private let model: DownloadModel

    init(source: String, target: String) {
        model = DownloadModel(source: source, target: target)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 210),
                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = String(localized: "Translation Languages")
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DownloadView(model: model))
        window.center()
        model.hide = { [weak window] in window?.orderOut(nil) }
    }

    func run() async -> Bool {
        AppActivation.windowOpened(window)
        window.makeKeyAndOrderFront(nil)
        let ok = await withCheckedContinuation { continuation in
            let model = self.model
            model.onFinish = { continuation.resume(returning: $0) }
            // Start once the window is on screen, so Apple's sheet has somewhere to attach
            Task { @MainActor in model.start() }
        }
        // The session has finished its work, so the view can go away safely
        window.close()
        return ok
    }
}

@MainActor
private final class DownloadModel: ObservableObject {
    let source: String
    let target: String
    @Published var configuration: TranslationSession.Configuration?
    @Published var cancelling = false
    var onFinish: ((Bool) -> Void)?
    var hide: () -> Void = {}
    /// The running session, to cancel it on macOS 26.
    private var session: AnyObject?

    init(source: String, target: String) {
        self.source = source
        self.target = target
    }

    func start() {
        configuration = TranslationSession.Configuration(source: Locale.Language(identifier: source),
                                                         target: Locale.Language(identifier: target))
    }

    func run(_ session: TranslationSession) async {
        self.session = session
        var ok = false
        do {
            try await session.prepareTranslation()
            ok = true
        } catch {
            Log.info("translation download ended: \(error)")
        }
        self.session = nil
        finish(ok)
    }

    func cancel() {
        cancelling = true
        if #available(macOS 26.0, *), let session = session as? TranslationSession {
            session.cancel()
        } else if session == nil {
            finish(false)
        } else {
            // macOS 15 can't cancel a session: hide the window and close it when the session returns
            hide()
        }
    }

    private func finish(_ ok: Bool) {
        guard let onFinish else { return }
        self.onFinish = nil
        onFinish(ok)
    }
}

private struct DownloadView: View {
    @ObservedObject var model: DownloadModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "translate")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("Download languages for translation")
                .font(.headline)
            Text("To translate \(TranslationLanguages.name(of: model.source)) → \(TranslationLanguages.name(of: model.target)), macOS needs to download these languages once. Translation then works offline.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for macOS…").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.cancelling)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 18)
        .frame(width: 440)
        .translationTask(model.configuration) { session in
            await model.run(session)
        }
    }
}
