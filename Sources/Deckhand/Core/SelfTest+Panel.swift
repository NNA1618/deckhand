import AppKit

extension SelfTest {
    /// Tabs, Home and the panel shell. Owned by the panel and utilities workstream.
    static func panel(_ check: Check) {
        let visible = NotchTab.visible(hidden: ["prompts", "home"])
        check(!visible.contains(.prompts) && visible.first == .home, "hidden tabs leave the strip, Home stays")

        // Order: Home first, stored order, unknown names dropped, new tabs appended, hidden left out
        let ordered = PanelSettings.ordered(order: ["shelf", "home", "bogus", "clipboard", "shelf"], hidden: ["recents"])
        check(ordered.prefix(3) == [.home, .shelf, .clipboard], "tab order: Home first, then the stored order (\(ordered.map(\.rawValue)))")
        check(Set(ordered).count == ordered.count && !ordered.contains(.recents)
              && ordered.count == NotchTab.allCases.count - 1, "tab order: no duplicates, missing tabs kept, hidden left out")
        check(PanelSettings.ordered(order: [], hidden: []) == NotchTab.allCases, "tab order: empty order means the default")

        // A hidden tab opened by its shortcut shows in the strip at its place
        let strip = PanelSettings.strip(order: ["shelf", "clipboard"], hidden: ["clipboard"], current: .clipboard)
        check(strip.prefix(3) == [.home, .shelf, .clipboard], "strip shows a hidden current tab in place")
        check(!PanelSettings.strip(order: [], hidden: ["clipboard"], current: .home).contains(.clipboard),
              "strip leaves hidden tabs out otherwise")

        // Tab when opened
        let shown: [NotchTab] = [.home, .clipboard, .media]
        check(PanelSettings.tabWhenOpened(choice: "last", last: "media", visible: shown) == .media, "opens on the last tab")
        check(PanelSettings.tabWhenOpened(choice: "last", last: "prompts", visible: shown) == .home,
              "a hidden last tab opens Home")
        check(PanelSettings.tabWhenOpened(choice: "clipboard", last: "media", visible: shown) == .clipboard, "opens on the chosen tab")
        check(PanelSettings.tabWhenOpened(choice: "nonsense", last: "media", visible: shown) == .home, "unknown choice opens Home")

        // Keyboard
        check(PanelSettings.neighbor(of: .media, in: shown, step: 1) == .home
              && PanelSettings.neighbor(of: .home, in: shown, step: -1) == .media, "⌃Tab wraps around")
        check(PanelSettings.neighbor(of: .shelf, in: shown, step: 1) == .home, "unknown current tab goes to the first")
        check(PanelContent.tabStep(keyCode: 48, modifiers: .control, editingText: true) == 1
              && PanelContent.tabStep(keyCode: 48, modifiers: [.control, .shift], editingText: true) == -1,
              "⌃Tab and ⌃⇧Tab work even in a text field")
        check(PanelContent.tabStep(keyCode: 123, modifiers: [], editingText: false) == -1
              && PanelContent.tabStep(keyCode: 124, modifiers: [], editingText: true) == nil
              && PanelContent.tabStep(keyCode: 124, modifiers: .command, editingText: false) == nil,
              "← → switch tabs only outside text fields and without modifiers")

        // Shortcuts on Home run their actions; tab shortcuts map both ways
        check(NotchTab.allCases.allSatisfy { $0 == .home || PanelActions.action(for: $0).flatMap(PanelActions.tab(for:)) == $0 },
              "every tab but Home has a shortcut that opens it")
        check(PanelActions.tab(for: .screenshot) == nil, "Capture Area captures instead of switching tabs")

        // Hint follows the activation setting and never hard-codes a shortcut
        check(HomeView.hint(hover: false, shortcut: "⌃⌥X").contains("⌃⌥X")
              && HomeView.hint(hover: false, shortcut: nil) != HomeView.hint(hover: true, shortcut: "⌃⌥X"),
              "Home hint follows the settings")

        // Menu key equivalents
        check(AppDelegate.keyEquivalent(for: 49) == " " && AppDelegate.keyEquivalent(for: 123) != nil,
              "menu shows Space and arrows as key equivalents")
        check(AppDelegate.modifierFlags(carbon: UInt32(0x1000 | 0x0800)) == [.control, .option], "Carbon modifiers map to menu modifiers")
    }
}
