import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let notch = NotchController()
    private var subscriptions = Set<AnyCancellable>()
    /// A menu item's action, run once its menu has closed so the click can't count as a click outside the panel.
    private var pendingMenuAction: (@MainActor () -> Void)?
    private var menuIsOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("launch")
        MainMenu.install(settingsTarget: self, settingsAction: #selector(openSettings))
        notch.start()
        PanelActions.notch = notch
        // A snapshot run is a second copy next to the user's own: it must not watch the clipboard,
        // take hotkeys, read Claude Code events or add a menu bar icon. Its data lives in a temporary folder.
        if !AppPaths.isSnapshot {
            setupLidSleepSafety()
            notch.viewModel.tab = PanelSettings.shared.tabWhenOpened
            setupMenuBar()
            setupHotkeys()
            if !Settings.shared.savePasswordsToHistory {
                // Older versions kept copies from password apps that set no concealed type
                ClipboardStore.shared.deleteItems(fromApps: ClipboardWatcher.passwordApps)
            }
            ClipboardWatcher.shared.start()
            if Database.shared.movedAside != nil {
                // The damaged file and its images are kept in Deckhand's folder
                notch.showToast(symbol: "exclamationmark.triangle",
                                text: String(localized: "Clipboard history was damaged and has been started over"),
                                style: .alert)
            }
            if Settings.shared.showPlayingInNotch { NowPlayingMonitor.shared.start() }
            UtilityNotices.install(notch: notch)
            TranslatorCoordinator.install(notch: notch)
            ClaudeNotices.install(notch: notch)
            CodexNotices.install(notch: notch)
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
        // Also when no session is running: the Mac must never be left unable to sleep
        LidSleep.shared.turnOff()
        DesktopCover.shared.hide()
    }

    /// Opening Deckhand again from Finder or Spotlight shows Settings, the way back when the menu bar icon is off.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.show()
        return false
    }

    // MARK: - Closed-lid sleep

    /// A crash or force quit may have left closed-lid sleep off; turn it back on now. Shutting down or logging out
    /// turns it back on too, in case quitting is cut short.
    private func setupLidSleepSafety() {
        let lid = LidSleep.shared
        lid.recoverAfterLaunch(keepAwakeActive: KeepAwake.shared.isActive)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LidSleep.shared.turnOff() }
        }
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        // @Published fires before the value is stored, so use the value it passes
        Settings.shared.$showMenuBarIcon.removeDuplicates().sink { [weak self] show in
            self?.setStatusItem(visible: show)
        }.store(in: &subscriptions)
    }

    private func setStatusItem(visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = Brand.menuBarIcon
            item.button?.toolTip = "Deckhand"
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu == statusItem?.menu { menuIsOpen = true }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu == statusItem?.menu else { return }
        menuIsOpen = false
        runPendingMenuAction()
    }

    /// Built right before it opens, so titles, times and shortcuts are always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu == statusItem?.menu else { return }
        menu.removeAllItems()
        menu.addItem(item(notch.viewModel.isOpen ? String(localized: "Close Deckhand") : String(localized: "Open Deckhand"),
                          #selector(menuToggle), hotkey: .toggle))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Capture Area"), #selector(menuCapture), hotkey: .screenshot))
        menu.addItem(item(String(localized: "Copy Text from Screen"), #selector(menuCaptureText), hotkey: .captureText))
        menu.addItem(item(String(localized: "Pick Color"), #selector(menuPickColor), hotkey: .colorPicker))
        menu.addItem(.separator())
        menu.addItem(timerMenuItem())
        menu.addItem(keepAwakeMenuItem())
        menu.addItem(.separator())
        for tab in PanelSettings.shared.visibleTabs where tab != .home {
            let mi = item(tab.title, #selector(menuOpenTab(_:)), hotkey: PanelActions.action(for: tab))
            mi.representedObject = tab.rawValue
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        if NotchSettings.shared.activation.opensOnHover { menu.addItem(hoverMenuItem()) }
        menu.addItem(item(String(localized: "Settings…"), #selector(openSettings), key: ","))
        menu.addItem(item(String(localized: "About Deckhand"), #selector(openAbout)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Quit Deckhand"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func timerMenuItem() -> NSMenuItem {
        let timer = Countdown.shared
        let parent = NSMenuItem(title: String(localized: "Timer"), action: nil, keyEquivalent: "")
        if timer.isRinging {
            parent.subtitle = String(localized: "Time is up")
        } else if timer.isPaused {
            parent.subtitle = String(localized: "Paused, \(timer.remainingText())")
        } else if timer.isRunning {
            parent.subtitle = String(localized: "\(timer.remainingText()) left")
        }
        parent.state = timer.isActive ? .on : .off
        let sub = NSMenu()
        if timer.isRinging {
            sub.addItem(item(String(localized: "Dismiss"), #selector(timerStop)))
            sub.addItem(.separator())
        } else if timer.isActive {
            sub.addItem(timer.isPaused ? item(String(localized: "Resume"), #selector(timerResume))
                                       : item(String(localized: "Pause"), #selector(timerPause)))
            sub.addItem(item(String(localized: "Add a Minute"), #selector(timerAddMinute)))
            sub.addItem(item(String(localized: "Stop"), #selector(timerStop)))
            sub.addItem(.separator())
        }
        for (i, m) in UtilitySettings.shared.timerPresets.enumerated() {
            let mi = item(KeepAwake.title(for: TimeInterval(m * 60)), #selector(timerStart(_:)))
            mi.tag = i
            sub.addItem(mi)
        }
        parent.submenu = sub
        return parent
    }

    private func keepAwakeMenuItem() -> NSMenuItem {
        let awake = KeepAwake.shared
        let parent = NSMenuItem(title: String(localized: "Keep Awake"), action: nil, keyEquivalent: "")
        parent.state = awake.isActive ? .on : .off
        if awake.isActive {
            parent.subtitle = awake.endsAt == nil ? String(localized: "On, no time limit")
                                                  : String(localized: "\(awake.remainingDescription()) left")
        }
        let sub = NSMenu()
        sub.addItem(item(awake.isActive ? String(localized: "Turn Off") : String(localized: "Turn On"),
                         #selector(menuToggleKeepAwake), hotkey: .keepAwake))
        if awake.isActive && UtilitySettings.shared.keepAwakeLidClosed {
            // A status line, not a switch: the setting lives in Settings → Keep Awake
            let lid = NSMenuItem(title: awake.lid.isOn ? String(localized: "Lid closed: on") : String(localized: "Lid closed: off"),
                                 action: nil, keyEquivalent: "")
            lid.isEnabled = false
            sub.addItem(lid)
        }
        sub.addItem(.separator())
        for (i, d) in KeepAwake.durations.enumerated() {
            let mi = item(KeepAwake.title(for: d), #selector(keepAwakeFor(_:)))
            mi.tag = i
            mi.state = awake.isActive && awake.duration == d ? .on : .off
            sub.addItem(mi)
        }
        parent.submenu = sub
        return parent
    }

    private func hoverMenuItem() -> NSMenuItem {
        if let until = notch.hoverPausedUntil {
            let mi = item(String(localized: "Resume Hover"), #selector(resumeHover))
            mi.subtitle = String(localized: "Paused until \(until.formatted(date: .omitted, time: .shortened))")
            return mi
        }
        return item(String(localized: "Pause Hover for 1 Hour"), #selector(pauseHover))
    }

    /// A menu item aimed at this delegate. With a hotkey, the current shortcut shows as a real key equivalent,
    /// lined up on the right like in every other menu.
    private func item(_ title: String, _ action: Selector, hotkey: HotkeyAction? = nil, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        if let hotkey, let shortcut = HotkeyManager.shared.activeShortcut(for: hotkey),
           let equivalent = Self.keyEquivalent(for: shortcut.keyCode) {
            mi.keyEquivalent = equivalent
            mi.keyEquivalentModifierMask = Self.modifierFlags(carbon: shortcut.modifiers)
        }
        return mi
    }

    /// The menu key equivalent for a Carbon key code, or nil for keys menus can't show.
    static func keyEquivalent(for keyCode: UInt32) -> String? {
        let special: [Int: Int] = [
            kVK_LeftArrow: NSLeftArrowFunctionKey, kVK_RightArrow: NSRightArrowFunctionKey,
            kVK_UpArrow: NSUpArrowFunctionKey, kVK_DownArrow: NSDownArrowFunctionKey,
            kVK_F1: NSF1FunctionKey, kVK_F2: NSF2FunctionKey, kVK_F3: NSF3FunctionKey, kVK_F4: NSF4FunctionKey,
            kVK_F5: NSF5FunctionKey, kVK_F6: NSF6FunctionKey, kVK_F7: NSF7FunctionKey, kVK_F8: NSF8FunctionKey,
            kVK_F9: NSF9FunctionKey, kVK_F10: NSF10FunctionKey, kVK_F11: NSF11FunctionKey, kVK_F12: NSF12FunctionKey,
        ]
        if let scalar = special[Int(keyCode)].flatMap({ Unicode.Scalar(UInt32($0)) }) { return String(Character(scalar)) }
        switch Int(keyCode) {
        case kVK_Space: return " "
        case kVK_Return: return "\r"
        case kVK_Tab: return "\t"
        case kVK_Delete: return "\u{8}"
        case kVK_Escape: return "\u{1b}"
        default:
            let name = KeyNames.name(for: keyCode)
            return name.count == 1 && name != "?" ? name.lowercased() : nil
        }
    }

    static func modifierFlags(carbon: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    // MARK: - Hotkeys

    private func setupHotkeys() {
        let hk = HotkeyManager.shared
        for action in HotkeyAction.allCases {
            hk.setHandler(action) { PanelActions.perform(action) }
        }
        hk.registerAll()
    }

    // MARK: - Menu actions

    private func afterMenuCloses(_ action: @escaping @MainActor () -> Void) {
        pendingMenuAction = action
        if !menuIsOpen { DispatchQueue.main.async { [weak self] in self?.runPendingMenuAction() } }
    }

    private func runPendingMenuAction() {
        guard let action = pendingMenuAction else { return }
        pendingMenuAction = nil
        DispatchQueue.main.async { action() }
    }

    @objc private func menuToggle() { afterMenuCloses { PanelActions.perform(.toggle) } }
    @objc private func menuCapture() { afterMenuCloses { PanelActions.perform(.screenshot) } }
    @objc private func menuCaptureText() { afterMenuCloses { PanelActions.perform(.captureText) } }
    @objc private func menuPickColor() { afterMenuCloses { PanelActions.perform(.colorPicker) } }
    @objc private func menuToggleKeepAwake() { afterMenuCloses { PanelActions.perform(.keepAwake) } }

    @objc private func menuOpenTab(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tab = NotchTab(rawValue: raw) else { return }
        afterMenuCloses { [weak self] in self?.notch.open(tab: tab) }
    }

    @objc private func keepAwakeFor(_ sender: NSMenuItem) {
        guard KeepAwake.durations.indices.contains(sender.tag) else { return }
        let d = KeepAwake.durations[sender.tag]
        let awake = KeepAwake.shared
        awake.isActive && awake.duration == d ? awake.stop() : awake.start(for: d)
    }

    @objc private func timerStart(_ sender: NSMenuItem) {
        let presets = UtilitySettings.shared.timerPresets
        guard presets.indices.contains(sender.tag) else { return }
        Countdown.shared.start(minutes: presets[sender.tag])
    }

    @objc private func timerPause() { Countdown.shared.pause() }
    @objc private func timerResume() { Countdown.shared.resume() }
    @objc private func timerAddMinute() { Countdown.shared.addMinute() }
    @objc private func timerStop() { Countdown.shared.stop() }

    @objc private func pauseHover() { notch.pauseHover(for: 3600) }
    @objc private func resumeHover() { notch.pauseHover(for: 0) }

    @objc private func openSettings() {
        SettingsWindow.show()
    }

    @objc private func openAbout() {
        SettingsWindow.show(.about)
    }
}
