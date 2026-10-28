import SwiftUI
import AppKit

struct EditorView: View {
    @ObservedObject var model: EditorModel
    let onClose: () -> Void
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 14)
                .padding(.top, 30)   // clear of the window buttons
                .padding(.bottom, 10)
            Divider().overlay(Theme.border)
            HStack(spacing: 0) {
                canvasArea
                    .padding(20)
                if model.askVisible {
                    Divider().overlay(Theme.border)
                    askPanel
                        .frame(width: 320)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.askVisible)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(EditorTool.allCases) { tool in
                    Button {
                        model.commitText()
                        model.tool = tool
                        if tool != .crop { model.cancelCrop() }
                    } label: {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 30, height: 26)
                            .foregroundColor(model.tool == tool ? .black : Theme.fgDim)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(model.tool == tool ? Theme.accent : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(Text(verbatim: "\(tool.title) (\(String(tool.shortcut.character).uppercased()))"))
                    .keyboardShortcut(model.pendingTextPoint == nil ? KeyboardShortcut(tool.shortcut, modifiers: []) : nil)
                }
            }
            .padding(3)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            HStack(spacing: 6) {
                ForEach(Array(EditorModel.palette.enumerated()), id: \.offset) { _, c in
                    Circle()
                        .fill(c)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                        .overlay(
                            Circle().stroke(Theme.accent, lineWidth: 2)
                                .frame(width: 22, height: 22)
                                .opacity(model.color == c ? 1 : 0)
                        )
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                        .onTapGesture { model.color = c }
                }
                ColorWell(color: $model.color)
                    .help(Text("Custom color"))
            }

            HStack(spacing: 4) {
                ForEach(0..<3) { level in
                    Button { model.widthLevel = level } label: {
                        Circle()
                            .fill(model.widthLevel == level ? Theme.accent : Theme.fgDim)
                            .frame(width: CGFloat(4 + level * 4), height: CGFloat(4 + level * 4))
                            .frame(width: 24, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(model.widthLevel == level ? Theme.surface2 : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(Text([LocalizedStringKey("Thin"), "Medium", "Thick"][level]))
                }
            }

            HStack(spacing: 2) {
                iconButton("arrow.uturn.backward", "Undo ⌘Z", enabled: model.canUndo) { model.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                iconButton("arrow.uturn.forward", "Redo ⇧⌘Z", enabled: model.canRedo) { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }

            Spacer(minLength: 8)

            if let status = model.status {
                Text(status).font(Theme.monoSmall).foregroundColor(Theme.accent)
                    .transition(.opacity)
            }
            iconButton("sparkle", "Ask Claude", enabled: true) { model.askVisible.toggle() }
            iconButton("pin", "Pin on Screen", enabled: true) {
                model.commitText()
                if let image = model.renderNSImage() { PinnedImageWindow.show(image) }
            }
            iconButton("square.and.arrow.down", "Save ⌘S", enabled: true) { model.save() }
                .keyboardShortcut("s", modifiers: .command)
            iconButton("doc.on.doc", "Copy ⌘C", enabled: true) { model.copyToClipboard() }
                .keyboardShortcut(model.pendingTextPoint == nil ? KeyboardShortcut("c", modifiers: .command) : nil)
            PrimaryButton(title: "Done") {
                model.copyToClipboard()
                onClose()
            }
            .fixedSize()
            .help(Text("Copy and close"))
        }
        .lineLimit(1)
        .animation(.easeOut(duration: 0.15), value: model.status)
    }

    private func iconButton(_ symbol: String, _ help: LocalizedStringKey, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 26)
                .foregroundColor(enabled ? Theme.fgDim : Theme.fgMute.opacity(0.5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(Text(help))
    }

    // MARK: - Ask Claude

    private var askPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask Claude about this image").font(Theme.title).foregroundColor(Theme.fg)
            TextField("What is on this screenshot?", text: $model.question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body).foregroundColor(Theme.fg)
                .lineLimit(1...4)
                .padding(9)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onSubmit { model.askClaude() }
            HStack {
                PrimaryButton(title: "Ask") { model.askClaude() }
                    .disabled(model.asking)
                if model.asking { ProgressView().controlSize(.small) }
                Spacer()
                if !model.answer.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.answer, forType: .string)
                    } label: { Image(systemName: "doc.on.doc").foregroundColor(Theme.fgDim) }
                    .buttonStyle(.plain)
                    .help(Text("Copy"))
                }
            }
            if let error = model.askError {
                Text(error).font(Theme.caption).foregroundColor(Theme.warn)
            }
            ScrollView {
                Text(model.answer)
                    .font(Theme.body).foregroundColor(Theme.fg)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fadeBottom()
        }
        .padding(16)
    }

    // MARK: - Canvas

    private var canvasArea: some View {
        GeometryReader { geo in
            let img = model.imageSize
            let k = min(geo.size.width / img.width, geo.size.height / img.height, 1 / model.pixelScale)
            let size = CGSize(width: img.width * k, height: img.height * k)

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
                }
                .frame(width: size.width, height: size.height)
                .overlay(
                    RoundedRectangle(cornerRadius: 2).stroke(Theme.border, lineWidth: 1)
                )
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            model.dragChanged(start: scaled(g.startLocation, k), current: scaled(g.location, k))
                        }
                        .onEnded { g in
                            model.dragEnded(start: scaled(g.startLocation, k), end: scaled(g.location, k))
                            if model.pendingTextPoint != nil { textFocused = true }
                        }
                )
                .onHover { inside in
                    if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                }

                if let at = model.pendingTextPoint {
                    TextField("Text", text: $model.pendingText)
                        .textFieldStyle(.plain)
                        .font(.system(size: max(model.strokeWidth * 6 * k, 11), weight: .bold))
                        .foregroundColor(model.color)
                        .frame(minWidth: 120)
                        .fixedSize()
                        .padding(2)
                        .background(Color.black.opacity(0.35))
                        .overlay(Rectangle().stroke(Theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        .offset(x: at.x * k - 2, y: at.y * k - 2)
                        .focused($textFocused)
                        .onSubmit { model.commitText() }
                        .onExitCommand { model.pendingTextPoint = nil }
                }

                if model.cropRect != nil {
                    HStack(spacing: 8) {
                        PrimaryButton(title: "Crop") { model.applyCrop() }
                            .keyboardShortcut(.return, modifiers: [])
                        Button("Cancel") { model.cancelCrop() }
                            .buttonStyle(.plain).font(Theme.monoSmall).foregroundColor(Theme.fgDim)
                            .keyboardShortcut(.escape, modifiers: [])
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .offset(x: 10, y: 10)
                }
            }
            .frame(width: size.width, height: size.height)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    private func scaled(_ p: CGPoint, _ k: CGFloat) -> CGPoint {
        CGPoint(x: p.x / k, y: p.y / k)
    }
}

@MainActor
enum EditorWindow {
    private static var windows: [NSWindow] = []

    @discardableResult
    static func open(image: NSImage) -> NSWindow? {
        guard let model = EditorModel(image: image) else {
            Log.info("editor: cannot read image")
            return nil
        }
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let view = EditorView(model: model, onClose: { [weak window] in window?.close() })
        window.contentViewController = NSHostingController(rootView: view)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 940, height: 460)

        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let pts = image.size
        let k = min(1, (visible.width * 0.85 - 40) / max(pts.width, 1), (visible.height * 0.85 - 110) / max(pts.height, 1))
        let size = NSSize(width: max(960, pts.width * k + 40), height: max(480, pts.height * k + 110))
        window.setContentSize(size)
        window.center()

        windows.append(window)
        let closingId = ObjectIdentifier(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                windows.removeAll { ObjectIdentifier($0) == closingId }
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Log.info("editor opened \(Int(pts.width))x\(Int(pts.height))")
        return window
    }
}

/// A rainbow swatch that opens the system color panel and feeds the picked color back.
struct ColorWell: View {
    @Binding var color: Color

    var body: some View {
        Button {
            ColorPanelBridge.shared.open(current: color) { color = $0 }
        } label: {
            Circle()
                .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((Color) -> Void)?

    func open(current: Color, onChange: @escaping (Color) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = NSColor(current)
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) {
        onChange?(Color(nsColor: panel.color))
    }
}
