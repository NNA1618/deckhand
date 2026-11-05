import Foundation
import NaturalLanguage

/// The translator's decisions as pure functions, so the self-test can check them without
/// Apple Translation, installed languages or the network.
enum TranslatorRules {
    // MARK: - Target language

    /// The language to translate into.
    ///
    /// - A target the user picked in the tab wins, unless the text is already in that language;
    ///   then the text goes into the preferred language (or the second one, if that's the same).
    /// - Otherwise text goes into the preferred language, and text already in it into the second one.
    static func target(source: String?, pinned: String?, preferred: String, second: String) -> String {
        let other = second != preferred ? second : TranslationLanguages.fallbackSecond(for: preferred)
        if let pinned {
            guard pinned == source else { return pinned }
            return pinned != preferred ? preferred : other
        }
        return source == preferred ? other : preferred
    }

    // MARK: - Detection

    /// Fewer letters than this count as short text, which needs a clearer winner.
    static let shortTextLetters = 10

    /// Picks the source language from recognizer hypotheses (codes → probability).
    ///
    /// Only languages Translation supports count. The user's own languages get a mild boost, a short
    /// word falls back to one of them, and a previous result is kept unless another language is clearly
    /// ahead, so the label doesn't flicker while typing.
    static func detectedLanguage(hypotheses: [String: Double], letters: Int, previous: String?,
                                 preferred: [String], supported: Set<String>) -> String? {
        guard letters > 0 else { return nil }
        let boosted = Dictionary(uniqueKeysWithValues: hypotheses.compactMap { code, p -> (String, Double)? in
            guard supported.contains(code) else { return nil }
            return (code, preferred.contains(code) ? min(1, p * 1.5) : p)
        })
        let top = boosted.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }
        let threshold = letters < shortTextLetters ? 0.5 : 0.3
        if let top, top.value >= threshold {
            if let previous, previous != top.key, let p = boosted[previous], p >= 0.15, top.value - p < 0.2 {
                return previous
            }
            return top.key
        }
        if let previous, (boosted[previous] ?? 0) >= 0.02 { return previous }
        let mine = preferred.compactMap { code in boosted[code].map { (code, $0) } }
            .filter { $0.1 >= 0.02 }
            .max { $0.1 < $1.1 }
        if let mine { return mine.0 }
        return letters >= shortTextLetters ? top?.key : nil
    }

    /// Recognizer hypotheses for `text` as translator codes. Only the start of long text is read.
    static func hypotheses(for text: String, supported: Set<String>) -> (hypotheses: [String: Double], letters: Int) {
        let sample = String(text.prefix(600))
        let letters = sample.unicodeScalars.filter(CharacterSet.letters.contains).count
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        var result: [String: Double] = [:]
        for (language, p) in recognizer.languageHypotheses(withMaximum: 30) {
            guard let code = TranslationLanguages.code(for: language.rawValue, in: supported) else { continue }
            result[code, default: 0] += p
        }
        return (result, letters)
    }

    // MARK: - Running translations

    struct Request: Equatable, Sendable {
        var text: String
        var source: String
        var target: String
    }

    /// Whether `request` needs a new run: not when the same text and languages already ran or are running.
    static func needsRun(_ request: Request, last: Request?, lastSucceededOrRunning: Bool) -> Bool {
        guard !request.text.isEmpty else { return false }
        return !(request == last && lastSucceededOrRunning)
    }

    enum HostUpdate: Equatable { case invalidate, replace }

    /// `.translationTask` runs again only when its configuration changes: the same languages need
    /// `invalidate()`, other languages a new configuration.
    static func hostUpdate(current: (source: String?, target: String?)?, source: String, target: String) -> HostUpdate {
        guard let current, current.source == source, current.target == target else { return .replace }
        return .invalidate
    }

    enum HostChoice: Equatable { case use(Int), create, wait }

    /// Which hidden window runs the next macOS 15 translation: the first free one, a new one while
    /// there are fewer than `max`, or none yet, because each is finishing a run that was cancelled or
    /// timed out (Apple's call can't be stopped).
    static func hostChoice(busy: [Bool], max: Int) -> HostChoice {
        if let free = busy.firstIndex(of: false) { return .use(free) }
        return busy.count < max ? .create : .wait
    }

    /// Copied text goes into the tab only when the field is empty, the setting is on, and the clipboard
    /// changed since the last time, so clearing the field doesn't bring the same text back.
    static func shouldPrefill(enabled: Bool, inputEmpty: Bool, changeCount: Int, lastUsedChangeCount: Int?) -> Bool {
        enabled && inputEmpty && changeCount != lastUsedChangeCount
    }

    /// Seconds after the last keystroke before translating as you type.
    static let typingDelay: Double = 0.6
    /// Seconds a translation may take before the tab gives up waiting.
    static let timeout: Double = 20
}
