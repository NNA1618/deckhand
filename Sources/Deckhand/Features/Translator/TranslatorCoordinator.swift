import AppKit

/// Entry points into translation from outside the Translate tab, such as the
/// "Translate selected text" shortcut. Owned by the translate workstream.
@MainActor
enum TranslatorCoordinator {
    private static weak var notch: NotchController?
    /// The last app other than Deckhand that was active: where "Paste" sends the translation.
    private static var lastApp: NSRunningApplication?
    private static var observer: NSObjectProtocol?
    /// A selection read is under way. It may send ⌘C and restore the clipboard, so a second press
    /// meanwhile would read the first one's restore and leave its own ⌘C on the clipboard.
    private(set) static var isReadingSelection = false

    /// Called once at launch, so the tab can reopen after a download and name the app it pastes into.
    static func install(notch: NotchController) {
        self.notch = notch
        TranslationCatalog.shared.loadIfNeeded()
        guard observer == nil else { return }
        lastApp = otherApp(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app = otherApp(app) { lastApp = app }
            }
        }
    }

    /// Opens the Translate tab with the selected text, or the clipboard text if nothing is selected.
    static func translateSelection(notch: NotchController) {
        self.notch = notch
        TranslationCatalog.shared.loadIfNeeded()
        let vm = TranslatorViewModel.shared
        if notch.viewModel.isOpen, NSApp.keyWindow is NotchWindow {
            // The panel has the keyboard focus, so there is no selection in another app to read
            notch.viewModel.tab = .translator
            if vm.input.isEmpty { vm.prefillIfNeeded() } else { vm.translate() }
            return
        }
        guard !isReadingSelection else { return }
        isReadingSelection = true
        Task {
            defer { isReadingSelection = false }
            // Read before opening: the panel takes the keyboard focus and the selection with it
            let result = await SelectionReader.read()
            vm.receive(result)
            showTab()
        }
    }

    /// Shows the Translate tab, opening the panel if needed.
    static func showTab() {
        guard let notch else { return }
        if notch.viewModel.isOpen {
            notch.viewModel.tab = .translator
        } else {
            notch.open(tab: .translator)
        }
    }

    /// The app that "Paste" sends the translation to.
    static var pasteTarget: NSRunningApplication? {
        otherApp(NSWorkspace.shared.frontmostApplication) ?? lastApp
    }

    private static func otherApp(_ app: NSRunningApplication?) -> NSRunningApplication? {
        guard let app, app.processIdentifier != getpid() else { return nil }
        return app
    }
}
