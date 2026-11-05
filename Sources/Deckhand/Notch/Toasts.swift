import Foundation

/// A short notice in the notch, e.g. after a screenshot.
struct Toast: Equatable, Identifiable {
    enum Style: Equatable {
        /// Goes away after Settings → Closed Notch → Duration.
        case info
        /// Something needs the user (Claude waits, the timer is up): stays until pointed at or seen in the panel.
        case alert
    }

    let id = UUID()
    let symbol: String
    let text: String
    var style: Style = .info

    func sameMessage(as other: Toast) -> Bool { symbol == other.symbol && text == other.text }
}

/// One notice at a time, the rest wait their turn; alerts jump ahead of info notices. Pure, for the self-test.
struct ToastQueue {
    static let maxWaiting = 4

    private(set) var current: Toast?
    private(set) var waiting: [Toast] = []

    /// Adds a notice. Returns true when it is shown right away (it became `current`).
    /// Repeating the shown message just restarts it; repeating a waiting one keeps a single copy.
    @discardableResult
    mutating func push(_ toast: Toast) -> Bool {
        if let current, current.sameMessage(as: toast) {
            // Keep the stronger style, so a repeated info notice can't downgrade an alert
            var replacement = toast
            if current.style == .alert { replacement.style = .alert }
            self.current = replacement
            return true
        }
        waiting.removeAll { $0.sameMessage(as: toast) }
        if current == nil && waiting.isEmpty {
            current = toast
            return true
        }
        if toast.style == .alert, let i = waiting.firstIndex(where: { $0.style == .info }) {
            waiting.insert(toast, at: i)
        } else {
            waiting.append(toast)
        }
        while waiting.count > Self.maxWaiting {
            // Drop the oldest info notice; alerts are only dropped when nothing else is left
            if let i = waiting.firstIndex(where: { $0.style == .info }) { waiting.remove(at: i) } else { waiting.removeFirst() }
        }
        return false
    }

    /// The shown notice is done; nothing shows until `next()`, which leaves a short gap for the animation.
    mutating func dismissCurrent() { current = nil }

    /// Shows the next waiting notice, if any.
    mutating func next() -> Toast? {
        guard current == nil, !waiting.isEmpty else { return current }
        current = waiting.removeFirst()
        return current
    }

    /// An alert waits behind an info notice, which should then make way sooner.
    var alertWaiting: Bool { waiting.contains { $0.style == .alert } }
}

/// What the closed notch shows when no notice is up: one badge, the most important first.
enum BadgeKind: String, Equatable, CaseIterable {
    case claude, timer, music, keepAwake

    struct Inputs: Equatable {
        var claudeActive = false, claudeEnabled = true
        var timerActive = false, timerEnabled = true
        var musicPlaying = false, musicEnabled = true
        var keepAwakeActive = false, keepAwakeEnabled = true
        var fullScreen = false, hideInFullScreen = true
    }

    /// Claude Code, then the timer, music and Keep Awake. Alerts are notices and come before all of these.
    static func pick(_ i: Inputs) -> BadgeKind? {
        if i.fullScreen && i.hideInFullScreen { return nil }
        if i.claudeActive && i.claudeEnabled { return .claude }
        if i.timerActive && i.timerEnabled { return .timer }
        if i.musicPlaying && i.musicEnabled { return .music }
        if i.keepAwakeActive && i.keepAwakeEnabled { return .keepAwake }
        return nil
    }
}
