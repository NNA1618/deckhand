import AppKit
import ImageIO
import QuartzCore

/// Hides the desktop icons without touching Finder: a window just above the icons on every screen
/// that shows the wallpaper, the way the user set it up (fill, fit, stretch or center).
///
/// The old way, `CreateDesktop = false` plus a Finder restart, cancelled copies in progress.
/// The cover lives only as long as Deckhand runs, so nothing is left behind after a quit or a crash.
@MainActor
final class DesktopCover {
    static let shared = DesktopCover()

    private(set) var isShown = false
    private var windows: [NSWindow] = []
    private var observers: [NSObjectProtocol] = []

    private init() {}

    func show() {
        guard !isShown else { return }
        isShown = true
        rebuild()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DesktopCover.shared.rebuild() }
        })
        // Each Space can have its own wallpaper
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DesktopCover.shared.refreshImages() }
        })
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    /// One window per screen, rebuilt when displays change.
    private func rebuild() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map(makeWindow)
        refreshImages()
    }

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let w = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above the icons, below every normal window
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        w.hasShadow = false
        w.isOpaque = true
        w.hidesOnDeactivate = false
        // ⌘H in Settings or the editor must not bring the desktop icons back
        w.canHide = false
        // Clicks stop here, so a hidden icon can't be opened by accident
        w.ignoresMouseEvents = false
        w.setFrame(screen.frame, display: false)
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        w.contentView = view
        w.orderFront(nil)
        return w
    }

    /// Loads each screen's wallpaper off the main thread and shows it with the user's scaling.
    private func refreshImages() {
        for (window, screen) in zip(windows, NSScreen.screens) {
            let workspace = NSWorkspace.shared
            let url = workspace.desktopImageURL(for: screen)
            let options = workspace.desktopImageOptions(for: screen) ?? [:]
            let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) } ?? .scaleProportionallyUpOrDown
            let clipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? true
            let fill = (options[.fillColor] as? NSColor) ?? .black
            let maxPixels = max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor
            window.contentView?.layer?.backgroundColor = fill.cgColor
            window.contentView?.layer?.contentsGravity = Self.gravity(scaling: scaling, clipping: clipping)
            guard let url else { continue }
            Task { [weak window] in
                let image = await Task.detached(priority: .userInitiated) { Self.decode(url, maxPixels: maxPixels) }.value
                guard let window, let image else { return }
                window.contentView?.layer?.contents = image.cgImage
            }
        }
    }

    /// How the wallpaper is laid out, from the options in System Settings → Wallpaper.
    nonisolated static func gravity(scaling: NSImageScaling, clipping: Bool) -> CALayerContentsGravity {
        switch scaling {
        case .scaleProportionallyUpOrDown, .scaleProportionallyDown:
            return clipping ? .resizeAspectFill : .resizeAspect   // Fill Screen : Fit to Screen
        case .scaleAxesIndependently:
            return .resize                                         // Stretch to Fill Screen
        case .scaleNone:
            return .center                                         // Center
        @unknown default:
            return .resizeAspectFill
        }
    }

    /// A downsampled wallpaper, never larger than the screen. Nil for folders and unreadable files.
    nonisolated private static func decode(_ url: URL, maxPixels: CGFloat) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixels),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return DecodedImage(cgImage: image)
    }

    /// Carries a decoded, immutable image from the decoding task to the main actor.
    private struct DecodedImage: @unchecked Sendable {
        let cgImage: CGImage
    }
}
