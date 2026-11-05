import AppKit
import SwiftUI

/// Keeps an image floating above all windows, like a sticky reference.
/// Drag to move, scroll or pinch to resize, double-click, Esc or ⌘W to close.
@MainActor
enum PinnedImageWindow {
    private static var windows: [ObjectIdentifier: (panel: NSPanel, observer: NSObjectProtocol)] = [:]
    /// Each new pin steps down and left from the previous one, so they don't stack exactly.
    static let cascadeStep: CGFloat = 28

    static func show(_ image: NSImage) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let k = min(1, 480 / max(image.size.width, 1), 360 / max(image.size.height, 1))
        let size = NSSize(width: image.size.width * k, height: image.size.height * k)
        let origin = origin(for: size, in: visible, index: windows.count)

        let panel = PinPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.aspectRatio = image.size
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = NSHostingView(rootView: PinnedImageView(image: image) { [weak panel] in panel?.close() })

        let id = ObjectIdentifier(panel)
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let entry = windows.removeValue(forKey: id) { NotificationCenter.default.removeObserver(entry.observer) }
            }
        }
        windows[id] = (panel, observer)
        panel.orderFrontRegardless()
    }

    /// Top right of the visible frame, stepped by `index`; wraps back to the corner before leaving the screen.
    static func origin(for size: NSSize, in visible: NSRect, index: Int) -> NSPoint {
        let maxSteps = max(1, Int((visible.height - size.height - 48) / cascadeStep))
        let step = CGFloat(index % maxSteps) * cascadeStep
        return NSPoint(x: max(visible.minX, visible.maxX - size.width - 24 - step),
                       y: max(visible.minY, visible.maxY - size.height - 24 - step))
    }
}

private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { close() }

    /// Borderless windows have no close button, so the standard ⌘W would only beep.
    override func performClose(_ sender: Any?) { close() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // By key code, so it works with any keyboard layout
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command, event.keyCode == 13 {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        resize(by: 1 + event.scrollingDeltaY / 200)
    }

    override func magnify(with event: NSEvent) {
        resize(by: 1 + event.magnification)
    }

    /// Resizes around the window's center, keeping the aspect ratio.
    private func resize(by factor: CGFloat) {
        var frame = self.frame
        let newWidth = min(max(frame.width * factor, 80), 2400)
        let ratio = frame.height / max(frame.width, 1)
        let newSize = NSSize(width: newWidth, height: newWidth * ratio)
        frame.origin.x += (frame.width - newSize.width) / 2
        frame.origin.y += (frame.height - newSize.height) / 2
        frame.size = newSize
        setFrame(frame, display: true)
    }
}

private struct PinnedImageView: View {
    let image: NSImage
    let onClose: () -> Void
    @State private var hover = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if hover {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.fg)
                            .frame(width: 22, height: 22)
                            .glassChip(in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(7)
                    .help(Text("Close"))
                    .accessibilityLabel(Text("Close"))
                }
            }
            .onHover { hover = $0 }
            .onTapGesture(count: 2, perform: onClose)
            .contextMenu {
                Button("Copy") {
                    if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                        rep.size = image.size
                        if let png = rep.representation(using: .png, properties: [:]) { ImageExport.copyPNG(png) }
                    }
                }
                Button("Close", action: onClose)
            }
    }
}
