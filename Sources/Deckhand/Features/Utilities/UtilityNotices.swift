import AppKit

/// Notices in the notch for the battery, the timer and Keep Awake, each behind its switch
/// in Settings → Closed Notch. Owned by the panel and utilities workstream.
@MainActor
enum UtilityNotices {
    static func install(notch: NotchController) {
        let battery = BatteryMonitor.shared
        battery.onEvent = { [weak notch] event in
            switch event {
            case .pluggedIn:
                guard Settings.shared.noticeCharging else { return }
                // Right after plugging in macOS may not have started charging yet; look again a moment later
                Task { @MainActor [weak notch] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let state = BatteryMonitor.read(), state.onAC else { return }
                    notch?.showToast(symbol: state.charging ? "bolt.fill" : "powerplug.fill",
                                     text: chargingText(percent: state.percent, charging: state.charging))
                }
            case .low(let percent):
                guard Settings.shared.noticeLowBattery else { return }
                notch?.showToast(symbol: "battery.25percent", text: String(localized: "Battery \(percent)%"))
            }
        }
        battery.onChange = { old, new in
            KeepAwake.shared.batteryChanged(from: old, to: new)
        }
        battery.start()

        Countdown.shared.onFinish = { [weak notch] in
            guard Settings.shared.noticeTimer else { return }
            notch?.showToast(symbol: "timer", text: String(localized: "Time is up"))
        }

        KeepAwake.shared.onEnd = { [weak notch] reason in
            guard Settings.shared.noticeKeepAwake else { return }
            switch reason {
            case .timeUp:
                notch?.showToast(symbol: "moon.zzz", text: String(localized: "Keep Awake ended"))
            case .lowBattery(let percent):
                notch?.showToast(symbol: "battery.25percent", text: String(localized: "Keep Awake off, battery \(percent)%"))
            }
        }
    }

    /// "Charging, 80 %" or, when macOS holds the charge, "Connected, 80 %".
    static func chargingText(percent: Int, charging: Bool) -> String {
        charging ? String(localized: "Charging, \(percent)%") : String(localized: "Connected, \(percent)%")
    }

    /// The Keep Awake shortcut: switches it and says what happened.
    static func toggleKeepAwake(notch: NotchController) {
        let awake = KeepAwake.shared
        awake.toggle()
        guard Settings.shared.noticeKeepAwake else { return }
        let text = awake.isActive
            ? (awake.endsAt == nil ? String(localized: "Keep Awake on")
                                   : String(localized: "Keep Awake for \(KeepAwake.title(for: awake.duration))"))
            : String(localized: "Keep Awake off")
        notch.showToast(symbol: awake.isActive ? "cup.and.saucer.fill" : "moon.zzz", text: text)
    }
}
