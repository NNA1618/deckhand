import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing

/// The Shelf: files dropped on the notch, kept until dragged on. Click selects (⌘ and ⇧ add),
/// a drag carries the whole selection, Space shows Quick Look.
struct ShelfView: View {
    @ObservedObject private var store = ShelfStore.shared
    @ObservedObject private var settings = ShelfSettings.shared
    @EnvironmentObject private var notch: NotchViewModel
    @State private var targeted = false
    @State private var anchor: UUID?
    @State private var keyMonitor: Any?

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 120), spacing: 10)]

    private var actionIds: Set<UUID> { store.selection.isEmpty ? Set(store.items.map(\.id)) : store.selection }

    var body: some View {
        VStack(spacing: 10) {
            if !store.items.isEmpty { header }

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        targeted ? Theme.accent : Theme.border,
                        style: StrokeStyle(lineWidth: 1, dash: store.items.isEmpty || targeted ? [5, 4] : [])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(targeted ? Theme.accentSoft : Theme.surface.opacity(0.5))
                    )

                if store.items.isEmpty {
                    EmptyState(symbol: "tray.and.arrow.down", title: "Drop files on the notch or here",
                               hint: "Then drag them anywhere you need")
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(store.items) { item in
                                ShelfTile(item: item,
                                          selected: store.selection.contains(item.id),
                                          reachable: !store.unreachable.contains(item.id),
                                          onClick: { click(item, $0) },
                                          menu: { menu(for: item) })
                            }
                        }
                        .padding(12)
                    }
                    // A click on empty space clears the selection
                    .background(Color.clear.contentShape(Rectangle()).onTapGesture { store.selection = [] })
                    .fadeBottom()
                }
            }
            .animation(.easeOut(duration: 0.15), value: targeted)
            .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
                // Tiles dragged out and dropped back here stay where they are
                guard store.draggingOut.isEmpty else { return false }
                accept(providers)
                return true
            }

            if !store.lastRemoved.isEmpty {
                StatusBar(text: removedText, buttonTitle: "Undo") { store.undoRemove() }
            }
        }
        .onAppear {
            store.refresh()
            installKeys()
        }
        .onDisappear(perform: removeKeys)
    }

    private var removedText: String {
        let n = store.lastRemoved.count
        return n == 1 ? String(localized: "Removed “\(store.lastRemoved[0].name)”") : String(localized: "Removed from the shelf: \(n)")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(store.selection.isEmpty
                 ? String(localized: "\(store.items.count) on the shelf")
                 : String(localized: "Selected: \(store.selection.count)"))
                .font(Theme.label).foregroundColor(Theme.fgMute)
                .lineLimit(1)
            Spacer()
            DragAllHandle(title: store.selection.isEmpty ? "Drag All" : "Drag Selected",
                          urls: { store.urls(for: actionIds) },
                          onDragStart: { store.draggingOut = actionIds },
                          onDragEnd: { ended(actionIds, $0) })
            ShareLink(items: store.urls(for: actionIds)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .medium)).foregroundColor(Theme.fg)
                    .frame(width: 28, height: 26)
                    .contentShape(Capsule())
                    .glassChip(in: Capsule(), interactive: true)
            }
            .buttonStyle(.plain)
            .help(Text("Share…"))
            Button { airdrop(store.urls(for: actionIds)) } label: {
                AirDropIcon(size: 15)
                    .frame(width: 28, height: 26)
                    .contentShape(Capsule())
                    .glassChip(in: Capsule(), interactive: true)
            }
            .buttonStyle(.plain)
            .help(Text("Send with AirDrop"))
            .accessibilityLabel(Text("Send with AirDrop"))
            GlassButton(title: store.selection.isEmpty ? "Clear" : "Remove", symbol: "xmark") {
                store.remove(actionIds)
            }
            .help(Text(store.selection.isEmpty ? "Take every file off the shelf. The files themselves stay." : "Take the selected files off the shelf. The files themselves stay."))
        }
    }

    // MARK: Selection

    private func click(_ item: ShelfItem, _ mods: NSEvent.ModifierFlags) {
        if mods.contains(.command) {
            if store.selection.contains(item.id) { store.selection.remove(item.id) } else { store.selection.insert(item.id) }
            anchor = item.id
        } else if mods.contains(.shift), let anchor, let a = store.items.firstIndex(where: { $0.id == anchor }),
                  let b = store.items.firstIndex(where: { $0.id == item.id }) {
            store.selection = Set(store.items[min(a, b)...max(a, b)].map(\.id))
        } else {
            store.selection = [item.id]
            anchor = item.id
        }
    }

    private func menu(for item: ShelfItem) -> NSMenu {
        if !store.selection.contains(item.id) { store.selection = [item.id] }
        let ids = store.targetIds(for: item)
        let urls = store.urls(for: ids)
        let menu = NSMenu()
        let reachable = !urls.isEmpty
        let several = ids.count > 1
        func add(_ title: String, _ symbol: String?, enabled: Bool = true, _ action: @escaping () -> Void) {
            let mi = ActionMenuItem(title, symbol: symbol, handler: action)
            mi.isEnabled = enabled
            menu.addItem(mi)
        }
        menu.autoenablesItems = false
        add(String(localized: "Open"), "arrow.up.forward.app", enabled: reachable) {
            urls.forEach { NSWorkspace.shared.open($0) }
        }
        add(String(localized: "Quick Look"), "eye", enabled: reachable) { QuickLook.shared.show(urls, notch: notch) }
        add(String(localized: "Show in Finder"), "folder", enabled: reachable) {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        menu.addItem(.separator())
        add(String(localized: "Copy"), "doc.on.doc", enabled: reachable) { copy(urls) }
        add(String(localized: "Send with AirDrop"), nil, enabled: reachable) { airdrop(urls) }
        if !several, reachable, let type = UTType(filenameExtension: item.url.pathExtension), type.conforms(to: .image) {
            add(String(localized: "Copy Text from Image"), "text.viewfinder") {
                Task { @MainActor in _ = await TextRecognizer.copyText(fromFile: item.url) }
            }
        }
        menu.addItem(.separator())
        add(String(localized: "Remove from Shelf"), "xmark") { store.remove(ids) }
        return menu
    }

    // MARK: Actions

    private func ended(_ ids: Set<UUID>, _ operation: NSDragOperation) {
        store.draggingOut = []
        if settings.removeAfterDrag, !operation.isEmpty { store.remove(ids) }
    }

    /// Loads every dropped file, then adds them in the order they were dragged.
    private func accept(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let results = DropResults(count: providers.count)
        for (i, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                results.set(url, at: i)
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { ShelfStore.shared.add(results.urls) }
        }
    }

    private func copy(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    /// The AirDrop window would open behind the panel, so the panel closes first.
    private func airdrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        notch.requestClose()
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { service.perform(withItems: urls) }
    }

    // MARK: Keyboard

    private func installKeys() {
        removeKeys()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window is NotchWindow else { return event }
            return MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let selected = store.urls(for: store.selection)
        switch (event.keyCode, mods) {
        case (49, []) where !selected.isEmpty:                        // Space
            let order = store.items.filter { store.selection.contains($0.id) }.map(\.url)
            QuickLook.shared.toggle(order, notch: notch)
            return true
        case (0, .command):                                           // ⌘A
            store.selection = Set(store.items.map(\.id))
            return true
        case (8, .command) where !selected.isEmpty:                   // ⌘C
            copy(selected)
            return true
        case (51, []), (117, []), (51, .command):                     // Delete
            guard !store.selection.isEmpty else { return false }
            store.remove(store.selection)
            return true
        default:
            return false
        }
    }
}

/// Collects dropped URLs from loader callbacks on any thread, keeping their positions.
private final class DropResults: @unchecked Sendable {
    private var slots: [URL?]
    private let lock = NSLock()
    init(count: Int) { slots = Array(repeating: nil, count: count) }
    func set(_ url: URL?, at i: Int) { lock.withLock { slots[i] = url } }
    var urls: [URL] { lock.withLock { slots.compactMap { $0 } } }
}

struct ShelfTile: View {
    let item: ShelfItem
    let selected: Bool
    let reachable: Bool
    let onClick: (NSEvent.ModifierFlags) -> Void
    let menu: () -> NSMenu
    @ObservedObject private var store = ShelfStore.shared
    @ObservedObject private var settings = ShelfSettings.shared
    @EnvironmentObject private var notch: NotchViewModel
    @State private var thumb: NSImage?
    @State private var hover = false

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: thumb ?? NSWorkspace.shared.icon(forFile: item.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(reachable ? 1 : 0.35)
                .overlay(alignment: .bottomTrailing) {
                    if !reachable {
                        Image(systemName: "questionmark.circle.fill")
                            .font(.system(size: 14)).foregroundStyle(.white, .black.opacity(0.6))
                    }
                }
            Text(item.name)
                .font(Theme.caption).foregroundColor(selected ? Theme.fg : Theme.fgDim)
                .lineLimit(2).multilineTextAlignment(.center).truncationMode(.middle)
                .frame(height: 28, alignment: .top)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Theme.accentSoft : hover ? Theme.surface2 : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(selected ? Theme.accent.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .overlay {
            FileTileInteraction(
                urls: { store.urls(for: store.targetIds(for: item)) },
                onClick: onClick,
                onDoubleClick: { if reachable { NSWorkspace.shared.open(item.url) } },
                onHover: { hover = $0 },
                menu: menu,
                onDragStart: { store.draggingOut = store.targetIds(for: item) },
                onDragEnd: { op in
                    let ids = store.targetIds(for: item)
                    store.draggingOut = []
                    if settings.removeAfterDrag, !op.isEmpty { store.remove(ids) }
                }
            )
        }
        .overlay(alignment: .topTrailing) {
            if hover {
                Button { store.remove([item.id]) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.black, .white)
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .help(Text("Remove from Shelf"))
            }
        }
        .help(reachable ? Text(verbatim: (item.path as NSString).abbreviatingWithTildeInPath)
                        : Text("Can't find this file. It may be in the Trash or on a drive that isn't connected."))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: item.name))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onClick([]) }
        .task(id: item.path) { thumb = await Thumbnail.make(for: item.url, size: 144) }
    }
}

/// The real AirDrop icon from the sharing service (SF Symbols has none), or a fallback glyph.
struct AirDropIcon: View {
    var size: CGFloat
    private static let image: NSImage? = NSSharingService(named: .sendViaAirDrop)?.image

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: size, height: size)
        } else {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: size * 0.75, weight: .medium))
                .foregroundColor(Theme.fg)
        }
    }
}

/// "Drag All" as a handle: dragging it carries every file (or the selection) at once.
private struct DragAllHandle: View {
    let title: LocalizedStringKey
    let urls: () -> [URL]
    let onDragStart: () -> Void
    let onDragEnd: (NSDragOperation) -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "hand.draw").font(.system(size: 11, weight: .medium))
            Text(title).font(Theme.label).lineLimit(1)
        }
        .foregroundColor(Theme.fg)
        .padding(.horizontal, 11).padding(.vertical, 6)
        .glassChip(in: Capsule())
        .opacity(hover ? 1 : 0.9)
        .overlay {
            FileTileInteraction(urls: urls, onHover: { hover = $0 }, onDragStart: onDragStart, onDragEnd: onDragEnd)
        }
        .help(Text("Drag from here to move all these files at once"))
        .fixedSize()
    }
}

/// QuickLook thumbnails, cached by file, size and modification date so reopening the panel is instant.
enum Thumbnail {
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {   // NSCache is thread-safe
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 400
        return c
    }()

    static func make(for url: URL, size: CGFloat) async -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)#\(Int(size))#\(modified?.timeIntervalSince1970 ?? 0)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: 2,
            representationTypes: .thumbnail
        )
        guard let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage else {
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }
}
