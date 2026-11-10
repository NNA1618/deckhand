import AppKit
import Foundation

/// Runs the commands behind "Also when the lid is closed", so the self-test can put a fake in their place.
@MainActor
protocol LidSleepRunner: AnyObject {
    /// Runs a tool and waits for it. Only `sudo -n` and `pmset -g` go through here: neither ever waits for input.
    func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String)
    /// Runs a shell command as root after macOS asks for an administrator's password.
    func runAsAdmin(_ shellCommand: String, prompt: String) async -> LidSleep.AdminResult
}

/// Keeps the Mac awake with the lid closed while Keep Awake is on.
///
/// Power assertions can't stop closed-lid sleep without an external display; only `pmset -a disablesleep 1` can,
/// and it needs root. Without a signed helper the way there is a one-line sudoers rule, installed once with the
/// administrator password, that lets this user run exactly `pmset -a disablesleep 1` and `… 0`, nothing else.
///
/// The one rule that matters: the Mac must never stay unable to sleep. A flag is saved before sleep is turned off,
/// and every way out turns it back on: Keep Awake ending, quitting, shutting down, a low battery, and the next
/// launch after a crash.
@MainActor
final class LidSleep: ObservableObject {
    static let shared = LidSleep(
        // The self-test and snapshot runs must never run sudo or change power settings
        runner: CommandLine.arguments.contains("--selftest") || AppPaths.isSnapshot ? InertLidSleepRunner() : SystemLidSleepRunner(),
        defaults: .standard)

    nonisolated static let sudo = "/usr/bin/sudo"
    nonisolated static let pmset = "/usr/bin/pmset"
    nonisolated static let sudoersFile = "/etc/sudoers.d/deckhand"
    nonisolated static let disableArguments = ["-a", "disablesleep", "1"]
    nonisolated static let enableArguments = ["-a", "disablesleep", "0"]
    /// Choices for the battery floor, in percent. There is no "never": on battery a closed Mac must sleep at some point.
    nonisolated static let batteryFloors = [50, 30, 20, 10]
    nonisolated static let flagKey = "lidSleepDisabledByDeckhand"

    enum AdminResult: Equatable {
        case done
        case cancelled
        case failed(String)
    }

    /// The sudoers rule is installed and sudo accepts it without a password.
    @Published private(set) var helperInstalled = false
    /// What `pmset -g` reports as SleepDisabled, whoever set it.
    @Published private(set) var systemSleepDisabled = false
    /// Deckhand turned closed-lid sleep off and hasn't turned it back on yet. Saved, so it survives a crash.
    @Published private(set) var isOn: Bool
    /// The password prompt is showing or the rule is being installed or removed.
    @Published private(set) var working = false
    /// The last install or remove problem, shown in Settings.
    @Published private(set) var problem: String?

    /// Called when a low battery turned closed-lid sleep back on, with the charge, for the notice in the notch.
    var onBatteryOff: (Int) -> Void = { _ in }

    private let runner: LidSleepRunner
    private let defaults: UserDefaults

    init(runner: LidSleepRunner, defaults: UserDefaults) {
        self.runner = runner
        self.defaults = defaults
        isOn = defaults.bool(forKey: Self.flagKey)
    }

    // MARK: - State

    /// Reads whether the rule works and what pmset says. Cheap: two short commands.
    func refresh() {
        helperInstalled = checkHelper()
        systemSleepDisabled = readSleepDisabled()
    }

    private func checkHelper() -> Bool {
        // -k ignores cached credentials, so only the passwordless rule can say yes
        runner.run(Self.sudo, ["-n", "-k", "-l", Self.pmset] + Self.disableArguments).status == 0
    }

    private func readSleepDisabled() -> Bool {
        let result = runner.run(Self.pmset, ["-g"])
        return result.status == 0 && Self.sleepDisabled(pmsetOutput: result.output)
    }

    private func setFlag(_ on: Bool) {
        defaults.set(on, forKey: Self.flagKey)
        isOn = on
    }

    // MARK: - On and off

    /// Turns closed-lid sleep off for a Keep Awake session. Does nothing without the helper, on battery below
    /// the floor, or when something else already turned it off (that setting is left alone).
    @discardableResult
    func turnOn(battery: BatteryMonitor.State?, floor: Int) -> Bool {
        if isOn { return true }
        guard Self.allowed(battery: battery, floor: floor) else {
            Log.info("lid sleep: not turned off, battery \(battery?.percent ?? -1)%")
            return false
        }
        helperInstalled = checkHelper()
        guard helperInstalled else { return false }
        if readSleepDisabled() {
            systemSleepDisabled = true
            Log.info("lid sleep: already disabled by something else, left alone")
            return false
        }
        // Saved before the command, so a crash right after it is still cleaned up on the next launch
        setFlag(true)
        let ok = runner.run(Self.sudo, ["-n", "-k", Self.pmset] + Self.disableArguments).status == 0
        systemSleepDisabled = readSleepDisabled()
        if !ok {
            Log.info("lid sleep: disablesleep 1 failed")
            if systemSleepDisabled { turnOff() } else { setFlag(false) }
            return false
        }
        Log.info("lid sleep: off while the lid is closed")
        return true
    }

    /// Lets the Mac sleep with the lid closed again, if Deckhand was the one that stopped it.
    func turnOff() {
        guard isOn else { return }
        let ok = runner.run(Self.sudo, ["-n", "-k", Self.pmset] + Self.enableArguments).status == 0
        systemSleepDisabled = readSleepDisabled()
        if ok || !systemSleepDisabled {
            setFlag(false)
            Log.info("lid sleep: back on")
        } else {
            // The flag stays, so the next launch tries again
            Log.info("lid sleep: disablesleep 0 failed")
        }
    }

    /// On launch: a flag left by a crash or force quit means sleep may still be off. Turn it back on.
    func recoverAfterLaunch(keepAwakeActive: Bool) {
        guard Self.needsRecovery(flag: isOn, keepAwakeActive: keepAwakeActive) else { return }
        Log.info("lid sleep: left off by an earlier run, turning it back on")
        turnOff()
    }

    /// On battery below the floor the Mac has to be able to sleep again; Keep Awake itself keeps running.
    func batteryChanged(to state: BatteryMonitor.State?, floor: Int) {
        guard isOn, !Self.allowed(battery: state, floor: floor) else { return }
        turnOff()
        if !isOn, let state { onBatteryOff(state.percent) }
    }

    // MARK: - Helper

    /// Installs the sudoers rule. macOS asks for an administrator's password.
    func installHelper() async {
        guard !working else { return }
        problem = nil
        guard let content = Self.sudoersContent(user: NSUserName()) else {
            problem = String(localized: "This account name can't be used in a sudoers rule.")
            return
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("deckhand-sudoers-\(UUID().uuidString)")
        do {
            try Data(content.utf8).write(to: temp, options: .atomic)
        } catch {
            problem = error.localizedDescription
            return
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        await runAdmin(Self.installCommand(tempPath: temp.path),
                       prompt: String(localized: "Deckhand wants to let Keep Awake turn sleep off while the lid is closed."))
    }

    /// Removes the sudoers rule, turning closed-lid sleep back on first.
    func removeHelper() async {
        guard !working else { return }
        problem = nil
        turnOff()
        await runAdmin(Self.removeCommand,
                       prompt: String(localized: "Deckhand wants to remove its Keep Awake rule for the closed lid."))
    }

    private func runAdmin(_ command: String, prompt: String) async {
        working = true
        let result = await runner.runAsAdmin(command, prompt: prompt)
        working = false
        switch result {
        case .done, .cancelled: break
        case .failed(let message):
            problem = message
            Log.info("lid sleep: admin command failed: \(message)")
        }
        refresh()
    }

    // MARK: - Rules, checked by the self-test

    /// The sudoers file: this user may run exactly the two pmset commands as root without a password.
    /// `nil` for a name that isn't a plain account name, so nothing broader can ever be written.
    nonisolated static func sudoersContent(user: String) -> String? {
        guard isPlainUserName(user) else { return nil }
        let commands = [disableArguments, enableArguments].map { ([pmset] + $0).joined(separator: " ") }
        return """
        # Installed by Deckhand for Keep Awake with the lid closed.
        # Lets \(user) turn closed-lid sleep off and back on, nothing else.
        # Remove it in Deckhand → Settings → Keep Awake, or delete \(sudoersFile).
        \(user) ALL=(root) NOPASSWD: \(commands.joined(separator: ", "))

        """
    }

    /// Letters, digits, `_`, `.` and `-`, starting with a letter or `_`; never a sudoers keyword like ALL.
    nonisolated static func isPlainUserName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 64, name != "ALL" else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        let letters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_")
        return letters.contains(first) && name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Copies the file into place as root:wheel 0440 under a name sudo ignores (it has a dot), checks it with
    /// visudo, and only then gives it the name sudo reads. A file that fails the check is deleted.
    nonisolated static func installCommand(tempPath: String) -> String {
        let staged = "/etc/sudoers.d/.deckhand.new"
        return [
            "/bin/mkdir -p /etc/sudoers.d",
            "/usr/bin/install -o root -g wheel -m 0440 \(shellQuoted(tempPath)) \(staged)",
            "{ /usr/sbin/visudo -cf \(staged) >/dev/null || { /bin/rm -f \(staged); exit 1; }; }",
            "/bin/mv -f \(staged) \(sudoersFile)",
        ].joined(separator: " && ")
    }

    nonisolated static let removeCommand = "/bin/rm -f \(sudoersFile)"

    nonisolated static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// An AppleScript string literal.
    nonisolated static func appleScriptQuoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `SleepDisabled 1` in `pmset -g`.
    nonisolated static func sleepDisabled(pmsetOutput: String) -> Bool {
        for line in pmsetOutput.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count >= 2, parts[0] == "SleepDisabled" { return parts[1] == "1" }
        }
        return false
    }

    /// A flag from an earlier run with no Keep Awake session to justify it.
    nonisolated static func needsRecovery(flag: Bool, keepAwakeActive: Bool) -> Bool {
        flag && !keepAwakeActive
    }

    /// On power always; on battery only at or above the floor. Unlike Keep Awake's own floor this applies
    /// to a session started below it too: a closed Mac in a bag must not drain to zero.
    nonisolated static func allowed(battery: BatteryMonitor.State?, floor: Int) -> Bool {
        guard let battery, !battery.onAC else { return true }
        return battery.percent >= floor
    }
}

/// The real commands.
@MainActor
final class SystemLidSleepRunner: LidSleepRunner {
    func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        guard let out = try? ProcessRunner.runSync(executable, arguments, timeout: 5) else { return (-1, "") }
        return (out.status, out.stdout)
    }

    func runAsAdmin(_ shellCommand: String, prompt: String) async -> LidSleep.AdminResult {
        let source = "do shell script \(LidSleep.appleScriptQuoted(shellCommand)) with prompt \(LidSleep.appleScriptQuoted(prompt)) with administrator privileges"
        switch await AppleScriptRunner.shared.run(source, timeout: 600) {
        case .success: return .done
        case .failure(let failure) where failure.code == -128: return .cancelled
        case .failure(let failure): return .failed(failure.message)
        }
    }
}

/// For the self-test and snapshots: runs nothing, so the helper always reads as not installed.
@MainActor
final class InertLidSleepRunner: LidSleepRunner {
    func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) { (1, "") }
    func runAsAdmin(_ shellCommand: String, prompt: String) async -> LidSleep.AdminResult { .cancelled }
}
