import Foundation

/// Translate settings, shown in Settings → Translate. Languages are stored as the short codes
/// used throughout the translator ("en", "ru", "zh-Hant", see `TranslationLanguages`).
@MainActor
final class TranslateSettings: ObservableObject {
    static let shared = TranslateSettings()
    private let d = UserDefaults.standard

    /// The language text is translated into.
    @Published var target: String { didSet { d.set(target, forKey: "translateTarget") } }
    /// Used instead of `target` when the text is already in the target language.
    @Published var secondLanguage: String { didSet { d.set(secondLanguage, forKey: "translateSecondLanguage") } }
    /// Recognize the language of the text; when off, `source` is always used.
    @Published var autoDetect: Bool { didSet { d.set(autoDetect, forKey: "translateAutoDetect") } }
    @Published var source: String { didSet { d.set(source, forKey: "translateSource") } }
    /// Shown first in the language lists and as one-click chips in the tab.
    @Published var favorites: [String] { didSet { d.set(favorites, forKey: "translateFavorites") } }
    /// Translate a moment after typing stops, without pressing the button.
    @Published var translateAsYouType: Bool { didSet { d.set(translateAsYouType, forKey: "translateAsYouType") } }
    /// Target languages used lately, newest first. Not a setting, but remembered between launches.
    @Published var recent: [String] { didSet { d.set(recent, forKey: "translateRecent") } }

    private init() {
        // The defaults follow the app language until the user picks something else
        let app = TranslationLanguages.appLanguageCode
        d.register(defaults: [
            "translateTarget": app,
            "translateSecondLanguage": TranslationLanguages.fallbackSecond(for: app),
            "translateAutoDetect": true,
            "translateSource": "en",
            "translateFavorites": ["ru", "en"],
            "translateAsYouType": true,
            "translateRecent": [String](),
        ])
        target = d.string(forKey: "translateTarget") ?? app
        secondLanguage = d.string(forKey: "translateSecondLanguage") ?? TranslationLanguages.fallbackSecond(for: app)
        autoDetect = d.bool(forKey: "translateAutoDetect")
        source = d.string(forKey: "translateSource") ?? "en"
        favorites = d.stringArray(forKey: "translateFavorites") ?? ["ru", "en"]
        translateAsYouType = d.bool(forKey: "translateAsYouType")
        recent = d.stringArray(forKey: "translateRecent") ?? []
    }

    func toggleFavorite(_ code: String) {
        if let i = favorites.firstIndex(of: code) { favorites.remove(at: i) } else { favorites.append(code) }
    }

    func noteUsed(target code: String) {
        let updated = TranslationLanguages.pushRecent(code, into: recent)
        if updated != recent { recent = updated }
    }
}
