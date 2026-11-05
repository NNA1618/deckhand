import AppKit
import Combine

/// One-click switches for common Mac settings, like One Switch.
///
/// Nothing here may block the main thread: Dark Mode goes through `AppleScriptRunner` (its own queue,
/// a timeout, a permission check first), mute through CoreAudio, Hide Desktop is a window of our own.
/// Only Hidden Files still needs Finder to restart, and it asks first.
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

    /// What went wrong with the last switch, shown on one line under the toggles.
    struct Problem: Equatable {
        let toggle: Toggle
        let message: String
        /// A longer explanation for the tooltip.
        let detail: String
        /// Offer a button that opens Privacy & Security → Automation.
        var opensAutomation = false
    }

    @Published private(set) var states: [Toggle: Bool] = [:]
    /// Switches still waiting for the system to answer.
    @Published private(set) var pending: Set<Toggle> = []
    @Published private(set) var problem: Problem?
    /// A switch that restarts Finder, waiting for the user to confirm.
    @Published private(set) var confirming: Toggle?
    /// False when the current output device has no mute control.
    @Published private(set) var canMute = true

    private let mute = SystemMute()
    nonisolated private static let systemEvents = "com.apple.systemevents"
    nonisolated private static let finder = "com.apple.finder"

    private init() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { QuickToggles.shared.refresh() }
        }
        mute.onChange = { [weak self] in self?.refresh() }
    }

    /// Reads every switch from the system. All reads are quick and local, so this is fine on the main thread.
    func refresh() {
        mute.start()
        let muted = mute.isMuted
        canMute = muted != nil
        var s: [Toggle: Bool] = [:]
        s[.darkMode] = Self.isDarkMode
        s[.mute] = muted ?? false
        s[.hideDesktop] = DesktopCover.shared.isShown || !Self.finderBool("CreateDesktop", default: true)
        s[.hiddenFiles] = Self.finderBool("AppleShowAllFiles", default: false)
        states = s
    }

    func isOn(_ t: Toggle) -> Bool { states[t] ?? false }

    /// Flips a switch. `beforePrompt` runs right before macOS may show a permission prompt,
    /// so the panel can get out of its way (it floats above alerts).
    func flip(_ t: Toggle, beforePrompt: @escaping () -> Void = {}) {
        guard !pending.contains(t) else { return }
        let target = !isOn(t)
        confirming = nil
        switch t {
        case .darkMode:
            setDarkMode(target, beforePrompt: beforePrompt)
        case .mute:
            if mute.setMuted(target) {
                succeeded(t)
            } else {
                fail(Problem(toggle: t, message: String(localized: "This output can't be muted"),
                             detail: String(localized: "The current sound output has no mute control.")))
            }
            refresh()
        case .hideDesktop:
            if !target && !Self.finderBool("CreateDesktop", default: true) {
                // Hidden by an older Deckhand through Finder: undoing that needs a Finder restart
                confirming = t
                return
            }
            target ? DesktopCover.shared.show() : DesktopCover.shared.hide()
            succeeded(t)
            refresh()
        case .hiddenFiles:
            confirming = t
        }
    }

    /// The user agreed to restart Finder for the switch in `confirming`.
    func confirm() {
        guard let t = confirming else { return }
        confirming = nil
        switch t {
        case .hiddenFiles:
            restartFinder(setting: "AppleShowAllFiles", to: !isOn(.hiddenFiles), for: t)
        case .hideDesktop:
            DesktopCover.shared.hide()
            restartFinder(setting: "CreateDesktop", to: true, for: t)
        default:
            break
        }
    }

    func cancelConfirmation() { confirming = nil }

    /// For `--snapshot`: shows an error line or the Finder question without touching anything.
    func showForSnapshot(problem: Problem?, confirming: Toggle?) {
        guard AppPaths.isSnapshot else { return }
        self.problem = problem
        self.confirming = confirming
    }

    func dismissProblem() { problem = nil }

    /// Opens Privacy & Security → Automation, after the user clicked the button.
    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Dark Mode

    nonisolated static var isDarkMode: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    private func setDarkMode(_ on: Bool, beforePrompt: @escaping () -> Void) {
        pending.insert(.darkMode)
        Task {
            defer { pending.remove(.darkMode) }
            var permission = await Self.permission(ask: false)
            if permission == .notAsked {
                beforePrompt()
                permission = await Self.permission(ask: true)
            }
            if permission == .denied {
                fail(Self.problem(for: .darkMode, code: -1743))
                return
            }
            let result = await AppleScriptRunner.shared.run(
                "tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)", timeout: 5)
            switch result {
            case .success:
                succeeded(.darkMode)
            case .failure(let failure):
                Log.info("dark mode: \(failure.code) \(failure.message)")
                fail(Self.problem(for: .darkMode, code: failure.code))
            }
            refresh()
        }
    }

    /// Asks macOS whether Deckhand may control System Events, off the main thread:
    /// with `ask` the call waits for the user to answer the prompt.
    private static func permission(ask: Bool) async -> AutomationPermission {
        await Task.detached(priority: .userInitiated) {
            AutomationPermission.status(bundleId: systemEvents, ask: ask)
        }.value
    }

    /// A message for an AppleScript error number. Pure, so the self-test can check the mapping.
    nonisolated static func problem(for toggle: Toggle, code: Int) -> Problem {
        switch code {
        case -1743, -10004:   // not allowed, privilege violation
            return Problem(toggle: toggle,
                           message: String(localized: "Not allowed in Automation settings"),
                           detail: String(localized: "Allow Deckhand to control System Events in System Settings → Privacy & Security → Automation."),
                           opensAutomation: true)
        case -1712:           // timed out
            return Problem(toggle: toggle,
                           message: String(localized: "System Events didn't respond"),
                           detail: String(localized: "System Events took too long to answer. Try again in a moment."))
        default:
            return Problem(toggle: toggle,
                           message: String(localized: "Couldn't switch \(toggle.title)"),
                           detail: String(localized: "macOS returned error \(code)."))
        }
    }

    // MARK: - Finder

    nonisolated static func finderBool(_ key: String, default value: Bool) -> Bool {
        CFPreferencesAppSynchronize(finder as CFString)
        guard let v = CFPreferencesCopyAppValue(key as CFString, finder as CFString) else { return value }
        if let b = v as? Bool { return b }
        if let s = v as? String { return ["1", "yes", "true"].contains(s.lowercased()) }
        return value
    }

    /// Finder reads these keys only at launch. Runs only after the user confirmed.
    private func restartFinder(setting key: String, to value: Bool, for t: Toggle) {
        CFPreferencesSetAppValue(key as CFString, value as CFBoolean, Self.finder as CFString)
        CFPreferencesAppSynchronize(Self.finder as CFString)
        pending.insert(t)
        Task {
            let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                p.arguments = ["Finder"]
                do { try p.run(); p.waitUntilExit() } catch { return false }
                return p.terminationStatus == 0
            }.value
            pending.remove(t)
            if ok {
                succeeded(t)
            } else {
                fail(Problem(toggle: t, message: String(localized: "Finder didn't restart"),
                             detail: String(localized: "The change applies the next time Finder starts.")))
            }
            refresh()
        }
    }

    // MARK: - Results

    private func succeeded(_ t: Toggle) {
        if problem?.toggle == t { problem = nil }
    }

    private func fail(_ p: Problem) {
        problem = p
    }
}
