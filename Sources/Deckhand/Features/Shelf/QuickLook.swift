import AppKit
import Quartz

/// Quick Look for files on the Shelf and in Recents. The preview floats above the panel, and the
/// panel stays open while it shows; when it closes, keyboard focus goes back where it was.
@MainActor
final class QuickLook: NSObject {
    static let shared = QuickLook()

    private var urls: [URL] = []
    private var index = 0
    private weak var notch: NotchViewModel?
    private var previousApp: NSRunningApplication?
    private var visibility: NSKeyValueObservation?
    private var showing = false

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    /// Shows `urls` starting at `index`, or closes the preview when it already shows them.
    func toggle(_ urls: [URL], at index: Int = 0, notch: NotchViewModel?) {
        if isVisible, urls == self.urls, index == self.index {
            QLPreviewPanel.shared().orderOut(nil)
            return
        }
        show(urls, at: index, notch: notch)
    }

    func show(_ urls: [URL], at index: Int = 0, notch: NotchViewModel?) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        self.index = min(max(index, 0), urls.count - 1)
        self.notch = notch
        notch?.holds.insert("quick-look")
        if !NSApp.isActive { previousApp = NSWorkspace.shared.frontmostApplication }
        // Arrow keys and Space work in the preview only while Deckhand is active
        NSApp.activate()
        panel.dataSource = self
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        panel.reloadData()
        panel.currentPreviewItemIndex = self.index
        panel.makeKeyAndOrderFront(nil)
        showing = true
        // The preview hides with orderOut (Space, Esc) as often as it closes, so watch visibility
        visibility = panel.observe(\.isVisible, options: [.new]) { [weak self] _, change in
            guard change.newValue == false else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.didClose() } }
        }
    }

    private func didClose() {
        guard showing, !isVisible else { return }
        showing = false
        visibility = nil
        notch?.holds.remove("quick-look")
        if let notchWindow = NSApp.windows.first(where: { $0 is NotchWindow }), notch?.isOpen == true {
            notchWindow.makeKey()
        } else if let previousApp {
            previousApp.activate()
        }
        previousApp = nil
    }
}

extension QuickLook: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}
