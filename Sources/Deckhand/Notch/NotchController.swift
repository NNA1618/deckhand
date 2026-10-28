import AppKit
import SwiftUI
import Combine

enum NotchTab: String, CaseIterable, Identifiable {
    case home, clipboard, translator, claude, prompts, media, shelf, recents

    var id: String { rawValue }
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
    /// Lets tabs close the panel, e.g. before opening the editor window.
    var requestClose: () -> Void = {}
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
                // Slightly wider than the cutout and a few points below it
                return notch.rect.insetBy(dx: -14, dy: -4)
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
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                MainActor.assumeIsolated { self?.close() }
                return nil
            }
            return event
        }
    }

    // MARK: - Hover

    private func cursorEntered() {
        cursorWasInside = true
        guard !viewModel.isOpen else { return }
        // A file is being dragged to the notch: open straight on the shelf
        let dragPB = NSPasteboard(name: .drag)
        let dragging = NSEvent.pressedMouseButtons != 0 && dragPB.changeCount != dragChangeCount
        if dragging {
            dragChangeCount = dragPB.changeCount
            open(tab: .shelf, manual: false)
        } else {
            open(tab: viewModel.tab, manual: false)
        }
    }

    private func cursorLeft() {
        guard viewModel.isOpen else { return }
        if openedManually && !cursorWasInside { return }
        close()
    }

    // MARK: - Public

    func toggle() {
        viewModel.isOpen ? close() : open(tab: viewModel.tab, manual: true)
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
