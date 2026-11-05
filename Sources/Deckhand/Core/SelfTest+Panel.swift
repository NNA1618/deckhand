import AppKit

extension SelfTest {
    /// Tabs, Home and the panel shell. Owned by the panel and utilities workstream.
    static func panel(_ check: Check) {
        let savedHidden = Settings.shared.hiddenTabs
        Settings.shared.hiddenTabs = ["prompts", "home"]
        check(!NotchTab.visible.contains(.prompts) && NotchTab.visible.first == .home, "hidden tabs leave the strip, Home stays")
        Settings.shared.hiddenTabs = savedHidden
    }
}
