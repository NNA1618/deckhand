import Foundation
import Combine

/// Settings of the timer and Keep Awake that are new in 0.5.
/// The older ones (default length, display sleep, notices, sounds) stay in `Settings`.
@MainActor
final class UtilitySettings: ObservableObject {
    static let shared = UtilitySettings()
    private let d = UserDefaults.standard

    nonisolated static let defaultPresets = [5, 15, 25, 45]
    /// Choices for "Turn off below", in percent; 0 means never.
    nonisolated static let batteryFloors = [0, 50, 20, 10]

    /// Timer lengths on Home and in the menu, in minutes.
    @Published var timerPresets: [Int] { didSet { d.set(timerPresets, forKey: "timerPresets") } }
    /// Keep "Time is up" at the notch and repeat the sound until dismissed.
    @Published var timerAlertUntilDismissed: Bool {
        didSet { d.set(timerAlertUntilDismissed, forKey: "timerAlertUntilDismissed") }
    }
    /// Keep Awake turns itself off on battery below this percentage; 0 means never.
    @Published var keepAwakeBatteryFloor: Int { didSet { d.set(keepAwakeBatteryFloor, forKey: "keepAwakeBatteryFloor") } }
    /// Keep Awake also stops sleep with the lid closed, through `LidSleep`. Needs its helper.
    @Published var keepAwakeLidClosed: Bool { didSet { d.set(keepAwakeLidClosed, forKey: "keepAwakeLidClosed") } }
    /// On battery below this percentage the Mac may sleep with the lid closed again.
    @Published var keepAwakeLidBatteryFloor: Int {
        didSet { d.set(keepAwakeLidBatteryFloor, forKey: "keepAwakeLidBatteryFloor") }
    }

    private init() {
        d.register(defaults: [
            "timerPresets": Self.defaultPresets,
            "timerAlertUntilDismissed": false,
            "keepAwakeBatteryFloor": 0,
            "keepAwakeLidClosed": false,
            "keepAwakeLidBatteryFloor": 20,
        ])
        timerPresets = Self.sanitized(presets: (d.array(forKey: "timerPresets") as? [Int]) ?? Self.defaultPresets)
        timerAlertUntilDismissed = d.bool(forKey: "timerAlertUntilDismissed")
        keepAwakeBatteryFloor = d.integer(forKey: "keepAwakeBatteryFloor")
        keepAwakeLidClosed = d.bool(forKey: "keepAwakeLidClosed")
        let lidFloor = d.integer(forKey: "keepAwakeLidBatteryFloor")
        keepAwakeLidBatteryFloor = LidSleep.batteryFloors.contains(lidFloor) ? lidFloor : 20
    }

    /// Four presets between 1 and `Countdown.maxMinutes`, falling back to the defaults for anything broken.
    nonisolated static func sanitized(presets: [Int]) -> [Int] {
        (0..<defaultPresets.count).map { i in
            let value = i < presets.count ? presets[i] : defaultPresets[i]
            return (1...Countdown.maxMinutes).contains(value) ? value : defaultPresets[i]
        }
    }
}
