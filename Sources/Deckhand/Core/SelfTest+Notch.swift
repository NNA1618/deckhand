import AppKit

extension SelfTest {
    /// Activation, the window and badges. Owned by the notch workstream.
    /// Geometry follows the owner's 14-inch MacBook: 1800 × 1169 pt, cutout x 790–1010, 38 pt tall,
    /// first menu-bar item at x 1068.
    static func notch(_ check: Check) {
        notchZones(check)
        notchOpening(check)
        notchClosing(check)
        notchToasts(check)
        notchBadges(check)
        notchDisplays(check)
        notchFullScreen(check)
    }

    /// A `.wait` for about this time (timestamps are sums of doubles).
    private static func waits(_ v: HoverIntent.Verdict, _ until: TimeInterval) -> Bool {
        if case .wait(let t) = v { return abs(t - until) < 1e-6 }
        return false
    }

    private static let cutout = CGRect(x: 790, y: 1131, width: 220, height: 38)
    private static let top: CGFloat = 1169

    private static func notchZones(_ check: Check) {
        let standard = ActivationZones.trigger(cutout: cutout, margin: HoverArea.standard.margin)
        check(standard == CGRect(x: 784, y: 1131, width: 232, height: 38), "standard zone is the cutout ± 6 pt: \(standard)")
        check(ActivationZones.contains(standard, CGPoint(x: 900, y: top)), "pointer pressed against the top edge counts")
        check(!ActivationZones.contains(standard, CGPoint(x: 900, y: 1125)), "zone stops at the bottom of the menu bar")
        check(!ActivationZones.contains(standard, CGPoint(x: 1068, y: 1150)), "first menu-bar item is outside the zone")
        let narrow = ActivationZones.trigger(cutout: cutout, margin: HoverArea.narrow.margin)
        check(!ActivationZones.contains(narrow, CGPoint(x: 787, y: 1150)) && ActivationZones.contains(standard, CGPoint(x: 787, y: 1150)),
              "narrow is the cutout only")
        let wide = ActivationZones.trigger(cutout: cutout, margin: HoverArea.wide.margin)
        check(wide.maxX == 1030 && wide.maxX < 1068, "wide zone still clear of the first menu-bar item")
        // Badges never widen the zone unless the user asked for it
        let withBadge = ActivationZones.trigger(cutout: cutout, margin: 6, badgeWidth: 220 + 2 * 130)
        check(withBadge.minX == 660 && withBadge.maxX == 1140, "badge hover zone spans the badge when enabled")
        let open = ActivationZones.open(panel: CGRect(x: 500, y: 689, width: 800, height: 480))
        check(open.maxY == top && open.minX == 490 && open.minY == 679, "open zone has slack but stays on the notch screen")
        check(!ActivationZones.contains(open, CGPoint(x: 900, y: top + 5)), "a display above is outside the open zone")
    }

    private static func notchOpening(_ check: Check) {
        let inside = CGPoint(x: 900, y: 1160)

        // Resting on the notch opens after the delay
        var rest = HoverIntent()
        let first = rest.pointerMoved(to: inside, at: 10, inTrigger: true)
        check(waits(first, 10.2), "resting starts the 0.2 s delay: \(first)")
        check(rest.evaluate(at: 10.2, inTrigger: true) == .act, "rest for the delay opens")

        // A sweep across the menu bar at 1000 pt/s never opens, however long it stays in the zone
        var sweep = HoverIntent()
        var verdict = HoverIntent.Verdict.idle
        var x: CGFloat = 700
        var t: TimeInterval = 20
        while x < 1100 {
            let inZone = x >= 784 && x < 1016
            verdict = sweep.pointerMoved(to: CGPoint(x: x, y: 1160), at: t, inTrigger: inZone)
            if verdict == .act { break }
            if case .wait(let until) = verdict, until <= t + 1.0 / 120 { verdict = sweep.evaluate(at: until, inTrigger: inZone) }
            if verdict == .act { break }
            x += 1000 / 120
            t += 1.0 / 120
        }
        check(verdict != .act, "a fast pass across the notch does not open")

        // ...but slowing down and stopping on the notch does
        var settle = HoverIntent()
        for i in 0..<10 { _ = settle.pointerMoved(to: CGPoint(x: 820 + CGFloat(i) * 9, y: 1160), at: 30 + Double(i) / 120, inTrigger: true) }
        let afterFast = settle.evaluate(at: 30.1, inTrigger: true)
        check(afterFast != .act, "no opening while still moving fast")
        if case .wait(let until) = afterFast {
            check(settle.evaluate(at: until, inTrigger: true) == .act, "opens once the pointer rests")
        } else {
            check(false, "a fast approach waits for the pointer to rest: \(afterFast)")
        }

        // After a click in the menu bar the pointer is busy with menus
        var click = HoverIntent()
        click.menuBarClicked(at: 40)
        let afterClick = click.pointerMoved(to: inside, at: 40.1, inTrigger: true)
        check(waits(afterClick, 40.8), "a menu-bar click holds hover for 0.8 s: \(afterClick)")
        check(click.evaluate(at: 40.8, inTrigger: true) == .act, "hover works again after the cooldown")

        // A held button (window resize, text selection) never opens; a file drag does
        var held = HoverIntent()
        check(held.pointerMoved(to: inside, at: 50, inTrigger: true, buttonsHeld: true) == .idle, "held button doesn't open")
        check(held.evaluate(at: 51, inTrigger: true, buttonsHeld: true) == .idle, "still held, still closed")
        var drag = HoverIntent()
        _ = drag.pointerMoved(to: inside, at: 60, inTrigger: true, buttonsHeld: true, fileDrag: true)
        check(drag.evaluate(at: 60.2, inTrigger: true, buttonsHeld: true, fileDrag: true) == .act, "a file drag opens")

        // After a deliberate close on the notch, the pointer must leave first
        var reopen = HoverIntent()
        reopen.closedDeliberately(pointerInTrigger: true)
        check(reopen.pointerMoved(to: inside, at: 70, inTrigger: true) == .idle, "no reopening after Esc while on the notch")
        check(reopen.evaluate(at: 75, inTrigger: true) == .idle, "resting there for long still doesn't reopen")
        _ = reopen.pointerMoved(to: CGPoint(x: 900, y: 1000), at: 76, inTrigger: false)
        _ = reopen.pointerMoved(to: inside, at: 77, inTrigger: true)
        check(reopen.evaluate(at: 77.2, inTrigger: true) == .act, "leaving and coming back opens again")
        var leftAlready = HoverIntent()
        leftAlready.closedDeliberately(pointerInTrigger: false)
        _ = leftAlready.pointerMoved(to: inside, at: 80, inTrigger: true)
        check(leftAlready.evaluate(at: 80.2, inTrigger: true) == .act, "closing elsewhere doesn't block the next hover")

        // Suspension (capture, color picker) and the hover pause
        var capture = HoverIntent()
        capture.setSuspended(true, at: 90, pointerInTrigger: false)
        check(capture.pointerMoved(to: inside, at: 91, inTrigger: true) == .idle, "no hover during capture")
        capture.setSuspended(false, at: 92, pointerInTrigger: true)
        check(capture.pointerMoved(to: inside, at: 92.1, inTrigger: true) == .idle, "capture ending on the notch needs a leave first")
        _ = capture.pointerMoved(to: CGPoint(x: 900, y: 900), at: 92.2, inTrigger: false)
        let grace = capture.pointerMoved(to: inside, at: 92.3, inTrigger: true)
        check(waits(grace, 92.5), "half a second of grace after capture: \(grace)")
        var paused = HoverIntent()
        paused.pause(for: 3600, at: 100)
        _ = paused.pointerMoved(to: inside, at: 101, inTrigger: true)
        check(paused.evaluate(at: 200, inTrigger: true) == .idle && paused.isPaused(at: 200), "paused for an hour")
        paused.pause(for: 0, at: 300)
        _ = paused.pointerMoved(to: CGPoint(x: 900, y: 900), at: 300, inTrigger: false)
        _ = paused.pointerMoved(to: inside, at: 301, inTrigger: true)
        check(paused.evaluate(at: 301.2, inTrigger: true) == .act && !paused.isPaused(at: 301), "resume ends the pause")

        // Speed estimate
        var speed = HoverIntent()
        _ = speed.pointerMoved(to: CGPoint(x: 0, y: 0), at: 0, inTrigger: false)
        _ = speed.pointerMoved(to: CGPoint(x: 50, y: 0), at: 0.05, inTrigger: false)
        check(abs(speed.speed(at: 0.05) - 1000) < 1, "speed: 50 pt in 50 ms is 1000 pt/s")
        check(speed.speed(at: 0.5) == 0, "a pointer without events is resting")
    }

    private static func notchClosing(_ check: Check) {
        var exit = HoverIntent()
        exit.config.closeDelay = 0.5
        exit.opened(pointerInside: true)
        let left = exit.pointerMovedWhileOpen(to: CGPoint(x: 100, y: 100), at: 10, inOpenZone: false)
        check(waits(left, 10.5), "leaving starts the close delay: \(left)")
        check(exit.pointerMovedWhileOpen(to: CGPoint(x: 900, y: 1000), at: 10.3, inOpenZone: true) == .idle, "coming back cancels")
        _ = exit.pointerMovedWhileOpen(to: CGPoint(x: 100, y: 100), at: 11, inOpenZone: false)
        check(exit.evaluateOpen(at: 11.5, inOpenZone: false) == .act, "staying away closes")

        var manual = HoverIntent()
        manual.opened(pointerInside: false)
        check(manual.evaluateOpen(at: 5, inOpenZone: false) == .idle, "a shortcut-opened panel waits for the pointer to arrive")
        _ = manual.pointerMovedWhileOpen(to: .zero, at: 6, inOpenZone: true)
        check(waits(manual.pointerMovedWhileOpen(to: .zero, at: 7, inOpenZone: false), 7.5), "then closes on leaving")

        var drag = HoverIntent()
        drag.opened(pointerInside: true)
        check(drag.pointerMovedWhileOpen(to: .zero, at: 1, inOpenZone: false, buttonsHeld: true) == .idle,
              "a drag or selection outside the panel doesn't close it")
        check(drag.pointerMovedWhileOpen(to: .zero, at: 2, inOpenZone: false, closeOnExit: false) == .idle,
              "'close only on click outside or Esc' ignores leaving")
    }

    private static func notchToasts(_ check: Check) {
        var q = ToastQueue()
        let a = Toast(symbol: "camera.viewfinder", text: "Copied to clipboard")
        check(q.push(a) && q.current == a, "first notice shows at once")
        check(!q.push(Toast(symbol: "eyedropper", text: "#FFFFFF")), "second notice waits")
        check(q.push(Toast(symbol: "camera.viewfinder", text: "Copied to clipboard")) && q.waiting.count == 1,
              "repeating the shown notice restarts it instead of queueing")
        let alert = Toast(symbol: "hand.raised.fill", text: "Needs you · site", style: .alert)
        q.push(alert)
        check(q.waiting.first == alert && q.alertWaiting, "alerts jump ahead of info notices")
        q.push(Toast(symbol: "eyedropper", text: "#FFFFFF"))
        check(q.waiting.count == 2, "a waiting duplicate is kept once")
        for i in 0..<6 { q.push(Toast(symbol: "x", text: "n\(i)")) }
        check(q.waiting.count == ToastQueue.maxWaiting && q.waiting.contains(alert), "queue is capped, alerts kept")
        q.dismissCurrent()
        check(q.current == nil && q.next() == alert, "the alert comes next")
        var repeatAlert = ToastQueue()
        repeatAlert.push(alert)
        repeatAlert.push(Toast(symbol: alert.symbol, text: alert.text, style: .info))
        check(repeatAlert.current?.style == .alert, "a repeated message keeps the alert style")

        // Width: measured, at least the cutout, capped; long Russian text gets truncated, not overflowing
        let short = ToastLayout.width(Toast(symbol: "x", text: "#FFFFFF"), notchWidth: 220, maxWidth: 460)
        check(short == 236, "short notice is just wider than the cutout: \(short)")
        let long = ToastLayout.width(Toast(symbol: "x", text: String(repeating: "Ждёт вас · очень-длинный-проект ", count: 4)),
                                     notchWidth: 220, maxWidth: 460)
        check(long == 460, "long notice is capped: \(long)")
        let mid = ToastLayout.width(Toast(symbol: "x", text: "Скопировано в буфер обмена · проект-с-длинным-именем"), notchWidth: 220, maxWidth: 460)
        check(mid > 236 && mid < 460, "medium notice is sized to its text: \(mid)")
    }

    private static func notchBadges(_ check: Check) {
        var i = BadgeKind.Inputs(claudeActive: true, timerActive: true, musicPlaying: true, keepAwakeActive: true)
        check(BadgeKind.pick(i) == .claude, "Claude Code comes first")
        i.claudeEnabled = false
        check(BadgeKind.pick(i) == .timer, "then the timer")
        i.timerEnabled = false
        check(BadgeKind.pick(i) == .music, "then music")
        i.musicPlaying = false
        check(BadgeKind.pick(i) == .keepAwake, "then Keep Awake")
        i.keepAwakeEnabled = false
        check(BadgeKind.pick(i) == nil, "per-badge switches are respected")
        let full = BadgeKind.Inputs(claudeActive: true, fullScreen: true, hideInFullScreen: true)
        check(BadgeKind.pick(full) == nil, "no badges in full screen when hidden there")
        check(BadgeKind.pick(BadgeKind.Inputs(claudeActive: true, fullScreen: true, hideInFullScreen: false)) == .claude,
              "badges stay in full screen when allowed")

        let en = Locale(identifier: "en"), ru = Locale(identifier: "ru")
        check(BadgeText.keepAwake(left: 6120, locale: en) == "1h 42m", "Keep Awake time in English: \(BadgeText.keepAwake(left: 6120, locale: en))")
        let ruText = BadgeText.keepAwake(left: 6120, locale: ru)
        check(ruText == "1 ч 42 мин", "Keep Awake time in Russian: \(ruText)")
        check(BadgeText.keepAwake(left: 20, locale: en) == "1m" && BadgeText.keepAwake(left: nil) == "∞", "last minute and unlimited")
        check(BadgeText.timer(left: 299.2, locale: en) == "5:00" && BadgeText.timer(left: 3725, locale: en) == "1h 2m",
              "timer: minutes:seconds, hours past an hour")
        let ears = [BadgeText.ear(for: "88:88"), BadgeText.ear(for: BadgeText.keepAwake(left: 6120, locale: ru))]
        check(ears.allSatisfy { $0 >= 40 && $0 <= 76 }, "time badge ears stay within 40–76 pt: \(ears)")
        check(GlassBackground.effectiveTint(style: .tinted, tint: 0) == 0.2 && GlassBackground.effectiveTint(style: .clear, tint: 0.8) == 0.4,
              "glass tint has a legibility floor and Clear keeps half")
    }

    private static func notchDisplays(_ check: Check) {
        let builtIn = ScreenDesc(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
                                 visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1130),
                                 safeTop: 38, auxLeftWidth: 790, auxRightWidth: 790, isBuiltIn: true)
        let external = ScreenDesc(frame: CGRect(x: 1800, y: 0, width: 2560, height: 1440),
                                  visibleFrame: CGRect(x: 1800, y: 0, width: 2560, height: 1416),
                                  safeTop: 0, auxLeftWidth: nil, auxRightWidth: nil, isBuiltIn: false)
        check(NotchGeometry.cutout(of: builtIn) == cutout, "cutout from the menu-bar areas: \(NotchGeometry.cutout(of: builtIn))")
        let virtual = NotchGeometry.cutout(of: external)
        check(virtual.width == NotchGeometry.virtualNotchWidth && virtual.height == 24 && virtual.midX == 1800 + 1280 && virtual.maxY == 1440,
              "virtual notch matches the real menu-bar height: \(virtual)")
        check(NotchGeometry.choose([], preference: .builtIn, pointer: nil) == nil, "no displays: no notch, no crash")
        check(NotchGeometry.choose([external, builtIn], preference: .builtIn, pointer: nil) == 1, "built-in with the notch wins")
        check(NotchGeometry.choose([external, builtIn], preference: .main, pointer: nil) == 0, "main is the one with the menu bar")
        check(NotchGeometry.choose([builtIn, external], preference: .pointer, pointer: CGPoint(x: 2000, y: 1440)) == 1,
              "pointer mode follows the pointer, top edge included")
        var lidClosed = external
        lidClosed.isBuiltIn = false
        check(NotchGeometry.choose([lidClosed], preference: .builtIn, pointer: nil) == 0, "lid closed falls back to the main display")
    }

    private static func notchFullScreen(_ check: Check) {
        typealias W = FullScreen.WindowInfo
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)   // window-server coordinates
        let menuBar = W(pid: 1, layer: FullScreen.menuBarLayer, bounds: CGRect(x: 0, y: 0, width: 1800, height: 39))
        let fullBelowNotch = W(pid: 42, layer: 0, bounds: CGRect(x: 0, y: 38, width: 1800, height: 1131))
        check(FullScreen.isFullScreen(windows: [fullBelowNotch], screen: screen, notchHeight: 38, ownPID: 7),
              "full screen below the camera housing is detected")
        check(FullScreen.isFullScreen(windows: [W(pid: 42, layer: 0, bounds: screen)], screen: screen, notchHeight: 0, ownPID: 7),
              "full screen on a display without a notch")
        check(!FullScreen.isFullScreen(windows: [fullBelowNotch, menuBar], screen: screen, notchHeight: 38, ownPID: 7),
              "a zoomed window with the menu bar showing is not full screen")
        check(!FullScreen.isFullScreen(windows: [W(pid: 7, layer: 0, bounds: screen)], screen: screen, notchHeight: 38, ownPID: 7),
              "Deckhand's own windows don't count")
        let otherDisplay = W(pid: 42, layer: 0, bounds: CGRect(x: 1800, y: 0, width: 2560, height: 1440))
        check(!FullScreen.isFullScreen(windows: [otherDisplay], screen: screen, notchHeight: 38, ownPID: 7),
              "full screen on another display doesn't block this one")
        let cut = CGRect(x: 790, y: 0, width: 220, height: 38)
        let statusMenu = W(pid: 3, layer: FullScreen.popUpMenuLayer, bounds: CGRect(x: 1060, y: 39, width: 240, height: 300))
        let farPanel = W(pid: 4, layer: FullScreen.popUpMenuLayer, bounds: CGRect(x: 6, y: 40, width: 241, height: 270))
        check(FullScreen.menuOpen(windows: [statusMenu], screen: screen, cutout: cut), "an open status menu near the notch blocks hover")
        check(!FullScreen.menuOpen(windows: [farPanel], screen: screen, cutout: cut), "a pop-up far from the notch doesn't")
    }
}
