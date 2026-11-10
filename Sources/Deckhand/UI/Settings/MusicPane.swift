import SwiftUI
import AppKit
import ApplicationServices

/// Now playing: the master switch, the sources with their permission status, and how the track shows.
/// Owned by the media workstream. The badge switch itself lives in Closed Notch.
struct MusicPane: View {
    @ObservedObject private var media = MediaSettings.shared
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var monitor = NowPlayingMonitor.shared
    @StateObject private var status = MusicSourceStatus()

    var body: some View {
        SettingsPane(.music) {
            Section {
                SettingsToggleRow(String(localized: "Find out what's playing"), isOn: $media.enabled)
                SettingsLinkRow(String(localized: "Badge at the notch"),
                                value: settings.showPlayingInNotch ? String(localized: "On") : String(localized: "Off"),
                                to: .section(.closedNotch))
                    .disabled(!media.enabled)
                FeedRow(feed: monitor.feed)
            } footer: {
                SettingsFooter("Shows the track in the Music tab and at the notch. When this is off, Deckhand checks nothing.")
            }

            Section {
                ForEach(MediaApp.allCases) { app in
                    SourceRow(app: app, status: status, isOn: Binding(
                        get: { media.isOn(app) },
                        set: { media.set(app, on: $0) }
                    ))
                }
            } header: {
                Text("Sources")
            } footer: {
                SettingsFooter("Apple Music and Spotify announce their tracks themselves. Browsers are asked for the tab title only while they play sound. macOS asks once per app for permission (Automation).")
            }
            .disabled(!media.enabled)

            Section {
                Picker("Hide after pause", selection: $media.hideDelay) {
                    ForEach(MediaSettings.hideDelays, id: \.self) { seconds in
                        Text(verbatim: Self.duration(seconds)).tag(seconds)
                    }
                }
                SettingsToggleRow(String(localized: "Album artwork"),
                                  detail: String(localized: "From the player, when it provides one"),
                                  isOn: $media.showArtwork)
            } header: {
                Text(String(localized: "music.display", defaultValue: "Display"))
            }
            .disabled(!media.enabled)

            Section {
                SettingsRow(String(localized: "Media keys"), detail: String(localized: "Accessibility")) {
                    PermissionBadge(state: status.accessibility ? .allowed : .notAsked)
                    if !status.accessibility {
                        Button("Allow…") { MediaController.requestAccessibility(); status.refresh(after: 1) }
                            .buttonStyle(.settings(.prominent))
                    }
                }
            } header: {
                Text("Controls")
            } footer: {
                SettingsFooter("Apple Music and Spotify are controlled directly. Browsers and Yandex Music get the system media keys, which need Accessibility.")
            }
        }
        .onSettingsActivation { status.refresh() }
    }

    /// "2 seconds", «2 секунды»: plural forms from the system, in the app's language.
    static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 60 ? [.minute] : [.second]
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        formatter.calendar = calendar
        return formatter.string(from: seconds) ?? "\(Int(seconds))"
    }
}

/// Which source the track comes from right now: the system Now Playing, or the apps asked directly.
private struct FeedRow: View {
    let feed: NowPlayingRules.Feed

    var body: some View {
        SettingsRow(String(localized: "Track source"), detail: detail) {
            StatusChip(label, kind: feed == .system ? .good : .neutral)
        }
    }

    private var label: String {
        switch feed {
        case .system: return String(localized: "System Now Playing")
        case .fallback: return String(localized: "Fallback")
        case .off: return String(localized: "Not running")
        }
    }

    private var detail: String {
        switch feed {
        case .system: return String(localized: "Every app that reports to macOS Now Playing")
        case .fallback: return String(localized: "Deckhand asks the apps below directly")
        case .off: return String(localized: "Starts while the badge is on or the Music tab is open")
        }
    }
}

/// One source: its icon, what it needs, its permission, a button to fix it, and the switch.
private struct SourceRow: View {
    let app: MediaApp
    @ObservedObject var status: MusicSourceStatus
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(app.displayName, detail: String(localized: need), icon: icon) {
            if isOn, app.kind != .other {
                PermissionBadge(state: state)
                action
            }
            Toggle(app.displayName, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var icon: SettingsRowIcon {
        if app == .other { return .symbol("square.grid.2x2", .indigo) }
        return AppIcon.icon(for: app).map(SettingsRowIcon.image) ?? .symbol("music.note", .pink)
    }

    private var need: String.LocalizationValue {
        switch app.kind {
        case .player: return "Controls and artwork need Automation"
        case .yandexApp: return "Reads the window title with Accessibility"
        case .browser: return "Tab titles while sound plays, with Automation"
        case .other: return "Podcasts, VLC, IINA and more, through macOS Now Playing"
        }
    }

    private var state: PermissionBadge.State {
        guard status.installed.contains(app) else { return .notInstalled }
        if app.kind == .yandexApp { return status.accessibility ? .allowed : .notAsked }
        switch status.automation[app] {
        case .allowed: return .allowed
        case .denied: return .denied
        case .notAsked: return .notAsked
        case .appNotRunning, .unknown, nil: return .notRunning
        }
    }

    @ViewBuilder private var action: some View {
        switch state {
        case .notAsked:
            Button("Allow…") {
                if app.kind == .yandexApp {
                    MediaController.requestAccessibility()
                    status.refresh(after: 1)
                } else {
                    status.ask(app)
                }
            }
            .buttonStyle(.settings(.prominent))
        case .denied:
            Button("Open System Settings") { MediaController.openPrivacySettings("Privacy_Automation") }
                .buttonStyle(.settings)
        case .allowed, .notRunning, .notInstalled:
            EmptyView()
        }
    }
}

/// A permission as a status chip, the way the Privacy pane shows them.
private struct PermissionBadge: View {
    enum State { case allowed, notAsked, denied, notRunning, notInstalled }
    let state: State

    var body: some View {
        StatusChip(label, kind: kind)
            .help(state == .notRunning ? Text("Checked when the app is open") : Text(verbatim: ""))
    }

    private var label: String {
        switch state {
        case .allowed: return String(localized: "Allowed")
        case .notAsked: return String(localized: "Not allowed yet")
        case .denied: return String(localized: "Turned off")
        case .notRunning: return String(localized: "Not running")
        case .notInstalled: return String(localized: "Not installed")
        }
    }

    private var kind: StatusChip.Kind {
        switch state {
        case .allowed: return .good
        case .notAsked: return .attention
        case .denied: return .error
        case .notRunning, .notInstalled: return .neutral
        }
    }
}

/// Permission status of every source, read without ever showing a prompt.
@MainActor
final class MusicSourceStatus: ObservableObject {
    @Published private(set) var automation: [MediaApp: AutomationPermission] = [:]
    @Published private(set) var installed: Set<MediaApp> = []
    @Published private(set) var accessibility = AXIsProcessTrusted()

    func refresh(after delay: TimeInterval = 0) {
        Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            accessibility = AXIsProcessTrusted()
            installed = Set(MediaApp.allCases.filter { Self.isInstalled($0) })
            let apps = MediaApp.allCases.filter(\.usesAppleEvents)
            let result = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: apps.map { ($0, AutomationPermission.status(bundleId: $0.bundleID)) })
            }.value
            if automation != result { automation = result }
        }
    }

    /// Shows the macOS Automation prompt for one app, then reads the answer. Only from a click.
    func ask(_ app: MediaApp) {
        let id = app.bundleID
        Task {
            _ = await Task.detached { AutomationPermission.status(bundleId: id, ask: true) }.value
            NowPlayingMonitor.shared.refresh()
            refresh()
        }
    }

    private static func isInstalled(_ app: MediaApp) -> Bool {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) != nil { return true }
        guard app == .yandexMusic else { return false }
        // The Yandex Music app has shipped under more than one identifier
        return ["/Applications/Яндекс Музыка.app", "/Applications/Yandex Music.app"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }
}
