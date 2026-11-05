import AppKit

/// What each shortcut does, in one place, so a global shortcut, a menu bar item and a row on Home
/// all behave the same way. Set up by the app delegate at launch.
@MainActor
enum PanelActions {
    /// The notch the actions act on.
    static weak var notch: NotchController?

    private static var last: (action: HotkeyAction, at: Date)?

    static func perform(_ action: HotkeyAction) {
        guard let notch else { return }
        // A menu item shows the same key equivalent as the global shortcut; if both fire for one key press,
        // run the action once
        if let last, last.action == action, Date().timeIntervalSince(last.at) < 0.3 { return }
        last = (action, Date())
        switch action {
        case .toggle: notch.toggle()
        case .screenshot: CaptureActions.captureArea(notch: notch)
        case .captureText: CaptureActions.captureText(notch: notch)
        case .colorPicker: CaptureActions.pickColor(notch: notch)
        case .keepAwake: UtilityNotices.toggleKeepAwake(notch: notch)
        case .translateSelection: TranslatorCoordinator.translateSelection(notch: notch)
        case .clipboard, .translator, .claude, .prompts, .media, .shelf, .recents:
            if let tab = tab(for: action) { notch.open(tab: tab) }
        }
    }

    /// The panel tab a shortcut opens, if it opens one.
    nonisolated static func tab(for action: HotkeyAction) -> NotchTab? {
        switch action {
        case .clipboard: return .clipboard
        case .translator: return .translator
        case .claude: return .claude
        case .prompts: return .prompts
        case .media: return .media
        case .shelf: return .shelf
        case .recents: return .recents
        case .toggle, .screenshot, .captureText, .colorPicker, .keepAwake, .translateSelection: return nil
        }
    }

    /// The shortcut that opens a tab, for menu items and tooltips.
    nonisolated static func action(for tab: NotchTab) -> HotkeyAction? {
        HotkeyAction.allCases.first { self.tab(for: $0) == tab }
    }
}
