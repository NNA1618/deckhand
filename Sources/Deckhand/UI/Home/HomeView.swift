import SwiftUI

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var vm: NotchViewModel
    @ObservedObject private var hotkeys = HotkeyManager.shared

    private func tab(for action: HotkeyAction) -> NotchTab? {
        switch action {
        case .toggle: return nil
        case .screenshot, .clipboard: return .clipboard
        case .captureText, .colorPicker, .keepAwake: return nil
        case .translator, .translateSelection: return .translator
        case .claude: return .claude
        case .prompts: return .prompts
        case .media: return .media
        case .shelf: return .shelf
        case .recents: return .recents
        }
    }

    /// The shortcuts worth seeing at a glance; the rest are in Settings.
    private let featured: [HotkeyAction] = [.toggle, .screenshot, .clipboard, .captureText, .keepAwake]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                BrandMark(size: 20)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
                Text("Deckhand")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Theme.fg)
                Text("NNA1618")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.fgMute)
                Spacer()
                Text("Hover to open · Esc to close · Drop files on the notch")
                    .font(Theme.caption)
                    .foregroundColor(Theme.fgMute)
                    .lineLimit(1)
            }
            HStack(alignment: .top, spacing: 12) {
                KeepAwakeCard()
                TimerCard()
                QuickTogglesCard()
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                ClaudeSessionsCard(limit: 3)
                    .frame(maxWidth: .infinity)
                shortcuts
                    .frame(width: 250)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Shortcuts").font(Theme.label).foregroundColor(Theme.fg)
                Spacer()
                Button {
                    vm.requestClose()
                    SettingsRouter.shared.section = .shortcuts
                    SettingsWindow.show()
                } label: {
                    Text("All").font(Theme.label).foregroundColor(Theme.fgDim)
                }
                .buttonStyle(.plain)
            }
            ForEach(featured) { action in
                Button {
                    if action == .keepAwake { KeepAwake.shared.toggle() }
                    if let t = tab(for: action) { vm.tab = t }
                } label: {
                    HStack {
                        Text(action.title).font(Theme.caption).foregroundColor(Theme.fgDim).lineLimit(1)
                        Spacer()
                        Text(hotkeys.shortcuts[action]?.display ?? "—")
                            .font(Theme.monoSmall).foregroundColor(Theme.fgMute)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassChip(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
