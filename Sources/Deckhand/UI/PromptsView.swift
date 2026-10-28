import SwiftUI

struct PromptsView: View {
    @StateObject private var vm = PromptsViewModel()

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                SearchField(placeholder: "Search", text: $vm.search)
                Button { vm.create() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.fg)
                        .frame(width: 30, height: 30)
                        .glassChip(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .help(Text("New Prompt"))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(vm.categories, id: \.self) { cat in
                        Button { vm.selectedCategory = cat } label: {
                            Chip(text: cat == PromptsViewModel.allKey ? String(localized: "All") : cat,
                                 active: vm.selectedCategory == cat)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // List
            if vm.prompts.isEmpty {
                EmptyState(symbol: "text.quote", title: "No matches")
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(vm.prompts) { p in
                            PromptRow(prompt: p,
                                      onCopy: { vm.copy($0) },
                                      onFavorite: { vm.toggleFavorite($0) },
                                      onDelete: { vm.delete($0) },
                                      onEdit: { vm.editing = $0 })
                        }
                    }
                }
            }
        }
        .sheet(item: $vm.editing) { p in
            PromptEditor(prompt: p, onSave: { vm.save($0) })
                .frame(minWidth: 480, minHeight: 400)
        }
    }
}

struct PromptRow: View {
    let prompt: Prompt
    let onCopy: (Prompt) -> Void
    let onFavorite: (Prompt) -> Void
    let onDelete: (Prompt) -> Void
    let onEdit: (Prompt) -> Void
    @State private var isHover = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: prompt.favorite ? "star.fill" : "doc.text")
                .foregroundColor(prompt.favorite ? Theme.accent : Theme.fgMute)
                .font(.system(size: 12)).frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(prompt.title).font(Theme.body).foregroundColor(Theme.fg)
                    Text(prompt.category).font(Theme.caption)
                        .foregroundColor(Theme.fgMute)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Theme.surface2).cornerRadius(3)
                }
                Text(prompt.body).font(Theme.caption).foregroundColor(Theme.fgDim)
                    .lineLimit(1)
            }
            Spacer()
            if isHover {
                HStack(spacing: 6) {
                    Button(action: { onFavorite(prompt) }) {
                        Image(systemName: prompt.favorite ? "star.fill" : "star")
                            .foregroundColor(prompt.favorite ? Theme.accent : Theme.fgMute)
                            .font(.system(size: 11))
                    }.buttonStyle(.plain)
                    Button(action: { onEdit(prompt) }) {
                        Image(systemName: "pencil")
                            .foregroundColor(Theme.fgMute).font(.system(size: 11))
                    }.buttonStyle(.plain)
                    Button(action: { onDelete(prompt) }) {
                        Image(systemName: "trash")
                            .foregroundColor(Theme.fgMute).font(.system(size: 11))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHover ? Theme.surface : Color.clear))
        .contentShape(Rectangle())
        .onHover { isHover = $0 }
        .onTapGesture { onCopy(prompt) }
    }
}

struct PromptEditor: View {
    @State var prompt: Prompt
    let onSave: (Prompt) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit Prompt").font(Theme.title).foregroundColor(Theme.fg)
            TextField("Title", text: $prompt.title)
                .textFieldStyle(.plain).font(Theme.body)
                .padding(8).background(Theme.surface2).cornerRadius(6)
            TextField("Category", text: $prompt.category)
                .textFieldStyle(.plain).font(Theme.body)
                .padding(8).background(Theme.surface2).cornerRadius(6)
            TextEditor(text: $prompt.body)
                .scrollContentBackground(.hidden)
                .padding(8).font(Theme.body).foregroundColor(Theme.fg)
                .background(Theme.surface2).cornerRadius(6)
                .frame(minHeight: 180)
            HStack {
                Toggle(isOn: $prompt.favorite) { Text("Favorite").font(Theme.body) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(prompt)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .background(Theme.bg)
    }
}
