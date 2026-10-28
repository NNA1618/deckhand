import Foundation
import NaturalLanguage

/// Translation helpers: language detection and picking the target language.
///
/// The translation itself runs in SwiftUI through `.translationTask()`,
/// Apple exposes Translation sessions only to SwiftUI views.
enum TranslatorService {
    static func detectLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    /// English goes to Russian, Russian to English, anything else to Russian.
    static func pickTargetLanguage(sourceCode: String) -> String {
        switch sourceCode {
        case "en": return "ru"
        case "ru": return "en"
        default: return "ru"
        }
    }

    /// Language name for the UI in the user's language.
    static func name(of code: String) -> String {
        let locale = Locale.current
        return (locale.localizedString(forLanguageCode: code) ?? code).capitalized(with: locale)
    }
}
