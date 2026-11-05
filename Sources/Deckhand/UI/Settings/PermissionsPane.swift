import SwiftUI
import AppKit
import ApplicationServices
import ServiceManagement

/// What Deckhand may use on this Mac and where its data lives. Owned by the Settings workstream.
/// Statuses are read without ever showing a macOS prompt; prompts and System Settings open only
/// from the buttons here.
struct PermissionsPane: View {
    @ObservedObject private var model = PermissionsModel.shared

    var body: some View {
        SettingsPane(.permissions) {
            Section {
                screenRecording
                accessibility
                SettingsRow(String(localized: "Files and Folders"),
                            detail: String(localized: "Watched folders in Recents"),
                            icon: .symbol("folder.fill", .blue)) {
                    Button("Open Settings…") { SystemSettingsLink.open(SystemSettingsLink.filesAndFolders) }
                        .buttonStyle(.settings)
                }
                SettingsRow(String(localized: "Login Items"),
                            detail: String(localized: "Open Deckhand when you log in"),
                            icon: .symbol("list.bullet", .gray)) {
                    loginChip
                    Button("Open Settings…") { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(.settings)
                }
            } header: {
                Text("Permissions")
            } footer: {
                SettingsFooter("Statuses refresh when you return to this window.")
            }

            Section {
                ForEach(model.automation) { app in
                    SettingsRow(app.name, detail: app.purpose, icon: app.icon.map(SettingsRowIcon.image)) {
                        Self.chip(for: app.status)
                    }
                }
                SettingsLinkRow(String(localized: "Open Automation Settings"),
                                icon: .symbol("gearshape.2.fill", .gray)) {
                    SystemSettingsLink.open(SystemSettingsLink.automation)
                }
            } header: {
                Text("Automation")
            } footer: {
                SettingsFooter("macOS asks once per app, the first time Deckhand needs it. An app that isn't running can't be checked.")
            }

            Section {
                ForEach(model.dataLocations) { location in
                    SettingsRow(location.title, detail: location.detail, icon: .symbol(location.symbol, location.color),
                                detailIsPath: true) {
                        if let size = location.size {
                            Text(size)
                                .font(Theme.label)
                                .foregroundStyle(Theme.fgDim)
                                .monospacedDigit()
                        }
                        RevealInFinderButton(url: location.url)
                    }
                }
            } header: {
                Text("Your data")
            } footer: {
                SettingsFooter("Deckhand itself never connects to the internet. Claude actions go through Claude Code or, if you chose it, the Anthropic API.")
            }
        }
        .onSettingsActivation {
            await model.refresh()
        }
    }

    // MARK: Rows

    private var screenRecording: some View {
        SettingsRow(String(localized: "Screen Recording"),
                    detail: model.screenRecordingNeedsRestart
                        ? String(localized: "If you allowed it, restart Deckhand to finish.")
                        : String(localized: "Screenshots and text from the screen"),
                    icon: .symbol("record.circle", .red)) {
            Self.chip(allowed: model.screenRecording)
            if model.screenRecordingNeedsRestart {
                // macOS doesn't say what the user chose, so both ways on stay open
                Button("Open Settings…") { SystemSettingsLink.open(SystemSettingsLink.screenRecording) }
                    .buttonStyle(.settings)
                Button("Restart Now") { AppRelauncher.relaunch(openSettings: true) }
                    .buttonStyle(.settings(.prominent))
            } else if !model.screenRecording {
                Button("Allow…") { model.requestScreenRecording() }
                    .buttonStyle(.settings(.prominent))
            }
        }
    }

    private var accessibility: some View {
        SettingsRow(String(localized: "Accessibility"),
                    detail: String(localized: "Paste into other apps, read the selected text"),
                    icon: .symbol("accessibility", .blue)) {
            Self.chip(allowed: model.accessibility)
            if !model.accessibility {
                Button("Allow…") { model.requestAccessibility() }
                    .buttonStyle(.settings(.prominent))
            }
        }
    }

    @ViewBuilder private var loginChip: some View {
        switch model.loginItem {
        case .enabled: StatusChip(String(localized: "On"), kind: .good)
        case .requiresApproval: StatusChip(String(localized: "Needs approval"), kind: .attention)
        default: StatusChip(String(localized: "Off"), kind: .neutral)
        }
    }

    // MARK: Chips

    static func chip(allowed: Bool) -> StatusChip {
        allowed ? StatusChip(String(localized: "Allowed"), kind: .good)
                : StatusChip(String(localized: "Not allowed"), kind: .attention)
    }

    static func chip(for status: AutomationPermission?) -> StatusChip {
        switch status {
        case .allowed: return StatusChip(String(localized: "Allowed"), kind: .good)
        case .denied: return StatusChip(String(localized: "Not allowed"), kind: .attention)
        case .notAsked: return StatusChip(String(localized: "Not asked yet"), kind: .neutral)
        case .appNotRunning: return StatusChip(String(localized: "Not running"), kind: .neutral)
        case .unknown: return StatusChip(String(localized: "Unknown"), kind: .neutral)
        case nil: return StatusChip(String(localized: "Checking…"), kind: .neutral)
        }
    }
}

// MARK: - Model

/// Permission statuses and data sizes, kept between visits so the pane doesn't flash empty.
@MainActor
final class PermissionsModel: ObservableObject {
    static let shared = PermissionsModel()

    struct AutomationApp: Identifiable {
        let bundleId: String
        let name: String
        let purpose: String
        let icon: NSImage?
        var status: AutomationPermission?
        var id: String { bundleId }
    }

    struct DataLocation: Identifiable {
        let title: String
        let detail: String
        let symbol: String
        let color: Color
        let url: URL
        var size: String?
        var id: String { url.path }
    }

    @Published private(set) var screenRecording = CGPreflightScreenCaptureAccess()
    @Published private(set) var accessibility = AXIsProcessTrusted()
    @Published private(set) var loginItem = SMAppService.mainApp.status
    @Published private(set) var automation: [AutomationApp] = []
    @Published private(set) var dataLocations: [DataLocation] = []
    /// The user asked for Screen Recording in this session; macOS applies it after a restart.
    @Published private(set) var screenRecordingRequested = false

    var screenRecordingNeedsRestart: Bool { screenRecordingRequested && !screenRecording }

    /// Apps Deckhand sends Apple Events to, and why. Only installed ones are listed.
    nonisolated static let automationTargets: [(bundleId: String, purpose: LocalizedTerm)] = [
        ("com.apple.Music", LocalizedTerm("permissions.purpose.nowPlaying", "What's playing")),
        ("com.spotify.client", LocalizedTerm("permissions.purpose.nowPlaying", "What's playing")),
        ("com.apple.Safari", LocalizedTerm("permissions.purpose.browserTabs", "What's playing in browser tabs")),
        ("com.google.Chrome", LocalizedTerm("permissions.purpose.browserTabs", "What's playing in browser tabs")),
        ("com.microsoft.edgemac", LocalizedTerm("permissions.purpose.browserTabs", "What's playing in browser tabs")),
        ("com.apple.systemevents", LocalizedTerm("permissions.purpose.darkMode", "Dark Mode switch on Home")),
    ]

    private static let requestedKey = "permissionsRequested"

    private init() {}

    func refresh() async {
        screenRecording = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
        loginItem = SMAppService.mainApp.status
        if automation.isEmpty { automation = Self.installedAutomationApps() }
        if dataLocations.isEmpty { dataLocations = Self.locations() }

        // Apple Event permission checks and folder sizes talk to other processes and the disk
        let ids = automation.map(\.bundleId)
        let statuses = await Task.detached(priority: .userInitiated) {
            ids.map { AutomationPermission.status(bundleId: $0, ask: false) }
        }.value
        for i in automation.indices where i < statuses.count { automation[i].status = statuses[i] }

        let urls = dataLocations.map(\.url)
        let sizes = await Task.detached(priority: .utility) { urls.map(Self.size(of:)) }.value
        for i in dataLocations.indices where i < sizes.count {
            dataLocations[i].size = sizes[i].map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        }
    }

    /// The first click shows macOS's own prompt, which adds Deckhand to the list; later clicks
    /// open the pane, because macOS shows that prompt only once. The flag is shared with the
    /// capture alert and the Screenshots pane.
    func requestScreenRecording() {
        screenRecordingRequested = true
        screenRecording = ScreenRecordingPermission.request(openSettings: false)
    }

    func requestAccessibility() {
        if askedBefore("accessibility") {
            SystemSettingsLink.open(SystemSettingsLink.accessibility)
        } else {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            accessibility = AXIsProcessTrustedWithOptions(options)
        }
    }

    /// Records that a prompt was shown and says whether it had been shown before.
    private func askedBefore(_ name: String) -> Bool {
        let d = UserDefaults.standard
        var asked = d.stringArray(forKey: Self.requestedKey) ?? []
        if asked.contains(name) { return true }
        asked.append(name)
        d.set(asked, forKey: Self.requestedKey)
        return false
    }

    private static func installedAutomationApps() -> [AutomationApp] {
        automationTargets.compactMap { target in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleId) else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            return AutomationApp(bundleId: target.bundleId,
                                 name: FileManager.default.displayName(atPath: url.path),
                                 purpose: target.purpose.localized,
                                 icon: icon,
                                 status: nil)
        }
    }

    private static func locations() -> [DataLocation] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            DataLocation(title: String(localized: "History, prompts and shelf"),
                         detail: (AppPaths.supportDir.path as NSString).abbreviatingWithTildeInPath,
                         symbol: "internaldrive.fill", color: .gray, url: AppPaths.supportDir),
            DataLocation(title: String(localized: "Logs"),
                         detail: "~/Library/Logs/Deckhand",
                         symbol: "doc.text.fill", color: .gray,
                         url: home.appendingPathComponent("Library/Logs/Deckhand", isDirectory: true)),
            DataLocation(title: String(localized: "Claude Code hook"),
                         detail: (ClaudeCodeMonitor.shared.settingsFile.url.path as NSString).abbreviatingWithTildeInPath,
                         symbol: "sparkle", color: SettingsSection.claude.color,
                         url: ClaudeCodeMonitor.shared.settingsFile.url),
        ]
    }

    /// Bytes in a file or folder, or nil when it doesn't exist.
    nonisolated static func size(of url: URL) -> Int64? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard isDirectory.boolValue else {
            let values = try? url.resourceValues(forKeys: keys)
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        let items = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: nil)
        while let item = items?.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: keys)
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
