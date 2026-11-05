import SwiftUI

/// Recents: new images and videos from the watched folders, with an optional prompt helper.
struct RecentsView: View {
    @ObservedObject private var settings = RecentsSettings.shared

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            if settings.showPrompt {
                PromptHelperColumn()
                    .frame(width: 300)
            }
            RecentFilesColumn()
        }
    }
}

// MARK: - Prompt helper

private struct PromptHelperColumn: View {
    @ObservedObject private var helper = PromptHelper.shared
    @ObservedObject private var settings = RecentsSettings.shared
    @ObservedObject private var claude = Settings.shared
    @EnvironmentObject private var notch: NotchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt").font(Theme.label).foregroundColor(Theme.fgMute)
            TextEditor(text: $helper.prompt)
                .scrollContentBackground(.hidden)
                .font(Theme.body).foregroundColor(Theme.fg)
                .padding(9)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxHeight: .infinity)

            if let suggestion = helper.suggestion {
                SuggestionCard(text: suggestion)
            } else if let error = helper.error {
                Text(error).font(Theme.caption).foregroundColor(Theme.warn).lineLimit(3)
                    .textSelection(.enabled)
            } else if helper.replaced != nil {
                StatusBar(text: String(localized: "Replaced with Claude's version"), buttonTitle: "Undo") { helper.undoReplace() }
            }

            HStack(spacing: 8) {
                if !ClaudeEngine.isAvailable {
                    GlassButton(title: "Set Up Claude…", symbol: "sparkle") {
                        notch.requestClose()
                        SettingsWindow.show(.claude)
                    }
                    .help(Text("Improving prompts needs Claude Code or an API key"))
                } else if helper.improving {
                    ProgressView().controlSize(.small)
                    GlassButton(title: "Stop", symbol: "stop.fill") { helper.stop() }
                } else {
                    PrimaryButton(title: "Improve with Claude") { helper.improve() }
                        .disabled(isBlank)
                        .opacity(isBlank ? 0.5 : 1)
                }
                iconButton("doc.on.doc", "Copy") { helper.copy(helper.prompt) }
                    .disabled(isBlank)
                iconButton("text.badge.plus", "Save as Prompt") { saveAsPrompt(helper.prompt) }
                    .disabled(isBlank)
                Spacer(minLength: 0)
                if let link = settings.link {
                    Link(destination: link) {
                        HStack(spacing: 3) {
                            Text(verbatim: link.host?.replacingOccurrences(of: "www.", with: "") ?? link.absoluteString)
                                .lineLimit(1).truncationMode(.middle)
                            Image(systemName: "arrow.up.right")
                        }
                        .font(Theme.caption).foregroundColor(Theme.fgDim)
                    }
                    .help(Text(verbatim: link.absoluteString))
                }
            }
        }
        .onAppear { helper.prefillFromClipboard() }
    }

    private var isBlank: Bool { helper.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func saveAsPrompt(_ text: String) {
        PromptsViewModel.shared.newDraft(body: text)
        notch.tab = .prompts
    }

    private func iconButton(_ symbol: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundColor(Theme.fg)
                .frame(width: 28, height: 26)
                .contentShape(Capsule())
                .glassChip(in: Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }
}

/// Claude's version of the prompt, kept apart from what the user typed.
private struct SuggestionCard: View {
    let text: String
    @ObservedObject private var helper = PromptHelper.shared
    @EnvironmentObject private var notch: NotchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("Claude's version", systemImage: "sparkle")
                    .font(Theme.label).foregroundColor(Theme.fgDim)
                Spacer()
                Button { helper.dismissSuggestion() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.fgMute)
                }
                .buttonStyle(.plain)
                .help(Text("Dismiss"))
            }
            ScrollView {
                Text(text).font(Theme.body).foregroundColor(Theme.fg)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 96)
            HStack(spacing: 8) {
                PrimaryButton(title: "Replace") { helper.replace() }
                GlassButton(title: "Copy", symbol: "doc.on.doc") { helper.copy(text) }
                Button {
                    PromptsViewModel.shared.newDraft(body: text)
                    notch.tab = .prompts
                } label: {
                    Image(systemName: "text.badge.plus").font(.system(size: 11, weight: .medium)).foregroundColor(Theme.fg)
                        .frame(width: 28, height: 26)
                        .contentShape(Capsule())
                        .glassChip(in: Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                .help(Text("Save as Prompt"))
            }
        }
        .padding(10)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Files

private struct RecentFilesColumn: View {
    @ObservedObject private var vm = RecentsViewModel.shared
    @ObservedObject private var settings = RecentsSettings.shared
    @EnvironmentObject private var notch: NotchViewModel
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(title).font(Theme.label).foregroundColor(Theme.fgMute)
                if vm.scanning && vm.hasScanned {
                    ProgressView().controlSize(.mini)
                        .help(Text("Looking for new files…"))
                }
                Spacer()
                Text(RecentsSettings.periodTitle(days: settings.days)).font(Theme.caption).foregroundColor(Theme.fgMute)
            }
            content
            if let status {
                StatusBar(text: status, buttonTitle: "OK") { self.status = nil }
            }
        }
        .onAppear { vm.appeared() }
        .onDisappear { vm.disappeared() }
    }

    private var title: LocalizedStringKey {
        switch settings.kinds {
        case .all: return "Recent images and videos"
        case .images: return "Recent images"
        case .videos: return "Recent videos"
        }
    }

    private var blockedFolders: [FolderProblem] { vm.problems.filter { $0.kind == .noAccess } }

    @ViewBuilder private var content: some View {
        if !vm.hasFolders {
            RecentsEmpty(symbol: "folder.badge.plus", title: String(localized: "No folders to watch"),
                         hint: String(localized: "Choose folders such as Downloads in Settings."),
                         button: "Add Folder…") { openSettings() }
        } else if !vm.hasScanned {
            VStack(spacing: 8) {
                Spacer()
                ProgressView().controlSize(.small)
                Text("Looking for new files…").font(Theme.caption).foregroundColor(Theme.fgMute)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.files.isEmpty, !blockedFolders.isEmpty {
            RecentsEmpty(symbol: "lock", title: String(localized: "No access to \(folderNames(blockedFolders))"),
                         hint: String(localized: "Allow Deckhand in System Settings → Privacy & Security → Files & Folders."),
                         button: "Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                    NSWorkspace.shared.open(url)
                }
            }
        } else if vm.files.isEmpty {
            RecentsEmpty(symbol: "photo.stack", title: String(localized: "Nothing new"),
                         hint: "\(RecentsSettings.periodTitle(days: settings.days)) · \(folderList)")
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                    ForEach(Array(vm.files.enumerated()), id: \.element.id) { index, file in
                        MediaTile(file: file,
                                  onClick: { QuickLook.shared.toggle(vm.files.map(\.url), at: index, notch: notch) },
                                  menu: { menu(for: file, index: index) })
                    }
                }
            }
            .fadeBottom()
            if !vm.problems.isEmpty {
                Text("Some folders can't be read: \(folderNames(vm.problems))")
                    .font(Theme.caption).foregroundColor(Theme.fgMute).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private var folderList: String {
        folderNames(vm.query.folders.map { FolderProblem(path: $0.path, kind: .missing) })
    }

    private func folderNames(_ problems: [FolderProblem]) -> String {
        problems.map { FileManager.default.displayName(atPath: $0.path) }.formatted(.list(type: .and))
    }

    private func openSettings() {
        notch.requestClose()
        SettingsWindow.show(.recents)
    }

    private func menu(for file: MediaFile, index: Int) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String?, _ action: @escaping () -> Void) {
            menu.addItem(ActionMenuItem(title, symbol: symbol, handler: action))
        }
        add(String(localized: "Quick Look"), "eye") { QuickLook.shared.show(vm.files.map(\.url), at: index, notch: notch) }
        add(String(localized: "Open"), "arrow.up.forward.app") { NSWorkspace.shared.open(file.url) }
        add(String(localized: "Show in Finder"), "folder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
        menu.addItem(.separator())
        add(String(localized: "Copy"), "doc.on.doc") { vm.copy(file) }
        add(String(localized: "Paste into the app you were using"), "arrow.turn.down.left") { paste(file) }
        add(String(localized: "Add to Shelf"), "tray.and.arrow.down") {
            ShelfStore.shared.add([file.url])
            status = String(localized: "Added to the shelf")
        }
        if !file.isVideo {
            add(String(localized: "Copy Text from Image"), "text.viewfinder") {
                Task { @MainActor in
                    let found = await TextRecognizer.copyText(fromFile: file.url)
                    status = found ? String(localized: "Text copied") : String(localized: "No text found")
                }
            }
        }
        return menu
    }

    private func paste(_ file: MediaFile) {
        vm.copy(file)
        guard PasteService.isTrusted else {
            status = String(localized: "The file is copied. To paste it for you, Deckhand needs Accessibility.")
            return
        }
        notch.requestClose()
        PasteService.pasteIntoFrontApp()
    }
}

/// An empty state with an optional action button.
private struct RecentsEmpty: View {
    let symbol: String
    let title: String
    let hint: String
    var button: LocalizedStringKey?
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: 7) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundColor(Theme.fgMute)
            Text(title).font(Theme.body).foregroundColor(Theme.fgDim).multilineTextAlignment(.center)
            Text(hint).font(Theme.caption).foregroundColor(Theme.fgMute).multilineTextAlignment(.center)
                .lineLimit(3)
            if let button { GlassButton(title: button, action: action).padding(.top, 4) }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
    }
}

struct MediaTile: View {
    let file: MediaFile
    let onClick: () -> Void
    let menu: () -> NSMenu
    @State private var thumb: NSImage?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let thumb {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Theme.surface
                    }
                }
                .frame(width: 100, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                if file.isVideo {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9)).foregroundColor(.white)
                        .padding(5).background(.black.opacity(0.6), in: Circle())
                        .padding(5)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(hover ? Theme.accent.opacity(0.7) : Color.clear, lineWidth: 1)
            )
            Text(file.name)
                .font(Theme.caption).foregroundColor(hover ? Theme.fg : Theme.fgDim)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 100, alignment: .leading)
        }
        .scaleEffect(hover ? 1.03 : 1)
        .animation(.easeOut(duration: 0.15), value: hover)
        .overlay {
            FileTileInteraction(urls: { [file.url] }, onClick: { _ in onClick() },
                                onDoubleClick: { NSWorkspace.shared.open(file.url) },
                                onHover: { hover = $0 }, menu: menu)
        }
        .help(Text(verbatim: file.name))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: file.name))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onClick() }
        .task(id: file.id) { thumb = await Thumbnail.make(for: file.url, size: 200) }
    }
}
