import SwiftUI

/// The open panel: the tab strip, the gear and the current tab.
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
            ForEach(NotchTab.visible) { tab in
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
