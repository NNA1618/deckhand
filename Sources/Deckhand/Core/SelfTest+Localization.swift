import Foundation

extension SelfTest {
    /// Russian strings. Shared; keep additions small.
    static func localization(_ check: Check) {
        // Only meaningful inside the .app, where the .lproj folders are bundled
        if let path = Bundle.main.path(forResource: "ru", ofType: "lproj"), let ru = Bundle(path: path) {
            check(ru.localizedString(forKey: "Settings", value: nil, table: nil) == "Настройки", "russian localization bundled")
            let percent = 50
            let charging = String(localized: "Charging, \(percent)%", bundle: ru)
            check(charging == "Заряжается, 50%", "russian interpolated string: \(charging)")
        }
    }
}
