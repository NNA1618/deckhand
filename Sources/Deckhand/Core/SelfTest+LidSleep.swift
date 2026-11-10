import Foundation

/// Stands in for sudo and pmset: remembers every command and keeps a pretend SleepDisabled.
@MainActor
private final class FakeLidSleepRunner: LidSleepRunner {
    var helperInstalled = true
    var sleepDisabled = false
    /// The next `pmset -a disablesleep 0` fails without changing anything.
    var failNextEnable = false
    private(set) var commands: [String] = []

    func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let line = ([executable] + arguments).joined(separator: " ")
        commands.append(line)
        if executable == LidSleep.pmset, arguments == ["-g"] {
            return (0, "System-wide power settings:\n SleepDisabled\t\t\(sleepDisabled ? 1 : 0)\nCurrently in use:\n sleep 1\n")
        }
        guard executable == LidSleep.sudo, helperInstalled else { return (1, "") }
        if arguments.contains("-l") { return (0, "") }
        if arguments.suffix(3) == LidSleep.disableArguments[...] { sleepDisabled = true; return (0, "") }
        if arguments.suffix(3) == LidSleep.enableArguments[...] {
            if failNextEnable { failNextEnable = false; return (1, "") }
            sleepDisabled = false
            return (0, "")
        }
        return (1, "")
    }

    func runAsAdmin(_ shellCommand: String, prompt: String) async -> LidSleep.AdminResult { .cancelled }

    func count(_ arguments: [String]) -> Int {
        let line = ([LidSleep.sudo, "-n", "-k", LidSleep.pmset] + arguments).joined(separator: " ")
        return commands.filter { $0 == line }.count
    }

    var disables: Int { count(LidSleep.disableArguments) }
    var enables: Int { count(LidSleep.enableArguments) }
}

extension SelfTest {
    /// Keep Awake with the lid closed. Nothing here runs sudo or pmset: a fake runner answers instead.
    static func lidSleep(_ check: Check) {
        lidSudoers(check)
        lidRules(check)
        lidRecovery(check)
        lidBattery(check)
        lidKeepAwake(check)
    }

    private static func lidSudoers(_ check: Check) {
        let content = LidSleep.sudoersContent(user: "alice") ?? ""
        let rules = content.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        check(rules == ["alice ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"],
              "lid sleep: sudoers holds one rule for the user (\(rules))")
        let commands = rules.first?.components(separatedBy: "NOPASSWD:").last?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        check(commands == ["/usr/bin/pmset -a disablesleep 1", "/usr/bin/pmset -a disablesleep 0"],
              "lid sleep: sudoers allows exactly the two pmset commands")
        check(!(commands.joined().contains("ALL")) && !content.contains("*") && !content.contains("%"),
              "lid sleep: sudoers has no wildcard, ALL command or group")
        check(content.hasSuffix("\n"), "lid sleep: sudoers ends with a newline, as visudo wants")
        check(LidSleep.sudoersContent(user: "j.doe_2-x") != nil, "lid sleep: plain account names are accepted")
        let bad = ["", "ALL", "a b", "%admin", "bob,root", "x\nALL ALL=(ALL) ALL", "-x", "a:b", "a=b", "#0", "ünï",
                   String(repeating: "a", count: 65)]
        check(bad.allSatisfy { LidSleep.sudoersContent(user: $0) == nil }, "lid sleep: odd account names are refused")

        let install = LidSleep.installCommand(tempPath: "/tmp/it's here")
        let check1 = install.range(of: "/usr/sbin/visudo -cf"), move = install.range(of: "/bin/mv -f")
        check(install.contains("/usr/bin/install -o root -g wheel -m 0440 '/tmp/it'\\''s here' /etc/sudoers.d/.deckhand.new"),
              "lid sleep: install copies as root:wheel 0440 under a name sudo ignores")
        check(check1 != nil && move != nil && check1!.lowerBound < move!.lowerBound
              && install.hasSuffix("/bin/mv -f /etc/sudoers.d/.deckhand.new /etc/sudoers.d/deckhand"),
              "lid sleep: install checks with visudo before the file goes live")
        check(install.contains("|| { /bin/rm -f /etc/sudoers.d/.deckhand.new; exit 1; }"), "lid sleep: a file visudo rejects is deleted")
        check(LidSleep.removeCommand == "/bin/rm -f /etc/sudoers.d/deckhand", "lid sleep: remove deletes only Deckhand's file")
        check(LidSleep.appleScriptQuoted(#"a "b" \c"#) == #""a \"b\" \\c""#, "lid sleep: AppleScript strings are escaped")
    }

    private static func lidRules(_ check: Check) {
        check(LidSleep.sleepDisabled(pmsetOutput: "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep 1")
              && !LidSleep.sleepDisabled(pmsetOutput: " SleepDisabled\t\t0\n")
              && !LidSleep.sleepDisabled(pmsetOutput: "Currently in use:\n sleep 1\n"),
              "lid sleep: SleepDisabled is read from pmset -g")
        check(LidSleep.needsRecovery(flag: true, keepAwakeActive: false)
              && !LidSleep.needsRecovery(flag: true, keepAwakeActive: true)
              && !LidSleep.needsRecovery(flag: false, keepAwakeActive: false),
              "lid sleep: a flag without a session needs recovery")
        typealias S = BatteryMonitor.State
        check(LidSleep.allowed(battery: nil, floor: 20)
              && LidSleep.allowed(battery: S(percent: 5, onAC: true, charging: true), floor: 20)
              && LidSleep.allowed(battery: S(percent: 20, onAC: false, charging: false), floor: 20)
              && !LidSleep.allowed(battery: S(percent: 19, onAC: false, charging: false), floor: 20),
              "lid sleep: on battery only at or above the floor")
    }

    private static func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "com.nna1618.deckhand.selftest.lidsleep"
        guard let d = UserDefaults(suiteName: name) else { return }
        d.removePersistentDomain(forName: name)
        body(d)
        d.removePersistentDomain(forName: name)
    }

    private static func lidRecovery(_ check: Check) {
        withDefaults { d in
            let fake = FakeLidSleepRunner()
            fake.sleepDisabled = true
            d.set(true, forKey: LidSleep.flagKey)
            let lid = LidSleep(runner: fake, defaults: d)
            check(lid.isOn, "lid sleep: the flag survives a restart")
            lid.recoverAfterLaunch(keepAwakeActive: true)
            check(fake.enables == 0, "lid sleep: no recovery while a session runs")
            lid.recoverAfterLaunch(keepAwakeActive: false)
            check(fake.enables == 1 && !fake.sleepDisabled && !lid.isOn && !d.bool(forKey: LidSleep.flagKey),
                  "lid sleep: a launch after a crash turns sleep back on and clears the flag")
            lid.recoverAfterLaunch(keepAwakeActive: false)
            check(fake.enables == 1, "lid sleep: nothing to recover without the flag")
        }
        withDefaults { d in
            let fake = FakeLidSleepRunner()
            let lid = LidSleep(runner: fake, defaults: d)
            check(lid.turnOn(battery: nil, floor: 20) && d.bool(forKey: LidSleep.flagKey) && fake.sleepDisabled,
                  "lid sleep: the flag is saved when Deckhand turns sleep off")
            fake.failNextEnable = true
            lid.turnOff()
            check(lid.isOn && d.bool(forKey: LidSleep.flagKey), "lid sleep: the flag stays when turning sleep back on failed")
            LidSleep(runner: fake, defaults: d).recoverAfterLaunch(keepAwakeActive: false)
            check(!fake.sleepDisabled && !d.bool(forKey: LidSleep.flagKey), "lid sleep: the next launch tries again")
        }
        withDefaults { d in
            let fake = FakeLidSleepRunner()
            fake.sleepDisabled = true
            let lid = LidSleep(runner: fake, defaults: d)
            check(!lid.turnOn(battery: nil, floor: 20) && !lid.isOn && fake.disables == 0, "lid sleep: sleep turned off by someone else is left alone")
            lid.turnOff()
            check(fake.enables == 0 && fake.sleepDisabled, "lid sleep: and never turned on by Deckhand")
        }
        withDefaults { d in
            let fake = FakeLidSleepRunner()
            fake.helperInstalled = false
            let lid = LidSleep(runner: fake, defaults: d)
            check(!lid.turnOn(battery: nil, floor: 20) && !lid.isOn && !d.bool(forKey: LidSleep.flagKey) && fake.disables == 0,
                  "lid sleep: nothing happens without the helper")
        }
    }

    private static func lidBattery(_ check: Check) {
        typealias S = BatteryMonitor.State
        withDefaults { d in
            let fake = FakeLidSleepRunner()
            let lid = LidSleep(runner: fake, defaults: d)
            var told: Int?
            lid.onBatteryOff = { told = $0 }
            check(!lid.turnOn(battery: S(percent: 15, onAC: false, charging: false), floor: 20) && fake.disables == 0,
                  "lid sleep: not turned off on battery below the floor")
            check(lid.turnOn(battery: S(percent: 15, onAC: true, charging: true), floor: 20), "lid sleep: low but on power is fine")
            lid.batteryChanged(to: S(percent: 21, onAC: false, charging: false), floor: 20)
            check(lid.isOn && told == nil, "lid sleep: unplugged above the floor keeps going")
            lid.batteryChanged(to: S(percent: 19, onAC: false, charging: false), floor: 20)
            check(!lid.isOn && fake.enables == 1 && !fake.sleepDisabled && told == 19,
                  "lid sleep: below the floor sleep comes back and the user is told")
        }
    }

    /// Keep Awake ending in any way issues `disablesleep 0` when Deckhand turned it on.
    private static func lidKeepAwake(_ check: Check) {
        typealias S = BatteryMonitor.State
        let awake = KeepAwake.shared
        let settings = UtilitySettings.shared
        let saved = (lid: awake.lid, battery: awake.battery, on: settings.keepAwakeLidClosed,
                     floor: settings.keepAwakeLidBatteryFloor, keepFloor: settings.keepAwakeBatteryFloor)
        defer {
            awake.stop()
            awake.lid = saved.lid
            awake.battery = saved.battery
            settings.keepAwakeLidClosed = saved.on
            settings.keepAwakeLidBatteryFloor = saved.floor
            settings.keepAwakeBatteryFloor = saved.keepFloor
        }
        withDefaults { d in
            let fake = FakeLidSleepRunner()
            awake.stop()
            awake.lid = LidSleep(runner: fake, defaults: d)
            awake.battery = { S(percent: 80, onAC: true, charging: true) }
            settings.keepAwakeLidBatteryFloor = 20
            settings.keepAwakeBatteryFloor = 0

            settings.keepAwakeLidClosed = false
            awake.start(for: 3600)
            check(fake.disables == 0 && !awake.lid.isOn, "keep awake: the lid is left alone when the setting is off")
            awake.stop()

            settings.keepAwakeLidClosed = true
            awake.start(for: 3600)
            check(fake.disables == 1 && awake.lid.isOn && fake.sleepDisabled, "keep awake: starting turns closed-lid sleep off")
            awake.start(for: nil)
            check(fake.enables == 0 && awake.lid.isOn, "keep awake: a new length keeps it off without a flip")
            awake.stop()
            check(fake.enables == 1 && !awake.lid.isOn && !fake.sleepDisabled, "keep awake: turning off issues disablesleep 0")

            awake.start(for: 3600)
            settings.keepAwakeLidClosed = false
            check(fake.enables == 2 && !fake.sleepDisabled && awake.isActive, "keep awake: switching the setting off mid-session lets it sleep")
            settings.keepAwakeLidClosed = true
            check(fake.disables == 3 && awake.lid.isOn, "keep awake: switching it on mid-session applies at once")

            awake.batteryChanged(from: S(percent: 80, onAC: true, charging: true), to: S(percent: 15, onAC: false, charging: false))
            check(fake.enables == 3 && !fake.sleepDisabled && awake.isActive,
                  "keep awake: a low battery issues disablesleep 0 and keeps the session")
            awake.stop()
            check(fake.enables == 3, "keep awake: nothing to undo after the battery did it")

            settings.keepAwakeBatteryFloor = 50
            awake.start(for: 3600)
            awake.batteryChanged(from: S(percent: 51, onAC: false, charging: false), to: S(percent: 49, onAC: false, charging: false))
            check(!awake.isActive && fake.enables == 4 && !fake.sleepDisabled, "keep awake: its own battery floor ending it issues disablesleep 0")
        }
    }
}
