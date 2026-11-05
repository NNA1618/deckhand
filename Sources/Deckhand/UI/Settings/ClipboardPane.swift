import SwiftUI
import AppKit

/// Clipboard history. Owned by the clipboard workstream.
struct ClipboardPane: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var clip = ClipboardSettings.shared
    @State private var diskUsage: Int64?
    @State private var confirmClear = false
    @State private var accessibility = PasteService.isTrusted
    @State private var secretCount = 0

    private let accessibilityTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsPane(.clipboard) {
            history
            pasting
            passwords
            ignoredApps
            Section {
                LabeledContent("Shortcut") { ShortcutRecorder(action: .clipboard) }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .clipboardHistoryChanged)) { _ in refresh() }
        .onReceive(accessibilityTimer) { _ in accessibility = PasteService.isTrusted }
        .alert("Clear clipboard history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) {
                ClipboardStore.shared.clearHistory()
                refresh()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pinned items stay.")
        }
    }

    // MARK: - Sections

    private var history: some View {
        Section {
            Toggle("Record clipboard history", isOn: $clip.recordHistory)
            Picker("Keep for", selection: $clip.historyMaxAgeDays) {
                Text("1 day").tag(1)
                Text("1 week").tag(7)
                Text("1 month").tag(30)
                Text("Forever").tag(0)
            }
            Picker("Maximum", selection: $settings.historyLimit) {
                ForEach([100, 500, 1000, 5000], id: \.self) { n in
                    Text("\(n) items").tag(n)
                }
                Text("No limit").tag(0)
            }
            Toggle("Save images", isOn: $clip.saveImages)
            Picker("Largest image", selection: $clip.maxImageMB) {
                Text(megabytes(5)).tag(5)
                Text(megabytes(20)).tag(20)
                Text("No limit").tag(0)
            }
            .disabled(!clip.saveImages)
            Toggle("Save copied files", isOn: $clip.saveFiles)
            LabeledContent("On disk") {
                HStack(spacing: 10) {
                    Text(diskUsage.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.clipboardImagesDir])
                    }
                }
            }
            HStack {
                Spacer()
                Button("Clear History…", role: .destructive) { confirmClear = true }
            }
        } header: {
            Text("History")
        } footer: {
            Text("Pinned items are never removed automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var pasting: some View {
        Section {
            Picker("Return and double-click", selection: $clip.pasteOnSelect) {
                Text("Paste into the app").tag(true)
                Text("Copy only").tag(false)
            }
            LabeledContent("Accessibility") {
                HStack(spacing: 8) {
                    Image(systemName: accessibility ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(accessibility ? .green : .orange)
                    Text(accessibility ? "Allowed" : "Not allowed")
                        .foregroundStyle(.secondary)
                    if !accessibility {
                        Button("Allow…") { PasteService.requestAccess() }
                    }
                }
            }
        } header: {
            Text("Pasting")
        } footer: {
            Text("Pasting into another app needs Accessibility. To paste without formatting, press \("⌥↩").")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var passwords: some View {
        Section {
            Toggle("Save copied passwords", isOn: $settings.savePasswordsToHistory)
            if !settings.savePasswordsToHistory && secretCount > 0 {
                HStack {
                    Text("Passwords saved earlier are still in the history.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove Saved Passwords") {
                        ClipboardStore.shared.deleteSecrets()
                        refresh()
                    }
                }
            }
            LabeledContent("Always treated as passwords") {
                Text(passwordAppNames)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Passwords")
        } footer: {
            Text("Passwords from password managers always paste normally. This only controls whether they stay in the history.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var ignoredApps: some View {
        Section {
            ForEach(settings.excludedApps, id: \.self) { bundleId in
                HStack(spacing: 8) {
                    if let icon = AppIconCache.icon(bundleId: bundleId) {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    }
                    Text(appName(bundleId))
                    Spacer()
                    Button {
                        settings.excludedApps.removeAll { $0 == bundleId }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(Text("Remove"))
                    .accessibilityLabel(Text("Remove \(appName(bundleId))"))
                }
            }
            Menu("Add App…") {
                ForEach(runningApps, id: \.bundleIdentifier) { app in
                    Button(app.localizedName ?? app.bundleIdentifier ?? "") {
                        add(app.bundleIdentifier)
                    }
                }
                if !runningApps.isEmpty { Divider() }
                Button("Choose…") { pickApp() }
            }
            .fixedSize()
        } header: {
            Text("Ignore apps")
        } footer: {
            Text("What you copy in these apps never enters the history.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func refresh() {
        secretCount = ClipboardStore.shared.secretCount()
        accessibility = PasteService.isTrusted
        let images = AppPaths.clipboardImagesDir
        let database = AppPaths.databaseURL
        Task {
            diskUsage = await Task.detached(priority: .utility) { Self.size(images: images, database: database) }.value
        }
    }

    /// The images folder plus the database and its journal.
    nonisolated private static func size(images: URL, database: URL) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let size = (try? fm.attributesOfItem(atPath: database.path + suffix))?[.size] as? NSNumber
            total += size?.int64Value ?? 0
        }
        let files = fm.enumerator(at: images, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        while let url = files?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    private func megabytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n * 1_000_000, countStyle: .file)
    }

    private var passwordAppNames: String {
        [String(localized: "Passwords"), String(localized: "Keychain Access"), "1Password", "Bitwarden"]
            .formatted(.list(type: .and).locale(ClipboardTime.locale))
    }

    /// Apps with a window that aren't ignored yet, to pick from without browsing.
    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && !settings.excludedApps.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }

    private func add(_ bundleId: String?) {
        guard let bundleId, !settings.excludedApps.contains(bundleId) else { return }
        settings.excludedApps.append(bundleId)
    }

    private func appName(_ bundleId: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return bundleId }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(Bundle(url: url)?.bundleIdentifier)
    }
}
