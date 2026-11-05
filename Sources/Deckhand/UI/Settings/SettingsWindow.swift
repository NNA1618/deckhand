import SwiftUI
import AppKit

/// Remembers the open section, so other parts of the app can open Settings at the right place.
@MainActor
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var selection: SettingsSection? = .general

    var section: SettingsSection {
        get { selection ?? .general }
        set { selection = newValue }
    }
}

/// The Settings window: a sidebar of sections and the selected pane, like System Settings.
/// The sidebar is a plain SwiftUI list rather than `NavigationSplitView`, which `--snapshot` can't capture.
struct SettingsView: View {
    @ObservedObject private var router = SettingsRouter.shared

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $router.selection)
                .frame(width: 220)
            Divider()
            SettingsDetail(section: router.section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}

struct SettingsSidebar: View {
    @Binding var selection: SettingsSection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(SettingsSection.groups.enumerated()), id: \.offset) { _, group in
                    ForEach(group) { section in
                        row(section)
                    }
                    Spacer().frame(height: 10)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 44)   // clear of the window buttons
        }
        .scrollIndicators(.never)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }

    private func row(_ section: SettingsSection) -> some View {
        let active = selection == section
        return Button { selection = section } label: {
            HStack(spacing: 8) {
                SettingsIcon(section: section)
                Text(section.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(active ? Color.white : Color.primary)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The pane for a section.
struct SettingsDetail: View {
    let section: SettingsSection

    var body: some View {
        switch section {
        case .general: GeneralPane()
        case .notch: NotchPane()
        case .closedNotch: ClosedNotchPane()
        case .clipboard: ClipboardPane()
        case .translate: TranslatePane()
        case .claude: ClaudePane()
        case .music: MusicPane()
        case .prompts: PromptsPane()
        case .recents: RecentsPane()
        case .capture: CapturePane()
        case .keepAwake: KeepAwakePane()
        case .shortcuts: ShortcutsPane()
        case .permissions: PermissionsPane()
        case .about: AboutPane()
        }
    }
}

// MARK: - Window

@MainActor
enum SettingsWindow {
    private(set) static var window: NSWindow?

    static func show(_ section: SettingsSection? = nil) {
        if let section { SettingsRouter.shared.section = section }
        if let window {
            AppActivation.windowOpened(window)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = String(localized: "Deckhand Settings")
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.contentViewController = NSHostingController(rootView: SettingsView())
        w.isReleasedWhenClosed = false
        w.setContentSize(NSSize(width: 760, height: 620))
        w.center()
        w.setFrameAutosaveName("DeckhandSettings")
        window = w
        AppActivation.windowOpened(w)
        w.makeKeyAndOrderFront(nil)
    }
}
