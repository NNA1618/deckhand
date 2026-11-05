import AppKit
import SwiftUI

/// `Deckhand --snapshot DIR` renders every panel tab, every Settings tab and the editor to PNG
/// files and quits. Uses the app's own view hierarchy, so no Screen Recording permission is needed.
/// Glass cannot be captured this way, so panels are composited over a neutral backdrop.
@MainActor
enum Snapshot {
    /// Parts of a run, so `--snapshot DIR --only panels,closed` can render just what changed.
    enum Part: String, CaseIterable { case panels, closed, settings, editor }

    static func run(dir: URL, notch: NotchController) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let args = CommandLine.arguments
        var parts = Set(Part.allCases)
        if let i = args.firstIndex(of: "--only"), i + 1 < args.count {
            parts = Set(args[i + 1].split(separator: ",").compactMap { Part(rawValue: String($0)) })
        }
        if parts.contains(.panels) { await panels(dir: dir, notch: notch) }
        if parts.contains(.closed) { await closedStates(dir: dir, notch: notch) }
        if parts.contains(.settings) { await settingsWindow(dir: dir) }
        if parts.contains(.editor) { await editorWindow(dir: dir) }
        Log.info("snapshot written to \(dir.path)")
    }

    /// Sample Claude Code sessions shown on Home, in the Claude tab and around the closed notch.
    static func sampleSessions(now: Date = Date()) -> [ClaudeSession] {
        [
            ClaudeSession(id: "a", cwd: "/Users/me/deckhand", app: "com.apple.Terminal", state: .working,
                          detail: "Edit · NotchRootView.swift", workStarted: now.addingTimeInterval(-247), updated: now),
            ClaudeSession(id: "b", cwd: "/Users/me/site", app: "com.anthropic.claudefordesktop", state: .waiting,
                          detail: "Claude needs your permission to use Bash", updated: now.addingTimeInterval(-30)),
            ClaudeSession(id: "c", cwd: "/Users/me/notes", state: .idle, updated: now.addingTimeInterval(-600)),
        ]
    }

    /// Every panel tab, open. Owned by the panel workstream.
    static func panels(dir: URL, notch: NotchController) async {
        ClaudeCodeMonitor.shared.showForSnapshot(sampleSessions())
        for tab in NotchTab.allCases {
            if notch.viewModel.isOpen { notch.viewModel.tab = tab } else { notch.open(tab: tab) }
            try? await Task.sleep(for: .milliseconds(900))
            if let (window, cutout) = notch.snapshotTarget {
                save(window, cutout: cutout, to: dir.appendingPathComponent("panel-\(tab.rawValue).png"))
            }
        }
        notch.close()
        ClaudeCodeMonitor.shared.showForSnapshot([])
    }

    /// Badges around the closed notch. Owned by the notch workstream.
    static func closedStates(dir: URL, notch: NotchController) async {
        let now = Date()
        let working = sampleSessions(now: now)[0]
        ClaudeCodeMonitor.shared.showForSnapshot(sampleSessions(now: now))

        try? await Task.sleep(for: .milliseconds(1200))
        if let (window, cutout) = notch.snapshotTarget {
            save(window, cutout: cutout, to: dir.appendingPathComponent("closed-claude-waiting.png"))
        }
        ClaudeCodeMonitor.shared.showForSnapshot([working])
        try? await Task.sleep(for: .milliseconds(1200))
        if let (window, cutout) = notch.snapshotTarget {
            save(window, cutout: cutout, to: dir.appendingPathComponent("closed-claude.png"))
        }
        ClaudeCodeMonitor.shared.showForSnapshot([])

        Countdown.shared.start(minutes: 25)
        try? await Task.sleep(for: .milliseconds(1200))
        if let (window, cutout) = notch.snapshotTarget {
            save(window, cutout: cutout, to: dir.appendingPathComponent("closed-timer.png"))
        }
        Countdown.shared.stop()

        NowPlayingMonitor.shared.showForSnapshot(NowPlaying(title: "Midnight City", artist: "M83", isPlaying: true, source: "Apple Music"))
        try? await Task.sleep(for: .milliseconds(1200))
        if let (window, cutout) = notch.snapshotTarget {
            save(window, cutout: cutout, to: dir.appendingPathComponent("closed-now-playing.png"))
        }
        NowPlayingMonitor.shared.showForSnapshot(nil)

        let wasAwake = KeepAwake.shared.isActive
        KeepAwake.shared.start(for: 2 * 3600)
        try? await Task.sleep(for: .milliseconds(1200))
        if let (window, cutout) = notch.snapshotTarget {
            save(window, cutout: cutout, to: dir.appendingPathComponent("closed-keep-awake.png"))
        }
        if !wasAwake { KeepAwake.shared.stop() }
    }

    /// Every Settings section. Owned by the Settings workstream.
    static func settingsWindow(dir: URL) async {
        SettingsWindow.show()
        for tab in SettingsSection.allCases {
            SettingsRouter.shared.section = tab
            try? await Task.sleep(for: .milliseconds(700))
            if let window = SettingsWindow.window {
                save(window, cutout: nil, to: dir.appendingPathComponent("settings-\(tab.rawValue).png"))
            }
        }
        SettingsWindow.window?.close()
    }

    /// The image editor. Owned by the capture workstream.
    static func editorWindow(dir: URL) async {
        guard let editor = EditorWindow.open(image: sampleImage()), let model = EditorWindow.model(for: editor) else { return }
        try? await Task.sleep(for: .milliseconds(900))
        save(editor, cutout: nil, to: dir.appendingPathComponent("editor.png"))

        // Annotations of every kind, a selection, the text sizes and the Ask panel with an answer
        let s = model.pixelScale
        func drag(_ tool: EditorTool, _ a: CGPoint, _ b: CGPoint) {
            model.tool = tool
            let pa = CGPoint(x: a.x * s, y: a.y * s), pb = CGPoint(x: b.x * s, y: b.y * s)
            model.dragChanged(start: pa, current: pb)
            model.dragEnded(start: pa, end: pb)
        }
        drag(.arrow, CGPoint(x: 420, y: 320), CGPoint(x: 330, y: 230))
        drag(.rect, CGPoint(x: 30, y: 160), CGPoint(x: 360, y: 240))
        drag(.blur, CGPoint(x: 440, y: 40), CGPoint(x: 600, y: 120))
        drag(.redact, CGPoint(x: 440, y: 140), CGPoint(x: 600, y: 170))
        model.tool = .text
        model.dragEnded(start: CGPoint(x: 40 * s, y: 40 * s), end: CGPoint(x: 40 * s, y: 40 * s))
        model.pendingText = String(localized: "Text")
        model.commitText()
        drag(.select, CGPoint(x: 400, y: 300), CGPoint(x: 400, y: 300))
        model.askVisible = true
        model.question = String(localized: "What’s in this screenshot?")
        model.answer = "A gradient with the words “Sample screenshot”."
        model.tool = .text
        try? await Task.sleep(for: .milliseconds(900))
        save(editor, cutout: nil, to: dir.appendingPathComponent("editor-ask.png"))
        editor.close()
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
            // The real notch is black; the debug run marks it red to check what it covers
            (CommandLine.arguments.contains("--clean") ? NSColor.black : NSColor.systemRed.withAlphaComponent(0.55)).setFill()
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
