import AppKit
import SwiftUI
import Combine

@main
struct DeckhandApp {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            let ok = MainActor.assumeIsolated { SelfTest.run() }
            exit(ok ? 0 : 1)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let notch = NotchController()
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("launch")
        MainMenu.install(settingsTarget: self, settingsAction: #selector(openSettings))
        notch.start()
        // A snapshot run is a second copy next to the user's own: it must not watch the clipboard,
        // take hotkeys, read Claude Code events or add a menu bar icon. Its data lives in a temporary folder.
        if !AppPaths.isSnapshot {
            setupMenuBar()
            setupHotkeys()
            if !Settings.shared.savePasswordsToHistory {
                // Older versions kept copies from password apps that set no concealed type
                ClipboardStore.shared.deleteItems(fromApps: ClipboardWatcher.passwordApps)
            }
            ClipboardWatcher.shared.start()
            if Settings.shared.showPlayingInNotch { NowPlayingMonitor.shared.start() }
            UtilityNotices.install(notch: notch)
            TranslatorCoordinator.install(notch: notch)
            ClaudeNotices.install(notch: notch)
        } else {
            Theme.flatForSnapshot = true
            Task.detached(priority: .utility) { ClaudeCLI.resolve() }
        }

        // For testing: `Deckhand --open clipboard` opens a tab on launch
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open") {
            let name = i + 1 < args.count ? args[i + 1] : "home"
            notch.open(tab: NotchTab(rawValue: name) ?? .home)
        }
        if args.contains("--settings") { SettingsWindow.show() }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in
                await Snapshot.run(dir: dir, notch: notch)
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        KeepAwake.shared.stop()
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Brand.menuBarIcon
        item.button?.toolTip = "Deckhand"
        statusItem = item
        rebuildMenu()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildMenu() }
        }
        KeepAwake.shared.$isActive.combineLatest(KeepAwake.shared.$duration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &subscriptions)
    }

    /// The menu shows current shortcuts, so it is rebuilt when they change.
    private func rebuildMenu() {
        let menu = NSMenu()
        add(menu, String(localized: "Open Deckhand"), #selector(toggleNotch), .toggle)
        add(menu, String(localized: "Capture Area"), #selector(takeScreenshot), .screenshot)
        add(menu, String(localized: "Copy Text from Screen"), #selector(captureText), .captureText)
        add(menu, String(localized: "Pick Color"), #selector(pickColor), .colorPicker)
        menu.addItem(keepAwakeMenuItem())
        menu.addItem(.separator())
        for tab in NotchTab.visible where tab != .home {
            let mi = NSMenuItem(title: tab.title, action: #selector(openTab(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = tab.rawValue
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Quit Deckhand"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    private func keepAwakeMenuItem() -> NSMenuItem {
        let awake = KeepAwake.shared
        let item = NSMenuItem(title: String(localized: "Keep Awake"), action: nil, keyEquivalent: "")
        item.state = awake.isActive ? .on : .off
        let sub = NSMenu()
        let off = NSMenuItem(title: String(localized: "Off"), action: #selector(keepAwakeOff), keyEquivalent: "")
        off.target = self
        off.state = awake.isActive ? .off : .on
        sub.addItem(off)
        sub.addItem(.separator())
        for (i, d) in KeepAwake.durations.enumerated() {
            let mi = NSMenuItem(title: KeepAwake.title(for: d), action: #selector(keepAwakeFor(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            mi.state = awake.isActive && awake.duration == d ? .on : .off
            sub.addItem(mi)
        }
        item.submenu = sub
        return item
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ hotkey: HotkeyAction) {
        let hint = HotkeyManager.shared.shortcuts[hotkey]?.display ?? ""
        let mi = NSMenuItem(title: hint.isEmpty ? title : "\(title)    \(hint)", action: action, keyEquivalent: "")
        mi.target = self
        menu.addItem(mi)
    }

    // MARK: - Hotkeys

    private func setupHotkeys() {
        let hk = HotkeyManager.shared
        hk.setHandler(.toggle) { [weak self] in self?.notch.toggle() }
        hk.setHandler(.screenshot) { [weak self] in self?.takeScreenshot() }
        hk.setHandler(.captureText) { [weak self] in self?.captureText() }
        hk.setHandler(.colorPicker) { [weak self] in self?.pickColor() }
        hk.setHandler(.keepAwake) { [weak self] in self?.toggleKeepAwake() }
        hk.setHandler(.translateSelection) { [weak self] in
            guard let self else { return }
            TranslatorCoordinator.translateSelection(notch: self.notch)
        }
        let tabs: [(HotkeyAction, NotchTab)] = [
            (.clipboard, .clipboard), (.translator, .translator), (.claude, .claude),
            (.prompts, .prompts), (.media, .media), (.shelf, .shelf), (.recents, .recents),
        ]
        for (action, tab) in tabs {
            hk.setHandler(action) { [weak self] in self?.notch.open(tab: tab) }
        }
        hk.registerAll()
    }

    // MARK: - Actions

    @objc private func takeScreenshot() { CaptureActions.captureArea(notch: notch) }
    @objc private func captureText() { CaptureActions.captureText(notch: notch) }
    @objc private func pickColor() { CaptureActions.pickColor(notch: notch) }

    private func toggleKeepAwake() { UtilityNotices.toggleKeepAwake(notch: notch) }

    @objc private func keepAwakeOff() { KeepAwake.shared.stop() }

    @objc private func keepAwakeFor(_ sender: NSMenuItem) {
        guard KeepAwake.durations.indices.contains(sender.tag) else { return }
        KeepAwake.shared.start(for: KeepAwake.durations[sender.tag])
    }

    @objc private func toggleNotch() {
        // The menu closes asynchronously; without the delay the click counts as a click outside the panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.notch.toggle() }
    }

    @objc private func openTab(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tab = NotchTab(rawValue: raw) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.notch.open(tab: tab) }
    }

    @objc private func openSettings() {
        SettingsWindow.show()
    }
}
