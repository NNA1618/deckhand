import SwiftUI
import AppKit
import ServiceManagement

/// Settings window in the style of System Settings: tabs with grouped forms.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "command") }
            ClipboardSettings().tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }
            ClaudeSettings().tabItem { Label("Claude", systemImage: "sparkle") }
            RecentsSettings().tabItem { Label("Recents", systemImage: "photo.stack") }
        }
        .frame(width: 560, height: 460)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @ObservedObject private var settings = Settings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            launchAtLogin = on
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                    }
                ))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
                Toggle("Show a notice in the notch after a screenshot", isOn: $settings.screenshotToast)
            }
            Section {
                LabeledContent("Language") {
                    Text("Follows the system language")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Deckhand by NNA1618. Open source under the MIT license.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

struct ShortcutSettings: View {
    @ObservedObject private var hotkeys = HotkeyManager.shared

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    LabeledContent {
                        ShortcutRecorder(action: action)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.title)
                            if hotkeys.conflicts.contains(action) {
                                Text("Taken by another app. Pick a different shortcut.")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            } footer: {
                HStack {
                    Text("Click a shortcut and press new keys. Use ⌘, ⌥ or ⌃. Esc cancels, ⌫ clears.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { hotkeys.resetToDefaults() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Shortcut recorder: click, press keys, done.
struct ShortcutRecorder: View {
    let action: HotkeyAction
    @ObservedObject private var hotkeys = HotkeyManager.shared
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(minWidth: 110)
                .padding(.vertical, 3)
                .foregroundStyle(recording ? Color.accentColor : (hotkeys.shortcuts[action] == nil ? .secondary : .primary))
        }
        .buttonStyle(.bordered)
        .onDisappear { stop() }
    }

    private var label: String {
        if recording { return String(localized: "Press keys…") }
        return hotkeys.shortcuts[action]?.display ?? String(localized: "Not set")
    }

    private func start() {
        recording = true
        hotkeys.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: // Esc
                stop()
            case 51, 117: // Delete, Forward Delete
                hotkeys.set(nil, for: action)
                stop()
            default:
                if let sc = Shortcut(event: event) {
                    hotkeys.set(sc, for: action)
                    stop()
                } else {
                    NSSound.beep()
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            hotkeys.registerAll()
        }
    }
}

// MARK: - Clipboard

struct ClipboardSettings: View {
    @ObservedObject private var settings = Settings.shared
    @State private var newApp = ""

    var body: some View {
        Form {
            Section {
                Picker("Keep history", selection: $settings.historyLimit) {
                    Text("100 items").tag(100)
                    Text("500 items").tag(500)
                    Text("1000 items").tag(1000)
                    Text("Unlimited").tag(0)
                }
                Toggle("Save copied passwords to history", isOn: $settings.savePasswordsToHistory)
            } footer: {
                Text("Passwords from password managers always paste normally. This only controls whether they stay in the history.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ignore apps") {
                ForEach(settings.excludedApps, id: \.self) { bundleId in
                    HStack {
                        Text(appName(bundleId))
                        Text(bundleId).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) {
                            settings.excludedApps.removeAll { $0 == bundleId }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add App…") { pickApp() }
            }
        }
        .formStyle(.grouped)
    }

    private func appName(_ bundleId: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return bundleId }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier,
              !settings.excludedApps.contains(id) else { return }
        settings.excludedApps.append(id)
    }
}

// MARK: - Claude

struct ClaudeSettings: View {
    @ObservedObject private var settings = Settings.shared
    @State private var key = ""
    @State private var hasKey = ClaudeAPI.shared.hasAPIKey

    var body: some View {
        Form {
            Section {
                if hasKey {
                    LabeledContent("API key") {
                        HStack {
                            Text("Saved in Keychain").foregroundStyle(.secondary)
                            Button("Remove") {
                                ClaudeAPI.shared.apiKey = nil
                                hasKey = false
                            }
                        }
                    }
                } else {
                    SecureField("API key", text: $key, prompt: Text(verbatim: "sk-ant-…"))
                    Button("Save to Keychain") {
                        ClaudeAPI.shared.apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                        key = ""
                        hasKey = ClaudeAPI.shared.hasAPIKey
                    }
                    .disabled(key.isEmpty)
                }
            } footer: {
                Link("Get a key at console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.caption)
            }
            Section {
                TextEditor(text: $settings.claudeInstructions)
                    .font(.body)
                    .frame(minHeight: 110)
            } header: {
                Text("Custom instructions for chat")
            } footer: {
                Text("How Claude should talk to you, for example tone, language or style rules.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Recents

struct RecentsSettings: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                ForEach(settings.watchedFolders, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                        Text((path as NSString).abbreviatingWithTildeInPath)
                        Spacer()
                        Button(role: .destructive) {
                            settings.watchedFolders.removeAll { $0 == path }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…") { pickFolder() }
            } header: {
                Text("Watched folders")
            } footer: {
                Text("Recents shows images and videos from these folders for the last 14 days, for example generations you downloaded from Higgsfield.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !settings.watchedFolders.contains(url.path) {
            settings.watchedFolders.append(url.path)
        }
    }
}

// MARK: - Window

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = String(localized: "Deckhand Settings")
        w.contentViewController = NSHostingController(rootView: SettingsView())
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
