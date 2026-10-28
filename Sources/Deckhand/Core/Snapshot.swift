import AppKit

/// `Deckhand --snapshot DIR` renders every panel tab, every Settings tab and the editor to PNG
/// files and quits. Uses the app's own view hierarchy, so no Screen Recording permission is needed.
/// Glass cannot be captured this way, so panels are composited over a neutral backdrop.
@MainActor
enum Snapshot {
    static func run(dir: URL, notch: NotchController) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for tab in NotchTab.allCases {
            if notch.viewModel.isOpen { notch.viewModel.tab = tab } else { notch.open(tab: tab) }
            try? await Task.sleep(for: .milliseconds(900))
            if let (window, cutout) = notch.snapshotTarget {
                save(window, cutout: cutout, to: dir.appendingPathComponent("panel-\(tab.rawValue).png"))
            }
        }
        notch.close()

        SettingsWindow.show()
        for tab in SettingsTab.allCases {
            SettingsRouter.shared.tab = tab
            try? await Task.sleep(for: .milliseconds(700))
            if let window = SettingsWindow.window {
                save(window, cutout: nil, to: dir.appendingPathComponent("settings-\(tab.rawValue).png"))
            }
        }
        SettingsWindow.window?.close()

        if let editor = EditorWindow.open(image: sampleImage()) {
            try? await Task.sleep(for: .milliseconds(900))
            save(editor, cutout: nil, to: dir.appendingPathComponent("editor.png"))
            editor.close()
        }
        Log.info("snapshot written to \(dir.path)")
    }

    private static func save(_ window: NSWindow, cutout: CGRect?, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)

        let size = view.bounds.size
        let out = NSImage(size: size)
        out.lockFocus()
        NSGradient(starting: NSColor(white: 0.32, alpha: 1), ending: NSColor(white: 0.18, alpha: 1))?
            .draw(in: NSRect(origin: .zero, size: size), angle: -90)
        rep.draw(in: NSRect(origin: .zero, size: size))
        if let cutout {
            NSColor.systemRed.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: cutout, xRadius: 8, yRadius: 8).fill()
        }
        out.unlockFocus()

        guard let tiff = out.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    private static func sampleImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 640, height: 400))
        image.lockFocus()
        NSGradient(starting: .systemIndigo, ending: .systemTeal)?.draw(in: NSRect(x: 0, y: 0, width: 640, height: 400), angle: 30)
        ("Sample screenshot" as NSString).draw(at: NSPoint(x: 40, y: 180), withAttributes: [
            .font: NSFont.systemFont(ofSize: 36, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        image.unlockFocus()
        return image
    }
}
