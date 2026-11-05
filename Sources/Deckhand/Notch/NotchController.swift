import AppKit
import SwiftUI
import Combine

enum NotchTab: String, CaseIterable, Identifiable {
    case home, clipboard, translator, claude, prompts, media, shelf, recents

    var id: String { rawValue }

    /// The tabs shown in the panel, in order.
    @MainActor static var visible: [NotchTab] { visible(hidden: Settings.shared.hiddenTabs) }

    static func visible(hidden: [String]) -> [NotchTab] {
        allCases.filter { $0 == .home || !hidden.contains($0.rawValue) }
    }

    var title: String {
        switch self {
        case .home: return String(localized: "Home")
        case .clipboard: return String(localized: "Clipboard")
        case .translator: return String(localized: "Translate")
        case .claude: return String(localized: "Claude")
        case .prompts: return String(localized: "Prompts")
        case .media: return String(localized: "Music")
        case .shelf: return String(localized: "Shelf")
        case .recents: return String(localized: "Recents")
        }
    }
    var symbol: String {
        switch self {
        case .home: return "house"
        case .clipboard: return "doc.on.clipboard"
        case .translator: return "character.bubble"
        case .claude: return "sparkle"
        case .prompts: return "text.quote"
        case .media: return "music.note"
        case .shelf: return "tray.full"
        case .recents: return "photo.stack"
        }
    }
}

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var isOpen = false
    @Published var tab: NotchTab = .home
    /// The notch size, so the closed shape hides exactly behind it.
    @Published var notchSize = CGSize(width: 200, height: 32)
    /// A short notice shown in the closed notch, e.g. after a screenshot.
    @Published var toast: Toast?
    /// Width of the closed shape, wider than the cutout while a badge shows; hovering any of it opens the panel.
    var closedWidth: CGFloat = 0
    /// Lets tabs close the panel, e.g. before opening the editor window.
    var requestClose: () -> Void = {}
}

extension Notification.Name {
    /// Opens the panel without closing it on the next click elsewhere, e.g. to preview appearance changes.
    static let previewNotchPanel = Notification.Name("previewNotchPanel")
}

struct Toast: Equatable {
    let id = UUID()
    let symbol: String
    let text: String
}

@MainActor
final class NotchController {
    let viewModel = NotchViewModel()
    private var window: NotchWindow?
    private var hover: HoverDetector?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var subscriptions = Set<AnyCancellable>()

    /// Opened by a shortcut or the menu: stay open until the cursor has been inside at least once.
    private var openedManually = false
    private var cursorWasInside = false

    func showToast(symbol: String, text: String) {
        let toast = Toast(symbol: symbol, text: text)
        withAnimation(.spring(response: 0.38, dampingFraction: 0.75)) { viewModel.toast = toast }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, self.viewModel.toast == toast else { return }
            withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) { self.viewModel.toast = nil }
        }
    }

    func start() {
        let notch = NotchGeometry.current()
        viewModel.notchSize = notch.rect.size
        viewModel.requestClose = { [weak self] in self?.close() }

        let root = NotchRootView().environmentObject(viewModel)
        let w = NotchWindow(rootView: root)
        w.pin(to: notch)
        w.orderFrontRegardless()
        window = w
        Log.info("window pinned frame=\(w.frame) notch=\(notch.rect) hasNotch=\(notch.hasNotch)")

        setupHover()
        setupMonitors()

        // @Published fires before the value is stored, so apply on the next turn
        let settings = Settings.shared
        settings.$panelSize.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.repin() }
        }.store(in: &subscriptions)
        settings.$hoverDelay.sink { [weak self] delay in
            self?.hover?.enterDelay = delay
        }.store(in: &subscriptions)

        NotificationCenter.default.addObserver(forName: .previewNotchPanel, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.viewModel.isOpen else { return }
                self.open(tab: self.viewModel.tab, manual: true)
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.repin() }
        }
    }

    private func repin() {
        let notch = NotchGeometry.current()
        viewModel.notchSize = notch.rect.size
        window?.pin(to: notch)
    }

    private func setupHover() {
        let detector = HoverDetector(
            zone: { [weak self] in
                guard let self, let window = self.window else { return .zero }
                let notch = NotchGeometry.current()
                if self.viewModel.isOpen {
                    return window.panelRect(notch: notch).insetBy(dx: -12, dy: -12)
                }
                // The cutout, or the badge around it, plus a margin and a few points below
                let extra = max(0, (self.viewModel.closedWidth - notch.rect.width) / 2)
                return notch.rect.insetBy(dx: -14 - extra, dy: -4)
            },
            onEnter: { [weak self] in self?.cursorEntered() },
            onExit: { [weak self] in self?.cursorLeft() }
        )
        detector.start()
        hover = detector
    }

    private func setupMonitors() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.viewModel.isOpen, let window = self.window else { return }
                let rect = window.panelRect(notch: NotchGeometry.current())
                if !rect.contains(NSEvent.mouseLocation) { self.close() }
            }
        }
        // Esc closes the open panel only; other windows (Settings, the editor, pinned images) keep their Esc
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.viewModel.isOpen, windowNumber == self.window?.windowNumber else { return false }
                self.close()
                return true
            }
            return handled ? nil : event
        }
    }

    // MARK: - Hover

    private func cursorEntered() {
        cursorWasInside = true
        guard !viewModel.isOpen else { return }
        // A file is being dragged to the notch: open straight on the shelf
        let dragPB = NSPasteboard(name: .drag)
        let dragging = NSEvent.pressedMouseButtons != 0 && dragPB.changeCount != dragChangeCount
        let settings = Settings.shared
        if dragging {
            dragChangeCount = dragPB.changeCount
            open(tab: .shelf, manual: false)
        } else if settings.openOnHover,
                  !(settings.hideInFullScreen && FullScreen.isFrontmostFullScreen(on: NotchGeometry.current().screen)) {
            open(tab: NotchTab.visible.contains(viewModel.tab) ? viewModel.tab : .home, manual: false)
        }
    }

    private func cursorLeft() {
        guard viewModel.isOpen else { return }
        if openedManually && !cursorWasInside { return }
        close()
    }

    // MARK: - Public

    /// Stops hover from opening the panel, e.g. while an area capture or the color picker runs.
    /// The notch workstream implements it; callers turn it off when they finish.
    func suspendHover(_ suspended: Bool) {}

    /// Stops hover from opening the panel for a while, e.g. "Pause hover for 1 hour" in the menu bar.
    func pauseHover(for duration: TimeInterval) {}

    /// For `--snapshot`: the notch window and the notch cutout in window coordinates.
    var snapshotTarget: (NSWindow, CGRect)? {
        guard let window else { return nil }
        let notch = NotchGeometry.current().rect
        return (window, CGRect(x: notch.minX - window.frame.minX, y: notch.minY - window.frame.minY,
                               width: notch.width, height: notch.height))
    }

    func toggle() {
        viewModel.isOpen ? close() : open(tab: NotchTab.visible.contains(viewModel.tab) ? viewModel.tab : .home, manual: true)
    }

    func open(tab: NotchTab, manual: Bool = true) {
        if viewModel.isOpen && viewModel.tab == tab && manual {
            close()
            return
        }
        viewModel.tab = tab
        guard !viewModel.isOpen else { return }

        openedManually = manual
        cursorWasInside = !manual
        hover?.reset(inside: !manual)

        window?.ignoresMouseEvents = false
        window?.makeKeyAndOrderFront(nil)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
            viewModel.isOpen = true
        }
        Log.info("open tab=\(tab.rawValue) manual=\(manual)")
    }

    func close() {
        guard viewModel.isOpen else { return }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) {
            viewModel.isOpen = false
        }
        window?.ignoresMouseEvents = true
        // Give keyboard focus back to the app the user was working in
        window?.orderOut(nil)
        window?.orderFrontRegardless()
        hover?.reset(inside: false)
        Log.info("close")
    }
}
