import AppKit

extension SelfTest {
    /// Keep Awake, the timer, battery and quick toggles. Owned by the panel and utilities workstream.
    static func utilities(_ check: Check) {
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
    }
}
