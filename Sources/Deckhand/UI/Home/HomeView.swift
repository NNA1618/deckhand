import SwiftUI

// MARK: - Home

struct HomeView: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var hotkeys = HotkeyManager.shared

    var body: some View {
        // Fits without scrolling at every panel size; scrolls only if something unusual (a long error,
        // a huge accessibility text size) makes it taller than the panel.
        // In the compact panel the Claude card gives up its third row first.
        ViewThatFits(in: .vertical) {
            content(sessions: 3)
            content(sessions: 2)
            ScrollView(.vertical, showsIndicators: false) { content(sessions: 2) }.fadeBottom(20)
        }
    }

    private func content(sessions: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 12) {
                KeepAwakeCard()
                TimerCard()
                QuickTogglesCard()
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                ClaudeSessionsCard(limit: sessions)
                    .frame(maxWidth: .infinity)
                ShortcutsCard()
                    .frame(width: 276)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            BrandMark(size: 18)
            Text(verbatim: "Deckhand")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.fg)
                .fixedSize()
            Spacer(minLength: 12)
            Text(Self.hint(hover: settings.openOnHover, shortcut: hotkeys.shortcuts[.toggle]?.display))
                .font(Theme.caption)
                .foregroundColor(Theme.fgMute)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// How to open and close the panel, following the current settings rather than always saying "Hover".
    static func hint(hover: Bool, shortcut: String?) -> String {
        if hover { return String(localized: "Hover over the notch to open · Esc closes") }
        if let shortcut { return String(localized: "Open with \(shortcut) · Esc closes") }
        return String(localized: "Open from the menu bar · Esc closes")
    }
}

// MARK: - Shortcuts

/// A few shortcuts at a glance. Each row does what its shortcut does.
struct ShortcutsCard: View {
    @EnvironmentObject var vm: NotchViewModel
    @ObservedObject private var hotkeys = HotkeyManager.shared

    /// The shortcuts worth seeing at a glance; the rest are in Settings.
    static let featured: [HotkeyAction] = [.toggle, .screenshot, .captureText, .colorPicker, .keepAwake]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Shortcuts").font(Theme.label).foregroundColor(Theme.fg)
                Spacer()
                Button {
                    vm.requestClose()
                    SettingsWindow.show(.shortcuts)
                } label: {
                    Text("All")
                        .font(Theme.label)
                        .foregroundColor(Theme.fgDim)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("All shortcuts in Settings"))
            }
            ForEach(Self.featured) { action in
                ShortcutRow(action: action, shortcut: hotkeys.shortcuts[action]?.display)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassChip(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ShortcutRow: View {
    let action: HotkeyAction
    let shortcut: String?
    @State private var hovering = false

    var body: some View {
        Button { PanelActions.perform(action) } label: {
            HStack(spacing: 8) {
                Text(action.title)
                    .font(Theme.caption)
                    .foregroundColor(hovering ? Theme.fg : Theme.fgDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(verbatim: shortcut ?? "—")
                    .font(Theme.monoSmall)
                    .foregroundColor(Theme.fgMute)
                    .fixedSize()
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Theme.surface : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(action.title))
        .accessibilityHint(Text(verbatim: shortcut ?? ""))
    }
}
