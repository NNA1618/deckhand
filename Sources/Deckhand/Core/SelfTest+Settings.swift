import AppKit

extension SelfTest {
    /// The Settings window. Owned by the Settings workstream. Pure checks: no window, no defaults.
    static func settings(_ check: Check) {
        sectionOrder(check)
        searchMatching(check)
        searchStrings(check)
        settingsHelpers(check)
    }

    private static func sectionOrder(_ check: Check) {
        let flat = SettingsSection.groups.flatMap { $0 }
        check(flat == SettingsSection.allCases, "settings: sidebar groups list every section once, in order")
        check(SettingsSection.groups.first?.first == .general && flat.last == .about, "settings: General first, About last")
        check(SettingsSection.allCases.allSatisfy { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil },
              "settings: every section symbol exists")
        check(Set(SettingsSection.allCases.map(\.titleTerm.key)).count == SettingsSection.allCases.count,
              "settings: section title keys are distinct")
    }

    private static func searchMatching(_ check: Check) {
        typealias Entry = SettingsSearch.Entry
        let english = Entry(title: "Shortcuts", labels: ["Open or close Deckhand", "In the panel"], synonyms: ["hotkey", "keyboard"])
        let russian = Entry(title: "Sochetaniya", labels: ["Otkryt ili zakryt Deckhand", "V paneli"], synonyms: ["khotkey"])
        let entries = [english, english, russian]
        func hit(_ query: String) -> SettingsSearch.Hit? {
            SettingsSearch.hit(SettingsSearch.tokenize(query), section: .shortcuts, entries: entries)
        }
        check(hit("hotkey")?.detail == nil && hit("hotkey") != nil, "settings search: a synonym finds the section")
        check(hit("KEYB") != nil, "settings search: case doesn't matter")
        check(hit("board") != nil, "settings search: three letters match inside a word")
        check(hit("pa") != nil && hit("ne") == nil, "settings search: short tokens only match word starts")
        check(hit("close deck")?.detail == "Open or close Deckhand", "settings search: several words match one label")
        check(hit("v panel")?.detail == "In the panel", "settings search: a match in another language shows the app's label")
        check(hit("volume") == nil, "settings search: unrelated words find nothing")
        check(SettingsSearch.normalize("Чёлка") == SettingsSearch.normalize("челка"), "settings search: ё and е are the same")
        check(SettingsSearch.results(for: "  ").count == SettingsSection.allCases.count, "settings search: empty query lists everything")
        check(SettingsSearch.results(for: "hotkey").map(\.section) == [.shortcuts], "settings search: hotkey leads to Shortcuts")
        check(SettingsSearch.results(for: "OCR").map(\.section) == [.capture], "settings search: OCR leads to Screenshots & Text")
        check(SettingsSearch.results(for: "API").contains { $0.section == .claude }, "settings search: API leads to Claude")
        check(SettingsSearch.results(for: "zzzz").isEmpty, "settings search: nonsense finds nothing")
        var buffer = TypeSelectBuffer()
        let start = Date()
        let all = SettingsSection.allCases
        let englishTitle: (SettingsSection) -> String = { $0.titleTerm.english }
        check(buffer.append("c", among: all, now: start, title: englishTitle) == .closedNotch, "settings: type-select picks the first match")
        check(buffer.append("li", among: all, now: start.addingTimeInterval(0.3), title: englishTitle) == .clipboard,
              "settings: type-select extends the prefix")
        check(buffer.append("s", among: all, now: start.addingTimeInterval(2), title: englishTitle) == .capture,
              "settings: type-select starts over after a pause")
    }

    /// Labels in English and Russian must line up, so a match in one language can be shown in the other.
    private static func searchStrings(_ check: Check) {
        guard let path = Bundle.main.path(forResource: "ru", ofType: "lproj"), let ru = Bundle(path: path) else { return }
        for section in SettingsSection.allCases {
            let term = SettingsSearch.labelsTerm(section)
            let en = SettingsSearch.split(term.english)
            let translated = SettingsSearch.split(term.value(in: ru))
            check(en.count == translated.count && term.value(in: ru) != term.english,
                  "settings search: \(section.rawValue) labels translated, \(en.count) = \(translated.count)")
            check(section.titleTerm.value(in: ru) != section.titleTerm.english || section == .claude,
                  "settings: \(section.rawValue) title translated")
        }
        let shortcuts = SettingsSearch.entries(.shortcuts)
        check(shortcuts.count == 3 && shortcuts[2].title != "Shortcuts", "settings search: Russian entries are read from ru.lproj")
    }

    private static func settingsHelpers(_ check: Check) {
        check(!AppRelauncher.needsRestart(chosen: "ru", launched: "ru"), "settings: same language needs no restart")
        check(AppRelauncher.needsRestart(chosen: "system", launched: "en"), "settings: another language needs a restart")
        check(GeneralPane.endonym("en") == "English", "settings: English is named in English")
        let info = SystemInfo.format(version: "0.5.0 (6)", macOS: "26.5.1", build: "25F80", model: "Mac15,6", language: "ru")
        check(info.contains("Deckhand version: 0.5.0 (6)") && info.contains("macOS version: 26.5.1 (25F80)")
              && info.contains("Mac model: Mac15,6"), "settings: system info has what the bug template asks for")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("deckhand-selftest-\(UUID().uuidString)")
        try? Data(count: 5000).write(to: file)
        check((PermissionsModel.size(of: file) ?? 0) >= 5000, "settings: data size counts a file")
        try? FileManager.default.removeItem(at: file)
        check(PermissionsModel.size(of: file) == nil, "settings: a missing file has no size")
    }
}
