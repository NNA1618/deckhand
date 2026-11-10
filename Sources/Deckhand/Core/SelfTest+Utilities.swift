import AppKit

extension SelfTest {
    /// Keep Awake, the timer, battery and quick toggles. Owned by the panel and utilities workstream.
    /// Nothing here touches Dark Mode, mute, the desktop or Finder: only the pure rules are checked.
    static func utilities(_ check: Check) {
        battery(check)
        timer(check)
        keepAwake(check)
        lidSleep(check)
        toggles(check)
    }

    private static func battery(_ check: Check) {
        var warned = Set<Int>()
        let onBattery = BatteryMonitor.State(percent: 50, onAC: false, charging: false)
        let plugged = BatteryMonitor.State(percent: 50, onAC: true, charging: true)
        check(BatteryMonitor.events(from: onBattery, to: plugged, warned: &warned) == [.pluggedIn(percent: 50, charging: true)],
              "battery: plugging in is reported")
        let held = BatteryMonitor.State(percent: 80, onAC: true, charging: false)
        check(BatteryMonitor.events(from: onBattery, to: held, warned: &warned) == [.pluggedIn(percent: 80, charging: false)],
              "battery: a held charge is reported as not charging")
        check(UtilityNotices.chargingText(percent: 80, charging: false) != UtilityNotices.chargingText(percent: 80, charging: true),
              "battery: Connected and Charging read differently")
        let low = BatteryMonitor.State(percent: 19, onAC: false, charging: false)
        check(BatteryMonitor.events(from: onBattery, to: low, warned: &warned) == [.low(percent: 19)]
              && BatteryMonitor.events(from: low, to: low, warned: &warned).isEmpty,
              "battery: low level is reported once")
    }

    private static func timer(_ check: Check) {
        let now = Date()
        check(Countdown.format(seconds: 300) == "5:00" && Countdown.format(seconds: 299.2) == "5:00"
              && Countdown.format(seconds: 3725) == "1:02:05" && Countdown.format(seconds: 0) == "0:00",
              "timer: time left is formatted")
        check(Countdown.remaining(endsAt: now.addingTimeInterval(90), pausedLeft: nil, now: now) == 90
              && Countdown.remaining(endsAt: now.addingTimeInterval(-5), pausedLeft: nil, now: now) == 0
              && Countdown.remaining(endsAt: nil, pausedLeft: 42, now: now) == 42,
              "timer: remaining time while running, overdue and paused")
        check(Countdown.adding(60, to: 30) == 90 && Countdown.adding(60, to: TimeInterval(Countdown.maxMinutes * 60)) == TimeInterval(Countdown.maxMinutes * 60),
              "timer: +1 min stops at the longest timer")
        check(UtilitySettings.sanitized(presets: [3, 0, 99999]) == [3, 15, 25, 45], "timer: broken presets fall back to defaults")
        check(TimerCard.step(9, by: 1) == 10 && TimerCard.step(10, by: 1) == 15 && TimerCard.step(12, by: -1) == 10
              && TimerCard.step(60, by: 1) == 75 && TimerCard.step(61, by: -1) == 60 && TimerCard.step(1, by: -1) == 1,
              "timer: custom length steps 1, 5, then 15 minutes")

        let timer = Countdown.shared
        timer.start(minutes: 5)
        check(timer.isRunning && timer.remainingText() == "5:00", "timer starts at 5:00 (\(timer.remainingText()))")
        timer.pause()
        timer.addMinute()
        check(timer.isPaused && timer.remainingText() == "6:00", "timer pauses and adds a minute (\(timer.remainingText()))")
        timer.resume()
        check(timer.isRunning && !timer.isPaused, "timer resumes")
        timer.start(minutes: 0)
        check(timer.minutes == 1, "timer: zero minutes becomes one")
        timer.stop()
        check(!timer.isActive && !timer.isRinging, "timer stops")
    }

    private static func keepAwake(_ check: Check) {
        typealias S = BatteryMonitor.State
        check(KeepAwake.shouldStop(previous: S(percent: 21, onAC: false, charging: false), now: S(percent: 19, onAC: false, charging: false), floor: 20),
              "keep awake: stops when the battery drops below the floor")
        check(!KeepAwake.shouldStop(previous: S(percent: 21, onAC: false, charging: false), now: S(percent: 19, onAC: false, charging: false), floor: 0),
              "keep awake: floor Never keeps running")
        check(!KeepAwake.shouldStop(previous: S(percent: 15, onAC: false, charging: false), now: S(percent: 14, onAC: false, charging: false), floor: 20),
              "keep awake: a session started below the floor keeps running")
        check(KeepAwake.shouldStop(previous: S(percent: 15, onAC: true, charging: true), now: S(percent: 15, onAC: false, charging: false), floor: 20),
              "keep awake: unplugging below the floor stops it")
        check(!KeepAwake.shouldStop(previous: S(percent: 21, onAC: true, charging: true), now: S(percent: 19, onAC: true, charging: true), floor: 20),
              "keep awake: on power it keeps running")

        let awake = KeepAwake.shared
        awake.start(for: 3600)
        check(awake.isActive && awake.holdsAssertion, "keep awake holds a power assertion")
        check(awake.holdsDisplayAssertion == !Settings.shared.keepAwakeAllowDisplaySleep, "keep awake follows the display setting")
        check(awake.remainingText() == "0:59" || awake.remainingText() == "1:00", "keep awake time left \(awake.remainingText())")
        check(awake.remainingDescription() == KeepAwake.shortTitle(for: 3600), "keep awake reads 1h, not 59m (\(awake.remainingDescription()))")
        awake.stop()
        check(!awake.isActive && !awake.holdsAssertion && !awake.holdsDisplayAssertion, "keep awake releases the assertions")
    }

    private static func toggles(_ check: Check) {
        let denied = QuickToggles.problem(for: .darkMode, code: -1743)
        let timeout = QuickToggles.problem(for: .darkMode, code: -1712)
        let other = QuickToggles.problem(for: .darkMode, code: -600)
        check(denied.opensAutomation && !timeout.opensAutomation && !other.opensAutomation
              && Set([denied.message, timeout.message, other.message]).count == 3,
              "toggles: permission, timeout and other errors read differently")
        check(DesktopCover.gravity(scaling: .scaleProportionallyUpOrDown, clipping: true) == .resizeAspectFill
              && DesktopCover.gravity(scaling: .scaleProportionallyUpOrDown, clipping: false) == .resizeAspect
              && DesktopCover.gravity(scaling: .scaleAxesIndependently, clipping: true) == .resize
              && DesktopCover.gravity(scaling: .scaleNone, clipping: false) == .center,
              "desktop cover follows the wallpaper's fill, fit, stretch and center")
    }
}
