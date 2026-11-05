import AppKit
import SwiftUI

/// Mouse handling for a file tile, done in AppKit because SwiftUI's `onDrag` can carry only one
/// file and never says where the drag ended. Lies over the tile: click (with modifiers),
/// double-click, hover, a context menu, and a drag that carries several files.
struct FileTileInteraction: NSViewRepresentable {
    /// The files a drag starting here carries.
    var urls: () -> [URL]
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onDoubleClick: (() -> Void)?
    var onHover: (Bool) -> Void = { _ in }
    var menu: () -> NSMenu? = { nil }
    var onDragStart: () -> Void = {}
    /// Called with the operation the drop target chose; empty when the drag was cancelled.
    var onDragEnd: (NSDragOperation) -> Void = { _ in }

    func makeNSView(context: Context) -> TileInteractionView {
        let view = TileInteractionView()
        view.setAccessibilityElement(false)
        update(view)
        return view
    }

    func updateNSView(_ view: TileInteractionView, context: Context) { update(view) }

    private func update(_ view: TileInteractionView) {
        view.urls = urls
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onHover = onHover
        view.menuProvider = menu
        view.onDragStart = onDragStart
        view.onDragEnd = onDragEnd
    }
}

final class TileInteractionView: NSView, NSDraggingSource {
    var urls: () -> [URL] = { [] }
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onDoubleClick: (() -> Void)?
    var onHover: (Bool) -> Void = { _ in }
    var menuProvider: () -> NSMenu? = { nil }
    var onDragStart: () -> Void = {}
    var onDragEnd: (NSDragOperation) -> Void = { _ in }

    private var downEvent: NSEvent?
    private var dragging = false
    private var tracking: NSTrackingArea?

    /// The panel is often not key (it opens on hover); the first click must still work.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        dragging = false
        if event.clickCount == 2, let onDoubleClick { onDoubleClick() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let down = downEvent else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 4 else { return }
        let files = urls()
        guard !files.isEmpty else { return }
        dragging = true
        onDragStart()
        let origin = convert(down.locationInWindow, from: nil)
        let items = files.enumerated().map { i, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 48, height: 48)
            // Stack several files slightly so the drag shows there is more than one
            let offset = CGFloat(min(i, 4)) * 5
            item.setDraggingFrame(NSRect(x: origin.x - 24 + offset, y: origin.y - 24 - offset, width: 48, height: 48),
                                  contents: icon)
            return item
        }
        let session = beginDraggingSession(with: items, event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    override func mouseUp(with event: NSEvent) {
        defer { downEvent = nil }
        guard !dragging, event.clickCount <= 1 else { return }
        onClick(event.modifierFlags.intersection([.command, .shift, .option, .control]))
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider() }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        Self.operations(for: context)
    }

    /// Copy, never move: dragging off the shelf must not take the file away from where it lives.
    /// No .generic: Finder may treat it as a move on the same disk, and the Dock's Trash as "trash it".
    nonisolated static func operations(for context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link] : [.copy]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        onDragEnd(operation)
    }
}

/// A menu item that runs a closure, for menus built in code.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
