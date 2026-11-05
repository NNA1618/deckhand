import SwiftUI
import AppKit

/// What shows around the notch while the panel is closed: badges, notices and sounds.
/// Owned by the notch workstream. Now-playing sources live in the Music pane.
struct ClosedNotchPane: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var notch = NotchSettings.shared
    @ObservedObject private var claude = ClaudeCodeMonitor.shared

    private static let durations: [Double] = [2, 4, 6]
    private static let hasBattery = BatteryMonitor.read() != nil

    var body: some View {
        SettingsPane(.closedNotch) {
            Section {
                row("Claude Code", "While a session works or waits for you", isOn: $settings.claudeInNotch)
                    .disabled(!claude.hooksInstalled)
                if !claude.hooksInstalled {
                    HStack {
                        Text("Claude Code isn't connected.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Connect in Claude") { SettingsRouter.shared.section = .claude }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                row("Timer", "Time left", isOn: $settings.badgeTimer)
                row("Music", "Track name while music plays", isOn: $settings.showPlayingInNotch)
                    .onChange(of: settings.showPlayingInNotch) { _, on in
                        if on { NowPlayingMonitor.shared.start() }
                    }
                row("Keep Awake", "A cup and the time left", isOn: $settings.keepAwakeIndicator)
                Toggle("Hide in full screen", isOn: $settings.hideBadgesInFullScreen)
                Toggle("Open the panel when pointing at a badge", isOn: $notch.badgeHoverOpens)
            } header: {
                Text("Badges")
            } footer: {
                Text("One badge shows at a time, in this order. Badges sit over menu-bar items, so pointing at them opens nothing unless you turn that on.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Screenshot copied", isOn: $settings.screenshotToast)
                row("Text from screen", "Copied or not found", isOn: $settings.noticeTextCapture)
                Toggle("Color copied", isOn: $settings.noticeColor)
                Toggle("Keep Awake on or off", isOn: $settings.noticeKeepAwake)
                Toggle("Timer finished", isOn: $settings.noticeTimer)
                if Self.hasBattery {
                    Toggle("Charger connected", isOn: $settings.noticeCharging)
                    row("Low battery", "At 20% and 10%", isOn: $settings.noticeLowBattery)
                }
                Toggle("Claude finished a task", isOn: $settings.claudeDoneNotice)
                Toggle("Claude needs you", isOn: $settings.noticeClaudeNeedsYou)
                Picker("Duration", selection: $settings.toastDuration) {
                    ForEach(Self.durations, id: \.self) { Text(verbatim: SettingsFormat.seconds($0, wide: true)).tag($0) }
                }
            } header: {
                Text("Notices")
            } footer: {
                Text("Notices that need you — Claude is waiting, the timer is up — stay until you point at them or open the panel.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                SoundPicker(title: "Claude needs you", selection: $settings.soundClaudeNeedsYou)
                SoundPicker(title: "Timer finished", selection: $settings.soundTimer)
            } header: {
                Text("Sounds")
            }
        }
    }

    private func row(_ title: LocalizedStringKey, _ caption: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A system sound menu with a play button. An empty name means no sound.
private struct SoundPicker: View {
    let title: LocalizedStringKey
    @Binding var selection: String

    /// The alert sounds that come with macOS, read once.
    static let names: [String] = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        return files.filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
    }()

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Picker(title, selection: $selection) {
                    Text("None").tag("")
                    Divider()
                    ForEach(Self.names, id: \.self) { Text(verbatim: $0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Button {
                    NSSound(named: NSSound.Name(selection))?.play()
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .disabled(selection.isEmpty)
                .help(Text("Play"))
                .accessibilityLabel(Text("Play"))
            }
        } label: {
            Text(title)
        }
    }
}
