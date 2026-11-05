import SwiftUI
import AppKit

/// Screenshots, text from the screen, the color picker and the editor. Owned by the capture and hotkeys workstream.
struct CapturePane: View {
    @ObservedObject private var capture = CaptureSettings.shared
    @State private var supported: [String] = []
    @State private var screenRecording = ScreenRecordingPermission.isGranted

    var body: some View {
        SettingsPane(.capture) {
            if !screenRecording {
                Section {
                    SettingsRow(String(localized: "Screen Recording is off"),
                                detail: String(localized: "Captures show only the desktop until you allow it."),
                                icon: .symbol("exclamationmark.triangle.fill", .orange)) {
                        // Asks once first: on macOS 15 Deckhand isn't in the list until it has
                        Button("Open System Settings") { ScreenRecordingPermission.request(openSettings: true) }
                            .buttonStyle(.settings(.prominent))
                    }
                }
            }

            Section {
                ShortcutRow(action: .screenshot, title: String(localized: "Shortcut"))
                Picker("After capture", selection: $capture.afterCapture) {
                    ForEach(CaptureAfterAction.allCases) { Text($0.title).tag($0) }
                }
                SettingsRow(String(localized: "Save to")) {
                    Label {
                        Text(FileManager.default.displayName(atPath: capture.saveFolder))
                            .foregroundStyle(Theme.fgDim)
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: capture.saveFolder))
                            .resizable().frame(width: 16, height: 16)
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                    Button("Choose…", action: chooseFolder)
                        .buttonStyle(.settings)
                }
                .help(Text(verbatim: capture.saveFolder))
                Picker("Format", selection: $capture.format) {
                    ForEach(CaptureFormat.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                SettingsToggleRow(String(localized: "Shutter sound"), isOn: $capture.shutterSound)
            } header: {
                Text("Capture Area")
            } footer: {
                SettingsFooter("Every choice copies the image first. While selecting, press Space to capture a window instead.")
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
                SettingsToggleRow(String(localized: "Detect automatically"), isOn: $capture.ocrAutoDetect)
                SettingsToggleRow(String(localized: "Correct words"),
                                  detail: String(localized: "Turn off for code, serial numbers and links."),
                                  isOn: $capture.ocrLanguageCorrection)
                SettingsToggleRow(String(localized: "Keep line breaks"), isOn: $capture.ocrKeepLineBreaks)
            } header: {
                Text("Text from Screen")
            } footer: {
                SettingsFooter("Put the language you capture most first. QR codes and barcodes are copied as their content.")
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
            }

            SettingsPaneActions {
                RestoreDefaultsButton(section: .capture,
                                      message: String(localized: "Shortcuts stay as they are. Restore them in Shortcuts.")) {
                    capture.restoreDefaults()
                }
            }
        }
        .task {
            supported = await Task.detached(priority: .utility) { TextRecognizer.supportedLanguages() }.value
        }
        .onSettingsActivation {
            screenRecording = ScreenRecordingPermission.isGranted
        }
    }

    // MARK: - Languages

    private var languages: some View {
        SettingsRow(String(localized: "Languages")) {
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
