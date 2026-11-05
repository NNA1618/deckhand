import SwiftUI
import AppKit
import ApplicationServices

/// Now playing: the master switch, the sources with their permission status, and how the track shows.
/// Owned by the media workstream. The badge switch itself lives in Closed Notch.
struct MusicPane: View {
    @ObservedObject private var media = MediaSettings.shared
    @ObservedObject private var settings = Settings.shared
    @StateObject private var status = MusicSourceStatus()

    var body: some View {
        SettingsPane(.music) {
            Section {
                Toggle("Find out what's playing", isOn: $media.enabled)
                LabeledContent("Badge at the notch") {
                    HStack(spacing: 8) {
                        Text(settings.showPlayingInNotch ? LocalizedStringKey("On") : LocalizedStringKey("Off")).foregroundStyle(.secondary)
                        Button("Closed Notch…") { SettingsRouter.shared.section = .closedNotch }
                    }
                }
                .disabled(!media.enabled)
            } footer: {
                Text("Shows the track in the Music tab and at the notch. When this is off, Deckhand checks nothing.")
                    .font(.caption).foregroundStyle(.secondary)
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
                Text("Apple Music and Spotify announce their tracks themselves. Browsers are asked for the tab title only while they play sound. macOS asks once per app for permission (Automation).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!media.enabled)

            Section {
                Picker("Hide after pause", selection: $media.hideDelay) {
                    ForEach(MediaSettings.hideDelays, id: \.self) { seconds in
                        Text(verbatim: Self.duration(seconds)).tag(seconds)
                    }
                }
                Toggle(isOn: $media.showArtwork) {
                    Text("Album artwork")
                    Text("From Apple Music and Spotify, when they allow it")
                }
            } header: {
                Text("Display")
            }
            .disabled(!media.enabled)

            Section {
                LabeledContent {
                    PermissionBadge(state: status.accessibility ? .allowed : .notAsked)
                    if !status.accessibility {
                        Button("Allow…") { MediaController.requestAccessibility(); status.refresh(after: 1) }
                    }
                } label: {
                    Text("Media keys")
                    Text("Accessibility")
                }
            } header: {
                Text("Controls")
            } footer: {
                Text("Apple Music and Spotify are controlled directly. Browsers and Yandex Music get the system media keys, which need Accessibility.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { status.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in status.refresh() }
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

/// One source: its icon, what it needs, its permission, a button to fix it, and the switch.
private struct SourceRow: View {
    let app: MediaApp
    @ObservedObject var status: MusicSourceStatus
    @Binding var isOn: Bool

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if isOn { action }
                Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
            }
        } label: {
            HStack(spacing: 8) {
                AppIcon(app: app).frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(verbatim: app.displayName)
                        if isOn { PermissionBadge(state: state) }
                    }
                    Text(need).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var need: LocalizedStringKey {
        switch app.kind {
        case .player: return "Controls and artwork need Automation"
        case .yandexApp: return "Reads the window title with Accessibility"
        case .browser: return "Tab titles while sound plays, with Automation"
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
        case .denied:
            Button("Open System Settings") { MediaController.openPrivacySettings("Privacy_Automation") }
        case .allowed, .notRunning, .notInstalled:
            EmptyView()
        }
    }
}

/// A colored dot and a word for a permission.
private struct PermissionBadge: View {
    enum State { case allowed, notAsked, denied, notRunning, notInstalled }
    let state: State

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private var label: LocalizedStringKey {
        switch state {
        case .allowed: return "Allowed"
        case .notAsked: return "Not allowed yet"
        case .denied: return "Turned off"
        case .notRunning: return "Checked when the app is open"
        case .notInstalled: return "Not installed"
        }
    }

    private var color: Color {
        switch state {
        case .allowed: return .green
        case .notAsked: return .orange
        case .denied: return .red
        case .notRunning, .notInstalled: return .gray
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
