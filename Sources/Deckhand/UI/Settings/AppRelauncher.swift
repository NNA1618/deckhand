import AppKit

@MainActor
enum AppRelauncher {
    /// The language setting this copy of Deckhand started with. A different choice needs a restart.
    static let languageAtLaunch = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"

    /// Whether picking `chosen` needs a restart to show, given the language Deckhand started with.
    nonisolated static func needsRestart(chosen: String, launched: String) -> Bool {
        chosen != launched
    }

    /// Keep Awake and the timer live in this process, so a restart ends them.
    static var restartStopsSomething: Bool {
        KeepAwake.shared.isActive || Countdown.shared.isActive
    }

    /// Starts a new copy once this one has quit. Only ever called from a button the user pressed.
    static func relaunch(openSettings: Bool) {
        guard !AppPaths.isSnapshot else { return }
        let path = Bundle.main.bundlePath
        let args = openSettings ? " --args --settings" : ""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\"\(args)", path]
        do {
            try p.run()
        } catch {
            Log.info("relaunch failed: \(error)")
            return
        }
        NSApp.terminate(nil)
    }

    /// Removes every setting stored in UserDefaults and restarts. Data (history, prompts, shelf),
    /// the API key in the Keychain and the Claude Code hook stay.
    static func resetAllSettings() {
        guard !AppPaths.isSnapshot else { return }
        UserDefaults.standard.removePersistentDomain(forName: AppPaths.bundleId)
        // The API key stays, and with no stored backend Settings would take this for a 0.4 install
        // and switch quick actions to the paid API. The default is Claude Code.
        UserDefaults.standard.set(ClaudeBackend.claudeCode.rawValue, forKey: "claudeBackend")
        UserDefaults.standard.synchronize()
        relaunch(openSettings: true)
    }
}
