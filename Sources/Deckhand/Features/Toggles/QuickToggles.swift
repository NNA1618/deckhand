import AppKit
import Combine

/// One-click switches for common Mac settings, like One Switch.
/// Each reads the real state each time the panel shows it, so changes made elsewhere are picked up.
@MainActor
final class QuickToggles: ObservableObject {
    static let shared = QuickToggles()

    enum Toggle: String, CaseIterable, Identifiable {
        case darkMode, mute, hideDesktop, hiddenFiles
        var id: String { rawValue }

        var title: String {
            switch self {
            case .darkMode: return String(localized: "Dark Mode")
            case .mute: return String(localized: "Mute")
            case .hideDesktop: return String(localized: "Hide Desktop")
            case .hiddenFiles: return String(localized: "Hidden Files")
            }
        }

        func symbol(on: Bool) -> String {
            switch self {
            case .darkMode: return on ? "moon.fill" : "moon"
            case .mute: return on ? "speaker.slash.fill" : "speaker.wave.2"
            case .hideDesktop: return on ? "eye.slash" : "menubar.dock.rectangle"
            case .hiddenFiles: return on ? "eye" : "eye.slash"
            }
        }

        var help: String {
            switch self {
            case .darkMode: return String(localized: "Switch the Mac between light and dark appearance")
            case .mute: return String(localized: "Mute or unmute the sound output")
            case .hideDesktop: return String(localized: "Hide the icons on the desktop, e.g. before a screen share")
            case .hiddenFiles: return String(localized: "Show hidden files in Finder")
            }
        }
    }

    @Published private(set) var states: [Toggle: Bool] = [:]
    @Published private(set) var error: String?

    private init() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        var s: [Toggle: Bool] = [:]
        for t in Toggle.allCases { s[t] = read(t) }
        states = s
    }

    func isOn(_ t: Toggle) -> Bool { states[t] ?? false }

    func flip(_ t: Toggle) {
        let target = !read(t)
        error = nil
        switch t {
        case .darkMode:
            runScript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(target)")
        case .mute:
            runScript("set volume output muted \(target)")
        case .hideDesktop:
            setFinder("CreateDesktop", !target)
        case .hiddenFiles:
            setFinder("AppleShowAllFiles", target)
        }
        // Finder and System Events apply changes a moment later
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refresh() }
        states[t] = target
    }

    private func read(_ t: Toggle) -> Bool {
        switch t {
        case .darkMode:
            return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        case .mute:
            return runScript("output muted of (get volume settings)")?.booleanValue ?? false
        case .hideDesktop:
            return !Self.finderBool("CreateDesktop", default: true)
        case .hiddenFiles:
            return Self.finderBool("AppleShowAllFiles", default: false)
        }
    }

    nonisolated static func finderBool(_ key: String, default value: Bool) -> Bool {
        CFPreferencesAppSynchronize("com.apple.finder" as CFString)
        guard let v = CFPreferencesCopyAppValue(key as CFString, "com.apple.finder" as CFString) else { return value }
        if let b = v as? Bool { return b }
        if let s = v as? String { return ["1", "yes", "true"].contains(s.lowercased()) }
        return value
    }

    /// Finder reads these keys only at launch, so it is restarted, like `killall Finder`.
    private func setFinder(_ key: String, _ value: Bool) {
        CFPreferencesSetAppValue(key as CFString, value as CFBoolean, "com.apple.finder" as CFString)
        CFPreferencesAppSynchronize("com.apple.finder" as CFString)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Finder"]
        try? p.run()
    }

    @discardableResult
    private func runScript(_ source: String) -> NSAppleEventDescriptor? {
        var info: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&info)
        if let info {
            Log.info("toggle script failed: \(info)")
            error = String(localized: "macOS did not allow this. Allow Deckhand in System Settings → Privacy & Security → Automation.")
        }
        return result
    }
}
