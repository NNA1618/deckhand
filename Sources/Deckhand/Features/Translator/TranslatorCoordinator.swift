import AppKit

/// Entry points into translation from outside the Translate tab, such as the
/// "Translate selected text" shortcut. Owned by the translate workstream.
@MainActor
enum TranslatorCoordinator {
    /// Opens the Translate tab with the selected text, or the clipboard text if nothing is selected.
    static func translateSelection(notch: NotchController) {
        notch.open(tab: .translator)
    }
}
