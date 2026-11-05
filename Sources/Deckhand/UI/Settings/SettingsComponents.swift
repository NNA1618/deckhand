import SwiftUI
import AppKit

// Building blocks for Settings panes, drawn in the notch panel's visual language (white accent,
// translucent cards, Theme text colors), so every pane shows rows, statuses, links and resets the same way.
// They all work inside `SettingsPane(.x) { Section { … } }`.

// MARK: - Cards

extension View {
    /// A translucent card like the panel's cards: glass on macOS 26, a flat fill in snapshots and
    /// with the Solid style, and a hairline edge so it reads on very clear glass.
    func settingsCard(cornerRadius: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .glassChip(in: shape)
            .overlay(shape.strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

// MARK: - Buttons

/// A capsule button like the panel's: `.prominent` is the white `PrimaryButton`, the default is a
/// translucent `GlassButton`, `.destructive` has red text. Use `.buttonStyle(.settings)` or
/// `.buttonStyle(.settings(.prominent))` on a plain `Button`.
struct SettingsButtonStyle: ButtonStyle {
    enum Kind { case normal, prominent, destructive }
    var kind: Kind = .normal

    func makeBody(configuration: Configuration) -> some View {
        SettingsButtonBody(configuration: configuration, kind: kind)
    }
}

private struct SettingsButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: SettingsButtonStyle.Kind
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(Theme.label)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: kind == .prominent ? 0 : 0.5))
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .fixedSize()
    }

    private var foreground: Color {
        switch kind {
        case .prominent: return .black
        case .destructive: return Color(red: 1, green: 0.42, blue: 0.4)
        case .normal: return Theme.fg
        }
    }

    private var fill: Color {
        kind == .prominent ? Theme.accent : Theme.surface2
    }
}

extension ButtonStyle where Self == SettingsButtonStyle {
    static var settings: SettingsButtonStyle { SettingsButtonStyle() }
    static func settings(_ kind: SettingsButtonStyle.Kind) -> SettingsButtonStyle { SettingsButtonStyle(kind: kind) }
}

// MARK: - Status

/// A colored dot and a short word, the way System Settings shows "Connected" or "Off".
struct StatusChip: View {
    enum Kind {
        /// Allowed, connected, on.
        case good
        /// Needs the user: not allowed, needs approval.
        case attention
        /// Neutral: not asked yet, off, not running.
        case neutral
        /// Broken: an error.
        case error

        var color: Color {
            switch self {
            case .good: return Color(red: 0.2, green: 0.84, blue: 0.4)
            case .attention: return Theme.warn
            case .neutral: return Theme.fgMute
            case .error: return Color(red: 1, green: 0.32, blue: 0.3)
            }
        }
    }

    let text: String
    let kind: Kind

    init(_ text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(kind.color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(Theme.label)
                .foregroundStyle(Theme.fgDim)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Theme.surface))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Rows

/// The icon at the start of a row: a colored tile with a symbol, or an app's icon.
enum SettingsRowIcon {
    case symbol(String, Color)
    case image(NSImage)
    case section(SettingsSection)

    @ViewBuilder var view: some View {
        switch self {
        case .symbol(let name, let color):
            SettingsSymbolTile(symbol: name, color: color, size: 24)
        case .section(let section):
            SettingsIcon(section: section, size: 24)
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
        }
    }
}

/// A row with an optional icon, a title, an optional caption under it and controls at the end.
/// `SettingsRow("Screen Recording", detail: "Screenshots", icon: .symbol("record.circle", .red)) { StatusChip(…) }`
struct SettingsRow<Accessory: View>: View {
    let title: String
    var detail: String?
    var icon: SettingsRowIcon?
    /// Keeps the caption on one line, cut in the middle: for paths.
    var detailIsPath = false
    private let accessory: Accessory

    init(_ title: String, detail: String? = nil, icon: SettingsRowIcon? = nil, detailIsPath: Bool = false,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.detailIsPath = detailIsPath
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 10) {
            icon?.view
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .foregroundStyle(Theme.fg)
                if let detail {
                    if detailIsPath {
                        Text(detail)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.fgMute)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(detail)
                    } else {
                        Text(detail)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.fgMute)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.vertical, icon == nil ? 0 : 1)
    }
}

/// A switch row with an optional caption. The switch uses the system style, as in System Settings.
struct SettingsToggleRow: View {
    let title: String
    var detail: String?
    var icon: SettingsRowIcon?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, icon: SettingsRowIcon? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self._isOn = isOn
    }

    var body: some View {
        SettingsRow(title, detail: detail, icon: icon) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A choice between two to four short options, drawn like the panel's chips: the chosen one is a
/// white capsule with black text. Use it where the panel uses chips; menus stay `Picker`.
struct ChipPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    init(_ title: String, selection: Binding<Value>, options: [(value: Value, label: String)]) {
        self.title = title
        self._selection = selection
        self.options = options
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .foregroundStyle(Theme.fg)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                ForEach(options, id: \.value) { option in
                    let active = option.value == selection
                    Button { selection = option.value } label: {
                        Text(option.label)
                            .font(Theme.label)
                            .foregroundStyle(active ? Color.black : Theme.fgDim)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(active ? Theme.accent : Color.clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
            .padding(2)
            .background(Capsule().fill(Theme.surface))
            .fixedSize()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// A row that leads somewhere: another Settings section (with a chevron) or a web page (with an arrow).
/// Use it for "one home per setting": a pane links to the section that owns a setting instead of repeating it.
struct SettingsLinkRow: View {
    enum Destination: Equatable {
        case section(SettingsSection)
        case url(URL)
        case action(String)
    }

    let title: String
    var value: String?
    var icon: SettingsRowIcon?
    let destination: Destination
    private let perform: (() -> Void)?
    @State private var hovering = false

    init(_ title: String, value: String? = nil, icon: SettingsRowIcon? = nil, to destination: Destination) {
        self.title = title
        self.value = value
        self.icon = icon
        self.destination = destination
        self.perform = nil
    }

    /// A row with a chevron that runs `action`, such as opening a sheet or a System Settings pane.
    init(_ title: String, value: String? = nil, icon: SettingsRowIcon? = nil, action: @escaping () -> Void) {
        self.title = title
        self.value = value
        self.icon = icon
        self.destination = .action(title)
        self.perform = action
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                icon?.view
                Text(title)
                    .foregroundStyle(Theme.fg)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .foregroundStyle(Theme.fgDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Image(systemName: chevron)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? Theme.fgDim : Theme.fgMute)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, icon == nil ? 0 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var chevron: String {
        if case .url = destination { return "arrow.up.right" }
        return "chevron.right"
    }

    private var help: String {
        switch destination {
        case .section(let section): return String(localized: "Opens \(section.title)")
        case .url(let url): return url.host() ?? url.absoluteString
        case .action: return title
        }
    }

    private func open() {
        switch destination {
        case .section(let section): SettingsRouter.shared.section = section
        case .url(let url): NSWorkspace.shared.open(url)
        case .action: perform?()
        }
    }
}

/// Opens a System Settings pane, only when the user clicks.
enum SystemSettingsLink {
    static let screenRecording = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    static let accessibility = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let automation = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
    static let filesAndFolders = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
    static let languageAndRegion = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!

    static func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

/// "Show in Finder" for a file or folder; disabled when it doesn't exist.
struct RevealInFinderButton: View {
    let url: URL

    var body: some View {
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        .buttonStyle(.settings)
        .disabled(!FileManager.default.fileExists(atPath: url.path))
    }
}

// MARK: - Confirmation

/// A button that asks before it acts. The alert names what happens and what stays.
struct ConfirmedButton: View {
    let title: String
    let alertTitle: String
    let message: String
    let confirmTitle: String
    var kind: SettingsButtonStyle.Kind = .destructive
    let action: () -> Void
    @State private var asking = false

    var body: some View {
        Button(title) { asking = true }
            .buttonStyle(.settings(kind))
            .alert(alertTitle, isPresented: $asking) {
                Button(confirmTitle, role: .destructive, action: action)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(message)
            }
    }
}

/// "Restore Defaults…" for one pane, with a confirmation that names the section.
/// Put it in `SettingsPaneActions` at the bottom of the pane.
struct RestoreDefaultsButton: View {
    let section: SettingsSection
    var message: String? = nil
    let action: () -> Void

    var body: some View {
        ConfirmedButton(
            title: String(localized: "Restore Defaults…"),
            alertTitle: String(localized: "Restore the default settings for “\(section.title)”?"),
            message: message ?? String(localized: "Only settings in this section change. Your data stays."),
            confirmTitle: String(localized: "Restore"),
            kind: .normal,
            action: action
        )
    }
}

/// Buttons at the bottom right of a pane, below the last group, as in System Settings.
/// `SettingsPaneActions { RestoreDefaultsButton(section: .notch) { … } }`
struct SettingsPaneActions<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Section {
        } footer: {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                content
            }
        }
    }
}

/// A footer line in the panel's caption style. Grouped forms already dim footers; this matches
/// the size and color to the panel.
struct SettingsFooter: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.caption)
            .foregroundStyle(Theme.fgMute)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Window activation

extension View {
    /// Runs `action` when the pane appears and each time the Settings window becomes key again,
    /// so statuses changed in System Settings or Terminal show up without reopening the pane.
    func onSettingsActivation(perform action: @escaping @MainActor () async -> Void) -> some View {
        modifier(SettingsActivationModifier(action: action))
    }
}

private struct SettingsActivationModifier: ViewModifier {
    @ObservedObject private var router = SettingsRouter.shared
    let action: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content.task(id: router.activation) { await action() }
    }
}
