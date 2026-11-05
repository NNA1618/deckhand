import AppKit

extension SelfTest {
    /// Tabs, Home and the panel shell. Owned by the panel and utilities workstream.
    static func panel(_ check: Check) {
        let visible = NotchTab.visible(hidden: ["prompts", "home"])
        check(!visible.contains(.prompts) && visible.first == .home, "hidden tabs leave the strip, Home stays")
    }
}
