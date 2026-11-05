import AppKit

/// Accessory apps show no menu bar, but AppKit still routes key equivalents through the main menu.
/// Without one, ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z do nothing in Deckhand's text fields, and ⌘W and ⌘Q
/// do nothing in its windows. The menu also shows while Settings makes Deckhand a regular app.
///
/// Titles use their own `menu.*` keys: words like "Edit" and "Copy" are translated differently
/// in a menu («Правка», «Скопировать») than on a button elsewhere in the app.
@MainActor
enum MainMenu {
    static func install(settingsTarget: AnyObject, settingsAction: Selector) {
        let main = NSMenu()

        let app = NSMenu()
        let about = app.addItem(withTitle: String(localized: "menu.about", defaultValue: "About Deckhand"),
                                action: #selector(MenuActions.showAbout(_:)), keyEquivalent: "")
        about.target = MenuActions.shared
        app.addItem(.separator())
        let settings = app.addItem(withTitle: String(localized: "menu.settings", defaultValue: "Settings…"),
                                   action: settingsAction, keyEquivalent: ",")
        settings.target = settingsTarget
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "menu.hide", defaultValue: "Hide Deckhand"),
                    action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: String(localized: "menu.hideOthers", defaultValue: "Hide Others"),
                    action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: String(localized: "menu.showAll", defaultValue: "Show All"),
                    action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "menu.quit", defaultValue: "Quit Deckhand"),
                    action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, title: "Deckhand"))

        let edit = NSMenu(title: String(localized: "menu.edit", defaultValue: "Edit"))
        edit.addItem(withTitle: String(localized: "menu.undo", defaultValue: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: String(localized: "menu.redo", defaultValue: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "menu.cut", defaultValue: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "menu.copy", defaultValue: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "menu.paste", defaultValue: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "menu.pasteAndMatchStyle", defaultValue: "Paste and Match Style"),
                     action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
            .keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: String(localized: "menu.selectAll", defaultValue: "Select All"),
                     action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: edit.title))

        // Back, Forward and Search reach the Settings window controller through the responder chain,
        // so they are only enabled while Settings is the key window.
        let view = NSMenu(title: String(localized: "menu.view", defaultValue: "View"))
        view.addItem(withTitle: String(localized: "menu.back", defaultValue: "Back"),
                     action: #selector(SettingsWindowController.settingsGoBack(_:)), keyEquivalent: "[")
        view.addItem(withTitle: String(localized: "menu.forward", defaultValue: "Forward"),
                     action: #selector(SettingsWindowController.settingsGoForward(_:)), keyEquivalent: "]")
        view.addItem(.separator())
        view.addItem(withTitle: String(localized: "menu.search", defaultValue: "Search"),
                     action: #selector(SettingsWindowController.settingsFocusSearch(_:)), keyEquivalent: "f")
        main.addItem(submenu(view, title: view.title))

        let window = NSMenu(title: String(localized: "menu.window", defaultValue: "Window"))
        window.addItem(withTitle: String(localized: "menu.close", defaultValue: "Close"),
                       action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: String(localized: "menu.minimize", defaultValue: "Minimize"),
                       action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: String(localized: "menu.zoom", defaultValue: "Zoom"),
                       action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(submenu(window, title: window.title))

        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// Targets for menu items that have no natural place in the responder chain.
@MainActor
final class MenuActions: NSObject {
    static let shared = MenuActions()

    /// Opens Settings → About, which has the version, links and system info for bug reports.
    @objc func showAbout(_ sender: Any?) {
        SettingsWindow.show(.about)
    }
}
