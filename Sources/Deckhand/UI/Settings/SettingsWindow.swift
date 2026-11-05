import SwiftUI
import AppKit
import Combine

/// Remembers the open section and the way back, so other parts of the app can open Settings
/// at the right place and back and forward work like System Settings.
@MainActor
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    private static let lastSectionKey = "settingsLastSection"

    @Published var selection: SettingsSection? {
        didSet { selectionChanged(from: oldValue) }
    }
    /// The sidebar search text.
    @Published var searchText = ""
    /// Bumped each time the Settings window becomes key, so panes can re-read statuses.
    @Published private(set) var activation = 0
    /// Bumped to move keyboard focus to the search field (⌘F).
    @Published private(set) var searchFocusRequest = 0
    /// Whether the window is key; the selected row dims when it isn't, like a native sidebar.
    @Published private(set) var windowIsKey = false

    private(set) var backStack: [SettingsSection] = []
    private(set) var forwardStack: [SettingsSection] = []
    /// The history after a back or forward step, applied together with the new selection.
    private var pendingHistory: (back: [SettingsSection], forward: [SettingsSection])?

    private init() {
        let last = UserDefaults.standard.string(forKey: Self.lastSectionKey).flatMap(SettingsSection.init(rawValue:))
        selection = AppPaths.isSnapshot ? .general : (last ?? .general)
    }

    var section: SettingsSection {
        get { selection ?? .general }
        set { selection = newValue }
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() {
        var back = backStack, forward = forwardStack
        guard let next = back.popLast() else { return }
        forward.append(section)
        step(to: next, back: back, forward: forward)
    }

    func goForward() {
        var back = backStack, forward = forwardStack
        guard let next = forward.popLast() else { return }
        back.append(section)
        step(to: next, back: back, forward: forward)
    }

    func windowKeyChanged(_ isKey: Bool) {
        windowIsKey = isKey
        if isKey { activation += 1 }
    }

    func focusSearch() { searchFocusRequest += 1 }

    /// The new history is built in local copies and stored in the selection's didSet, so nothing
    /// that reacts to the change (or reads back and forward meanwhile) sees half of it, and no
    /// stack is held `inout` while observers run.
    private func step(to next: SettingsSection, back: [SettingsSection], forward: [SettingsSection]) {
        pendingHistory = (back, forward)
        selection = next
    }

    private func selectionChanged(from old: SettingsSection?) {
        let pending = pendingHistory
        pendingHistory = nil
        guard let new = selection, new != old else { return }
        if let pending {
            backStack = pending.back
            forwardStack = pending.forward
        } else if let old {
            backStack = backStack + [old]
            forwardStack = []
        }
        // A snapshot run shares the user's defaults; it must not change them
        if !AppPaths.isSnapshot { UserDefaults.standard.set(new.rawValue, forKey: Self.lastSectionKey) }
    }
}

// MARK: - Window

/// The Settings window, laid out like System Settings on macOS 26 and drawn like the notch panel:
/// the whole window is the panel's glass (same style and tint, following changes live), with a
/// floating sidebar card that holds the traffic lights, and back and forward in the toolbar above
/// the pane. `NavigationSplitView` isn't used because `--snapshot` captures it blank.
@MainActor
enum SettingsWindow {
    private static var controller: SettingsWindowController?
    static var window: NSWindow? { controller?.window }

    static let contentSize = NSSize(width: 760, height: 620)
    /// The sidebar card's width; the column around it adds `inset` on both sides.
    static let sidebarWidth: CGFloat = 220
    static let inset: CGFloat = 8
    /// The panel's corner radius, so the window has the same shape language.
    static let cornerRadius: CGFloat = 26
    /// The unified toolbar's height, where the traffic lights and back and forward sit.
    static let toolbarHeight: CGFloat = 52

    static func show(_ section: SettingsSection? = nil) {
        if let section { SettingsRouter.shared.section = section }
        let controller = controller ?? SettingsWindowController()
        Self.controller = controller
        controller.present()
    }

    /// Scrolls the pane to its end, for the snapshot of long panes. False when it already fits.
    static func scrollPaneToEnd() -> Bool {
        guard let content = window?.contentView,
              let scroll = scrollViews(in: content).max(by: { $0.frame.width < $1.frame.width }),
              let document = scroll.documentView else { return false }
        let visible = scroll.contentView.bounds.height
        guard document.frame.height > visible + 4 else { return false }
        let y = document.isFlipped ? document.frame.height - visible : 0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        return true
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        view.subviews.flatMap { sub -> [NSScrollView] in
            (sub as? NSScrollView).map { [$0] } ?? scrollViews(in: sub)
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    private let router = SettingsRouter.shared
    /// Two plain columns: no system sidebar material and no content backgrounds, so the glass
    /// behind shows through. It's a split view so the toolbar can place back and forward over the pane.
    private let split = SettingsSplitView()
    private var navigationGroup: NSToolbarItemGroup?
    private var observers = Set<AnyCancellable>()

    private static let trackingItem = NSToolbarItem.Identifier("settings.tracking")
    private static let navigationItem = NSToolbarItem.Identifier("settings.navigation")

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsWindow.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.contentView = SettingsRootView(split: split)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        let toolbar = NSToolbar(identifier: "DeckhandSettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.titlebarSeparatorStyle = .none
        window.contentMinSize = NSSize(width: 700, height: 460)
        window.setContentSize(SettingsWindow.contentSize)
        window.center()
        // A snapshot run shares the user's defaults, so it must not save its window frame there
        if !AppPaths.isSnapshot { window.setFrameAutosaveName("DeckhandSettings") }
        window.title = router.section.title

        // @Published fires before the router records history, so update on the next turn
        router.$selection.receive(on: DispatchQueue.main).sink { [weak self] selection in
            MainActor.assumeIsolated {
                self?.window?.title = (selection ?? .general).title
                self?.updateNavigation()
            }
        }
        .store(in: &observers)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        guard let window else { return }
        AppActivation.windowOpened(window)
        window.makeKeyAndOrderFront(nil)
        // The shadow follows the glass's rounded shape once it has been drawn
        DispatchQueue.main.async { window.invalidateShadow() }
    }

    // MARK: Window delegate

    func windowDidBecomeKey(_ notification: Notification) { router.windowKeyChanged(true) }
    func windowDidResignKey(_ notification: Notification) { router.windowKeyChanged(false) }
    func windowDidResize(_ notification: Notification) { window?.invalidateShadow() }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.trackingItem, Self.navigationItem, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.trackingItem:
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split, dividerIndex: 0)
        case Self.navigationItem:
            let back = String(localized: "menu.back", defaultValue: "Back")
            let forward = String(localized: "menu.forward", defaultValue: "Forward")
            let images = [
                NSImage(systemSymbolName: "chevron.left", accessibilityDescription: back),
                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: forward),
            ].compactMap { $0 }
            let group = NSToolbarItemGroup(itemIdentifier: id, images: images, selectionMode: .momentary,
                                           labels: [back, forward], target: self, action: #selector(navigate(_:)))
            group.autovalidates = false
            group.label = back
            for (item, tip) in zip(group.subitems, [back, forward]) { item.toolTip = tip }
            navigationGroup = group
            updateNavigation()
            return group
        default:
            return nil
        }
    }

    private func updateNavigation() {
        guard let group = navigationGroup, group.subitems.count == 2 else { return }
        group.subitems[0].isEnabled = router.canGoBack
        group.subitems[1].isEnabled = router.canGoForward
        group.isEnabled = router.canGoBack || router.canGoForward
    }

    @objc private func navigate(_ sender: NSToolbarItemGroup) {
        if sender.selectedIndex == 0 { router.goBack() } else { router.goForward() }
    }

    // MARK: Actions (also reached from the View menu through the responder chain)

    @objc func settingsGoBack(_ sender: Any?) { router.goBack() }
    @objc func settingsGoForward(_ sender: Any?) { router.goForward() }
    @objc func settingsFocusSearch(_ sender: Any?) { router.focusSearch() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(settingsGoBack(_:)): return router.canGoBack
        case #selector(settingsGoForward(_:)): return router.canGoForward
        default: return true
        }
    }
}

/// The glass behind everything, then the two columns on top.
@MainActor
private final class SettingsRootView: NSView {
    init(split: SettingsSplitView) {
        super.init(frame: NSRect(origin: .zero, size: SettingsWindow.contentSize))
        let glass = Self.hosting(SettingsWindowGlass())
        for sub in [glass, split] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
            NSLayoutConstraint.activate([
                sub.leadingAnchor.constraint(equalTo: leadingAnchor),
                sub.trailingAnchor.constraint(equalTo: trailingAnchor),
                sub.topAnchor.constraint(equalTo: topAnchor),
                sub.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        split.addArrangedSubview(Self.hosting(SettingsSidebar()))
        split.addArrangedSubview(Self.hosting(SettingsDetailHost()))
        split.setHoldingPriority(.defaultHigh + 10, forSubviewAt: 0)
        split.adjustSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The hosting views must not size the window to their content: the window owns its size.
    private static func hosting<V: View>(_ view: V) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        return host
    }
}

/// The panel's glass, with its style and tint, updated when they change in Notch & Panel.
private struct SettingsWindowGlass: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        GlassBackground(cornerRadius: SettingsWindow.cornerRadius, style: settings.panelStyle, tint: settings.glassTint)
            .id(settings.panelStyle == .solid)   // solid and glass are different views
            .ignoresSafeArea()
    }
}

/// A split view with a fixed sidebar column and a divider that takes no room and draws nothing;
/// the sidebar card has its own edge.
@MainActor
final class SettingsSplitView: NSSplitView, NSSplitViewDelegate {
    static var column: CGFloat { SettingsWindow.sidebarWidth + 2 * SettingsWindow.inset }

    init() {
        super.init(frame: .zero)
        isVertical = true
        dividerStyle = .thin
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var dividerThickness: CGFloat { 0 }
    override func drawDivider(in rect: NSRect) {}

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        Self.column
    }

    /// Only the pane grows when the window is resized.
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard subviews.count == 2 else { return splitView.adjustSubviews() }
        let column = min(Self.column, bounds.width)
        subviews[0].frame = NSRect(x: 0, y: 0, width: column, height: bounds.height)
        subviews[1].frame = NSRect(x: column, y: 0, width: bounds.width - column, height: bounds.height)
    }
}

// MARK: - Sidebar

/// The floating sidebar card: search, the Deckhand card, then the sections in groups.
/// ↑/↓ move, typing letters jumps to a section, ⌘F searches, Return in search opens the first
/// result, Esc clears the search and then goes back to the list.
struct SettingsSidebar: View {
    @ObservedObject private var router = SettingsRouter.shared
    @FocusState private var focus: Focus?
    @State private var typeSelect = TypeSelectBuffer()

    enum Focus { case search, list }

    var body: some View {
        let hits = SettingsSearch.results(for: router.searchText)
        VStack(spacing: 0) {
            SettingsSearchCapsule(
                text: $router.searchText,
                focus: $focus,
                onSubmit: { if let first = hits.first { router.section = first.section } },
                onLeave: { focus = .list }
            )
            .padding(.horizontal, 10)
            .padding(.top, SettingsWindow.toolbarHeight - SettingsWindow.inset + 2)
            .padding(.bottom, 8)

            if hits.isEmpty {
                noResults
            } else {
                list(hits)
            }
        }
        .frame(width: SettingsWindow.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .settingsCard(cornerRadius: SettingsWindow.cornerRadius - SettingsWindow.inset)
        .padding(SettingsWindow.inset)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .onAppear { focus = .list }
        .onChange(of: router.searchFocusRequest) { focus = .search }
    }

    private func list(_ hits: [SettingsSearch.Hit]) -> some View {
        let details = Dictionary(hits.map { ($0.section, $0.detail) }, uniquingKeysWith: { first, _ in first })
        let groups = SettingsSection.groups
            .map { $0.filter { details.keys.contains($0) } }
            .filter { !$0.isEmpty }
        let ordered = groups.flatMap { $0 }
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if router.searchText.isEmpty {
                        SettingsAppCard()
                            .padding(.bottom, 10)
                    }
                    ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                        if index > 0 { Spacer().frame(height: 10) }
                        ForEach(group) { section in
                            SettingsSidebarRow(
                                section: section,
                                detail: details[section] ?? nil,
                                selected: router.selection == section,
                                windowIsKey: router.windowIsKey || AppPaths.isSnapshot
                            ) {
                                router.section = section
                                focus = .list
                            }
                            .id(section)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
            // Rows fade out under the search field instead of being cut by a hard edge
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 10)
                    Rectangle()
                }
            }
            .focusable()
            .focused($focus, equals: .list)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1, in: ordered) }
            .onKeyPress(.downArrow) { move(1, in: ordered) }
            .onKeyPress(phases: .down) { press in
                guard press.modifiers.subtracting(.shift).isEmpty,
                      let letter = press.characters.first, letter.isLetter || letter.isNumber,
                      let match = typeSelect.append(press.characters, among: ordered) else { return .ignored }
                router.section = match
                return .handled
            }
            .onChange(of: router.selection) { _, selection in
                guard let selection else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(selection) }
            }
        }
    }

    private func move(_ step: Int, in sections: [SettingsSection]) -> KeyPress.Result {
        guard !sections.isEmpty else { return .ignored }
        let index = router.selection.flatMap { sections.firstIndex(of: $0) } ?? (step > 0 ? -1 : sections.count)
        let next = min(max(index + step, 0), sections.count - 1)
        router.section = sections[next]
        return .handled
    }

    private var noResults: some View {
        VStack(spacing: 4) {
            Text("No Results")
                .font(Theme.title)
                .foregroundStyle(Theme.fgDim)
            Text("Try another word.")
                .font(Theme.caption)
                .foregroundStyle(Theme.fgMute)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }
}

/// One section in the sidebar. The selected row is a white pill with black text,
/// like the active tab in the panel; it greys out while the window isn't key.
struct SettingsSidebarRow: View {
    let section: SettingsSection
    let detail: String?
    let selected: Bool
    let windowIsKey: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                SettingsIcon(section: section, size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(section.title)
                        .font(.system(size: 13, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? Color.black : Theme.fg)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(Theme.caption)
                            .foregroundStyle(selected ? Color.black.opacity(0.6) : Theme.fgMute)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(minHeight: 32)
            .background(background)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        if selected {
            shape.fill(windowIsKey ? Theme.accent : Theme.accent.opacity(0.7))
        } else if hovering {
            shape.fill(Theme.surface)
        }
    }
}

/// Deckhand's own card under the search field, in the place of System Settings' account card.
struct SettingsAppCard: View {
    @ObservedObject private var router = SettingsRouter.shared

    var body: some View {
        Button { router.section = .about } label: {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "Deckhand")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.fg)
                    Text(verbatim: "NNA1618 · \(AppVersion.short)")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.fgDim)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(SettingsSection.about.title)
        .accessibilityLabel(SettingsSection.about.title)
    }
}

/// Type-to-select for the sidebar: letters typed within a second form a prefix.
struct TypeSelectBuffer {
    private var buffer = ""
    private var last = Date.distantPast

    mutating func append(_ characters: String, among sections: [SettingsSection], now: Date = Date(),
                         title: (SettingsSection) -> String = { $0.title }) -> SettingsSection? {
        if now.timeIntervalSince(last) > 1 { buffer = "" }
        last = now
        buffer += characters
        let prefix = SettingsSearch.normalize(buffer)
        return sections.first(where: { SettingsSearch.normalize(title($0)).hasPrefix(prefix) })
    }
}

/// The capsule search field at the top of the sidebar, styled like the panel's search fields.
struct SettingsSearchCapsule: View {
    @Binding var text: String
    var focus: FocusState<SettingsSidebar.Focus?>.Binding
    let onSubmit: () -> Void
    let onLeave: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.fgMute)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .foregroundStyle(Theme.fg)
                .focused(focus, equals: .search)
                .onSubmit(onSubmit)
                .onKeyPress(.escape) {
                    if text.isEmpty { onLeave() } else { text = "" }
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    onLeave()
                    return .handled
                }
                .accessibilityLabel(Text("Search Settings"))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.fgMute)
                }
                .buttonStyle(.plain)
                .help(Text("Clear"))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Theme.surface2, in: Capsule())
        .overlay(Capsule().strokeBorder(focus.wrappedValue == .search ? Theme.fgMute : .clear, lineWidth: 1))
    }
}

// MARK: - Detail

/// The selected pane, below the toolbar band. A new identity per section, so each pane
/// starts scrolled to the top.
struct SettingsDetailHost: View {
    @ObservedObject private var router = SettingsRouter.shared

    var body: some View {
        VStack(spacing: 0) {
            // The toolbar band with back and forward; the pane starts below it. The 2 pt gap keeps
            // macOS 26 from attaching its toolbar edge effect to the pane, which the glass doesn't
            // need and which `--snapshot` can't capture (it comes out as a white sheet).
            Color.clear.frame(height: SettingsWindow.toolbarHeight + 2)
            SettingsDetail(section: router.section)
                .id(router.section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
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
