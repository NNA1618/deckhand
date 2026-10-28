import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing

struct ShelfView: View {
    @StateObject private var store = ShelfStore.shared
    @State private var targeted = false

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 120), spacing: 10)]

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("\(store.items.count) on the shelf")
                    .font(Theme.label).foregroundColor(Theme.fgMute)
                Spacer()
                if !store.items.isEmpty {
                    GlassButton(title: "AirDrop All", symbol: "airplayaudio") { airdrop(store.items.map(\.url)) }
                    GlassButton(title: "Clear", symbol: "trash") { store.clear() }
                }
            }

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
                                          onRemove: { store.remove(item) },
                                          onAirDrop: { airdrop([item.url]) })
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .animation(.easeOut(duration: 0.15), value: targeted)
            .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
                accept(providers)
                return true
            }
        }
        .onAppear { store.pruneMissing() }
    }

    private func accept(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { ShelfStore.shared.add([url]) }
            }
        }
    }

    private func airdrop(_ urls: [URL]) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
    }
}

struct ShelfTile: View {
    let item: ShelfItem
    let onRemove: () -> Void
    let onAirDrop: () -> Void
    @State private var thumb: NSImage?
    @State private var hover = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: thumb ?? NSWorkspace.shared.icon(forFile: item.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .opacity(item.exists ? 1 : 0.35)
                if hover {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.black, .white)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                }
            }
            Text(item.name)
                .font(Theme.caption).foregroundColor(Theme.fgDim)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hover ? Theme.surface2 : Color.clear)
        )
        .onHover { hover = $0 }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("AirDrop") { onAirDrop() }
            Divider()
            Button("Remove from Shelf") { onRemove() }
        }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .task(id: item.path) { thumb = await Thumbnail.make(for: item.url, size: 144) }
    }
}

enum Thumbnail {
    static func make(for url: URL, size: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: 2,
            representationTypes: .thumbnail
        )
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
