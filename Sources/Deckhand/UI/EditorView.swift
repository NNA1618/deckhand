import SwiftUI
import AppKit

/// The image editor. Looks like the notch panel: the same glass, translucent capsules for the
/// toolbar groups and a white capsule for the active tool. Only the canvas behind the image is a
/// neutral dark grey, so colors in the image are judged correctly.
struct EditorView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var settings = Settings.shared
    /// Copy, close and give focus back to the app the user came from.
    let onDone: () -> Void
    @FocusState private var textFocused: Bool

    var body: some View {
        ZStack {
            GlassBackground(cornerRadius: 16, style: settings.panelStyle, tint: settings.glassTint)
                .ignoresSafeArea()
            VStack(spacing: 10) {
                // In the title bar row, next to the window buttons
                topBar
                    .padding(.leading, 78)
                    .padding(.trailing, 14)
                    .frame(height: 36)
                    .padding(.top, 2)
                HStack(spacing: 10) {
                    canvasArea
                    if model.askVisible {
                        askPanel
                            .frame(width: 300)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 14)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.askVisible)
                bottomBar
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .foregroundColor(Theme.fg)
        .preferredColorScheme(.dark)
    }

    // MARK: - Top bar: tools and style

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(EditorTool.allCases) { tool in
                    let active = model.tool == tool
                    Button {
                        model.perform(.tool(tool))
                    } label: {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 30, height: 26)
                            .foregroundColor(active ? .black : Theme.fgDim)
                            .background(Capsule().fill(active ? Theme.accent : Color.clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(Text(verbatim: "\(tool.title) (\(KeyNames.name(for: UInt32(tool.keyCode))))"))
                    .accessibilityLabel(Text(tool.title))
                }
            }
            .padding(3)
            .glassChip(in: Capsule())

            HStack(spacing: 4) {
                ForEach(Array(EditorModel.palette.enumerated()), id: \.offset) { _, c in
                    Button { model.color = c } label: {
                        Circle()
                            .fill(c)
                            .frame(width: 15, height: 15)
                            .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                            .overlay(
                                Circle().stroke(Theme.accent, lineWidth: 2)
                                    .frame(width: 21, height: 21)
                                    .opacity(model.color == c ? 1 : 0)
                            )
                            .frame(width: 22, height: 26)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                ColorWell(color: $model.color, owner: model)
                    .help(Text("Custom color"))
                Divider().frame(height: 16).overlay(Theme.border)
                sizePicker
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .glassChip(in: Capsule())
            .opacity(model.tool.usesColor ? 1 : 0.45)

            Spacer(minLength: 8)

            HStack(spacing: 0) {
                iconButton("arrow.uturn.backward", "Undo", keys: "⌘Z", enabled: model.canUndo) { model.undo() }
                iconButton("arrow.uturn.forward", "Redo", keys: "⇧⌘Z", enabled: model.canRedo) { model.redo() }
            }
            .padding(.horizontal, 4)
            .glassChip(in: Capsule())
        }
        .lineLimit(1)
    }

    /// Stroke width, or text size while the text tool is active.
    @ViewBuilder
    private var sizePicker: some View {
        if model.tool == .text {
            ForEach(0..<3) { level in
                Button { model.textSizeLevel = level } label: {
                    Text(verbatim: "A")
                        .font(.system(size: [10, 13, 16][level], weight: .bold))
                        .foregroundColor(model.textSizeLevel == level ? .black : Theme.fgDim)
                        .frame(width: 24, height: 22)
                        .background(Capsule().fill(model.textSizeLevel == level ? Theme.accent : Color.clear))
                }
                .buttonStyle(.plain)
                .help(Text([LocalizedStringKey("Small text"), "Medium text", "Large text"][level]))
            }
        } else {
            ForEach(0..<3) { level in
                Button { model.widthLevel = level } label: {
                    Circle()
                        .fill(model.widthLevel == level ? Color.black : Theme.fgDim)
                        .frame(width: CGFloat(4 + level * 3), height: CGFloat(4 + level * 3))
                        .frame(width: 24, height: 22)
                        .background(Capsule().fill(model.widthLevel == level ? Theme.accent : Color.clear))
                }
                .buttonStyle(.plain)
                .help(Text([LocalizedStringKey("Thin"), "Medium", "Thick"][level]))
            }
        }
    }

    // MARK: - Bottom bar: zoom, status and actions

    private var bottomBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                iconButton("minus.magnifyingglass", "Zoom Out", keys: "⌘−", enabled: true) { model.perform(.zoomOut) }
                Button { model.perform(model.zoom == nil ? .zoomActual : .zoomFit) } label: {
                    Text(zoomLabel)
                        .font(Theme.label.monospacedDigit())
                        .foregroundColor(Theme.fgDim)
                        .frame(minWidth: 48)
                }
                .buttonStyle(.plain)
                .help(Text("Fit or actual size") + Text(verbatim: " (⌘0, ⌘1)"))
                iconButton("plus.magnifyingglass", "Zoom In", keys: "⌘+", enabled: true) { model.perform(.zoomIn) }
            }
            .padding(.horizontal, 4)
            .glassChip(in: Capsule())

            if let status = model.status {
                Text(status).font(Theme.label).foregroundColor(Theme.fg)
                    .transition(.opacity)
            }
            Spacer(minLength: 8)

            HStack(spacing: 0) {
                iconButton("text.viewfinder", "Copy Text from Image", keys: nil, enabled: true) { model.copyRecognizedText() }
                iconButton("sparkle", "Ask Claude", keys: nil, enabled: true, agent: .claudeCode) { model.askVisible.toggle() }
                iconButton("pin", "Pin on Screen", keys: nil, enabled: true) {
                    model.commitText()
                    if let image = model.renderNSImage() { PinnedImageWindow.show(image) }
                }
                iconButton("square.and.arrow.down", "Save", keys: "⌘S", enabled: true) { model.save() }
                iconButton("doc.on.doc", "Copy", keys: "⌘C", enabled: true) { model.copyToClipboard() }
            }
            .padding(.horizontal, 4)
            .glassChip(in: Capsule())

            PrimaryButton(title: "Done", action: onDone)
                .help(Text("Copy and close"))
        }
        .lineLimit(1)
        .animation(.easeOut(duration: 0.15), value: model.status)
    }

    private var zoomLabel: String {
        guard let zoom = model.zoom else { return String(localized: "Fit") }
        return Double(zoom).formatted(.percent.precision(.fractionLength(0)))
    }

    /// A toolbar button with a symbol, or with an agent's own app icon for an action that runs it.
    private func iconButton(_ symbol: String, _ help: LocalizedStringKey, keys: String?, enabled: Bool,
                            agent: AgentProvider? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let agent {
                    AgentIcon(provider: agent, size: 16).opacity(enabled ? 1 : 0.5)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(enabled ? Theme.fgDim : Theme.fgMute.opacity(0.5))
                }
            }
            .frame(width: 30, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(keys.map { Text(help) + Text(verbatim: " (\($0))") } ?? Text(help))
        .accessibilityLabel(Text(help))
    }

    // MARK: - Ask Claude

    private var askPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask Claude about the image").font(Theme.title).foregroundColor(Theme.fg)
            TextField("What’s in this screenshot?", text: $model.question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body).foregroundColor(Theme.fg)
                .lineLimit(1...4)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .glassChip(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onSubmit { model.askClaude() }
            HStack(spacing: 8) {
                PrimaryButton(title: "Ask") { model.askClaude() }
                    .disabled(model.asking)
                    .opacity(model.asking ? 0.5 : 1)
                if model.asking { ProgressView().controlSize(.small) }
                Spacer()
                if !model.answer.isEmpty {
                    GlassButton(title: "Copy", symbol: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.answer, forType: .string)
                    }
                }
            }
            if let error = model.askError {
                Text(error).font(Theme.caption).foregroundColor(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // An AppKit text view, so ⌘C and ⌘A act on the selected answer, not on the image
            ReadOnlyText(text: model.answer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassChip(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Canvas

    private var canvasArea: some View {
        GeometryReader { geo in
            let fit = fitScale(in: geo.size)
            let k = model.zoom.map { $0 / model.pixelScale } ?? fit
            let size = CGSize(width: model.imageSize.width * k, height: model.imageSize.height * k)
            ScrollView([.horizontal, .vertical]) {
                canvas(k: k, size: size)
                    .frame(width: max(size.width + 32, geo.size.width), height: max(size.height + 32, geo.size.height))
            }
            .scrollIndicators(model.zoom == nil ? .hidden : .automatic)
            .onAppear { model.fitZoom = fit * model.pixelScale }
            .onChange(of: geo.size) { _, new in model.fitZoom = fitScale(in: new) * model.pixelScale }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { g in
                        if pinchStart == nil { pinchStart = model.zoom ?? model.fitZoom }
                        model.setZoom((pinchStart ?? 1) * g.magnification)
                    }
                    .onEnded { _ in pinchStart = nil }
            )
        }
        // Neutral, so the image's colors look right whatever is behind the window
        .background(Color(white: Theme.flatForSnapshot ? 0.13 : 0.11).opacity(0.92),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @State private var pinchStart: CGFloat?

    /// Image pixels to points so the image fits with a margin, never enlarged past actual size.
    private func fitScale(in available: CGSize) -> CGFloat {
        let img = model.imageSize
        guard img.width > 0, img.height > 0 else { return 1 }
        return max(0.01, min((available.width - 32) / img.width, (available.height - 32) / img.height, 1 / model.pixelScale))
    }

    private func canvas(k: CGFloat, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                model.drawContent(in: &ctx, scale: k, includeDraft: true, outlines: false)
                if let crop = model.cropRect {
                    let r = CGRect(x: crop.minX * k, y: crop.minY * k, width: crop.width * k, height: crop.height * k)
                    var dim = Path(CGRect(origin: .zero, size: size))
                    dim.addRect(r)
                    ctx.fill(dim, with: .color(.black.opacity(0.6)), style: FillStyle(eoFill: true))
                    ctx.stroke(Path(r), with: .color(.white), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                }
                if let b = model.selectedBounds {
                    let r = CGRect(x: b.minX * k - 4, y: b.minY * k - 4, width: b.width * k + 8, height: b.height * k + 8)
                    ctx.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(.white), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                }
            }
            .frame(width: size.width, height: size.height)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.border, lineWidth: 1))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        // Take focus from the Ask field or the answer, so tool letters, ⌘Z, ⌘C and ⌫
                        // go back to the editor. A text being placed on the image keeps it.
                        if !textFocused, let window = model.window, window.firstResponder is NSText {
                            window.makeFirstResponder(nil)
                        }
                        model.dragChanged(start: scaled(g.startLocation, k), current: scaled(g.location, k))
                    }
                    .onEnded { g in
                        model.dragEnded(start: scaled(g.startLocation, k), end: scaled(g.location, k))
                        if model.pendingTextPoint != nil { textFocused = true }
                    }
            )
            .pointerStyle(model.tool == .select ? .default : .rectSelection)

            if let at = model.pendingTextPoint {
                TextField("Text", text: $model.pendingText)
                    .textFieldStyle(.plain)
                    .font(.system(size: max(model.fontSize * k, 11), weight: .bold))
                    .foregroundColor(model.color)
                    .frame(minWidth: 120)
                    .fixedSize()
                    .padding(2)
                    .background(Color.black.opacity(0.35))
                    .overlay(Rectangle().stroke(Theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    .offset(x: at.x * k - 2, y: at.y * k - 2)
                    .focused($textFocused)
                    .onSubmit { model.commitText() }
                    .onExitCommand { model.cancelText() }
            }

            if model.cropRect != nil {
                HStack(spacing: 8) {
                    PrimaryButton(title: "Crop") { model.applyCrop() }
                    GlassButton(title: "Cancel") { model.cancelCrop() }
                }
                .padding(6)
                .offset(x: 10, y: 10)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func scaled(_ p: CGPoint, _ k: CGFloat) -> CGPoint {
        CGPoint(x: p.x / k, y: p.y / k)
    }
}

/// Selectable, non-editable text backed by NSTextView, so the standard Copy and Select All work on it.
struct ReadOnlyText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = false
            view.textContainerInset = .zero
            view.textContainer?.lineFragmentPadding = 0
            view.font = .systemFont(ofSize: 13)
            view.textColor = NSColor.white.withAlphaComponent(0.95)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }
}

/// Opens editor windows and gives each its keyboard handling and lifetime.
@MainActor
enum EditorWindow {
    /// Everything that lives exactly as long as one editor window.
    private final class Session {
        let window: NSWindow
        let model: EditorModel
        var keyMonitor: Any?
        var closeObserver: NSObjectProtocol?
        /// The app the user was in, which gets focus back on Done.
        let previousApp: NSRunningApplication?

        init(window: NSWindow, model: EditorModel, previousApp: NSRunningApplication?) {
            self.window = window
            self.model = model
            self.previousApp = previousApp
        }
    }

    private static var sessions: [ObjectIdentifier: Session] = [:]

    /// The model of an open editor window, for snapshots.
    static func model(for window: NSWindow) -> EditorModel? { sessions[ObjectIdentifier(window)]?.model }

    @discardableResult
    static func open(image: NSImage) -> NSWindow? {
        guard let model = EditorModel(image: image, tool: CaptureSettings.shared.editorDefaultTool) else {
            Log.info("editor: cannot read image")
            return nil
        }
        let front = NSWorkspace.shared.frontmostApplication
        let previous = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let id = ObjectIdentifier(window)
        let view = EditorView(model: model, onDone: { done(id) })
        window.contentViewController = NSHostingController(rootView: view)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 460)
        window.title = String(localized: "Editor")
        model.window = window

        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let pts = image.size
        let chrome = NSSize(width: 60, height: 140)
        let k = min(1, (visible.width * 0.85 - chrome.width) / max(pts.width, 1), (visible.height * 0.85 - chrome.height) / max(pts.height, 1))
        window.setContentSize(NSSize(width: max(900, pts.width * k + chrome.width), height: max(480, pts.height * k + chrome.height)))
        window.center()

        let session = Session(window: window, model: model, previousApp: previous)
        let windowNumber = window.windowNumber
        session.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard event.windowNumber == windowNumber else { return event }
            let keyCode = Int(event.keyCode)
            let modifiers = Shortcut(event: event).modifiers
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let window, window.attachedSheet == nil else { return false }
                let textFocused = window.firstResponder is NSText
                guard let command = EditorCommand.from(keyCode: keyCode, modifiers: modifiers, textFocused: textFocused) else { return false }
                return model.perform(command)
            }
            return consumed ? nil : event
        }
        session.closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { closed(id) }
        }
        sessions[id] = session

        AppActivation.windowOpened(window)
        window.makeKeyAndOrderFront(nil)
        Log.info("editor opened \(Int(pts.width))x\(Int(pts.height))")
        return window
    }

    /// Done: copy, close, and hand focus back so the next ⌘V lands in the app the user came from.
    /// The window closes even if copying failed, and the notch says so, since the editor's own notice goes with it.
    private static func done(_ id: ObjectIdentifier) {
        guard let session = sessions[id] else { return }
        session.model.copyToClipboard { copied in
            let previous = session.previousApp
            session.window.close()
            if !copied {
                PanelActions.notch?.showToast(symbol: "exclamationmark.triangle",
                                              text: String(localized: "Not copied"))
            }
            guard let previous, !previous.isTerminated else { return }
            NSApp.yieldActivation(to: previous)
            previous.activate()
        }
    }

    private static func closed(_ id: ObjectIdentifier) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        if let monitor = session.keyMonitor { NSEvent.removeMonitor(monitor) }
        if let observer = session.closeObserver { NotificationCenter.default.removeObserver(observer) }
        session.model.close()
        ColorPanelBridge.shared.release(owner: session.model)
        Log.info("editor closed")
    }
}

/// A rainbow swatch that opens the system color panel and feeds the picked color back.
struct ColorWell: View {
    @Binding var color: Color
    let owner: AnyObject

    var body: some View {
        Button {
            ColorPanelBridge.shared.open(current: color, owner: owner) { color = $0 }
        } label: {
            Circle()
                .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                .frame(width: 15, height: 15)
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                .frame(width: 22, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// The shared system color panel, connected to one editor at a time.
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((Color) -> Void)?
    private weak var owner: AnyObject?

    func open(current: Color, owner: AnyObject, onChange: @escaping (Color) -> Void) {
        self.onChange = onChange
        self.owner = owner
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = NSColor(current)
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }

    /// The editor closed: forget it, so the panel can't recolor a window that is gone or keep it alive.
    func release(owner: AnyObject) {
        guard self.owner === owner || self.owner == nil else { return }
        onChange = nil
        self.owner = nil
        // NSColorPanel.shared creates the panel, and with it a saved panel state; only touch one that exists
        guard NSColorPanel.sharedColorPanelExists else { return }
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        if panel.isVisible { panel.orderOut(nil) }
    }

    @objc private func changed(_ panel: NSColorPanel) {
        onChange?(Color(nsColor: panel.color))
    }
}
