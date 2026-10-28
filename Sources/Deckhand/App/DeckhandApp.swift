import AppKit
import SwiftUI

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("launch")
        if CommandLine.arguments.contains("--snapshot") { Theme.flatForSnapshot = true }
        notch.start()
        setupMenuBar()
        setupHotkeys()
        ClipboardWatcher.shared.start()

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
    }

    /// The menu shows current shortcuts, so it is rebuilt when they change.
    private func rebuildMenu() {
        let menu = NSMenu()
        add(menu, String(localized: "Open Deckhand"), #selector(toggleNotch), .toggle)
        add(menu, String(localized: "Capture Area"), #selector(takeScreenshot), .screenshot)
        add(menu, String(localized: "Copy Text from Screen"), #selector(captureText), .captureText)
        add(menu, String(localized: "Pick Color"), #selector(pickColor), .colorPicker)
        menu.addItem(.separator())
        for tab in NotchTab.allCases where tab != .home {
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

    @objc private func takeScreenshot() {
        notch.close()
        ScreenshotService.captureRegion { [weak self] in
            guard Settings.shared.screenshotToast else { return }
            self?.notch.showToast(symbol: "camera.viewfinder", text: String(localized: "Copied to clipboard"))
        }
    }

    @objc private func captureText() {
        notch.close()
        ScreenshotService.captureText { [weak self] text in
            guard let text else {
                self?.notch.showToast(symbol: "text.viewfinder", text: String(localized: "No text found"))
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.notch.showToast(symbol: "text.viewfinder", text: String(localized: "Text copied"))
        }
    }

    @objc private func pickColor() {
        notch.close()
        NSColorSampler().show { [weak self] color in
            guard let color, let rgb = color.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02X%02X%02X",
                             Int((rgb.redComponent * 255).rounded()),
                             Int((rgb.greenComponent * 255).rounded()),
                             Int((rgb.blueComponent * 255).rounded()))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
            MainActor.assumeIsolated { self?.notch.showToast(symbol: "eyedropper", text: hex) }
        }
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
