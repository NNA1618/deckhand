import SwiftUI

/// The sections of the Settings window, in sidebar order.
/// Each one has its own pane file in this folder, owned by one area of the app.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general, notch, closedNotch
    case clipboard, translate, claude, music, prompts, recents
    case capture, keepAwake
    case shortcuts, permissions
    case about

    var id: String { rawValue }

    /// Sidebar groups, separated by space like System Settings.
    static let groups: [[SettingsSection]] = [
        [.general, .notch, .closedNotch],
        [.clipboard, .translate, .claude, .music, .prompts, .recents],
        [.capture, .keepAwake],
        [.shortcuts, .permissions],
        [.about],
    ]

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .notch: return String(localized: "Notch & Panel")
        case .closedNotch: return String(localized: "Closed Notch")
        case .clipboard: return String(localized: "Clipboard")
        case .translate: return String(localized: "Translate")
        case .claude: return String(localized: "Claude")
        case .music: return String(localized: "Music")
        case .prompts: return String(localized: "Prompts")
        case .recents: return String(localized: "Recents")
        case .capture: return String(localized: "Screenshots & Text")
        case .keepAwake: return String(localized: "Keep Awake & Timer")
        case .shortcuts: return String(localized: "Shortcuts")
        case .permissions: return String(localized: "Privacy & Permissions")
        case .about: return String(localized: "About")
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
        case .notch: return Color(white: 0.15)
        case .closedNotch: return .red
        case .clipboard: return .teal
        case .translate: return .indigo
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .music: return .pink
        case .prompts: return .green
        case .recents: return .orange
        case .capture: return .purple
        case .keepAwake: return .brown
        case .permissions: return .blue
        }
    }
}

/// A white symbol in a colored rounded square, as in System Settings.
struct SettingsIcon: View {
    let section: SettingsSection
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: section.symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(section.color.gradient, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
    }
}

/// One Settings pane: a grouped form with the section's title.
/// Panes put their `Section`s inside: `SettingsPane(.clipboard) { Section { … } }`.
struct SettingsPane<Content: View>: View {
    let section: SettingsSection
    private let content: Content

    init(_ section: SettingsSection, @ViewBuilder content: () -> Content) {
        self.section = section
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SettingsIcon(section: section, size: 26)
                Text(section.title)
                    .font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 34)
            .padding(.bottom, 2)
            Form {
                content
            }
            .formStyle(.grouped)
        }
    }
}
