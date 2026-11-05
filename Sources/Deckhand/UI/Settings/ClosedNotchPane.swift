import SwiftUI

/// What shows around the notch while the panel is closed: badges, notices and sounds.
/// Owned by the notch workstream.
struct ClosedNotchPane: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        SettingsPane(.closedNotch) {
            Section {
                Toggle("Show the playing track around the notch", isOn: $settings.showPlayingInNotch)
                    .onChange(of: settings.showPlayingInNotch) { _, on in
                        if on { NowPlayingMonitor.shared.start() }
                    }
                Toggle("Show working sessions around the notch", isOn: $settings.claudeInNotch)
                Toggle("Show a cup around the notch while awake", isOn: $settings.keepAwakeIndicator)
            }
            Section {
                Toggle("Show a notice in the notch after a screenshot", isOn: $settings.screenshotToast)
                Toggle("Show charging and low battery in the notch", isOn: $settings.batteryNotices)
                Toggle("Show a notice when a task is done", isOn: $settings.claudeDoneNotice)
                Toggle("Play a sound when Claude needs you", isOn: $settings.claudeSound)
            }
        }
    }
}
