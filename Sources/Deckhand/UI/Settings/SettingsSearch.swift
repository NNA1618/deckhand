import Foundation

/// Finds Settings sections by title, by the names of their settings and by synonyms.
/// It matches English and Russian whatever the app language is, so "hotkey" and the Russian
/// word for shortcut both lead to Shortcuts. Labels are lists separated by semicolons in the strings
/// file; the English and Russian lists must have the same length, so a match in one language
/// can be shown in the other.
enum SettingsSearch {
    struct Hit: Equatable {
        let section: SettingsSection
        /// The matching setting, in the app's language; nil when the title or a synonym matched.
        let detail: String?
    }

    /// One section's searchable text in one language.
    struct Entry {
        let title: String
        let labels: [String]
        let synonyms: [String]
    }

    /// Names of the settings in each section, as the panes show them.
    static func labelsTerm(_ section: SettingsSection) -> LocalizedTerm {
        let key = "search.\(section.rawValue).labels"
        switch section {
        case .general:
            return LocalizedTerm(key, "Open at login; Language; Show in the menu bar; Fill in copied text; Version; Reset All Settings")
        case .notch:
            return LocalizedTerm(key, "Open the panel; Hover delay; Hover area; Tab when opened; Don't open over full-screen apps; Close the panel; Close delay; Preview on Screen; Style; Tint; Size; Tabs; Open the Shelf when files are dragged to the notch; Display; Without a notch")
        case .closedNotch:
            return LocalizedTerm(key, "Badges; Hide in full screen; Notices; Screenshot copied; Text from screen; Color copied; Keep Awake on or off; Timer finished; Charger connected; Low battery; Claude finished a task; Claude needs you; Duration; Sounds")
        case .clipboard:
            return LocalizedTerm(key, "Keep for; Maximum; Save images; Largest image; Save copied files; On disk; Clear History; Return and double-click; Save copied passwords; Ignore apps")
        case .translate:
            return LocalizedTerm(key, "Translate into; Second language; Detect the language automatically; Source language; Favorite languages; Translation Languages")
        case .claude:
            return LocalizedTerm(key, "Connection; Run with; Claude Code; Location; API key; Model; Actions in the panel")
        case .codex:
            return LocalizedTerm(key, "Connection; Approve from the notch; Wait for an answer; Codex needs you; Codex finished a task; Sound")
        case .music:
            return LocalizedTerm(key, "Find out what's playing; Apple Music; Spotify; Yandex Music; Browser tabs")
        case .prompts:
            return LocalizedTerm(key, "Clicking a prompt; Fill in {{variables}} first; Sort; Import; Export; Restore Starter Prompts; Delete All Prompts")
        case .recents:
            return LocalizedTerm(key, "Folders; Add Folder; Period; Include subfolders; Show the prompt field; Link button")
        case .capture:
            return LocalizedTerm(key, "Capture area; After capture; Save to; Format; Shutter sound; Languages; Correct words; Keep line breaks; Pick a color; Copy as; Start with")
        case .keepAwake:
            return LocalizedTerm(key, "Default length; Let the display turn off; Turn off below; Timer presets; Alert until I dismiss it; Battery")
        case .shortcuts:
            return LocalizedTerm(key, "Open or close Deckhand; Capture an area; Capture an area and edit; Capture a window; Capture the whole screen; Capture the screen in 3 seconds; Copy text from the screen; Pick a color on the screen; Turn Keep Awake on or off; Translate selected text; Open a Tab; In the Panel; Close the panel; Editor tools")
        case .permissions:
            return LocalizedTerm(key, "Screen Recording; Accessibility; Automation; Files and Folders; Login Items; Your data; Logs")
        case .about:
            return LocalizedTerm(key, "Source code; Releases; Report a Problem; Copy System Info; Acknowledgements; License")
        }
    }

    /// Words people may type that aren't labels: older names, jargon, other apps' terms.
    static func synonymsTerm(_ section: SettingsSection) -> LocalizedTerm {
        let key = "search.\(section.rawValue).synonyms"
        switch section {
        case .general: return LocalizedTerm(key, "startup; launch; login items; menu bar icon; status item; English; Russian; reset; prefill")
        case .notch: return LocalizedTerm(key, "hover; click; activation; glass; liquid glass; transparent; solid; appearance; shelf; drag and drop; monitor; external display; full screen")
        case .closedNotch: return LocalizedTerm(key, "badge; notification; toast; sound; alert; battery; charging; music; timer")
        case .clipboard: return LocalizedTerm(key, "history; copy; paste; password; exclude; pin")
        case .translate: return LocalizedTerm(key, "translation; language; translator; detect")
        case .claude: return LocalizedTerm(key, "Anthropic; API; key; hook; sessions; Haiku; Sonnet; Opus; Keychain; AI")
        case .codex: return LocalizedTerm(key, "OpenAI; ChatGPT; hook; hooks.json; sessions; approvals; permissions; agent; AI")
        case .music: return LocalizedTerm(key, "now playing; track; song; player; YouTube; SoundCloud")
        case .prompts: return LocalizedTerm(key, "prompt; library; template; variables; JSON")
        case .recents: return LocalizedTerm(key, "downloads; images; videos; generations; watched folders")
        case .capture: return LocalizedTerm(key, "screenshot; OCR; recognize text; color picker; eyedropper; hex; editor; PNG")
        case .keepAwake: return LocalizedTerm(key, "caffeinate; sleep; awake; Amphetamine; timer; countdown; pomodoro")
        case .shortcuts: return LocalizedTerm(key, "hotkey; keyboard; global shortcut; key binding")
        case .permissions: return LocalizedTerm(key, "privacy; permission; security; data; storage; TCC")
        case .about: return LocalizedTerm(key, "GitHub; bug; issue; MIT; NNA1618; update; version")
        }
    }

    // MARK: - Index

    /// The Russian strings, read directly so Russian words match in the English app too.
    private static let russian: Bundle? = Bundle.main.path(forResource: "ru", ofType: "lproj").flatMap(Bundle.init(path:))

    /// The app's language first, then English, then Russian.
    static func entries(_ section: SettingsSection) -> [Entry] {
        [
            Entry(title: section.titleTerm.localized,
                  labels: split(labelsTerm(section).localized),
                  synonyms: split(synonymsTerm(section).localized)),
            entry(section, bundle: nil),
            entry(section, bundle: russian),
        ]
    }

    private static func entry(_ section: SettingsSection, bundle: Bundle?) -> Entry {
        Entry(title: section.titleTerm.value(in: bundle),
              labels: split(labelsTerm(section).value(in: bundle)),
              synonyms: split(synonymsTerm(section).value(in: bundle)))
    }

    static func split(_ list: String) -> [String] {
        list.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - Matching

    /// Sections that match, in sidebar order. An empty query matches everything.
    static func results(for query: String) -> [Hit] {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return SettingsSection.allCases.map { Hit(section: $0, detail: nil) } }
        return SettingsSection.allCases.compactMap { hit(tokens, section: $0, entries: entries($0)) }
    }

    /// Pure matching for one section, separate from the bundles so the self-test can feed it.
    static func hit(_ tokens: [String], section: SettingsSection, entries: [Entry]) -> Hit? {
        guard let current = entries.first else { return nil }
        // A setting's name is the most useful thing to show, so look for one first
        for entry in entries {
            for (i, label) in entry.labels.enumerated() where matches(tokens, label) {
                let shown = current.labels.count == entry.labels.count ? current.labels[i] : nil
                return Hit(section: section, detail: shown)
            }
        }
        let other = entries.contains { entry in
            matches(tokens, entry.title) || entry.synonyms.contains { matches(tokens, $0) }
        }
        return other ? Hit(section: section, detail: nil) : nil
    }

    static func tokenize(_ query: String) -> [String] {
        normalize(query).split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init)
    }

    /// Case, accents and width don't matter; this also makes "ё" and "е" the same.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Every token must start a word of the text; tokens of three letters or more may also
    /// appear inside a word ("клав" in a compound, "board" in "keyboard").
    static func matches(_ tokens: [String], _ text: String) -> Bool {
        let haystack = normalize(text)
        let words = haystack.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init)
        return tokens.allSatisfy { token in
            words.contains { $0.hasPrefix(token) } || (token.count >= 3 && haystack.contains(token))
        }
    }
}
