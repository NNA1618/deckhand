import SwiftUI

/// Root of the notch window.
///
/// Closed: a black shape slightly smaller than the cutout, fully hidden behind it.
/// Open: the shape grows into a panel of Liquid Glass with a dark tint.
/// The top of the panel runs past the screen edge, so top corners are square and bottom corners round.
struct NotchRootView: View {
    @EnvironmentObject var vm: NotchViewModel
    @ObservedObject private var player = NowPlayingMonitor.shared
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var awake = KeepAwake.shared

    private let panelRadius: CGFloat = 26
    private var showToast: Bool { !vm.isOpen && vm.toast != nil }
    private var showPlaying: Bool {
        !vm.isOpen && vm.toast == nil && settings.showPlayingInNotch && player.now.isPlaying && !player.now.title.isEmpty
    }

    private var showAwake: Bool {
        !vm.isOpen && vm.toast == nil && !showPlaying && settings.keepAwakeIndicator && awake.isActive
    }
    /// Something is shown around the closed notch, so the shape grows past the cutout.
    private var showBadge: Bool { showToast || showPlaying || showAwake }

    private var size: CGSize {
        if vm.isOpen { return settings.panelSize.size }
        if showToast { return CGSize(width: vm.notchSize.width + 280, height: vm.notchSize.height) }
        if showPlaying { return CGSize(width: vm.notchSize.width + NowPlayingBadge.sideWidth * 2, height: vm.notchSize.height) }
        if showAwake { return CGSize(width: vm.notchSize.width + KeepAwakeBadge.sideWidth * 2, height: vm.notchSize.height) }
        return CGSize(width: max(vm.notchSize.width - 6, 10), height: max(vm.notchSize.height - 2, 10))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(topRadius: showBadge ? 8 : 0, bottomRadius: showBadge ? 14 : 9)
                    .fill(Color.black)
                    .opacity(vm.isOpen ? 0 : 1)

                if showPlaying {
                    NowPlayingBadge(now: player.now, notchWidth: vm.notchSize.width, height: vm.notchSize.height)
                        .transition(.opacity)
                }

                if showAwake {
                    KeepAwakeBadge(notchWidth: vm.notchSize.width, height: vm.notchSize.height)
                        .transition(.opacity)
                }

                if showToast, let toast = vm.toast {
                    HStack(spacing: 0) {
                        Image(systemName: toast.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.fg)
                            .frame(width: 140)
                        Spacer(minLength: vm.notchSize.width)
                        Text(toast.text)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.fg)
                            .lineLimit(1)
                            .frame(width: 140)
                    }
                    .frame(height: vm.notchSize.height)
                    .transition(.opacity)
                }

                if vm.isOpen {
                    PanelContent()
                        .id(settings.panelStyle == .solid)   // glass chips are chosen when views are built
                        .padding(.horizontal, 20)
                        .padding(.top, vm.notchSize.height + 8)
                        .padding(.bottom, 18)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            // Glass is taller than the panel by its radius so the top rounding falls off screen.
            // It sits in a background so its extra height never affects the content layout.
            .background(alignment: .top) {
                GlassBackground(cornerRadius: panelRadius, style: settings.panelStyle, tint: settings.glassTint)
                    .id(settings.panelStyle == .solid)   // solid and glass are different views
                    .frame(width: size.width, height: size.height + panelRadius)
                    .offset(y: -panelRadius)
                    .opacity(vm.isOpen ? 1 : 0)
            }
            .clipped(antialiased: true)
            .shadow(color: .black.opacity(vm.isOpen ? 0.45 : 0), radius: 22, y: 10)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: vm.isOpen)
        .animation(.spring(response: 0.38, dampingFraction: 0.75), value: vm.toast)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: showPlaying)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: showAwake)
    }
}

struct PanelContent: View {
    @EnvironmentObject var vm: NotchViewModel

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                TabStrip()
                Spacer()
                Button {
                    vm.requestClose()
                    SettingsWindow.show()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.fgDim)
                        .frame(width: 28, height: 28)
                        .glassChip(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .help(Text("Settings"))
            }
            Group {
                switch vm.tab {
                case .home: HomeView()
                case .clipboard: ClipboardView()
                case .translator: TranslatorView()
                case .claude: ClaudeView()
                case .prompts: PromptsView()
                case .media: MediaView()
                case .shelf: ShelfView()
                case .recents: RecentsView()
                }
            }
            .id(vm.tab)
            .transition(.opacity.combined(with: .offset(y: 6)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .animation(.easeOut(duration: 0.18), value: vm.tab)
    }
}

struct TabStrip: View {
    @EnvironmentObject var vm: NotchViewModel
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(NotchTab.allCases) { tab in
                let active = vm.tab == tab
                Button { vm.tab = tab } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol).font(.system(size: 11, weight: .medium))
                        if active { Text(tab.title).font(Theme.label) }
                    }
                    .foregroundColor(active ? .black : Theme.fgDim)
                    .padding(.horizontal, active ? 11 : 8)
                    .padding(.vertical, 6)
                    .background {
                        if active {
                            Capsule().fill(Theme.accent).matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(Text(tab.title))
            }
        }
        .padding(3)
        .glassChip(in: Capsule())
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: vm.tab)
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var vm: NotchViewModel
    @ObservedObject private var hotkeys = HotkeyManager.shared

    private func tab(for action: HotkeyAction) -> NotchTab? {
        switch action {
        case .toggle: return nil
        case .screenshot, .clipboard: return .clipboard
        case .captureText, .colorPicker, .keepAwake: return nil
        case .translator: return .translator
        case .claude: return .claude
        case .prompts: return .prompts
        case .media: return .media
        case .shelf: return .shelf
        case .recents: return .recents
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 30) {
            VStack(alignment: .leading, spacing: 8) {
                Text("NNA1618")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.fgMute)
                HStack(spacing: 10) {
                    BrandMark(size: 34)
                    Text("Deckhand")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(Theme.fg)
                }
                Text("Hover over the notch to open. Move away, press Esc or click outside to close. Drop a file on the notch to keep it on the shelf.")
                    .font(Theme.caption)
                    .foregroundColor(Theme.fgDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 260, alignment: .leading)
                Spacer(minLength: 12)
                KeepAwakeCard()
                    .frame(maxWidth: 260)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Shortcuts")
                    .font(Theme.label).foregroundColor(Theme.fgMute)
                ForEach(HotkeyAction.allCases) { action in
                    Button {
                        if action == .keepAwake { KeepAwake.shared.toggle() }
                        if let t = tab(for: action) { vm.tab = t }
                    } label: {
                        HStack {
                            Text(action.title).font(Theme.body).foregroundColor(Theme.fgDim)
                            Spacer()
                            Text(hotkeys.shortcuts[action]?.display ?? "—")
                                .font(Theme.monoSmall).foregroundColor(Theme.fgMute)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Capsule().fill(Theme.surface))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Keep Awake

/// Home tab control: a switch and the session lengths.
struct KeepAwakeCard: View {
    @ObservedObject private var awake = KeepAwake.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: awake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(awake.isActive ? Theme.fg : Theme.fgDim)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep Awake").font(Theme.label).foregroundColor(Theme.fg)
                    TimelineView(.periodic(from: .now, by: 20)) { context in
                        Text(status(now: context.date)).font(Theme.caption).foregroundColor(Theme.fgMute)
                    }
                }
                Spacer()
                Toggle("Keep Awake", isOn: Binding(get: { awake.isActive }, set: { _ in awake.toggle() }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            HStack(spacing: 6) {
                ForEach(Array(KeepAwake.durations.enumerated()), id: \.offset) { _, d in
                    let active = awake.isActive && awake.duration == d
                    Button { active ? awake.stop() : awake.start(for: d) } label: {
                        Chip(text: KeepAwake.shortTitle(for: d), active: active)
                    }
                    .buttonStyle(.plain)
                    .help(Text(KeepAwake.title(for: d)))
                }
            }
        }
        .padding(12)
        .glassChip(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func status(now: Date) -> String {
        guard awake.isActive else { return String(localized: "Off") }
        if awake.endsAt == nil { return String(localized: "On until turned off") }
        return String(localized: "On, \(awake.remainingText(now: now)) left")
    }
}

/// Shown around the closed notch while Keep Awake is on: a cup on the left, time left on the right.
struct KeepAwakeBadge: View {
    let notchWidth: CGFloat
    let height: CGFloat
    static let sideWidth: CGFloat = 46
    @ObservedObject private var awake = KeepAwake.shared

    var body: some View {
        Color.clear
            .frame(width: notchWidth + Self.sideWidth * 2, height: height)
            .overlay(alignment: .leading) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.fg)
                    .padding(.leading, 18)
            }
            .overlay(alignment: .trailing) {
                TimelineView(.periodic(from: .now, by: 20)) { context in
                    Text(awake.remainingText(now: context.date))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundColor(Theme.fg)
                }
                .padding(.trailing, 14)
            }
    }
}
