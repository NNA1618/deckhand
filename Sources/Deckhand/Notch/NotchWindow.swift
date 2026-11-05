import AppKit
import SwiftUI

/// A transparent borderless panel pinned to the top of the notch screen, centred on the notch.
///
/// There are two: the badge window shows the closed notch (badges, notices) and never takes clicks;
/// the panel window is ordered in only while the panel is open or animating, so ordering it out at the end
/// of the close animation hands keyboard focus back without any visible flash.
/// The windows never resize while shown: SwiftUI draws opening and closing inside them.
@MainActor
final class NotchWindow: NSPanel {
    /// The open panel size, from Settings → Notch & Panel.
    static var panelSize: CGSize { Settings.shared.panelSize.size }
    /// Room for the panel shadow (radius 22, offset 10) on the sides and below.
    static let margin: CGFloat = 36

    /// A click inside: called before the click is handled, with the location in global coordinates.
    var onMouseDown: ((CGPoint) -> Void)?

    /// The badge window only catches the click-to-open click and must never take keyboard focus.
    private let takesFocus: Bool

    init<Content: View>(rootView: Content, level: NSWindow.Level, takesFocus: Bool) {
        self.takesFocus = takesFocus
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        // Glass and text are designed for dark; in Light Mode AppKit glass would otherwise turn light
        appearance = NSAppearance(named: .darkAqua)

        let hosting = FirstClickHostingView(rootView: rootView)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = hosting
    }

    override var canBecomeKey: Bool { takesFocus }
    override var canBecomeMain: Bool { false }

    /// The window sits over the menu bar on purpose; don't let AppKit push it below.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            // Hover opens without focus; a click inside is the moment to take it
            if takesFocus && !isKeyWindow { makeKey() }
            onMouseDown?(NSEvent.mouseLocation)
        }
        super.sendEvent(event)
    }

    /// Full panel width plus shadow room, top edge at the top of the screen.
    func pin(to notch: NotchInfo, size: CGSize) {
        let frame = CGRect(
            x: (notch.rect.midX - size.width / 2).rounded(),
            y: notch.screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        if frame != self.frame { setFrame(frame, display: true) }
    }

    static func panelWindowSize() -> CGSize {
        CGSize(width: panelSize.width + margin * 2, height: panelSize.height + margin)
    }

    /// The open panel's frame in global Cocoa coordinates.
    static func panelRect(notch: NotchInfo) -> CGRect {
        let size = panelSize
        return CGRect(
            x: notch.rect.midX - size.width / 2,
            y: notch.screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}

/// Buttons in the panel work on the first click even before the panel is key (it opens on hover without focus).
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
