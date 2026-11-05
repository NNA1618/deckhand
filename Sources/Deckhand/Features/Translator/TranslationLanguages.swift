import Foundation
@preconcurrency import Translation

/// The languages Apple Translation offers, as short codes ("en", "ru", "zh-Hant").
///
/// Apple lists regional variants separately (en-US, en-GB, en-IN, …). The tab folds them into one
/// language per code, and keeps the script only where it changes the language (Simplified and
/// Traditional Chinese), so the lists stay short enough for the notch panel.
enum TranslationLanguages {
    /// Used until `LanguageAvailability` answers, and if it never does.
    static let fallback = ["ar", "de", "en", "es", "fr", "hi", "id", "it", "ja", "ko", "nl", "pl", "pt", "ru",
                           "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant"]

    /// Folds `(language, script)` pairs into codes: the script is kept only for languages listed with
    /// more than one script.
    static func codes(from pairs: [(language: String, script: String?)]) -> [String] {
        var scripts: [String: Set<String>] = [:]
        for pair in pairs { scripts[pair.language, default: []].insert(pair.script ?? "") }
        var result = Set<String>()
        for pair in pairs {
            if let script = pair.script, !script.isEmpty, scripts[pair.language, default: []].count > 1 {
                result.insert("\(pair.language)-\(script)")
            } else {
                result.insert(pair.language)
            }
        }
        return result.sorted()
    }

    /// The code in `available` for a language identifier such as "zh-Hant-TW", "pt-PT" or "nb".
    static func code(for identifier: String, in available: Set<String>) -> String? {
        let language = Locale.Language(identifier: identifier)
        guard let base = language.languageCode?.identifier else { return nil }
        if let script = language.script?.identifier, available.contains("\(base)-\(script)") {
            return "\(base)-\(script)"
        }
        if available.contains(base) { return base }
        // "zh" alone means Simplified Chinese
        if let script = Locale.Language(identifier: base).maximalIdentifier.split(separator: "-").dropFirst().first,
           available.contains("\(base)-\(script)") {
            return "\(base)-\(script)"
        }
        // Norwegian: Translation lists Bokmål
        if base == "no", available.contains("nb") { return "nb" }
        return nil
    }

    /// The language Deckhand's own UI is shown in.
    static var appLanguageCode: String {
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        return code(for: preferred, in: Set(fallback)) ?? "en"
    }

    /// The locale for language names: names follow the app's language, not the system's.
    static var appLocale: Locale { Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en") }

    /// The second language when none is set: English, or Russian for English speakers.
    static func fallbackSecond(for first: String) -> String { first == "en" ? "ru" : "en" }

    /// "Русский", "Китайский (традиционное письмо)": the name in `locale` with a capital first letter.
    static func name(of code: String, in locale: Locale = appLocale) -> String {
        let raw = locale.localizedString(forIdentifier: code) ?? code
        guard let first = raw.first else { return code }
        return String(first).uppercased(with: locale) + raw.dropFirst()
    }

    /// Codes sorted by their names in `locale`.
    static func sortedByName(_ codes: [String], in locale: Locale = appLocale) -> [String] {
        codes.map { ($0, name(of: $0, in: locale)) }
            .sorted { $0.1.compare($1.1, locale: locale) == .orderedAscending }
            .map(\.0)
    }

    /// Splits `all` into favorites, recent languages that aren't favorites, and the rest by name.
    static func grouped(all: [String], favorites: [String], recent: [String], locale: Locale = appLocale)
        -> (favorites: [String], recent: [String], rest: [String]) {
        let available = Set(all)
        let fav = unique(favorites.filter(available.contains))
        let rec = unique(recent.filter { available.contains($0) && !fav.contains($0) })
        let shown = Set(fav + rec)
        return (fav, rec, sortedByName(all.filter { !shown.contains($0) }, in: locale))
    }

    /// `code` first, then the previous recent languages, at most `limit`.
    static func pushRecent(_ code: String, into recent: [String], limit: Int = 4) -> [String] {
        Array(([code] + recent.filter { $0 != code }).prefix(limit))
    }

    /// Codes whose name in the app language, the English name or the code itself contains `query`.
    static func matching(_ query: String, in codes: [String], locale: Locale = appLocale) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return codes }
        let english = Locale(identifier: "en")
        return codes.filter { code in
            [name(of: code, in: locale), name(of: code, in: english), code].contains {
                $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    /// "en-US" for speech: language plus the usual region.
    static func speechIdentifier(for code: String) -> String {
        let max = Locale.Language(identifier: code)
        let lang = max.languageCode?.identifier ?? code
        guard let region = Locale.Language(identifier: max.maximalIdentifier).region?.identifier else { return lang }
        return "\(lang)-\(region)"
    }

    private static func unique(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        return codes.filter { seen.insert($0).inserted }
    }
}

/// The supported languages, loaded once from `LanguageAvailability`.
@MainActor
final class TranslationCatalog: ObservableObject {
    static let shared = TranslationCatalog()
    @Published private(set) var codes: [String] = TranslationLanguages.fallback
    private var loaded = false

    private init() {}

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        Task {
            let languages = await LanguageAvailability().supportedLanguages
            let pairs = languages.compactMap { lang -> (language: String, script: String?)? in
                guard let code = lang.languageCode?.identifier else { return nil }
                return (code, Locale.Language(identifier: lang.maximalIdentifier).script?.identifier)
            }
            let codes = TranslationLanguages.codes(from: pairs)
            if !codes.isEmpty { self.codes = codes }
        }
    }
}
