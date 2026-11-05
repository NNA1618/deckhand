import AppKit
@preconcurrency import Translation

extension SelfTest {
    /// Translation. Owned by the translate workstream. Pure logic only: no sessions, downloads or network.
    static func translate(_ check: Check) {
        targets(check)
        detection(check)
        languages(check)
        runs(check)
        selectionClipboard(check)
    }

    private static func targets(_ check: Check) {
        let t = TranslatorRules.target
        check(t("en", nil, "ru", "en") == "ru", "translate: English goes into the preferred language")
        check(t("ru", nil, "ru", "en") == "en", "translate: text in the preferred language goes into the second one")
        check(t("de", nil, "ru", "en") == "ru", "translate: other languages go into the preferred language")
        check(t("ru", nil, "ru", "ru") == "en", "translate: same first and second language falls back to English")
        check(t("en", nil, "en", "en") == "ru", "translate: English speakers fall back to Russian")
        check(t("en", "de", "ru", "en") == "de", "translate: a picked target wins")
        check(t("de", "de", "ru", "en") == "ru", "translate: text already in the picked target goes into the preferred one")
        check(t("ru", "ru", "ru", "en") == "en", "translate: text in a picked preferred language goes into the second one")
        check(t(nil, nil, "ru", "en") == "ru", "translate: unknown source uses the preferred language")
    }

    private static func detection(_ check: Check) {
        let supported: Set<String> = ["en", "ru", "uk", "de", "fr", "zh-Hans", "zh-Hant"]
        let mine = ["ru", "en"]
        func pick(_ h: [String: Double], letters: Int, previous: String? = nil) -> String? {
            TranslatorRules.detectedLanguage(hypotheses: h, letters: letters, previous: previous,
                                             preferred: mine, supported: supported)
        }
        check(pick(["de": 0.95], letters: 20) == "de", "detect: a clear winner")
        check(pick(["bg": 0.53, "ru": 0.42], letters: 6) == "ru", "detect: unsupported languages don't count")
        check(pick(["ca": 0.23, "fr": 0.09, "en": 0.03], letters: 1) == "en",
              "detect: one letter falls back to one of the user's languages")
        check(pick(["fr": 0.63, "en": 0.05], letters: 7) == "fr", "detect: a short but clear word")
        check(pick(["en": 0.4, "de": 0.45], letters: 30, previous: "en") == "en",
              "detect: the previous language is kept unless another is clearly ahead")
        check(pick(["en": 0.1, "de": 0.9], letters: 30, previous: "en") == "de",
              "detect: switches when another language is clearly ahead")
        check(pick([:], letters: 0) == nil, "detect: nothing for empty text")
        check(pick(["xx": 0.9], letters: 4) == nil, "detect: nothing when no supported language fits short text")

        let real = Set(TranslationLanguages.fallback)
        func recognize(_ text: String) -> String? {
            let (h, letters) = TranslatorRules.hypotheses(for: text, supported: real)
            return TranslatorRules.detectedLanguage(hypotheses: h, letters: letters, previous: nil,
                                                    preferred: mine, supported: real)
        }
        check(recognize("Hallo, wie geht es dir heute?") == "de", "detect: German sentence")
        check(recognize("Добрий день, як справи?") == "uk", "detect: Ukrainian is not taken for Russian")
        check(recognize("привет") == "ru", "detect: short Russian word")
        check(recognize("這是一個測試") == "zh-Hant", "detect: Traditional Chinese keeps its script")
    }

    private static func languages(_ check: Check) {
        let pairs: [(language: String, script: String?)] = [
            ("en", "Latn"), ("en", "Latn"), ("pt", "Latn"), ("pt", "Latn"),
            ("zh", "Hans"), ("zh", "Hant"), ("zh", "Hant"), ("ru", "Cyrl"),
        ]
        check(TranslationLanguages.codes(from: pairs) == ["en", "pt", "ru", "zh-Hans", "zh-Hant"],
              "languages: regional variants fold, scripts stay only for Chinese")
        let available: Set<String> = ["en", "pt", "nb", "zh-Hans", "zh-Hant"]
        let code = TranslationLanguages.code
        check(code("zh-Hant-TW", available) == "zh-Hant" && code("zh", available) == "zh-Hans",
              "languages: Chinese identifiers map to the right script")
        check(code("pt-PT", available) == "pt" && code("en-GB", available) == "en" && code("no", available) == "nb",
              "languages: regional and legacy identifiers map to codes")
        check(code("la", available) == nil, "languages: unsupported identifiers map to nothing")

        let ru = Locale(identifier: "ru")
        check(TranslationLanguages.name(of: "de", in: ru) == "Немецкий", "languages: names follow the app language, capitalized")
        check(TranslationLanguages.name(of: "de", in: Locale(identifier: "en")) == "German", "languages: English names")

        let all = ["de", "en", "fr", "ru", "uk"]
        let groups = TranslationLanguages.grouped(all: all, favorites: ["ru", "en", "xx"], recent: ["de", "ru"],
                                                  locale: Locale(identifier: "en"))
        check(groups.favorites == ["ru", "en"] && groups.recent == ["de"] && groups.rest == ["fr", "uk"],
              "languages: favorites, then recent, then the rest by name")
        check(TranslationLanguages.pushRecent("fr", into: ["de", "fr", "en", "ru"]) == ["fr", "de", "en", "ru"]
              && TranslationLanguages.pushRecent("uk", into: ["de", "fr", "en", "ru"]).count == 4,
              "languages: recent list moves to the front and stays short")
        check(TranslationLanguages.matching("нем", in: all, locale: ru) == ["de"]
              && TranslationLanguages.matching("germ", in: all, locale: ru) == ["de"],
              "languages: search by the app-language name and the English name")
        check(TranslationLanguages.speechIdentifier(for: "zh-Hant") == "zh-TW"
              && TranslationLanguages.speechIdentifier(for: "en") == "en-US",
              "languages: speech voices get a region")
    }

    private static func runs(_ check: Check) {
        check(TranslatorRules.hostUpdate(current: ("en", "ru"), source: "en", target: "ru") == .invalidate,
              "translate: the same languages re-run with invalidate()")
        check(TranslatorRules.hostUpdate(current: ("en", "ru"), source: "en", target: "de") == .replace
              && TranslatorRules.hostUpdate(current: nil, source: "en", target: "ru") == .replace,
              "translate: other languages get a new configuration")

        let a = TranslatorRules.Request(text: "Hello", source: "en", target: "ru")
        check(!TranslatorRules.needsRun(a, last: a, lastSucceededOrRunning: true), "translate: no second run of the same text")
        check(TranslatorRules.needsRun(a, last: a, lastSucceededOrRunning: false), "translate: a failed run can run again")
        check(TranslatorRules.needsRun(TranslatorRules.Request(text: "Hello", source: "en", target: "de"),
                                       last: a, lastSucceededOrRunning: true), "translate: new languages run")
        check(!TranslatorRules.needsRun(TranslatorRules.Request(text: "", source: "en", target: "ru"),
                                        last: nil, lastSucceededOrRunning: false), "translate: empty text never runs")

        check(TranslatorRules.shouldPrefill(enabled: true, inputEmpty: true, changeCount: 5, lastUsedChangeCount: 4),
              "translate: new clipboard text fills the empty field")
        check(!TranslatorRules.shouldPrefill(enabled: true, inputEmpty: true, changeCount: 5, lastUsedChangeCount: 5),
              "translate: the same clipboard doesn't come back after clearing")
        check(!TranslatorRules.shouldPrefill(enabled: true, inputEmpty: false, changeCount: 6, lastUsedChangeCount: 5)
              && !TranslatorRules.shouldPrefill(enabled: false, inputEmpty: true, changeCount: 6, lastUsedChangeCount: 5),
              "translate: no prefill over typed text or when turned off")

        let failure = TranslationEngine.failure
        check(failure(TranslationError.unsupportedLanguagePairing) as? TranslationFailure == .unsupported
              && failure(TranslationError.unableToIdentifyLanguage) as? TranslationFailure == .unrecognized
              && failure(TranslationError.internalError) as? TranslationFailure == .failed
              && failure(CancellationError()) is CancellationError,
              "translate: framework errors map to clear reasons")
        if #available(macOS 26.0, *) {
            check(failure(TranslationError.notInstalled) as? TranslationFailure == .needsDownload,
                  "translate: missing languages offer a download")
        }
    }

    /// Saving and restoring the clipboard around the ⌘C that reads a selection. Private pasteboard only.
    private static func selectionClipboard(_ check: Check) {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.nna1618.deckhand.selftest.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let custom = NSPasteboard.PasteboardType("com.example.deckhand.custom")
        let promise = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")

        pb.clearContents()
        let first = NSPasteboardItem()
        first.setString("original", forType: .string)
        first.setData(Data([1, 2, 3]), forType: custom)
        first.setData(Data("file:///tmp/x".utf8), forType: promise)
        let second = NSPasteboardItem()
        second.setString("second", forType: .string)
        pb.writeObjects([first, second])
        let saved = PasteboardContents.save(pb)
        check(saved.restores && saved.items.count == 2, "selection: the clipboard is saved item by item")
        check(!saved.items.joined().contains { $0.type == promise.rawValue },
              "selection: promised files are not read, so the copying app writes nothing out")

        pb.clearContents()
        pb.setString("selected text", forType: .string)
        saved.restore(to: pb)
        let items = pb.pasteboardItems ?? []
        check(items.count == 2 && items.first?.string(forType: .string) == "original"
              && items.first?.data(forType: custom) == Data([1, 2, 3])
              && items.last?.string(forType: .string) == "second",
              "selection: the clipboard comes back with every item and type")

        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"] {
            pb.clearContents()
            pb.declareTypes([.string, NSPasteboard.PasteboardType(marker)], owner: nil)
            pb.setString("hunter2", forType: .string)
            pb.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
            let secret = PasteboardContents.save(pb)
            pb.clearContents()
            pb.setString("selected text", forType: .string)
            let count = pb.changeCount
            secret.restore(to: pb)
            check(!secret.restores && secret.items.isEmpty && pb.changeCount == count
                  && pb.string(forType: .string) == "selected text",
                  "selection: a \(marker) copy is neither read nor put back")
        }
    }
}
