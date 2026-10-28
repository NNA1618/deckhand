import SwiftUI

struct ClipboardView: View {
    @StateObject private var vm = ClipboardViewModel()
    @EnvironmentObject var notch: NotchViewModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                SearchField(placeholder: "Search", text: $vm.search)
                Text("Click an image to edit it")
                    .font(Theme.caption).foregroundColor(Theme.fgMute)
            }

            if vm.items.isEmpty {
                if vm.search.isEmpty {
                    EmptyState(symbol: "doc.on.clipboard", title: "Clipboard is empty",
                               hint: "Copy something or capture an area with ⌘⇧S")
                } else {
                    EmptyState(symbol: "magnifyingglass", title: "No matches")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(vm.items) { item in
                            ClipboardRow(
                                item: item,
                                onCopy: { vm.copy($0) },
                                onEdit: { edit($0) },
                                onPin: { vm.togglePin($0) },
                                onDelete: { vm.delete($0) }
                            )
                        }
                    }
                }
                .fadeBottom()
            }
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
    let onCopy: (ClipboardItem) -> Void
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

            if hover || item.pinned {
                HStack(spacing: 8) {
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
                .fill(hover ? Theme.surface : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            if item.kind == .image { onEdit(item) } else { copy() }
        }
    }

    @ViewBuilder private var leading: some View {
        if item.kind == .image, let path = item.imagePath, let image = ThumbnailCache.image(at: path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 64, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.border, lineWidth: 1))
        } else {
            Image(systemName: item.kind == .file ? "doc" : "text.alignleft")
                .foregroundColor(Theme.fgMute).font(.system(size: 12))
                .frame(width: 20, height: 20)
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
