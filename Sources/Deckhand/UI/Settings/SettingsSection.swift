import SwiftUI

/// The sections of the Settings window, in sidebar order.
/// Each one has its own pane file in this folder, owned by one area of the app.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general, notch, closedNotch
    case clipboard, translate, claude, codex, music, prompts, recents
    case capture, keepAwake
    case shortcuts, permissions
    case about

    var id: String { rawValue }

    /// Sidebar groups, separated by space like System Settings.
    static let groups: [[SettingsSection]] = [
        [.general, .notch, .closedNotch],
        [.clipboard, .translate, .claude, .codex, .music, .prompts, .recents],
        [.capture, .keepAwake],
        [.shortcuts, .permissions],
        [.about],
    ]

    /// The sidebar and toolbar title. Uses its own keys, because words like "General" and
    /// "Translate" mean something else elsewhere in the app.
    var title: String { titleTerm.localized }

    /// The one-line description under the title at the top of the pane.
    var subtitle: String { subtitleTerm.localized }

    var titleTerm: LocalizedTerm {
        switch self {
        case .general: return LocalizedTerm("section.general", "General")
        case .notch: return LocalizedTerm("section.notch", "Notch & Panel")
        case .closedNotch: return LocalizedTerm("section.closedNotch", "Closed Notch")
        case .clipboard: return LocalizedTerm("section.clipboard", "Clipboard")
        case .translate: return LocalizedTerm("section.translate", "Translate")
        case .claude: return LocalizedTerm("section.claude", "Claude")
        case .codex: return LocalizedTerm("section.codex", "Codex")
        case .music: return LocalizedTerm("section.music", "Music")
        case .prompts: return LocalizedTerm("section.prompts", "Prompts")
        case .recents: return LocalizedTerm("section.recents", "Recents")
        case .capture: return LocalizedTerm("section.capture", "Screenshots & Text")
        case .keepAwake: return LocalizedTerm("section.keepAwake", "Keep Awake & Timer")
        case .shortcuts: return LocalizedTerm("section.shortcuts", "Shortcuts")
        case .permissions: return LocalizedTerm("section.permissions", "Privacy & Permissions")
        case .about: return LocalizedTerm("section.about", "About")
        }
    }

    private var subtitleTerm: LocalizedTerm {
        switch self {
        case .general: return LocalizedTerm("section.general.subtitle", "Startup, language and the menu bar.")
        case .notch: return LocalizedTerm("section.notch.subtitle", "How the panel opens and closes, how it looks and which tabs it has.")
        case .closedNotch: return LocalizedTerm("section.closedNotch.subtitle", "What shows around the notch while the panel is closed.")
        case .clipboard: return LocalizedTerm("section.clipboard.subtitle", "History of what you copy. It never leaves this Mac.")
        case .translate: return LocalizedTerm("section.translate.subtitle", "On-device translation with Apple Translation.")
        case .claude: return LocalizedTerm("section.claude.subtitle", "Claude Code sessions in the notch and quick actions for text.")
        case .codex: return LocalizedTerm("section.codex.subtitle", "OpenAI Codex sessions in the notch, from Terminal, editors and the ChatGPT app.")
        case .music: return LocalizedTerm("section.music.subtitle", "What's playing, where it comes from and the track at the notch.")
        case .prompts: return LocalizedTerm("section.prompts.subtitle", "Your prompt library in the panel.")
        case .recents: return LocalizedTerm("section.recents.subtitle", "New images and videos from folders you choose.")
        case .capture: return LocalizedTerm("section.capture.subtitle", "Capture an area, copy text from the screen and pick colors.")
        case .keepAwake: return LocalizedTerm("section.keepAwake.subtitle", "Keep the Mac from sleeping and time short tasks.")
        case .shortcuts: return LocalizedTerm("section.shortcuts.subtitle", "Global shortcuts work in any app.")
        case .permissions: return LocalizedTerm("section.permissions.subtitle", "What Deckhand can use on this Mac and where your data lives.")
        case .about: return LocalizedTerm("section.about.subtitle", "Version, license and links.")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .notch: return "rectangle.topthird.inset.filled"
        case .closedNotch: return "bell.badge.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .translate: return "translate"
        case .claude: return "sparkle"
        case .codex: return AgentProvider.codex.fallbackSymbol
        case .music: return "music.note"
        case .prompts: return "text.quote"
        case .recents: return "photo.stack.fill"
        case .capture: return "camera.viewfinder"
        case .keepAwake: return "cup.and.saucer.fill"
        case .shortcuts: return "keyboard.fill"
        case .permissions: return "hand.raised.fill"
        case .about: return "info.circle.fill"
        }
    }

    /// The color of the rounded square behind the icon.
    var color: Color {
        switch self {
        case .general, .shortcuts, .about: return .gray
        case .notch: return Color(white: 0.22)
        case .closedNotch: return .red
        case .clipboard: return .teal
        case .translate: return .indigo
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color(white: 0.3)
        case .music: return .pink
        case .prompts: return .green
        case .recents: return .orange
        case .capture: return .purple
        case .keepAwake: return .brown
        case .permissions: return .blue
        }
    }
}

/// A string looked up by key with an English default, so the same key can also be read
/// in another language (the Settings search matches English and Russian whatever the app language is).
struct LocalizedTerm: Hashable, Sendable {
    let key: String
    let english: String

    init(_ key: String, _ english: String) {
        self.key = key
        self.english = english
    }

    /// In the app's language.
    var localized: String { Bundle.main.localizedString(forKey: key, value: english, table: nil) }

    /// In a specific `.lproj` bundle, or English when there is none.
    func value(in bundle: Bundle?) -> String {
        bundle?.localizedString(forKey: key, value: english, table: nil) ?? english
    }
}

/// A white symbol in a colored rounded square, as in System Settings.
struct SettingsIcon: View {
    let section: SettingsSection
    var size: CGFloat = 20

    var body: some View {
        if section == .claude, AgentProvider.claudeCode.appIcon != nil {
            // Claude's own icon from the installed Claude app, like System Settings shows app icons
            AgentIcon(provider: .claudeCode, size: size)
        } else if section == .codex, AgentProvider.codex.appIcon != nil {
            // Codex's own icon from the installed ChatGPT app (formerly the Codex app); Deckhand ships no logos
            AgentIcon(provider: .codex, size: size)
        } else {
            SettingsSymbolTile(symbol: section.symbol, color: section.color, size: size)
        }
    }
}

/// The rounded colored square used for sections and permission rows.
struct SettingsSymbolTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.235, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * 0.56, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
            .frame(width: size, height: size)
            .background(color.gradient, in: shape)
            // A hairline keeps dark tiles visible on a dark sidebar
            .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// One Settings pane: a hero card with the section's icon, title and description, then a grouped
/// form whose groups are translucent cards on the window's glass.
/// Panes put their `Section`s inside: `SettingsPane(.clipboard) { Section { … } }`.
struct SettingsPane<Content: View>: View {
    let section: SettingsSection
    private let showsHeader: Bool
    private let content: Content

    init(_ section: SettingsSection, showsHeader: Bool = true, @ViewBuilder content: () -> Content) {
        self.section = section
        self.showsHeader = showsHeader
        self.content = content()
    }

    var body: some View {
        Form {
            if showsHeader {
                Section {
                    SettingsHeroCard(section: section)
                }
            }
            content
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .hidingScrollEdgeEffect()
        .environment(\.colorScheme, .dark)
    }
}

extension View {
    /// The pane sits below the toolbar band, so macOS 26's blur under the toolbar isn't needed;
    /// it also can't be captured by `--snapshot` and would cover the pane there.
    @ViewBuilder
    func hidingScrollEdgeEffect() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .all)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// The card at the top of a pane, as in System Settings on macOS 26: a large icon,
/// the title in bold and one line about the section, centered.
struct SettingsHeroCard: View {
    let section: SettingsSection

    var body: some View {
        VStack(spacing: 8) {
            SettingsIcon(section: section, size: 54)
            Text(section.title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.fg)
            Text(section.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Theme.fgDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
