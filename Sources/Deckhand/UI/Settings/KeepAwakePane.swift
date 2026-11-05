import SwiftUI

/// Keep Awake, the timer and battery notices. Owned by the panel and utilities workstream.
struct KeepAwakePane: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        SettingsPane(.keepAwake) {
            Section {
                Picker("Default length", selection: $settings.keepAwakeDefaultDuration) {
                    ForEach(Array(KeepAwake.durations.enumerated()), id: \.offset) { _, d in
                        Text(KeepAwake.title(for: d)).tag(d)
                    }
                }
                Toggle("Let the display sleep", isOn: $settings.keepAwakeAllowDisplaySleep)
            } header: {
                Text("Keep Awake")
            } footer: {
                Text("Stops the Mac from sleeping when idle. With the lid closed it still sleeps unless an external display, keyboard and power are connected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
