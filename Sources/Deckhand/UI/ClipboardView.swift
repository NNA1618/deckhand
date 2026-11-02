import SwiftUI

struct ClipboardView: View {
    @StateObject private var vm = ClipboardViewModel()
    @EnvironmentObject var notch: NotchViewModel
    @State private var keyMonitor: Any?

    /// The row Return pastes: the one picked with the arrows, or the top match while searching.
    private var activeId: Int64? {
        if let id = vm.selectedId, vm.items.contains(where: { $0.id == id }) { return id }
        return vm.search.isEmpty ? nil : vm.items.first?.id
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                SearchField(placeholder: "Search", text: $vm.search, focusOnAppear: true)
                Text("↑↓ to pick, Return to paste, ⌘1–9 for the first nine")
                    .font(Theme.caption).foregroundColor(Theme.fgMute)
                    .fixedSize()
            }

            if vm.items.isEmpty {
                if vm.search.isEmpty {
                    EmptyState(symbol: "doc.on.clipboard", title: "Clipboard is empty",
                               hint: "Copy something or capture an area with ⌘⇧S")
                } else {
                    EmptyState(symbol: "magnifyingglass", title: "No matches")
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(vm.items.enumerated()), id: \.element.id) { index, item in
                                ClipboardRow(
                                    item: item,
                                    number: index < 9 ? index + 1 : nil,
                                    selected: item.id == activeId,
                                    onCopy: { vm.copy($0) },
                                    onPaste: { paste($0) },
                                    onEdit: { edit($0) },
                                    onPin: { vm.togglePin($0) },
                                    onDelete: { vm.delete($0) }
                                )
                                .id(item.id)
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
        }
        .onChange(of: vm.search) { _, _ in vm.selectedId = nil }
        .onAppear(perform: installKeys)
        .onDisappear(perform: removeKeys)
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
    }

    /// Returns true when the key was used.
    private func handle(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods == .command, let n = Self.digitKeyCodes.firstIndex(of: event.keyCode) {
            guard n < vm.items.count else { return false }
            paste(vm.items[n])
            return true
        }
        guard mods.isEmpty else { return false }
        switch event.keyCode {
        case 125: move(by: 1); return true    // down
        case 126: move(by: -1); return true   // up
        case 36, 76:                          // Return, Enter
            guard let id = activeId, let item = vm.items.first(where: { $0.id == id }) else { return false }
            paste(item)
            return true
        default:
            return false
        }
    }

    private func move(by step: Int) {
        guard !vm.items.isEmpty else { return }
        let current = activeId.flatMap { id in vm.items.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + step, 0), vm.items.count - 1) } ?? 0
        vm.selectedId = vm.items[next].id
    }

    private func paste(_ item: ClipboardItem) {
        vm.copy(item)
        notch.requestClose()
        if !PasteService.pasteIntoFrontApp() {
            Log.info("paste: accessibility permission missing, item left in clipboard")
        }
    }

    private func edit(_ item: ClipboardItem) {
        guard let path = item.imagePath, let image = NSImage(contentsOfFile: path) else { return }
        notch.requestClose()
        // Let the panel close first, then open the editor window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            EditorWindow.open(image: image)
        }
    }
}

struct ClipboardRow: View {
    let item: ClipboardItem
    /// 1...9 for the rows ⌘1–⌘9 paste.
    var number: Int? = nil
    var selected = false
    let onCopy: (ClipboardItem) -> Void
    let onPaste: (ClipboardItem) -> Void
    let onEdit: (ClipboardItem) -> Void
    let onPin: (ClipboardItem) -> Void
    let onDelete: (ClipboardItem) -> Void
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            leading

            VStack(alignment: .leading, spacing: 2) {
                Text(item.kind == .image ? String(localized: "Image") : item.preview)
                    .font(Theme.body).foregroundColor(Theme.fg)
                    .lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if let name = item.sourceAppName {
                        Text(name).font(Theme.caption).foregroundColor(Theme.fgMute)
                        Text("·").font(Theme.caption).foregroundColor(Theme.fgMute)
                    }
                    Text(relativeTime).font(Theme.caption).foregroundColor(Theme.fgMute)
                }
            }
            Spacer()

            if copied {
                Text("Copied").font(Theme.label).foregroundColor(Theme.accent)
            }

            if let number, !hover {
                Text("⌘\(number)").font(Theme.monoSmall).foregroundColor(Theme.fgMute)
            }

            if hover || item.pinned {
                HStack(spacing: 8) {
                    if hover {
                        rowButton("arrow.turn.down.left", "Paste into the app you were using") { onPaste(item) }
                    }
                    if item.kind == .image && hover {
                        rowButton("pencil.tip.crop.circle", "Edit") { onEdit(item) }
                        rowButton("doc.on.doc", "Copy") { copy() }
                        rowButton("pip", "Pin on Screen") {
                            if let path = item.imagePath, let image = NSImage(contentsOfFile: path) {
                                PinnedImageWindow.show(image)
                            }
                        }
                    }
                    rowButton(item.pinned ? "pin.fill" : "pin", "Pin", tint: item.pinned ? Theme.accent : nil) { onPin(item) }
                    if hover {
                        rowButton("trash", "Delete") { onDelete(item) }
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.surface2 : hover ? Theme.surface : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { onPaste(item) }
        .onTapGesture {
            if item.kind == .image { onEdit(item) } else { copy() }
        }
    }

    @ViewBuilder private var leading: some View {
        if item.kind == .image, let path = item.imagePath, let image = ThumbnailCache.image(at: path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
        } else {
            Image(systemName: item.kind == .file ? "doc" : "text.alignleft")
                .foregroundColor(Theme.fgMute).font(.system(size: 12))
                .frame(width: 44, height: 20)
        }
    }

    private func rowButton(_ symbol: String, _ help: LocalizedStringKey, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundColor(tint ?? Theme.fgDim)
        }
        .buttonStyle(.plain)
        .help(Text(help))
    }

    private func copy() {
        onCopy(item)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    private var relativeTime: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
                return f.localizedString(for: item.createdAt, relativeTo: Date())
    }
}
