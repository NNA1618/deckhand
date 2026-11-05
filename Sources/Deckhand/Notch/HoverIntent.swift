import CoreGraphics
import Foundation

/// The hover zones in global Cocoa coordinates (origin bottom left, y up). Pure, for the self-test.
enum ActivationZones {
    /// Where resting the pointer opens the panel: the physical cutout plus `margin` on each side,
    /// never below the menu-bar band, so app windows and menu-bar items next to the notch stay usable.
    /// With `badgeWidth` (only when the user asked for badges to open the panel) it spans the badge instead.
    static func trigger(cutout: CGRect, margin: CGFloat, badgeWidth: CGFloat? = nil) -> CGRect {
        let width = max(cutout.width + 2 * margin, badgeWidth ?? 0)
        return CGRect(x: cutout.midX - width / 2, y: cutout.minY, width: width, height: cutout.height)
    }

    /// Where the pointer may wander while the panel is open without closing it: the panel plus a little slack,
    /// but never above the top of the notch screen (that is another display).
    static func open(panel: CGRect, slack: CGFloat = 10) -> CGRect {
        let r = panel.insetBy(dx: -slack, dy: -slack)
        return CGRect(x: r.minX, y: r.minY, width: r.width, height: panel.maxY - r.minY)
    }

    /// Like `CGRect.contains`, but the top edge counts: the pointer pressed against the top of the screen
    /// reports y == maxY, and that is the most deliberate place to point at.
    static func contains(_ rect: CGRect, _ p: CGPoint) -> Bool {
        p.x >= rect.minX && p.x < rect.maxX && p.y >= rect.minY && p.y <= rect.maxY
    }
}

/// Decides when hovering opens and when leaving closes the panel, from pointer samples and clicks.
///
/// Pure value type with explicit timestamps (seconds on any monotonic clock), so every rule is checked
/// in the self-test without moving the real pointer. The controller feeds it events and runs one-shot timers
/// for the times it asks for; nothing polls.
struct HoverIntent {
    struct Config: Equatable {
        /// How long the pointer must rest on the notch.
        var openDelay: TimeInterval = 0.2
        /// How long the pointer must stay away before the panel closes.
        var closeDelay: TimeInterval = 0.5
        /// Faster than this the pointer is passing by, on the way to something else.
        var passThroughSpeed: CGFloat = 600
        /// After a click in the menu bar the pointer is busy with a menu.
        var clickCooldown: TimeInterval = 0.8
        /// After hover suspension ends (capture, color picker), so the pointer can get away first.
        var resumeGrace: TimeInterval = 0.5
    }

    enum Verdict: Equatable {
        case idle
        /// Ask again at this time, if nothing else happens first.
        case wait(until: TimeInterval)
        case act
    }

    struct Sample: Equatable {
        var point: CGPoint
        var time: TimeInterval
    }

    var config = Config()

    private(set) var samples: [Sample] = []
    /// When the pointer started resting on the notch (restarted by fast movement, held buttons and clicks).
    private(set) var dwellStart: TimeInterval?
    /// False after a deliberate close while the pointer was on the notch, until it leaves the trigger zone.
    private(set) var armed = true
    private(set) var lastMenuBarClick: TimeInterval = -.infinity
    /// Capture or the color picker runs.
    private(set) var suspended = false
    private(set) var graceUntil: TimeInterval = -.infinity
    /// "Pause hover" from the menu bar.
    private(set) var pausedUntil: TimeInterval = -.infinity

    // While open
    private(set) var wasInsideOpen = true
    private(set) var leftAt: TimeInterval?

    private static let speedWindow: TimeInterval = 0.1
    private static let maxSamples = 8

    // MARK: - Opening

    /// The pointer moved (or a button changed) while the panel is closed.
    /// `buttonsHeld` is any mouse button down; `fileDrag` means files from Finder or another app are being dragged.
    mutating func pointerMoved(to p: CGPoint, at t: TimeInterval, inTrigger: Bool,
                               buttonsHeld: Bool = false, fileDrag: Bool = false) -> Verdict {
        record(p, t)
        guard inTrigger else {
            dwellStart = nil
            armed = true
            return .idle
        }
        guard armed, !suspended else { dwellStart = nil; return .idle }
        if buttonsHeld && !fileDrag { dwellStart = nil; return .idle }
        if !fileDrag && speed(at: t) > config.passThroughSpeed {
            dwellStart = t
        } else if dwellStart == nil {
            dwellStart = t
        }
        return evaluate(at: t, inTrigger: true, buttonsHeld: buttonsHeld, fileDrag: fileDrag)
    }

    /// Re-check at a time asked for by `.wait`, with the pointer's state at that moment.
    mutating func evaluate(at t: TimeInterval, inTrigger: Bool, buttonsHeld: Bool = false, fileDrag: Bool = false) -> Verdict {
        guard inTrigger, armed, !suspended, t >= pausedUntil else { return .idle }
        if buttonsHeld && !fileDrag { dwellStart = nil; return .idle }
        guard let start = dwellStart else { dwellStart = t; return .wait(until: t + config.openDelay) }
        let readyAt = max(start + config.openDelay, lastMenuBarClick + config.clickCooldown, graceUntil)
        if t < readyAt { return .wait(until: readyAt) }
        if !fileDrag && speed(at: t) > config.passThroughSpeed {
            dwellStart = t
            return .wait(until: t + config.openDelay)
        }
        dwellStart = nil
        return .act
    }

    /// A click anywhere in the menu-bar band: the user is working with menus, not the notch.
    mutating func menuBarClicked(at t: TimeInterval) {
        lastMenuBarClick = t
        dwellStart = nil
    }

    /// Esc, the shortcut, a click outside or the menu closed the panel. If the pointer is still on the notch,
    /// it has to leave before hover can open the panel again; otherwise it would reopen right away.
    mutating func closedDeliberately(pointerInTrigger: Bool) {
        armed = !pointerInTrigger
        dwellStart = nil
        leftAt = nil
    }

    /// The panel closed because the pointer left; hover may open it again on the next visit.
    mutating func closedByLeaving() {
        dwellStart = nil
        leftAt = nil
    }

    mutating func setSuspended(_ on: Bool, at t: TimeInterval, pointerInTrigger: Bool) {
        guard on != suspended else { return }
        suspended = on
        dwellStart = nil
        if !on {
            graceUntil = t + config.resumeGrace
            armed = !pointerInTrigger
        }
    }

    /// Pause for `duration` seconds; 0 resumes.
    mutating func pause(for duration: TimeInterval, at t: TimeInterval) {
        pausedUntil = duration > 0 ? t + duration : -.infinity
        dwellStart = nil
    }

    func isPaused(at t: TimeInterval) -> Bool { t < pausedUntil }

    // MARK: - Closing

    /// The panel just opened. A panel opened by the shortcut or the menu while the pointer is elsewhere
    /// stays until the pointer has been inside once, so it doesn't close before the user gets there.
    mutating func opened(pointerInside: Bool) {
        wasInsideOpen = pointerInside
        leftAt = nil
        dwellStart = nil
    }

    /// The pointer moved while the panel is open. `.act` means close now.
    mutating func pointerMovedWhileOpen(to p: CGPoint, at t: TimeInterval, inOpenZone: Bool,
                                        buttonsHeld: Bool = false, closeOnExit: Bool = true) -> Verdict {
        record(p, t)
        return evaluateOpen(at: t, inOpenZone: inOpenZone, buttonsHeld: buttonsHeld, closeOnExit: closeOnExit)
    }

    mutating func evaluateOpen(at t: TimeInterval, inOpenZone: Bool, buttonsHeld: Bool = false,
                               closeOnExit: Bool = true) -> Verdict {
        if inOpenZone {
            wasInsideOpen = true
            leftAt = nil
            return .idle
        }
        // A drag or a text selection that strays outside must not lose the panel under it
        guard closeOnExit, wasInsideOpen, !buttonsHeld else { leftAt = nil; return .idle }
        let since = leftAt ?? t
        leftAt = since
        return t - since >= config.closeDelay ? .act : .wait(until: since + config.closeDelay)
    }

    // MARK: - Speed

    /// Points per second over the last 0.1 s. A pointer that sent no events lately is resting: 0.
    func speed(at t: TimeInterval) -> CGFloat {
        guard let last = samples.last, t - last.time <= Self.speedWindow else { return 0 }
        let recent = samples.filter { last.time - $0.time <= Self.speedWindow }
        if recent.count >= 2, let first = recent.first {
            var path: CGFloat = 0
            for (a, b) in zip(recent, recent.dropFirst()) { path += hypot(b.point.x - a.point.x, b.point.y - a.point.y) }
            return path / CGFloat(max(last.time - first.time, 1.0 / 120))
        }
        // One recent sample: compare with the one before it, if that is not ancient
        guard samples.count >= 2 else { return 0 }
        let prev = samples[samples.count - 2]
        let dt = last.time - prev.time
        guard dt > 0, dt <= 0.25 else { return 0 }
        return hypot(last.point.x - prev.point.x, last.point.y - prev.point.y) / CGFloat(dt)
    }

    private mutating func record(_ p: CGPoint, _ t: TimeInterval) {
        if let last = samples.last, last.point == p, t - last.time < Self.speedWindow { return }
        samples.append(Sample(point: p, time: t))
        if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }
    }
}
