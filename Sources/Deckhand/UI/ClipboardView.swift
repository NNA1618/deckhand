import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ClipboardView: View {
    @ObservedObject private var vm = ClipboardViewModel.shared
    @ObservedObject private var watcher = ClipboardWatcher.shared
    @ObservedObject private var clipSettings = ClipboardSettings.shared
    @EnvironmentObject var notch: NotchViewModel
    @FocusState private var searchFocused: Bool
    @State private var keyMonitor: Any?
    @State private var keyObserver: NSObjectProtocol?

    var body: some View {
        VStack(spacing: 8) {
            header
            if watcher.isPaused { pausedBanner }
            ZStack {
                content
                if let item = vm.previewItem {
                    ClipboardPreview(item: item, store: vm.store,
                                     onPaste: { vm.paste(item, notch: notch) },
                                     onCopy: { if vm.copy(item) { vm.show(ClipboardNotice(kind: .info, text: String(localized: "Copied"))) } },
                                     onClose: { vm.previewItem = nil })
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: vm.previewItem?.id)
            if let notice = vm.notice {
                NoticeBar(notice: notice, onDismiss: { vm.notice = nil })
            } else if !vm.rows.isEmpty {
                hints
            }
        }
        .onAppear {
            vm.appeared()
            installKeys()
            focusIfKey()
        }
        .onDisappear(perform: removeKeys)
    }

    // MARK: - Parts

    private var header: some View {
        HStack(spacing: 8) {
            ClipboardSearchField(text: $vm.search, focused: $searchFocused)
            HStack(spacing: 2) {
                ForEach(ClipboardFilter.allCases) { f in
                    Button { vm.filter = f } label: {
                        Image(systemName: f.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(vm.filter == f ? .black : Theme.fgDim)
                            .frame(width: 28, height: 24)
                            .background(Capsule().fill(vm.filter == f ? Theme.accent : Color.clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(Text(f.title))
                    .accessibilityLabel(Text(f.title))
                    .accessibilityAddTraits(vm.filter == f ? .isSelected : [])
                }
            }
            .padding(2)
            .glassChip(in: Capsule())
            pauseMenu
        }
    }

    private var pauseMenu: some View {
        Menu {
            if watcher.isPaused {
                Button("Resume Recording") { watcher.resume() }
            } else {
                Button("Pause for 10 Minutes") { watcher.pause(for: 600) }
                Button("Pause for 1 Hour") { watcher.pause(for: 3600) }
                Button("Pause Until Resumed") { watcher.pause(for: nil) }
            }
        } label: {
            Image(systemName: watcher.isPaused ? "pause.circle.fill" : "pause.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(watcher.isPaused ? Theme.warn : Theme.fgDim)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 28, height: 28)
        .glassChip(in: Circle())
        .help(Text(watcher.isPaused ? "Resume Recording" : "Pause Recording"))
    }

    private var pausedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.fill").font(.system(size: 10)).foregroundColor(Theme.warn)
            Text(pausedText).font(Theme.caption).foregroundColor(Theme.fgDim)
            Spacer()
            Button("Resume") { watcher.resume() }
                .buttonStyle(.plain).font(Theme.label).foregroundColor(Theme.fg)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
    }

    private var pausedText: String {
        guard let until = watcher.pausedUntil, until != .distantFuture else {
            return String(localized: "Recording is paused.")
        }
        let time = until.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(ClipboardTime.locale))
        return String(localized: "Recording is paused until \(time).")
    }

    @ViewBuilder private var content: some View {
        if vm.rows.isEmpty {
            if vm.historyIsEmpty {
                EmptyState(symbol: "doc.on.clipboard", title: "No clipboard history yet",
                           hint: clipSettings.recordHistory ? "What you copy shows up here." : "Recording is off in Settings.")
            } else {
                EmptyState(symbol: "magnifyingglass", title: "No matches")
            }
        } else {
            list
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !vm.pinned.isEmpty {
                        sectionHeader("Pinned")
                        ForEach(vm.pinned) { row($0) }
                        if !vm.recent.isEmpty { sectionHeader("History") }
                    }
                    ForEach(vm.recent) { item in
                        row(item).onAppear { vm.loadMoreIfNeeded(after: item) }
                    }
                }
            }
            .fadeBottom()
            .onChange(of: vm.selectedId) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) }
            }
        }
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(Theme.label).foregroundColor(Theme.fgMute)
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ item: ClipboardItem) -> some View {
        ClipboardRow(
            item: item,
            imageURL: vm.store.imageURL(for: item),
            number: vm.number(for: item),
            selected: item.id == vm.selectedId,
            actions: ClipboardRowActions(
                choose: { plain in
                    vm.selectedId = item.id
                    vm.choose(item, plain: plain, notch: notch)
                },
                copy: { vm.copy(item) },
                paste: { plain in vm.paste(item, plain: plain, notch: notch) },
                preview: {
                    vm.selectedId = item.id
                    vm.togglePreview(item)
                },
                edit: { edit(item) },
                pin: { vm.togglePin(item) },
                delete: { vm.delete(item) },
                notify: { vm.show($0) }
            )
        )
        .id(item.id)
    }

    private var hints: some View {
        HStack(spacing: 14) {
            KeyHint(keys: "↑↓", label: "Select")
            KeyHint(keys: "↩", label: clipSettings.pasteOnSelect ? "Paste" : "Copy")
            KeyHint(keys: "⌥↩", label: "Paste as Plain Text")
            KeyHint(keys: "⌘1–9", label: "Quick Paste")
            KeyHint(keys: "Space", label: "Preview", localizedKeys: true)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
    }

    // MARK: - Focus

    /// The search field takes the keyboard only when the panel is key (opened by a click, the
    /// shortcut or the menu). A hover-open never steals typing from the app underneath.
    private func focusIfKey() {
        if NSApp.keyWindow is NotchWindow { searchFocused = true }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard note.object is NotchWindow else { return }
            MainActor.assumeIsolated { searchFocused = true }
        }
    }

    // MARK: - Keyboard

    private static let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]   // 1...9

    private func installKeys() {
        removeKeys()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
    }

    /// Returns true when the key was used.
    private func handle(_ event: NSEvent) -> Bool {
        guard event.window is NotchWindow, notch.isOpen, notch.tab == .clipboard else { return false }
        // Input methods (Chinese, Japanese…) use arrows and Return while composing
        if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let selected = vm.selectedItem

        if mods == .command {
            if let n = Self.digitKeyCodes.firstIndex(of: event.keyCode) {
                guard n < vm.recent.count else { return false }
                vm.choose(vm.recent[n], notch: notch)
                return true
            }
            switch event.keyCode {
            case 16:                            // ⌘Y, Quick Look's shortcut
                vm.togglePreview()
                return true
            case 51:                            // ⌘⌫, unless it is editing the search text
                guard let selected, vm.search.isEmpty else { return false }
                vm.delete(selected)
                return true
            case 35:                            // ⌘P
                guard let selected else { return false }
                vm.togglePin(selected)
                return true
            default:
                return false
            }
        }
        if mods == .option, event.keyCode == 36 || event.keyCode == 76 {
            guard let selected else { return false }
            vm.choose(selected, plain: true, notch: notch)
            return true
        }
        guard mods.isEmpty || mods == .shift else { return false }
        switch event.keyCode {
        case 125 where mods.isEmpty: vm.move(by: 1); return true       // down
        case 126 where mods.isEmpty: vm.move(by: -1); return true      // up
        case 36, 76:                                                    // Return, Enter
            guard let selected else { return false }
            vm.choose(selected, notch: notch)
            return true
        case 49 where mods.isEmpty && (vm.search.isEmpty || vm.previewItem != nil):   // Space
            vm.togglePreview()
            return true
        case 53:                                                        // Esc: preview, then search, then the panel
            if vm.previewItem != nil { vm.previewItem = nil; return true }
            if !vm.search.isEmpty { vm.search = ""; return true }
            return false
        default:
            return false
        }
    }

    private func edit(_ item: ClipboardItem) {
        guard let url = vm.store.imageURL(for: item), let image = NSImage(contentsOf: url) else {
            vm.show(ClipboardNotice(kind: .error, text: ClipboardWriter.Failure.missingImage.message))
            return
        }
        notch.requestClose()
        // Let the panel close first, then open the editor window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            EditorWindow.open(image: image)
        }
    }
}

// MARK: - Search field

/// The panel's search field with focus controlled by the Clipboard tab.
private struct ClipboardSearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(Theme.fgMute)
            TextField("Search", text: $text)
                .textFieldStyle(.plain).font(Theme.body).foregroundColor(Theme.fg)
                .focused(focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundColor(Theme.fgMute)
                }
                .buttonStyle(.plain)
                .help(Text("Clear Search"))
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .glassChip(in: Capsule())
    }
}

/// A key and what it does, e.g. "↩ Paste".
private struct KeyHint: View {
    let keys: String
    let label: LocalizedStringKey
    /// Key names that are words ("Space") are translated; symbols are not.
    var localizedKeys = false

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if localizedKeys { Text(LocalizedStringKey(keys)) } else { Text(verbatim: keys) }
            }
            .font(Theme.monoSmall).foregroundColor(Theme.fgDim)
            Text(label).font(Theme.caption).foregroundColor(Theme.fgMute)
        }
        .fixedSize()
    }
}

private struct NoticeBar: View {
    let notice: ClipboardNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundColor(notice.kind == .info ? Theme.fgDim : Theme.warn)
            Text(notice.text).font(Theme.caption).foregroundColor(Theme.fg)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if notice.kind == .needsAccessibility {
                GlassButton(title: "Allow…") { PasteService.requestAccess() }
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.fgMute)
            }
            .buttonStyle(.plain)
            .help(Text("Dismiss"))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface2))
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch notice.kind {
        case .info: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        case .needsAccessibility: return "hand.raised"
        }
    }
}

// MARK: - Row

struct ClipboardRowActions {
    let choose: (_ plain: Bool) -> Void
    let copy: () -> Bool
    let paste: (_ plain: Bool) -> Void
    let preview: () -> Void
    let edit: () -> Void
    let pin: () -> Void
    let delete: () -> Void
    let notify: (ClipboardNotice) -> Void
}

struct ClipboardRow: View {
    let item: ClipboardItem
    let imageURL: URL?
    /// 1...9 for the rows ⌘1–⌘9 paste.
    var number: Int? = nil
    var selected = false
    let actions: ClipboardRowActions
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ClipboardThumbnail(item: item, imageURL: imageURL)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(item.kind == .link ? Theme.body.monospaced() : Theme.body)
                    .foregroundColor(Theme.fg)
                    .lineLimit(item.kind == .text && !item.isSecret ? 2 : 1)
                    .truncationMode(item.kind == .file || item.kind == .link ? .middle : .tail)
                    .multilineTextAlignment(.leading)
                meta
            }
            Spacer(minLength: 6)

            if copied {
                Text("Copied").font(Theme.label).foregroundColor(Theme.accent)
            }
            if hover {
                buttons
            } else if let number {
                Text(verbatim: "⌘\(number)").font(Theme.monoSmall).foregroundColor(Theme.fgMute)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.surface2 : hover ? Theme.surface : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: click)
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text("Paste")) { actions.paste(false) }
    }

    private var meta: some View {
        HStack(spacing: 5) {
            if let bundleId = item.sourceApp, let icon = AppIconCache.icon(bundleId: bundleId) {
                Image(nsImage: icon).resizable().frame(width: 12, height: 12)
            }
            if let name = item.sourceAppName {
                Text(name).lineLimit(1)
                Text(verbatim: "·")
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(ClipboardTime.relative(item.lastUsedAt, now: context.date))
            }
            if let detail {
                Text(verbatim: "·")
                Text(detail).lineLimit(1)
            }
        }
        .font(Theme.caption).foregroundColor(Theme.fgMute)
    }

    private var detail: String? {
        if item.isSecret { return String(localized: "Password") }
        switch item.kind {
        case .image: return item.preview.isEmpty ? nil : item.preview
        case .link: return String(localized: "Link")
        case .file: return item.fileURLs.first.map { $0.deletingLastPathComponent().lastPathComponent }
        case .text: return nil
        }
    }

    /// One click copies, a double-click chooses (pastes by default), ⇧-click pastes as plain text.
    /// A single tap gesture keeps clicks instant; the double-click is read from the event.
    private func click() {
        let event = NSApp.currentEvent
        if event?.modifierFlags.contains(.shift) == true {
            actions.paste(true)
        } else if (event?.clickCount ?? 1) >= 2 {
            actions.choose(false)
        } else {
            copy()
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            rowButton("arrow.turn.down.left", "Paste into the app you were using") { actions.paste(false) }
            rowButton("eye", "Preview") { actions.preview() }
            switch item.kind {
            case .image:
                rowButton("pencil.tip.crop.circle", "Edit") { actions.edit() }
                rowButton("text.viewfinder", "Copy Text from Image") { copyImageText() }
                rowButton("pip", "Pin on Screen") { pinOnScreen() }
            case .link:
                rowButton("safari", "Open Link") { openLink() }
            case .file:
                rowButton("folder", "Show in Finder") { showInFinder() }
            case .text:
                EmptyView()
            }
            rowButton(item.pinned ? "pin.fill" : "pin", item.pinned ? "Unpin" : "Pin",
                      tint: item.pinned ? Theme.accent : nil) { actions.pin() }
            rowButton("trash", "Delete") { actions.delete() }
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Paste") { actions.paste(false) }
        if item.kind == .text && item.hasRichText || item.kind == .link {
            Button("Paste as Plain Text") { actions.paste(true) }
        }
        Button("Copy") { copy() }
        Button("Preview") { actions.preview() }
        switch item.kind {
        case .image:
            Divider()
            Button("Edit") { actions.edit() }
            Button("Copy Text from Image") { copyImageText() }
            Button("Pin on Screen") { pinOnScreen() }
        case .link:
            Divider()
            Button("Open Link") { openLink() }
        case .file:
            Divider()
            Button("Show in Finder") { showInFinder() }
        case .text:
            EmptyView()
        }
        Divider()
        Button(item.pinned ? "Unpin" : "Pin") { actions.pin() }
        Button("Delete", role: .destructive) { actions.delete() }
    }

    private func rowButton(_ symbol: String, _ help: LocalizedStringKey, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundColor(tint ?? Theme.fgDim)
                .frame(width: 18, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }

    private func copy() {
        guard actions.copy() else { return }
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    private func copyImageText() {
        guard let url = imageURL, FileManager.default.fileExists(atPath: url.path) else {
            actions.notify(ClipboardNotice(kind: .error, text: ClipboardWriter.Failure.missingImage.message))
            return
        }
        Task { @MainActor in
            let found = await TextRecognizer.copyText(fromFile: url)
            actions.notify(ClipboardNotice(kind: found ? .info : .error,
                                           text: found ? String(localized: "Text copied") : String(localized: "No text found")))
        }
    }

    private func pinOnScreen() {
        guard let url = imageURL, let image = NSImage(contentsOf: url) else {
            actions.notify(ClipboardNotice(kind: .error, text: ClipboardWriter.Failure.missingImage.message))
            return
        }
        PinnedImageWindow.show(image)
    }

    private func openLink() {
        if let url = URL(string: item.preview), ClipboardText.isLink(item.preview) { NSWorkspace.shared.open(url) }
    }

    private func showInFinder() {
        let existing = item.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            actions.notify(ClipboardNotice(kind: .error, text: ClipboardWriter.Failure.missingFiles.message))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(existing)
    }
}

/// The square at the start of a row: an image thumbnail, a file icon or a symbol.
/// Thumbnails are decoded off the main thread.
private struct ClipboardThumbnail: View {
    let item: ClipboardItem
    let imageURL: URL?
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: item.kind == .image ? .fill : .fit)
                    .frame(width: 44, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        if item.kind == .image {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1)
                        }
                    }
            } else if item.kind == .file, let icon = fileIcon {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 44, height: 30)
            } else {
                Image(systemName: symbol)
                    .foregroundColor(Theme.fgMute).font(.system(size: 12))
                    .frame(width: 44, height: 20)
            }
        }
        .task(id: item.id) { await load() }
    }

    private var symbol: String {
        if item.isSecret { return "key" }
        switch item.kind {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    /// An icon by file type: no disk access, so a slow or missing volume can't stall the list.
    private var fileIcon: NSImage? {
        guard let first = item.fileURLs.first else { return nil }
        if first.hasDirectoryPath || first.pathExtension.isEmpty { return NSWorkspace.shared.icon(for: .folder) }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: first.pathExtension) ?? .data)
    }

    private func load() async {
        let path: String?
        switch item.kind {
        case .image:
            path = imageURL?.path
        case .file:
            // Image files get a real thumbnail
            path = item.fileURLs.count == 1 && (UTType(filenameExtension: item.fileURLs[0].pathExtension)?.conforms(to: .image) ?? false)
                ? item.fileURLs[0].path : nil
        default:
            path = nil
        }
        guard let path else { return }
        if let hit = ThumbnailCache.cached(at: path) { thumbnail = hit; return }
        thumbnail = await Task.detached(priority: .userInitiated) { ThumbnailCache.image(at: path) }.value
    }
}

// MARK: - Preview

/// A larger look at an item inside the panel (Space or ⌘Y): the whole text, the image,
/// or the files with their sizes.
private struct ClipboardPreview: View {
    let item: ClipboardItem
    let store: ClipboardStore
    let onPaste: () -> Void
    let onCopy: () -> Void
    let onClose: () -> Void
    @State private var text: String?
    @State private var image: NSImage?
    @State private var files: [(url: URL, size: String?, exists: Bool)] = []

    /// Very long texts are shown in part; pasting still uses the whole text.
    private static let shownCharacters = 100_000

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(heading).font(Theme.label).foregroundColor(Theme.fg).lineLimit(1).truncationMode(.middle)
                if let name = item.sourceAppName {
                    Text(verbatim: "· \(name)").font(Theme.caption).foregroundColor(Theme.fgMute).lineLimit(1)
                }
                Spacer()
                GlassButton(title: "Copy", symbol: "doc.on.doc", action: onCopy)
                PrimaryButton(title: "Paste", action: onPaste)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.fgDim)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(Text("Close Preview"))
            }
            Group {
                switch item.kind {
                case .text, .link:
                    ScrollView {
                        Text(item.isSecret ? item.title : (text ?? ""))
                            .font(item.kind == .link ? Theme.mono : Theme.body)
                            .foregroundColor(Theme.fg)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                case .image:
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        EmptyState(symbol: "photo", title: "The image file is missing.")
                    }
                case .file:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(files, id: \.url) { file in
                                HStack(spacing: 8) {
                                    Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: file.url.pathExtension) ?? .data))
                                        .resizable().frame(width: 20, height: 20)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(file.url.lastPathComponent).font(Theme.body).foregroundColor(file.exists ? Theme.fg : Theme.fgMute)
                                        Text(file.exists ? (file.size ?? file.url.deletingLastPathComponent().path)
                                                         : String(localized: "The file no longer exists."))
                                            .font(Theme.caption).foregroundColor(Theme.fgMute)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1))
        .task(id: item.id) { await load() }
    }

    /// The body already shows the text, so the heading names the kind instead.
    private var heading: String {
        if item.isSecret { return String(localized: "Password") }
        switch item.kind {
        case .text: return String(localized: "Text")
        case .link: return String(localized: "Link")
        case .image: return item.preview.isEmpty ? item.title : "\(item.title) · \(item.preview)"
        case .file: return item.title
        }
    }

    private func load() async {
        text = nil
        image = nil
        switch item.kind {
        case .text, .link:
            text = store.text(id: item.id).map { String($0.prefix(Self.shownCharacters)) }
        case .image:
            guard let url = store.imageURL(for: item) else { return }
            image = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
        case .file:
            let urls = item.fileURLs
            files = await Task.detached(priority: .userInitiated) {
                urls.map { url in
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                    let exists = FileManager.default.fileExists(atPath: url.path)
                    let size = values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
                    return (url, values?.isDirectory == true ? nil : size, exists)
                }
            }.value
        }
    }
}

// MARK: - Helpers

/// Relative times in the app's language: "now" for fresh items, then "5 min ago".
enum ClipboardTime {
    static var locale: Locale { Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en") }

    @MainActor private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = locale
        return f
    }()

    @MainActor static func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return String(localized: "clipboard.time.now", defaultValue: "now") }
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// App icons by bundle id, looked up once.
@MainActor
enum AppIconCache {
    private static var icons: [String: NSImage?] = [:]

    static func icon(bundleId: String) -> NSImage? {
        if let hit = icons[bundleId] { return hit }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        icons[bundleId] = icon
        return icon
    }
}
