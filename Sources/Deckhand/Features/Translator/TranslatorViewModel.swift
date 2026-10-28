import SwiftUI

@MainActor
final class TranslatorViewModel: ObservableObject {
    @Published var input: String = ""
    @Published var output: String = ""
    @Published var sourceLang: String = "en"
    @Published var targetLang: String = "ru"
    @Published var isTranslating: Bool = false
    @Published var error: String?

    /// Prefill with the clipboard text when the tab opens.
    func loadFromClipboardIfEmpty() {
        guard input.isEmpty else { return }
        if let s = NSPasteboard.general.string(forType: .string), !s.isEmpty {
            input = s
            refreshLanguages()
        }
    }

    func refreshLanguages() {
        if let detected = TranslatorService.detectLanguage(input) {
            sourceLang = detected
            targetLang = TranslatorService.pickTargetLanguage(sourceCode: detected)
        }
    }

    func swapLanguages() {
        swap(&sourceLang, &targetLang)
        swap(&input, &output)
    }

    func copyOutput() {
        guard !output.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(output, forType: .string)
    }
}
