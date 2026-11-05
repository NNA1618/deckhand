import SwiftUI
import AppKit

/// The open panel: the tab strip, the current tab's name, the gear and the current tab.
struct PanelContent: View {
    @EnvironmentObject var vm: NotchViewModel
    @ObservedObject private var panelSettings = PanelSettings.shared
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                TabStrip()
                Text(vm.tab.title)
                    .font(Theme.title)
                    .foregroundColor(Theme.fg)
                    .lineLimit(1)
                    .id(vm.tab)
                    .transition(.opacity)
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
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
                .accessibilityLabel(Text("Settings"))
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
        .onAppear(perform: installKeys)
        .onDisappear {
            removeKeys()
            resetTabAfterClose()
        }
        .onChange(of: vm.tab, initial: true) { _, tab in
            panelSettings.lastTab = tab.rawValue
        }
    }

    // MARK: - Tab when opened

    /// After the panel closes, line up the tab the next hover or toggle should open on.
    /// A shortcut for a specific tab still wins, because it sets the tab as it opens.
    private func resetTabAfterClose() {
        let vm = self.vm
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !vm.isOpen else { return }
            let next = PanelSettings.shared.tabWhenOpened
            if vm.tab != next { vm.tab = next }
        }
    }

    // MARK: - Keyboard

    /// ⌃Tab and ⌃⇧Tab switch tabs anywhere in the panel; ← and → do too while no text field has focus.
    private func installKeys() {
        removeKeys()
        let vm = self.vm
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let window = event.window
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let keyCode = event.keyCode
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard window is NotchWindow, vm.isOpen,
                      let step = Self.tabStep(keyCode: keyCode, modifiers: mods,
                                              editingText: window?.firstResponder is NSText) else { return false }
                let tabs = PanelSettings.strip(order: PanelSettings.shared.tabOrder,
                                               hidden: Settings.shared.hiddenTabs, current: vm.tab)
                vm.tab = PanelSettings.neighbor(of: vm.tab, in: tabs, step: step)
                return true
            }
            return handled ? nil : event
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Which way a key press moves through the tabs, or nil when it isn't a tab key. Pure, for the self-test.
    nonisolated static func tabStep(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, editingText: Bool) -> Int? {
        switch keyCode {
        case 48 where modifiers == .control: return 1                      // ⌃Tab
        case 48 where modifiers == [.control, .shift]: return -1          // ⌃⇧Tab
        case 123 where modifiers.isEmpty && !editingText: return -1        // ←
        case 124 where modifiers.isEmpty && !editingText: return 1         // →
        default: return nil
        }
    }
}

/// Icon tabs of one fixed width, so nothing moves under the pointer when the selection changes.
/// The selected tab's name sits next to the strip.
struct TabStrip: View {
    @EnvironmentObject var vm: NotchViewModel
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var panelSettings = PanelSettings.shared
    @ObservedObject private var hotkeys = HotkeyManager.shared
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelSettings.strip(order: panelSettings.tabOrder, hidden: settings.hiddenTabs, current: vm.tab)) { tab in
                let active = vm.tab == tab
                Button { vm.tab = tab } label: {
                    TabIcon(tab: tab)
                        .foregroundColor(active ? .black : Theme.fgDim)
                        .frame(width: 36, height: 26)
                        .background {
                            if active {
                                Capsule().fill(Theme.accent).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(Text(help(for: tab)))
                .accessibilityLabel(Text(tab.title))
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
        }
        .padding(3)
        .glassChip(in: Capsule())
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: vm.tab)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Tabs"))
    }

    /// "Clipboard  ⌃⌥V" when the tab has a shortcut.
    private func help(for tab: NotchTab) -> String {
        guard let action = PanelActions.action(for: tab), let shortcut = hotkeys.activeShortcut(for: action) else { return tab.title }
        return "\(tab.title)  \(shortcut.display)"
    }
}

/// The icon of a panel tab. Every tab icon is drawn here, so a tab can get a custom image
/// (such as Claude's own icon) in one place. Callers set the color: white in the panel, the system color in Settings.
struct TabIcon: View {
    let tab: NotchTab

    var body: some View {
        if tab == .claude {
            // Claude's own icon, from the installed Claude app
            AgentIcon(provider: .claudeCode, size: 15)
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: tab.symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16, height: 16)
        }
    }
}
