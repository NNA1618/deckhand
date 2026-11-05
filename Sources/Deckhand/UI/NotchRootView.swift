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
        closedIdle && !showClaude && !showTimer && settings.showPlayingInNotch && player.showsInNotch
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
        .onChange(of: size.width, initial: true) { _, width in
            if !vm.isOpen { vm.closedWidth = width }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: showClaude)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: showTimer)
    }
}
