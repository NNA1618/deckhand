import SwiftUI
import AppKit

/// Screenshots, text from the screen, the color picker and the editor. Owned by the capture and hotkeys workstream.
struct CapturePane: View {
    @ObservedObject private var capture = CaptureSettings.shared
    @State private var supported: [String] = []
    @State private var screenRecording = ScreenRecordingPermission.isGranted
    @State private var confirmReset = false

    var body: some View {
        SettingsPane(.capture) {
            if !screenRecording {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Screen Recording is off")
                            Text("Captures show only the desktop until you allow it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        // Asks once first: on macOS 15 Deckhand isn't in the list until it has
                        Button("Open System Settings") { ScreenRecordingPermission.request(openSettings: true) }
                    }
                }
            }

            Section {
                ShortcutRow(action: .screenshot, title: String(localized: "Shortcut"))
                Picker("After capture", selection: $capture.afterCapture) {
                    ForEach(CaptureAfterAction.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Save to") {
                    HStack(spacing: 8) {
                        Label {
                            Text(FileManager.default.displayName(atPath: capture.saveFolder))
                        } icon: {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: capture.saveFolder))
                                .resizable().frame(width: 16, height: 16)
                        }
                        .lineLimit(1)
                        .truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                .help(Text(verbatim: capture.saveFolder))
                Picker("Format", selection: $capture.format) {
                    ForEach(CaptureFormat.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                Toggle("Shutter sound", isOn: $capture.shutterSound)
            } header: {
                Text("Capture Area")
            } footer: {
                Text("Every choice copies the image first. While selecting, press Space to capture a window instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ShortcutRow(action: .captureAndEdit)
                ShortcutRow(action: .captureWindow)
                ShortcutRow(action: .captureScreen)
                ShortcutRow(action: .captureDelayed)
            } header: {
                Text("More Ways to Capture")
            }

            Section {
                ShortcutRow(action: .captureText, title: String(localized: "Shortcut"))
                languages
                Toggle("Detect automatically", isOn: $capture.ocrAutoDetect)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Correct words", isOn: $capture.ocrLanguageCorrection)
                    Text("Turn off for code, serial numbers and links.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Keep line breaks", isOn: $capture.ocrKeepLineBreaks)
            } header: {
                Text("Text from Screen")
            } footer: {
                Text("Put the language you capture most first. QR codes and barcodes are copied as their content.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ShortcutRow(action: .colorPicker, title: String(localized: "Shortcut"))
                Picker("Copy as", selection: $capture.colorFormat) {
                    ForEach(ColorFormat.allCases) { Text(verbatim: $0.title).tag($0) }
                }
            } header: {
                Text("Pick a Color")
            }

            Section {
                Picker("Start with", selection: $capture.editorDefaultTool) {
                    ForEach(EditorTool.allCases) { tool in
                        Label(tool.title, systemImage: tool.symbol).tag(tool)
                    }
                }
            } header: {
                Text("Editor")
            } footer: {
                HStack {
                    Spacer()
                    Button("Restore Defaults…") { confirmReset = true }
                }
            }
        }
        .task {
            supported = await Task.detached(priority: .utility) { TextRecognizer.supportedLanguages() }.value
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenRecording = ScreenRecordingPermission.isGranted
        }
        .confirmationDialog(Text("Restore the default screenshot settings?"), isPresented: $confirmReset) {
            Button("Restore Defaults") { capture.restoreDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shortcuts stay as they are. Restore them in Shortcuts.")
        }
    }

    // MARK: - Languages

    private var languages: some View {
        LabeledContent("Languages") {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(Array(capture.ocrLanguages.enumerated()), id: \.element) { index, code in
                    HStack(spacing: 6) {
                        Text(Self.languageName(code))
                        Button {
                            capture.ocrLanguages.swapAt(index, index - 1)
                        } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        .help(Text("Move up"))
                        .accessibilityLabel(Text("Move up"))
                        Button {
                            capture.ocrLanguages.remove(at: index)
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(capture.ocrLanguages.count == 1)
                        .help(Text("Remove"))
                        .accessibilityLabel(Text("Remove"))
                    }
                }
                Menu("Add Language") {
                    ForEach(available, id: \.self) { code in
                        Button(Self.languageName(code)) { capture.ocrLanguages.append(code) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(available.isEmpty)
            }
        }
    }

    private var available: [String] {
        supported.filter { !capture.ocrLanguages.contains($0) }
            .sorted { Self.languageName($0).localizedCompare(Self.languageName($1)) == .orderedAscending }
    }

    /// The language's name in the app's language («Русский», "German"). The region is left out
    /// (Vision has one variant per language); the script stays, to tell Chinese variants apart.
    static func languageName(_ code: String) -> String {
        let app = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        let parts = code.split(separator: "-").map(String.init)
        let hasScript = parts.count > 1 && parts[1].count == 4
        let name = (hasScript ? app.localizedString(forIdentifier: code) : app.localizedString(forLanguageCode: parts.first ?? code)) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = capture.saveFolderURL
        panel.prompt = String(localized: "Choose")
        let apply: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { capture.saveFolder = url.path }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: apply) } else { panel.begin(completionHandler: apply) }
    }
}
