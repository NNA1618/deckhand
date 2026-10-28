import AppKit
import SwiftUI

/// Keeps an image floating above all windows, like a sticky reference.
/// Drag to move, scroll or pinch to resize, double-click or Esc to close.
@MainActor
enum PinnedImageWindow {
    private static var windows: [NSWindow] = []

    static func show(_ image: NSImage) {
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let k = min(1, 480 / max(image.size.width, 1), 360 / max(image.size.height, 1))
        let size = NSSize(width: image.size.width * k, height: image.size.height * k)

        let panel = PinPanel(
            contentRect: NSRect(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24,
                                width: size.width, height: size.height),
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
        panel.contentView = NSHostingView(rootView: PinnedImageView(image: image) { [weak panel] in panel?.close() })

        windows.append(panel)
        let id = ObjectIdentifier(panel)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { windows.removeAll { ObjectIdentifier($0) == id } }
        }
        panel.orderFrontRegardless()
    }
}

private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { close() }

    override func scrollWheel(with event: NSEvent) {
        let factor = 1 + event.scrollingDeltaY / 200
        var frame = self.frame
        let newWidth = min(max(frame.width * factor, 80), 2000)
        let ratio = frame.height / frame.width
        frame.origin.y += frame.height - newWidth * ratio
        frame.size = NSSize(width: newWidth, height: newWidth * ratio)
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
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.15), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if hover {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }
            }
            .onHover { hover = $0 }
            .onTapGesture(count: 2, perform: onClose)
            .contextMenu {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
                Button("Close", action: onClose)
            }
    }
}
