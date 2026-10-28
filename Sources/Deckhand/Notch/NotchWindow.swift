import AppKit
import SwiftUI

/// A transparent window of fixed size pinned to the top of the screen, centered on the notch.
///
/// The window never resizes: macOS clips windows that grow over the menu bar.
/// SwiftUI draws opening and closing inside it, growing the shape out of the notch.
final class NotchWindow: NSPanel {
    static let panelSize = CGSize(width: 800, height: 480)
    static let margin: CGFloat = 24   // room for the shadow

    init<Content: View>(rootView: Content) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .mainMenu + 3
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: rootView)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func pin(to notch: NotchInfo) {
        let w = Self.panelSize.width + Self.margin * 2
        let h = Self.panelSize.height + Self.margin
        let frame = CGRect(
            x: notch.rect.midX - w / 2,
            y: notch.screen.frame.maxY - h,
            width: w,
            height: h
        )
        setFrame(frame, display: true)
    }

    /// The open panel's frame in global Cocoa coordinates.
    func panelRect(notch: NotchInfo) -> CGRect {
        let size = Self.panelSize
        return CGRect(
            x: notch.rect.midX - size.width / 2,
            y: notch.screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}
