import AppKit
import SwiftUI
import Combine

enum NotchTab: String, CaseIterable, Identifiable {
    case home, clipboard, translator, claude, prompts, media, shelf, recents

    var id: String { rawValue }

    /// The tabs shown in the panel, in the user's order.
    @MainActor static var visible: [NotchTab] { PanelSettings.shared.visibleTabs }

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
        case .claude: return AgentProvider.claudeCode.fallbackSymbol   // TabIcon draws Claude's own icon
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
    /// False on a display without a camera housing, where the notch is drawn.
    @Published var hasNotch = true
    /// The pointer is on the trigger zone, so a notch that is invisible until hovered shows itself.
    @Published var peek = false
    /// The notice shown in the notch (closed) or as a banner in the panel (open).
    @Published var toast: Toast?
    /// Widest a notice may grow on this display.
    @Published var toastMaxWidth: CGFloat = 440
    /// Lets tabs close the panel, e.g. before opening the editor window.
    var requestClose: () -> Void = {}
    /// Reasons the panel stays open when the pointer leaves or the user clicks elsewhere, e.g. a prompt
    /// being edited, Quick Look showing a file or a context menu. Esc, the shortcut and the menu still close it.
    var holds: Set<String> = []
    /// Esc goes to the open tab first, e.g. to close a preview, clear a search or stop a request; the panel
    /// closes only when the tab doesn't use it. One path, because AppKit runs local key monitors in no set order.
    var escapeHandlers: [NotchTab: @MainActor () -> Bool] = [:]
}

extension Notification.Name {
    /// Shows the panel while Settings stays usable, to preview appearance changes. Posting it again ends the preview.
    static let previewNotchPanel = Notification.Name("previewNotchPanel")
}

/// Runs the notch: the two windows, hover and click activation, closing, notices and display changes.
@MainActor
final class NotchController {
    /// How the panel came to be open; it decides focus and how it may close.
    private enum OpenReason: String {
        case hover, click, drag, manual, preview
        /// Hover and drags leave keyboard focus with the app the user is typing in.
        var takesFocus: Bool { self == .click || self == .manual }
    }

    let viewModel = NotchViewModel()
    let closedModel = ClosedNotchModel()
    private var panelWindow: NotchWindow?
    private var badgeWindow: NotchWindow?
    private var notch: NotchInfo?

    private var intent = HoverIntent()
    private let tracker = PointerTracker()
    private var openTimer: Timer?
    private var closeTimer: Timer?
    private var orderOutWork: DispatchWorkItem?
    private var openedBy: OpenReason?

    private var toasts = ToastQueue()
    private var toastTimer: Timer?
    private var toastShownAt = Date.distantPast

    private var keyMonitor: Any?
    private var dragChangeCount = 0
    private var fileDragCache: (count: Int, isFiles: Bool)?
    /// The current mouse press started inside the open panel, so a drag from it is the panel's own.
    private var dragFromPanel = false
    private var suspended = false
    private var suspensions = 0
    private var suspendSafety: DispatchWorkItem?
    /// When "Pause Hover" ends, on the wall clock: the pause in `intent` counts uptime, which stops during sleep.
    private var hoverPauseEnds: Date?
    private var previewMove: (window: NSWindow, original: CGRect, moved: CGRect)?
    private var subscriptions = Set<AnyCancellable>()

    private static let toastGap: TimeInterval = 0.3
    private static let closeAnimation: TimeInterval = 0.45

    // MARK: - Notices

    /// Shows a notice in the notch. While the panel is open it appears as a banner inside it; while another notice
    /// is up it waits its turn. `.alert` stays until the pointer touches it or the panel is opened.
    func showToast(symbol: String, text: String, style: Toast.Style = .info) {
        let toast = Toast(symbol: symbol, text: text, style: style)
        if toasts.push(toast), let current = toasts.current {
            present(current)
        } else if toasts.alertWaiting, let current = toasts.current, current.style == .info {
            // Let the waiting alert through soon, but give the shown notice a moment to be read
            let readBy = toastShownAt.addingTimeInterval(1.0)
            scheduleToastDismiss(after: max(0.2, readBy.timeIntervalSinceNow))
        }
    }

    /// Takes back a notice that no longer applies, e.g. "Time is up" once the timer was dismissed elsewhere.
    func withdrawToast(symbol: String, text: String) {
        if toasts.withdraw(Toast(symbol: symbol, text: text)) { dismissToast() }
    }

    private func present(_ toast: Toast) {
        toastShownAt = Date()
        withAnimation(Self.morph) { viewModel.toast = toast }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: toast.text,
            .priority: (toast.style == .alert ? NSAccessibilityPriorityLevel.high : .medium).rawValue,
        ])
        if toast.style == .info || viewModel.isOpen {
            scheduleToastDismiss(after: Settings.shared.toastDuration)
        } else {
            toastTimer?.invalidate()
            toastTimer = nil
        }
    }

    private func scheduleToastDismiss(after seconds: TimeInterval) {
        toastTimer?.invalidate()
        toastTimer = oneShot(after: seconds) { [weak self] in self?.dismissToast() }
    }

    private func dismissToast() {
        toastTimer?.invalidate()
        toastTimer = nil
        toasts.dismissCurrent()
        withAnimation(Self.morph) { viewModel.toast = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.toastGap) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.toasts.current == nil, let next = self.toasts.next() else { return }
                self.present(next)
            }
        }
    }

    /// For `--snapshot`: clears the shown and waiting notices.
    func dismissNoticesForSnapshot() {
        toasts = ToastQueue()
        toastTimer?.invalidate()
        toastTimer = nil
        viewModel.toast = nil
    }

    /// The notice's frame in global coordinates, to notice the pointer touching an alert.
    private func toastRect(_ toast: Toast, notch: NotchInfo) -> CGRect {
        let width = ToastLayout.width(toast, notchWidth: notch.rect.width, maxWidth: viewModel.toastMaxWidth)
        let height = notch.rect.height + ToastLayout.drop
        return CGRect(x: notch.rect.midX - width / 2, y: notch.screenFrame.maxY - height, width: width, height: height)
    }

    // MARK: - Start

    func start() {
        viewModel.requestClose = { [weak self] in self?.close() }
        dragChangeCount = NSPasteboard(name: .drag).changeCount

        let badge = NotchWindow(rootView: NotchClosedView().environmentObject(viewModel).environmentObject(closedModel),
                                level: .mainMenu + 2, takesFocus: false)
        let panel = NotchWindow(rootView: NotchPanelView().environmentObject(viewModel), level: .mainMenu + 3, takesFocus: true)
        badge.onMouseDown = { [weak self] p in self?.badgeClicked(at: p) }
        panel.onMouseDown = { [weak self] p in self?.panelClicked(at: p) }
        panel.onPerformClose = { [weak self] in self?.close() }
        badgeWindow = badge
        panelWindow = panel
        refreshGeometry()
        if let notch { Log.info("notch \(notch.rect) hasNotch=\(notch.hasNotch) screen=\(notch.screenFrame)") }

        setupKeyMonitor()
        observeSettings()

        // A context menu may reach past the panel; moving onto its items must not close the panel under it
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.viewModel.holds.insert("menu") }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.viewModel.holds.remove("menu") }
        }

        NotificationCenter.default.addObserver(forName: .previewNotchPanel, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePreview() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshGeometry() }
        }

        // A snapshot run is a second copy next to the user's own: it must not react to the pointer
        guard !AppPaths.isSnapshot else { return }
        tracker.handlers = PointerTracker.Handlers(
            moved: { [weak self] p in self?.pointerMoved(p) },
            mouseDown: { [weak self] p, type in self?.mouseDown(at: p, type: type) },
            mouseUp: { [weak self] p in self?.pointerMoved(p) },
            resumed: { [weak self] in self?.trackingResumed() }
        )
        tracker.wantsPoll = { [weak self] in self?.viewModel.isOpen ?? false }
        tracker.start()

        let fullScreen = FullScreen.shared
        fullScreen.screen = { [weak self] in self?.notch?.screen }
        fullScreen.onChange = { [weak self] value in self?.closedModel.fullScreen = value }
        fullScreen.start()
    }

    private func observeSettings() {
        // @Published fires before the value is stored, so apply on the next turn
        Settings.shared.$panelSize.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshGeometry() } }
        }.store(in: &subscriptions)
        let ns = NotchSettings.shared
        ns.$display.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshGeometry() } }
        }.store(in: &subscriptions)
        ns.$hoverDelay.sink { [weak self] in self?.intent.config.openDelay = $0 }.store(in: &subscriptions)
        ns.$closeDelay.sink { [weak self] in self?.intent.config.closeDelay = $0 }.store(in: &subscriptions)
    }

    private func setupKeyMonitor() {
        // Esc closes the open panel only; other windows (Settings, the editor, pinned images) keep their Esc
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.viewModel.isOpen, windowNumber == self.panelWindow?.windowNumber else { return false }
                if let tabUsesIt = self.viewModel.escapeHandlers[self.viewModel.tab], tabUsesIt() { return true }
                self.close()
                return true
            }
            return handled ? nil : event
        }
    }

    // MARK: - Geometry

    /// Picks the display and re-pins both windows. Runs at start, on display changes, wake and setting changes,
    /// and in "display with the pointer" mode when the pointer moves to another display.
    private func refreshGeometry(pointer: CGPoint? = nil) {
        guard let badgeWindow, let panelWindow else { return }
        guard let info = NotchGeometry.resolve(preference: NotchSettings.shared.display,
                                               pointer: pointer ?? NSEvent.mouseLocation) else {
            // No display for a moment (clamshell while a display reconnects): hide and wait for the next change
            notch = nil
            if viewModel.isOpen { close() }
            badgeWindow.orderOut(nil)
            return
        }
        notch = info
        if viewModel.notchSize != info.rect.size { viewModel.notchSize = info.rect.size }
        if viewModel.hasNotch != info.hasNotch { viewModel.hasNotch = info.hasNotch }
        viewModel.toastMaxWidth = min(460, info.screenFrame.width - 40)

        let badgeWidth = max(info.rect.width + 2 * 160, viewModel.toastMaxWidth + 40)
        badgeWindow.pin(to: info, size: CGSize(width: badgeWidth, height: info.rect.height + ToastLayout.drop + 24))
        panelWindow.pin(to: info, size: NotchWindow.panelWindowSize())
        if !badgeWindow.isVisible { badgeWindow.orderFrontRegardless() }
        FullScreen.shared.refreshSoon()
    }

    private func triggerRect(_ notch: NotchInfo) -> CGRect {
        let ns = NotchSettings.shared
        let badgeShown = !viewModel.isOpen && viewModel.toast == nil && closedModel.badge != nil
        let badgeWidth = ns.badgeHoverOpens && badgeShown ? notch.rect.width + 2 * closedModel.earWidth : nil
        return ActivationZones.trigger(cutout: notch.rect, margin: ns.hoverArea.margin, badgeWidth: badgeWidth)
    }

    private func inTrigger(_ p: CGPoint) -> Bool {
        guard let notch else { return false }
        return ActivationZones.contains(triggerRect(notch), p)
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - Pointer

    private func pointerMoved(_ p: CGPoint) {
        if NotchSettings.shared.display == .pointer, !viewModel.isOpen,
           let notch, !ActivationZones.contains(notch.screenFrame, p) {
            refreshGeometry(pointer: p)
        }
        guard let notch else { return }
        let buttons = NSEvent.pressedMouseButtons != 0
        viewModel.isOpen ? movedWhileOpen(p, notch: notch, buttons: buttons) : movedWhileClosed(p, notch: notch, buttons: buttons)
    }

    private func movedWhileClosed(_ p: CGPoint, notch: NotchInfo, buttons: Bool) {
        let ns = NotchSettings.shared
        let trigger = ActivationZones.contains(triggerRect(notch), p)
        if viewModel.peek != trigger { viewModel.peek = trigger }
        // Click mode: catch the click on the notch itself, let every other click through to the menu bar,
        // and to a full-screen app when the panel shouldn't open over it (cached state, no window server call)
        let fullScreenBlocks = Settings.shared.hideInFullScreen && closedModel.fullScreen
        setIgnoresMouse(badgeWindow, !(ns.activation.opensOnClick && trigger) || fullScreenBlocks)

        if let toast = viewModel.toast, toast.style == .alert, toastTimer == nil,
           ActivationZones.contains(toastRect(toast, notch: notch), p) {
            scheduleToastDismiss(after: 1.0)   // seen
        }

        let fileDrag = buttons && trigger && isFileDrag()
        let hoverOpens = ns.activation.opensOnHover || (fileDrag && ns.dragOpensShelf)
        let verdict = intent.pointerMoved(to: p, at: now, inTrigger: trigger && hoverOpens,
                                          buttonsHeld: buttons, fileDrag: fileDrag && ns.dragOpensShelf)
        handleOpenVerdict(verdict, fileDrag: fileDrag)
    }

    private func movedWhileOpen(_ p: CGPoint, notch: NotchInfo, buttons: Bool) {
        let panelRect = NotchWindow.panelRect(notch: notch)
        let overPanel = ActivationZones.contains(panelRect, p)
        // Only the panel itself takes clicks; the shadow margins pass them to the app below
        setIgnoresMouse(panelWindow, !overPanel)
        // Files dragged in from another app switch to the Shelf; a drag out of the panel (a Recents tile) doesn't
        if buttons, overPanel, !dragFromPanel, NotchSettings.shared.dragOpensShelf, viewModel.tab != .shelf, isFileDrag() {
            viewModel.tab = .shelf
        }
        let verdict = intent.pointerMovedWhileOpen(
            to: p, at: now, inOpenZone: ActivationZones.contains(ActivationZones.open(panel: panelRect), p),
            buttonsHeld: buttons, closeOnExit: closesOnExit)
        handleCloseVerdict(verdict)
    }

    /// Leaving closes the panel unless something holds it open: an editor, Quick Look or a context menu.
    private var closesOnExit: Bool {
        NotchSettings.shared.closeOnPointerExit && viewModel.holds.isEmpty
    }

    private func handleOpenVerdict(_ verdict: HoverIntent.Verdict, fileDrag: Bool) {
        switch verdict {
        case .idle:
            openTimer?.invalidate()
            openTimer = nil
        case .wait(let until):
            openTimer?.invalidate()
            openTimer = oneShot(after: until - now) { [weak self] in self?.reevaluateOpen() }
        case .act:
            openTimer?.invalidate()
            openTimer = nil
            hoverOpen(fileDrag: fileDrag)
        }
    }

    private func reevaluateOpen() {
        guard !viewModel.isOpen, let notch else { return }
        let p = NSEvent.mouseLocation
        let ns = NotchSettings.shared
        let buttons = NSEvent.pressedMouseButtons != 0
        let trigger = ActivationZones.contains(triggerRect(notch), p)
        let fileDrag = buttons && trigger && isFileDrag()
        let hoverOpens = ns.activation.opensOnHover || (fileDrag && ns.dragOpensShelf)
        let verdict = intent.evaluate(at: now, inTrigger: trigger && hoverOpens, buttonsHeld: buttons,
                                      fileDrag: fileDrag && ns.dragOpensShelf)
        handleOpenVerdict(verdict, fileDrag: fileDrag)
    }

    private func hoverOpen(fileDrag: Bool) {
        guard let notch else { return }
        // Checked only now, at the moment of opening, so moving the pointer never asks the window server
        if Settings.shared.hideInFullScreen && FullScreen.shared.isFullScreen { return }
        if fileDrag {
            open(tab: .shelf, reason: .drag)
            return
        }
        if FullScreen.shared.menuOpenNear(notch.rect, on: notch.screen) { return }
        open(tab: openingTab(), reason: .hover)
    }

    private func handleCloseVerdict(_ verdict: HoverIntent.Verdict) {
        switch verdict {
        case .idle:
            closeTimer?.invalidate()
            closeTimer = nil
        case .wait(let until):
            guard closeTimer == nil else { return }
            closeTimer = oneShot(after: until - now) { [weak self] in self?.reevaluateClose() }
        case .act:
            close(deliberate: false)
        }
    }

    private func reevaluateClose() {
        closeTimer = nil
        guard viewModel.isOpen, let notch else { return }
        let p = NSEvent.mouseLocation
        let zone = ActivationZones.open(panel: NotchWindow.panelRect(notch: notch))
        let verdict = intent.evaluateOpen(at: now, inOpenZone: ActivationZones.contains(zone, p),
                                          buttonsHeld: NSEvent.pressedMouseButtons != 0,
                                          closeOnExit: closesOnExit)
        handleCloseVerdict(verdict)
    }

    private func mouseDown(at p: CGPoint, type: NSEvent.EventType) {
        dragChangeCount = NSPasteboard(name: .drag).changeCount
        fileDragCache = nil
        guard let notch else { return }
        dragFromPanel = viewModel.isOpen && ActivationZones.contains(NotchWindow.panelRect(notch: notch), p)
        let inMenuBar = ActivationZones.contains(notch.screenFrame, p) && p.y >= notch.screenFrame.maxY - notch.menuBarHeight
        if inMenuBar && !inTrigger(p) { intent.menuBarClicked(at: now) }
        openTimer?.invalidate()
        openTimer = nil

        guard viewModel.isOpen else { return }
        if ActivationZones.contains(NotchWindow.panelRect(notch: notch), p) { return }
        // While previewing, Settings stays usable
        if openedBy == .preview, let settings = previewMove?.window ?? SettingsWindow.window,
           settings.isVisible, settings.frame.contains(p) { return }
        // An editor or Quick Look inside the panel keeps it open; Esc, the shortcut and the menu still close it
        guard viewModel.holds.isEmpty else { return }
        close()
    }

    private func badgeClicked(at p: CGPoint) {
        guard !viewModel.isOpen, NotchSettings.shared.activation.opensOnClick, inTrigger(p) else { return }
        if Settings.shared.hideInFullScreen && FullScreen.shared.isFullScreen { return }
        open(tab: openingTab(), reason: .click)
    }

    private func panelClicked(at p: CGPoint) {
        // In click mode, clicking the notch again closes the panel
        guard NotchSettings.shared.activation == .click, let notch,
              ActivationZones.contains(notch.rect, p) else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.close() } }
    }

    private func trackingResumed() {
        refreshGeometry()
        intent.closedDeliberately(pointerInTrigger: inTrigger(NSEvent.mouseLocation))
        // A hover pause counts uptime, which stops while the Mac sleeps; line it up with the clock again
        if let end = hoverPauseEnds {
            let left = end.timeIntervalSinceNow
            intent.pause(for: max(0, left), at: now)
            if left <= 0 { hoverPauseEnds = nil }
        }
    }

    /// Files are being dragged from Finder or another app (not a window resize or a text selection).
    /// The drag pasteboard changes when a drag starts; reading its types is cached per drag.
    private func isFileDrag() -> Bool {
        let pb = NSPasteboard(name: .drag)
        let count = pb.changeCount
        guard count != dragChangeCount else { return false }
        if let cache = fileDragCache, cache.count == count { return cache.isFiles }
        let isFiles = pb.types?.contains(.fileURL) ?? false
        fileDragCache = (count, isFiles)
        return isFiles
    }

    // MARK: - Public

    /// Stops hover from opening the panel, e.g. while an area capture or the color picker runs. Calls nest:
    /// hover comes back when the last one ends, then the pointer has to leave the notch first and hover waits
    /// half a second more.
    func suspendHover(_ suspend: Bool) {
        suspensions = max(0, suspensions + (suspend ? 1 : -1))
        setHoverSuspended(suspensions > 0)
    }

    private func setHoverSuspended(_ suspended: Bool) {
        guard suspended != self.suspended else { return }
        self.suspended = suspended
        intent.setSuspended(suspended, at: now, pointerInTrigger: inTrigger(NSEvent.mouseLocation))
        openTimer?.invalidate()
        openTimer = nil
        suspendSafety?.cancel()
        if suspended {
            // A caller that never says it finished must not switch hover off for good
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.suspensions = 0
                    self?.setHoverSuspended(false)
                }
            }
            suspendSafety = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: work)
        }
    }

    /// Stops hover from opening the panel for a while, e.g. "Pause hover for 1 hour" in the menu bar. 0 resumes.
    func pauseHover(for duration: TimeInterval) {
        hoverPauseEnds = duration > 0 ? Date(timeIntervalSinceNow: duration) : nil
        intent.pause(for: duration, at: now)
        openTimer?.invalidate()
        openTimer = nil
    }

    /// When a hover pause ends, or nil when hover isn't paused (for the menu bar).
    var hoverPausedUntil: Date? {
        guard let end = hoverPauseEnds, end > Date() else { return nil }
        return end
    }

    /// For `--snapshot`: the window showing the notch now, and the cutout in window coordinates.
    var snapshotTarget: (NSWindow, CGRect)? {
        guard let notch, let window = viewModel.isOpen ? panelWindow : badgeWindow else { return nil }
        let r = notch.rect
        return (window, CGRect(x: r.minX - window.frame.minX, y: r.minY - window.frame.minY, width: r.width, height: r.height))
    }

    /// The tab the panel opens on.
    private func openingTab() -> NotchTab {
        PanelSettings.shared.tabWhenOpened
    }

    func toggle() {
        viewModel.isOpen ? close() : open(tab: openingTab(), manual: true)
    }

    /// Opens the panel on `tab`. A manual open (shortcut, menu, another feature) takes keyboard focus;
    /// opening the tab that is already shown closes the panel, so a tab's shortcut toggles it.
    func open(tab: NotchTab, manual: Bool = true) {
        open(tab: tab, reason: manual ? .manual : .hover)
    }

    private func open(tab: NotchTab, reason: OpenReason) {
        if viewModel.isOpen && viewModel.tab == tab && reason == .manual {
            close()
            return
        }
        viewModel.tab = tab
        if viewModel.isOpen {
            if reason.takesFocus { panelWindow?.makeKey() }
            return
        }
        guard let notch, let panelWindow else { return }
        orderOutWork?.cancel()
        orderOutWork = nil
        openTimer?.invalidate()
        openTimer = nil

        let p = NSEvent.mouseLocation
        let panelRect = NotchWindow.panelRect(notch: notch)
        panelWindow.ignoresMouseEvents = !ActivationZones.contains(panelRect, p)
        panelWindow.orderFrontRegardless()
        if reason.takesFocus { panelWindow.makeKey() }
        badgeWindow?.ignoresMouseEvents = true
        viewModel.peek = false

        let inside = ActivationZones.contains(ActivationZones.open(panel: panelRect), p)
        intent.opened(pointerInside: inside || reason == .hover || reason == .drag)
        openedBy = reason
        withAnimation(Self.morph) { viewModel.isOpen = true }
        tracker.updatePoll()

        if reason == .hover && NotchSettings.shared.hapticOnOpen {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        // An alert that waited for the user is seen now; let the banner go after the usual time
        if let toast = viewModel.toast, toast.style == .alert {
            scheduleToastDismiss(after: Settings.shared.toastDuration)
        }
        Log.info("open tab=\(tab.rawValue) by=\(reason.rawValue)")
    }

    /// Closes the panel. A deliberate close (Esc, the shortcut, a click outside, the menu, a feature)
    /// keeps hover from reopening it until the pointer has left the notch.
    func close() { close(deliberate: true) }

    private func close(deliberate: Bool) {
        guard viewModel.isOpen else { return }
        let by = openedBy
        closeTimer?.invalidate()
        closeTimer = nil
        openedBy = nil
        let p = NSEvent.mouseLocation
        if deliberate { intent.closedDeliberately(pointerInTrigger: inTrigger(p)) } else { intent.closedByLeaving() }
        if by == .preview { endPreviewMove() }

        withAnimation(Self.morph) { viewModel.isOpen = false }
        panelWindow?.ignoresMouseEvents = true
        // Hand keyboard focus back to the app the user was in right away, since a paste may follow at once;
        // ordering out and straight back in keeps the window on screen for the close animation
        if let panel = panelWindow, panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        // Take the window off screen once the shape has shrunk back into the notch, so nothing flashes
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.viewModel.isOpen else { return }
                self.panelWindow?.orderOut(nil)
            }
        }
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeAnimation, execute: work)
        tracker.updatePoll()
        Log.info("close deliberate=\(deliberate) openedBy=\(by?.rawValue ?? "-")")
    }

    // MARK: - Preview

    private func togglePreview() {
        if viewModel.isOpen {
            if openedBy == .preview { close() }
            return
        }
        open(tab: openingTab(), reason: .preview)
        movePreviewedSettings()
    }

    /// Moves Settings below the panel while previewing, so the panel doesn't cover it; put back afterwards
    /// unless the user moved it meanwhile.
    private func movePreviewedSettings() {
        guard let notch, let window = SettingsWindow.window, window.isVisible,
              let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        let panelRect = NotchWindow.panelRect(notch: notch)
        let frame = window.frame
        guard frame.intersects(panelRect) else { return }
        let top = panelRect.minY - 16
        let y = max(visible.minY, top - frame.height)
        let moved = CGRect(x: frame.minX, y: y, width: frame.width, height: frame.height)
        window.setFrame(moved, display: true, animate: true)
        previewMove = (window, frame, window.frame)
    }

    private func endPreviewMove() {
        guard let move = previewMove else { return }
        previewMove = nil
        if move.window.isVisible, move.window.frame == move.moved {
            move.window.setFrame(move.original, display: true, animate: true)
        }
    }

    // MARK: - Helpers

    /// One spring for every change of the notch shape, so a notice replacing a badge doesn't bounce.
    static let morph = Animation.spring(response: 0.4, dampingFraction: 0.86)

    /// Mouse events arrive often; only touch the window when the value changes.
    private func setIgnoresMouse(_ window: NSWindow?, _ ignore: Bool) {
        if let window, window.ignoresMouseEvents != ignore { window.ignoresMouseEvents = ignore }
    }

    private func oneShot(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Timer {
        let t = Timer(timeInterval: max(0, seconds), repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(t, forMode: .common)
        return t
    }
}
