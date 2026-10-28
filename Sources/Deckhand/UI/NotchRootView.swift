import SwiftUI

/// Root of the notch window.
///
/// Closed: a black shape slightly smaller than the cutout, fully hidden behind it.
/// Open: the shape grows into a panel of Liquid Glass with a dark tint.
/// The top of the panel runs past the screen edge, so top corners are square and bottom corners round.
struct NotchRootView: View {
    @EnvironmentObject var vm: NotchViewModel

    private let panelRadius: CGFloat = 26
    private var showToast: Bool { !vm.isOpen && vm.toast != nil }

    private var size: CGSize {
        if vm.isOpen { return NotchWindow.panelSize }
        if showToast { return CGSize(width: vm.notchSize.width + 280, height: vm.notchSize.height) }
        return CGSize(width: max(vm.notchSize.width - 6, 10), height: max(vm.notchSize.height - 2, 10))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(topRadius: showToast ? 8 : 0, bottomRadius: showToast ? 14 : 9)
                    .fill(Color.black)
                    .opacity(vm.isOpen ? 0 : 1)

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
                GlassBackground(cornerRadius: panelRadius)
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
        case .captureText, .colorPicker: return nil
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
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Shortcuts")
                    .font(Theme.label).foregroundColor(Theme.fgMute)
                ForEach(HotkeyAction.allCases) { action in
                    Button {
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
