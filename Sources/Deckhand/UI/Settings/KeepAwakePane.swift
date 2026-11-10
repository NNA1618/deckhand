import SwiftUI

/// Keep Awake and the timer. Owned by the panel and utilities workstream.
/// Notices, the badge and sounds live in Closed Notch; the rows at the bottom link there.
struct KeepAwakePane: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var utility = UtilitySettings.shared
    @ObservedObject private var lid = KeepAwake.shared.lid
    /// The battery floor only makes sense on a Mac with a battery.
    private let hasBattery = BatteryMonitor.read() != nil

    var body: some View {
        SettingsPane(.keepAwake) {
            Section {
                ShortcutRow(action: .keepAwake, title: String(localized: "Shortcut"))
                Picker("Default length", selection: $settings.keepAwakeDefaultDuration) {
                    ForEach(Array(KeepAwake.durations.enumerated()), id: \.offset) { _, d in
                        Text(KeepAwake.title(for: d)).tag(d)
                    }
                }
                SettingsToggleRow(String(localized: "Let the display turn off"), isOn: $settings.keepAwakeAllowDisplaySleep)
                if hasBattery {
                    Picker("Turn off below", selection: $utility.keepAwakeBatteryFloor) {
                        ForEach(UtilitySettings.batteryFloors, id: \.self) { floor in
                            if floor == 0 {
                                Text("Never").tag(floor)
                            } else {
                                Text(Double(floor) / 100, format: .percent).tag(floor)
                            }
                        }
                    }
                }
            } header: {
                Text("Keep Awake")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    SettingsFooter("The default length is used by the shortcut and the menu bar.")
                    SettingsFooter("Stops the Mac from sleeping when idle. With the lid closed it still sleeps, unless the setting below is on or an external display, keyboard and power are connected.")
                }
            }

            lidSection

            Section {
                SettingsRow(String(localized: "Presets")) {
                    HStack(spacing: 6) {
                        ForEach(0..<utility.timerPresets.count, id: \.self) { i in
                            TextField("", value: presetBinding(i), format: .number)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 44)
                                .accessibilityLabel(Text("Preset \(i + 1)"))
                        }
                        Text("min").foregroundStyle(Theme.fgDim).fixedSize()
                    }
                }
                SettingsToggleRow(String(localized: "Alert until I dismiss it"),
                                  detail: String(localized: "Keeps “Time is up” at the notch and repeats the sound."),
                                  isOn: $utility.timerAlertUntilDismissed)
            } header: {
                Text("Timer")
            }

            Section {
                SettingsLinkRow(String(localized: "Sound, badge and notices"), to: .section(.closedNotch))
            } footer: {
                SettingsFooter("The timer sound, the badge at the notch, and the Keep Awake and battery notices.")
            }
        }
    }

    /// "Also when the lid is closed" and the one-time helper it needs.
    private var lidSection: some View {
        Section {
            SettingsRow(String(localized: "Closed-lid helper"),
                        detail: lid.helperInstalled ? String(localized: "Installed. Lets you run only the two pmset commands.")
                                                    : String(localized: "Asks for an administrator password once.")) {
                HStack(spacing: 8) {
                    if lid.working { ProgressView().controlSize(.small) }
                    if lid.helperInstalled {
                        ConfirmedButton(title: String(localized: "Remove…"),
                                        alertTitle: String(localized: "Remove the closed-lid helper?"),
                                        message: String(localized: "macOS asks for an administrator password. The Mac then sleeps with the lid closed again."),
                                        confirmTitle: String(localized: "Remove")) {
                            Task { await lid.removeHelper() }
                        }
                        .disabled(lid.working)
                    } else {
                        Button(String(localized: "Install…")) { Task { await lid.installHelper() } }
                            .buttonStyle(.settings(.prominent))
                            .disabled(lid.working)
                    }
                }
            }
            if let problem = lid.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsToggleRow(String(localized: "Also when the lid is closed"),
                              detail: String(localized: "Turns sleep off only while Keep Awake is on."),
                              isOn: $utility.keepAwakeLidClosed)
                .disabled(!lid.helperInstalled)
            if hasBattery {
                Picker("On battery, sleep again below", selection: $utility.keepAwakeLidBatteryFloor) {
                    ForEach(LidSleep.batteryFloors, id: \.self) { floor in
                        Text(Double(floor) / 100, format: .percent).tag(floor)
                    }
                }
                .disabled(!lid.helperInstalled || !utility.keepAwakeLidClosed)
            }
            SettingsRow(String(localized: "Status")) { lidStatus }
        } header: {
            Text("With the Lid Closed")
        } footer: {
            SettingsFooter("The helper is a rule in /etc/sudoers.d/deckhand that lets your account run “pmset -a disablesleep 1” and “pmset -a disablesleep 0” without a password, nothing else. Sleep comes back when Keep Awake ends, when Deckhand quits, on shutdown, and on the next launch after a crash.")
        }
        .onSettingsActivation { lid.refresh() }
    }

    @ViewBuilder private var lidStatus: some View {
        if lid.isOn {
            StatusChip(String(localized: "Lid closed: on"), kind: .good)
        } else if lid.systemSleepDisabled {
            StatusChip(String(localized: "Sleep is off, not by Deckhand"), kind: .attention)
        } else {
            StatusChip(String(localized: "Lid closed: off"), kind: .neutral)
        }
    }

    /// One preset field. Values outside 1…600 minutes fall back to the default for that slot.
    private func presetBinding(_ i: Int) -> Binding<Int> {
        Binding(
            get: { utility.timerPresets[i] },
            set: { value in
                var presets = utility.timerPresets
                presets[i] = value
                utility.timerPresets = UtilitySettings.sanitized(presets: presets)
            }
        )
    }
}
