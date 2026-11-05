import AppKit

/// Notices in the notch for the battery, the timer and Keep Awake.
/// Owned by the panel and utilities workstream.
@MainActor
enum UtilityNotices {
    static func install(notch: NotchController) {
        BatteryMonitor.shared.onEvent = { [weak notch] event in
            guard Settings.shared.batteryNotices else { return }
            switch event {
            case .pluggedIn(let percent):
                notch?.showToast(symbol: "bolt.fill", text: String(localized: "Charging, \(percent)%"))
            case .low(let percent):
                notch?.showToast(symbol: "battery.25percent", text: String(localized: "Battery \(percent)%"))
            }
        }
        BatteryMonitor.shared.start()

        Countdown.shared.onFinish = { [weak notch] in
            notch?.showToast(symbol: "timer", text: String(localized: "Time is up"))
        }
    }

    static func toggleKeepAwake(notch: NotchController) {
        let awake = KeepAwake.shared
        awake.toggle()
        let text = awake.isActive
            ? (awake.endsAt == nil ? String(localized: "Awake until turned off")
                                   : String(localized: "Awake for \(KeepAwake.title(for: awake.duration))"))
            : String(localized: "Sleep as usual")
        notch.showToast(symbol: awake.isActive ? "cup.and.saucer.fill" : "moon.zzz", text: text)
    }
}
