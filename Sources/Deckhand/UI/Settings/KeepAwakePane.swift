import SwiftUI

/// Keep Awake and the timer. Owned by the panel and utilities workstream.
/// Notices, the badge and sounds live in Closed Notch; the rows at the bottom link there.
struct KeepAwakePane: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var utility = UtilitySettings.shared
    /// The battery floor only makes sense on a Mac with a battery.
    private let hasBattery = BatteryMonitor.read() != nil

    var body: some View {
        SettingsPane(.keepAwake) {
            Section {
                LabeledContent("Shortcut") { ShortcutRecorder(action: .keepAwake) }
                Picker("Default length", selection: $settings.keepAwakeDefaultDuration) {
                    ForEach(Array(KeepAwake.durations.enumerated()), id: \.offset) { _, d in
                        Text(KeepAwake.title(for: d)).tag(d)
                    }
                }
                Toggle("Let the display turn off", isOn: $settings.keepAwakeAllowDisplaySleep)
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
                    Text("The default length is used by the shortcut and the menu bar.")
                    Text("Stops the Mac from sleeping when idle. With the lid closed it still sleeps unless an external display, keyboard and power are connected.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Presets") {
                    HStack(spacing: 6) {
                        ForEach(0..<utility.timerPresets.count, id: \.self) { i in
                            TextField("", value: presetBinding(i), format: .number)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 44)
                                .accessibilityLabel(Text("Preset \(i + 1)"))
                        }
                        Text("min").foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $utility.timerAlertUntilDismissed) {
                    Text("Alert until I dismiss it")
                    Text("Keeps “Time is up” at the notch and repeats the sound.")
                }
            } header: {
                Text("Timer")
            }

            Section {
                Button {
                    SettingsRouter.shared.section = .closedNotch
                } label: {
                    HStack {
                        Text("Sound, badge and notices").foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } footer: {
                Text("The timer sound, the badge at the notch, and the Keep Awake and battery notices.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
