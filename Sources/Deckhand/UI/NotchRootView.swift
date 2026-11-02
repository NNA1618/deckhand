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
    @ObservedObject private var timer = Countdown.shared
    @ObservedObject private var claude = ClaudeCodeMonitor.shared

    private let panelRadius: CGFloat = 26
    private var showToast: Bool { !vm.isOpen && vm.toast != nil }
    // One badge at a time, most urgent first: toast, Claude Code, timer, music, Keep Awake
    private var closedIdle: Bool { !vm.isOpen && vm.toast == nil }
    private var showClaude: Bool { closedIdle && settings.claudeInNotch && !claude.active.isEmpty }
    private var showTimer: Bool { closedIdle && !showClaude && timer.isActive }
    private var showPlaying: Bool {
        closedIdle && !showClaude && !showTimer && settings.showPlayingInNotch && player.now.isPlaying && !player.now.title.isEmpty
    }
    private var showAwake: Bool {
        closedIdle && !showClaude && !showTimer && !showPlaying && settings.keepAwakeIndicator && awake.isActive
    }
    /// Something is shown around the closed notch, so the shape grows past the cutout.
    private var showBadge: Bool { showToast || showClaude || showTimer || showPlaying || showAwake }

    private var size: CGSize {
        if vm.isOpen { return settings.panelSize.size }
        if showToast { return CGSize(width: vm.notchSize.width + 280, height: vm.notchSize.height) }
        if showClaude { return CGSize(width: vm.notchSize.width + ClaudeBadge.sideWidth * 2, height: vm.notchSize.height) }
        if showTimer { return CGSize(width: vm.notchSize.width + TimerBadge.sideWidth * 2, height: vm.notchSize.height) }
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

                if showClaude {
                    ClaudeBadge(notchWidth: vm.notchSize.width, height: vm.notchSize.height)
                        .transition(.opacity)
                }

                if showTimer {
                    TimerBadge(notchWidth: vm.notchSize.width, height: vm.notchSize.height)
                        .transition(.opacity)
                }

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
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: showClaude)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: showTimer)
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
                    SettingsRouter.shared.tab = .shortcuts
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

// MARK: - Timer

struct TimerCard: View {
    @ObservedObject private var timer = Countdown.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(timer.isActive ? Theme.fg : Theme.fgDim)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Timer").font(Theme.label).foregroundColor(Theme.fg)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(timer.isActive ? timer.remainingText(now: context.date) : String(localized: "Off"))
                            .font(timer.isActive ? Theme.caption.monospacedDigit() : Theme.caption)
                            .foregroundColor(Theme.fgMute)
                    }
                }
                Spacer()
                if timer.isActive {
                    roundButton(timer.isPaused ? "play.fill" : "pause.fill", timer.isPaused ? "Resume" : "Pause") {
                        timer.isPaused ? timer.resume() : timer.pause()
                    }
                    roundButton("xmark", "Stop") { timer.stop() }
                }
            }
            HStack(spacing: 6) {
                ForEach(Countdown.presets, id: \.self) { m in
                    Button { timer.start(minutes: m) } label: {
                        Chip(text: KeepAwake.shortTitle(for: TimeInterval(m * 60)), active: timer.isActive && timer.minutes == m)
                    }
                    .buttonStyle(.plain)
                }
                if timer.isActive {
                    Button { timer.addMinute() } label: { Chip(text: "+1") }
                        .buttonStyle(.plain)
                        .help(Text("Add a minute"))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassChip(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func roundButton(_ symbol: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Theme.fg)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.surface2))
        }
        .buttonStyle(.plain)
        .help(Text(help))
    }
}

/// Around the closed notch while the timer runs: a timer icon and the time left.
struct TimerBadge: View {
    let notchWidth: CGFloat
    let height: CGFloat
    static let sideWidth: CGFloat = 54
    @ObservedObject private var timer = Countdown.shared

    var body: some View {
        Color.clear
            .frame(width: notchWidth + Self.sideWidth * 2, height: height)
            .overlay(alignment: .leading) {
                Image(systemName: timer.isPaused ? "pause.fill" : "timer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.fg)
                    .padding(.leading, 18)
            }
            .overlay(alignment: .trailing) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(timer.remainingText(now: context.date))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundColor(Theme.fg)
                }
                .padding(.trailing, 14)
            }
    }
}

// MARK: - Quick toggles

struct QuickTogglesCard: View {
    @ObservedObject private var toggles = QuickToggles.shared
    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(QuickToggles.Toggle.allCases) { t in
                    let on = toggles.isOn(t)
                    Button { toggles.flip(t) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: t.symbol(on: on))
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 14)
                            Text(t.title).font(Theme.label).lineLimit(1).minimumScaleFactor(0.85)
                            Spacer(minLength: 0)
                        }
                        .foregroundColor(on ? .black : Theme.fgDim)
                        .padding(.horizontal, 8).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Theme.accent : Theme.surface2))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text(t.help))
                }
            }
            if let error = toggles.error {
                Text(error).font(Theme.caption).foregroundColor(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassChip(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear { toggles.refresh() }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
