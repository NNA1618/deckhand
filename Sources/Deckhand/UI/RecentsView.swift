import SwiftUI

struct RecentsView: View {
    @StateObject private var vm = RecentsViewModel()

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Prompt").font(Theme.label).foregroundColor(Theme.fgMute)
                TextEditor(text: $vm.prompt)
                    .scrollContentBackground(.hidden)
                    .font(Theme.body).foregroundColor(Theme.fg)
                    .padding(9)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                if let error = vm.error {
                    Text(error).font(Theme.caption).foregroundColor(Theme.warn).lineLimit(3)
                }
                HStack(spacing: 8) {
                    if vm.improving { ProgressView().controlSize(.small) }
                    PrimaryButton(title: "Improve with Claude") { vm.improve() }
                        .disabled(vm.prompt.isEmpty || vm.improving)
                    GlassButton(title: "Copy", symbol: "doc.on.doc") { vm.copyPrompt() }
                    Spacer()
                    Link(destination: URL(string: "https://higgsfield.ai")!) {
                        Image(systemName: "arrow.up.right.square").foregroundColor(Theme.fgDim)
                    }
                    .help(Text(verbatim: "higgsfield.ai"))
                }
            }
            .frame(width: 300)

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Recent images and videos").font(Theme.label).foregroundColor(Theme.fgMute)
                    Spacer()
                    Text("Last 14 days").font(Theme.caption).foregroundColor(Theme.fgMute)
                }
                if vm.recent.isEmpty {
                    EmptyState(symbol: "photo.stack", title: "Nothing new yet",
                               hint: "Add watched folders in Settings")
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                            ForEach(vm.recent) { MediaTile(file: $0) }
                        }
                    }
                    .fadeBottom()
                }
            }
        }
        .onAppear {
            vm.scan()
            vm.loadPromptFromClipboard()
        }
    }
}

struct MediaTile: View {
    let file: MediaFile
    @State private var thumb: NSImage?
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Theme.surface
                }
            }
            .frame(width: 96, height: 72)
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
        .scaleEffect(hover ? 1.03 : 1)
        .animation(.easeOut(duration: 0.15), value: hover)
        .onHover { hover = $0 }
        .help(Text(verbatim: file.url.lastPathComponent))
        .onTapGesture(count: 2) { NSWorkspace.shared.open(file.url) }
        .onDrag { NSItemProvider(contentsOf: file.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(file.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            Button("Add to Shelf") { ShelfStore.shared.add([file.url]) }
        }
        .task(id: file.id) { thumb = await Thumbnail.make(for: file.url, size: 192) }
    }
}
