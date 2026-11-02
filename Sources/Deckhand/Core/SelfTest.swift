import AppKit

/// `Deckhand --selftest` checks editor logic without UI and exits.
/// Exists because the test frameworks are not available without Xcode.
@MainActor
enum SelfTest {
    static func run() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ name: String) {
            Log.info("selftest \(cond ? "ok  " : "FAIL") \(name)")
            print("\(cond ? "ok  " : "FAIL") \(name)")
            if !cond { ok = false }
        }

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 300,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = NSImage(size: NSSize(width: 200, height: 150))
        image.addRepresentation(rep)

        guard let model = EditorModel(image: image) else {
            check(false, "editor model init")
            return false
        }
        check(model.pixelScale == 2, "retina scale = 2")

        model.tool = .arrow
        model.dragChanged(start: CGPoint(x: 10, y: 10), current: CGPoint(x: 200, y: 150))
        model.dragEnded(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 200, y: 150))
        check(model.annotations.count == 1, "arrow added")

        model.tool = .text
        model.dragEnded(start: CGPoint(x: 30, y: 30), end: CGPoint(x: 30, y: 30))
        model.pendingText = "привет"
        model.commitText()
        check(model.annotations.count == 2, "text added")

        let flat = model.renderCGImage()
        check(flat?.width == 400 && flat?.height == 300, "export keeps pixel size")

        model.tool = .crop
        model.dragChanged(start: CGPoint(x: 50, y: 50), current: CGPoint(x: 250, y: 150))
        model.applyCrop()
        check(model.imageSize == CGSize(width: 200, height: 100), "crop size")
        check(model.annotations.isEmpty, "crop flattens annotations")

        model.undo()
        check(model.imageSize == CGSize(width: 400, height: 300), "undo crop size")
        check(model.annotations.count == 2, "undo restores annotations")

        model.redo()
        check(model.imageSize == CGSize(width: 200, height: 100), "redo crop")

        let out = model.renderNSImage()
        check(out?.size == NSSize(width: 100, height: 50), "nsimage point size after crop")

        check(ClipboardWatcher.isPassword(types: ["public.utf8-plain-text"], sourceApp: "com.apple.Passwords"),
              "copies from Apple Passwords count as passwords")
        check(ClipboardWatcher.isPassword(types: ["org.nspasteboard.ConcealedType"], sourceApp: nil),
              "concealed type counts as password")
        check(!ClipboardWatcher.isPassword(types: ["public.utf8-plain-text"], sourceApp: "com.microsoft.edgemac"),
              "plain copy is not a password")

        check("Translate this sentence".looksLikeProse && "привет".looksLikeProse, "prose is prefilled")
        check(!"77.88.8.8".looksLikeProse && !"me@example.com".looksLikeProse && !"https://a.b/c".looksLikeProse,
              "addresses and links are not prefilled")

        var warned = Set<Int>()
        let onBattery = BatteryMonitor.State(percent: 50, onAC: false, charging: false)
        let plugged = BatteryMonitor.State(percent: 50, onAC: true, charging: true)
        check(BatteryMonitor.events(from: onBattery, to: plugged, warned: &warned) == [.pluggedIn(percent: 50)],
              "battery: plugging in is reported")
        let low = BatteryMonitor.State(percent: 19, onAC: false, charging: false)
        check(BatteryMonitor.events(from: onBattery, to: low, warned: &warned) == [.low(percent: 19)]
              && BatteryMonitor.events(from: low, to: low, warned: &warned).isEmpty,
              "battery: low level is reported once")

        let awake = KeepAwake.shared
        awake.start(for: 60)
        check(awake.isActive && awake.holdsAssertion, "keep awake holds a power assertion")
        check(awake.remainingText() == "0:01", "keep awake time left \(awake.remainingText())")
        awake.stop()
        check(!awake.isActive && !awake.holdsAssertion, "keep awake releases the assertion")

        // Claude Code: one session through its hook events
        var sessions: [String: ClaudeSession] = [:]
        let t0 = Date()
        func event(_ name: String, _ extra: [String: Any] = [:], at seconds: Double) -> ClaudeCodeMonitor.Signal? {
            var e: [String: Any] = ["session_id": "s1", "cwd": "/Users/me/deckhand", "hook_event_name": name]
            e.merge(extra) { $1 }
            return ClaudeCodeMonitor.apply(event: e, app: "com.apple.Terminal", now: t0.addingTimeInterval(seconds), to: &sessions)
        }
        _ = event("SessionStart", at: 0)
        check(sessions["s1"]?.state == .idle && sessions["s1"]?.project == "deckhand", "claude: session starts idle")
        _ = event("UserPromptSubmit", ["prompt": "secret"], at: 1)
        _ = event("PreToolUse", ["tool_name": "Edit", "tool_input": ["file_path": "/a/NotchView.swift", "old_string": "x"]], at: 2)
        check(sessions["s1"]?.state == .working && sessions["s1"]?.detail == "Edit · NotchView.swift", "claude: working on a tool")
        let ask = event("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"], at: 3)
        check(ask == .needsYou(project: "deckhand") && sessions["s1"]?.state == .waiting, "claude: permission prompt needs you")
        _ = event("PostToolUse", ["tool_name": "Bash"], at: 4)
        check(sessions["s1"]?.state == .working, "claude: back to work after the answer")
        let done = event("Stop", at: 12)
        check(done == .finished(project: "deckhand", seconds: 11) && sessions["s1"]?.state == .idle, "claude: finished after 11 s")
        check(event("Notification", ["notification_type": "idle_prompt"], at: 70) == nil && sessions["s1"]?.state == .idle,
              "claude: idle reminder is not an alert")
        _ = event("SessionEnd", at: 80)
        check(sessions.isEmpty, "claude: session end removes it")
        check(ClaudeCodeMonitor.toolSummary(name: "Bash", input: ["command": "/usr/bin/git status --short"]) == "Bash · git"
              && ClaudeCodeMonitor.toolSummary(name: "mcp__github__create_issue", input: nil) == "issue",
              "claude: tool labels never show the full input")
        check(ClaudeCodeMonitor.appId(fromFileName: "1790000000-123-com.googlecode.iterm2.json") == "com.googlecode.iterm2"
              && ClaudeCodeMonitor.appId(fromFileName: "1790000000-123-unknown.json") == nil, "claude: app from event file name")

        // Installing keeps the user's own hooks and settings, removing restores them
        let userSettings: [String: Any] = [
            "env": ["A": "1"],
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]],
        ]
        let installed = ClaudeCodeMonitor.withHooks(userSettings, command: "\"/x/claude-hook.sh\"")
        let hooks = installed["hooks"] as? [String: Any] ?? [:]
        check(ClaudeCodeMonitor.events.allSatisfy { hooks[$0] != nil } && (hooks["Stop"] as? [Any])?.count == 2,
              "claude: hook added to every event next to the user's")
        let twice = ClaudeCodeMonitor.withHooks(installed, command: "\"/x/claude-hook.sh\"")
        check(((twice["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count == 2, "claude: installing twice adds it once")
        func json(_ o: [String: Any]) -> Data? { try? JSONSerialization.data(withJSONObject: o, options: .sortedKeys) }
        check(json(ClaudeCodeMonitor.withoutHooks(installed)) == json(userSettings), "claude: removing restores the settings")

        // The hook script writes the event to the folder with the app in the name
        let fakeHome = FileManager.default.temporaryDirectory.appendingPathComponent("deckhand-hook-\(UUID().uuidString)")
        let inbox = fakeHome.appendingPathComponent("Library/Application Support/Deckhand/claude-events")
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let script = fakeHome.appendingPathComponent("claude-hook.sh")
        try? ClaudeCodeMonitor.scriptBody.write(to: script, atomically: true, encoding: .utf8)
        let payload = #"{"session_id":"s2","hook_event_name":"Stop"}"#
        let hookRun = try? ClaudeCLI.run(executable: "/bin/sh", arguments: [script.path], input: payload, timeout: 5,
                                         env: ["HOME": fakeHome.path, "__CFBundleIdentifier": "com.apple.Terminal"])
        let written = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []
        let content = written.first.flatMap { try? String(contentsOf: inbox.appendingPathComponent($0), encoding: .utf8) }
        check(hookRun?.status == 0 && hookRun?.stdout.isEmpty == true && written.count == 1
              && written[0].hasSuffix("-com.apple.Terminal.json") && content == payload,
              "claude: hook script saves the event \(written)")
        let internalRun = try? ClaudeCLI.run(executable: "/bin/sh", arguments: [script.path], input: payload, timeout: 5,
                                             env: ["HOME": fakeHome.path, "DECKHAND_INTERNAL": "1"])
        check(internalRun?.status == 0 && ((try? FileManager.default.contentsOfDirectory(atPath: inbox.path))?.count ?? 0) == 1,
              "claude: Deckhand's own calls are ignored")
        try? FileManager.default.removeItem(at: fakeHome)

        let cliArgs = ClaudeCLI.arguments(system: "Fix it", model: .haiku55, allowRead: false)
        check(cliArgs.starts(with: ["-p", "--model", "haiku"]) && cliArgs.suffix(2) == ["--tools", ""]
              && cliArgs.contains("--no-session-persistence"), "claude code call has no tools and no saved session")

        let savedHidden = Settings.shared.hiddenTabs
        Settings.shared.hiddenTabs = ["prompts", "home"]
        check(!NotchTab.visible.contains(.prompts) && NotchTab.visible.first == .home, "hidden tabs leave the strip, Home stays")
        Settings.shared.hiddenTabs = savedHidden

        let timer = Countdown.shared
        timer.start(minutes: 5)
        check(timer.isRunning && timer.remainingText() == "5:00", "timer starts at 5:00 (\(timer.remainingText()))")
        timer.pause()
        timer.addMinute()
        check(timer.isPaused && timer.remainingText() == "6:00", "timer pauses and adds a minute (\(timer.remainingText()))")
        timer.resume()
        check(timer.isRunning && !timer.isPaused, "timer resumes")
        timer.stop()
        check(!timer.isActive, "timer stops")

        // Only meaningful inside the .app, where the .lproj folders are bundled
        if let path = Bundle.main.path(forResource: "ru", ofType: "lproj"), let ru = Bundle(path: path) {
            check(ru.localizedString(forKey: "Settings", value: nil, table: nil) == "Настройки", "russian localization bundled")
            let percent = 50
            let charging = String(localized: "Charging, \(percent)%", bundle: ru)
            check(charging == "Заряжается, 50%", "russian interpolated string: \(charging)")
        }

        // Blur: pixelating a striped image must change pixels inside the region
        let stripes = NSImage(size: NSSize(width: 200, height: 100))
        stripes.lockFocus()
        for x in stride(from: 0, to: 200, by: 4) {
            (x % 8 == 0 ? NSColor.black : NSColor.white).setFill()
            NSRect(x: x, y: 0, width: 4, height: 100).fill()
        }
        stripes.unlockFocus()
        if let blurModel = EditorModel(image: stripes), let before = blurModel.renderCGImage() {
            blurModel.tool = .blur
            let w = CGFloat(before.width), h = CGFloat(before.height)
            blurModel.dragChanged(start: CGPoint(x: 0, y: 0), current: CGPoint(x: w / 2, y: h))
            blurModel.dragEnded(start: CGPoint(x: 0, y: 0), end: CGPoint(x: w / 2, y: h))
            let after = blurModel.renderCGImage()
            check(after.map { !pixelsEqual($0, before) } ?? false, "blur changes pixels")
        }

        if let big = CGContext(data: nil, width: 4000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage(),
           let png = EditorModel.pngForUpload(big), let rep = NSBitmapImageRep(data: png) {
            check(rep.pixelsWide == 1568 && rep.pixelsHigh == 392, "upload image downscaled to 1568")
        }

        let ocrImage = NSImage(size: NSSize(width: 600, height: 160))
        ocrImage.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 600, height: 160).fill()
        ("Deckhand reads text" as NSString).draw(at: NSPoint(x: 30, y: 60), withAttributes: [
            .font: NSFont.systemFont(ofSize: 40, weight: .medium), .foregroundColor: NSColor.black,
        ])
        ocrImage.unlockFocus()
        let ocrFile = FileManager.default.temporaryDirectory.appendingPathComponent("deckhand-selftest-ocr.png")
        if let tiff = ocrImage.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: ocrFile)
        }
        let recognized = TextRecognizer.recognize(at: ocrFile) ?? ""
        check(recognized.contains("Deckhand reads text"), "text recognition: \(recognized)")

        let sc = Shortcut(keyCode: 1, modifiers: UInt32(1 << 8 | 1 << 9)) // ⌘⇧S
        check(sc.display == "⇧⌘S", "shortcut display \(sc.display)")

        return ok
    }

    private static func pixelsEqual(_ a: CGImage, _ b: CGImage) -> Bool {
        guard let da = a.dataProvider?.data, let db = b.dataProvider?.data else { return false }
        return (da as Data) == (db as Data)
    }
}
