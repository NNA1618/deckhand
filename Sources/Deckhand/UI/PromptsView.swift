import SwiftUI

/// The Prompts tab: the library, an inline editor and the `{{variable}}` form.
/// Everything lives in the shared view model, so closing the panel loses nothing.
struct PromptsView: View {
    @ObservedObject private var vm = PromptsViewModel.shared
    @ObservedObject private var settings = PromptSettings.shared
    @EnvironmentObject private var notch: NotchViewModel

    var body: some View {
        Group {
            if vm.draft != nil {
                PromptEditor(vm: vm)
                    .holdsPanelOpen("prompt-editor")
            } else if vm.fill != nil {
                PromptFillForm(vm: vm, close: notch.requestClose)
                    .holdsPanelOpen("prompt-fill")
            } else {
                PromptList(vm: vm)
            }
        }
        .onAppear { vm.refresh(resort: true) }
    }
}

// MARK: - List

private struct PromptList: View {
    @ObservedObject var vm: PromptsViewModel
    @ObservedObject private var settings = PromptSettings.shared
    @EnvironmentObject private var notch: NotchViewModel
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                SearchField(placeholder: "Search", text: $vm.search, focusOnAppear: true)
                Button { vm.newDraft() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.fg)
                        .frame(width: 30, height: 30)
                        .glassChip(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .help(Text("New Prompt"))
                .accessibilityLabel(Text("New Prompt"))
            }

            if !vm.categories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        chip(nil)
                        ForEach(vm.categories, id: \.self) { chip($0) }
                    }
                }
            }

            content

            if let deleted = vm.deleted {
                StatusBar(text: String(localized: "Deleted “\(deleted.title)”"), buttonTitle: "Undo") { vm.undoDelete() }
            } else if let notice = vm.notice {
                StatusBar(text: notice, buttonTitle: "Allow…") {
                    vm.notice = nil
                    notch.requestClose()
                    SettingsWindow.show(.permissions)
                } onDismiss: { vm.notice = nil }
            }
        }
        .onAppear(perform: installKeys)
        .onDisappear(perform: removeKeys)
    }

    private func chip(_ category: String?) -> some View {
        Button { vm.selectedCategory = category } label: {
            Chip(text: category ?? String(localized: "All"), active: vm.selectedCategory == category)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var content: some View {
        if vm.libraryIsEmpty {
            VStack(spacing: 10) {
                EmptyState(symbol: "text.quote", title: "No prompts yet",
                           hint: "Save prompts you use often and copy them in one click.")
                    .frame(maxHeight: 150)
                HStack(spacing: 8) {
                    PrimaryButton(title: "New Prompt") { vm.newDraft() }
                    GlassButton(title: "Add Starter Prompts", symbol: "sparkles") {
                        PromptStore.shared.addStarters()
                        vm.refresh(resort: true)
                    }
                }
                Spacer()
            }
        } else if vm.prompts.isEmpty {
            EmptyState(symbol: "magnifyingglass", title: "No matches")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(vm.prompts.enumerated()), id: \.element.id) { index, p in
                            PromptRow(prompt: p,
                                      number: index < 9 ? index + 1 : nil,
                                      selected: p.id == vm.selectedId,
                                      flash: vm.flash?.id == p.id ? vm.flash?.text : nil,
                                      action: settings.clickAction,
                                      onUse: { vm.activate($0, close: notch.requestClose) },
                                      onAlternate: { vm.activate($0, action: settings.clickAction == .copy ? .paste : .copy,
                                                                 close: notch.requestClose) },
                                      onFavorite: { vm.toggleFavorite($0) },
                                      onDelete: { vm.delete($0) },
                                      onEdit: { vm.edit($0) })
                                .id(p.id)
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

    // MARK: Keyboard

    private static let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]   // 1...9

    private func installKeys() {
        removeKeys()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only keys typed into the panel; Settings and other windows keep theirs
            guard event.window is NotchWindow else { return event }
            return MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// The row Return uses: the one picked with the arrows, or the top match while searching.
    private var activePrompt: Prompt? {
        if let id = vm.selectedId, let p = vm.prompts.first(where: { $0.id == id }) { return p }
        return vm.search.isEmpty ? nil : vm.prompts.first
    }

    private func handle(_ event: NSEvent) -> Bool {
        // Keep input methods (Chinese, Japanese) composing in the search field
        if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods == .command, let n = Self.digitKeyCodes.firstIndex(of: event.keyCode) {
            guard n < vm.prompts.count else { return false }
            vm.activate(vm.prompts[n], close: notch.requestClose)
            return true
        }
        if mods == .command, event.keyCode == 45 {   // ⌘N
            vm.newDraft()
            return true
        }
        guard mods.isEmpty || mods == .option else { return false }
        switch event.keyCode {
        case 125 where mods.isEmpty: move(by: 1); return true    // down
        case 126 where mods.isEmpty: move(by: -1); return true   // up
        case 36, 76:                                             // Return, Enter; ⌥ does the other action
            guard let p = activePrompt else { return false }
            let other: PromptClickAction = settings.clickAction == .copy ? .paste : .copy
            vm.activate(p, action: mods == .option ? other : nil, close: notch.requestClose)
            return true
        default:
            return false
        }
    }

    private func move(by step: Int) {
        guard !vm.prompts.isEmpty else { return }
        let current = vm.selectedId.flatMap { id in vm.prompts.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + step, 0), vm.prompts.count - 1) } ?? 0
        vm.selectedId = vm.prompts[next].id
    }
}

struct PromptRow: View {
    let prompt: Prompt
    var number: Int?
    var selected = false
    /// A confirmation such as "Copied", shown for a moment after a click.
    var flash: String?
    let action: PromptClickAction
    let onUse: (Prompt) -> Void
    let onAlternate: (Prompt) -> Void
    let onFavorite: (Prompt) -> Void
    let onDelete: (Prompt) -> Void
    let onEdit: (Prompt) -> Void
    @State private var isHover = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: prompt.favorite ? "star.fill" : "text.quote")
                .foregroundColor(prompt.favorite ? Theme.accent : Theme.fgMute)
                .font(.system(size: 12)).frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(prompt.title).font(Theme.body).foregroundColor(Theme.fg).lineLimit(1)
                    Text(prompt.category).font(Theme.caption)
                        .foregroundColor(Theme.fgMute).lineLimit(1)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .layoutPriority(-1)
                }
                Text(prompt.body).font(Theme.caption).foregroundColor(Theme.fgDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let flash {
                Label(flash, systemImage: "checkmark")
                    .font(Theme.label).foregroundColor(Theme.accent)
                    .transition(.opacity)
            } else if isHover {
                HStack(spacing: 10) {
                    rowButton(action == .copy ? "arrow.turn.down.left" : "doc.on.doc",
                              action == .copy ? "Paste into the app you were using" : "Copy") { onAlternate(prompt) }
                    rowButton(prompt.favorite ? "star.fill" : "star",
                              prompt.favorite ? "Remove from Favorites" : "Add to Favorites",
                              tint: prompt.favorite ? Theme.accent : nil) { onFavorite(prompt) }
                    rowButton("pencil", "Edit") { onEdit(prompt) }
                    rowButton("trash", "Delete") { onDelete(prompt) }
                }
            } else if let number {
                Text(verbatim: "⌘\(number)").font(Theme.monoSmall).foregroundColor(Theme.fgMute)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.surface2 : isHover ? Theme.surface : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHover = $0 }
        .onTapGesture { onUse(prompt) }
        .animation(.easeOut(duration: 0.12), value: flash)
        .help(Text(action == .copy ? "Click to copy" : "Click to paste into the app you were using"))
        .contextMenu {
            Button("Copy") { if action == .copy { onUse(prompt) } else { onAlternate(prompt) } }
            Button("Paste into the app you were using") { if action == .paste { onUse(prompt) } else { onAlternate(prompt) } }
            Divider()
            Button(prompt.favorite ? "Remove from Favorites" : "Add to Favorites") { onFavorite(prompt) }
            Button("Edit") { onEdit(prompt) }
            Divider()
            Button("Delete") { onDelete(prompt) }
        }
    }

    private func rowButton(_ symbol: String, _ help: LocalizedStringKey, tint: Color? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundColor(tint ?? Theme.fgDim)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }
}

// MARK: - Editor

/// Edits a draft in place of the list. The panel stays open while it shows.
private struct PromptEditor: View {
    @ObservedObject var vm: PromptsViewModel
    @FocusState private var focus: Field?

    private enum Field { case title, body }

    private var draft: Binding<PromptDraft> {
        Binding(get: { vm.draft ?? PromptDraft() }, set: { vm.draft = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(vm.draft?.id == nil ? "New Prompt" : "Edit Prompt")
                    .font(Theme.title).foregroundColor(Theme.fg)
                Spacer()
                GlassButton(title: "Cancel") { vm.cancelDraft() }
                    .keyboardShortcut(".", modifiers: .command)
                PrimaryButton(title: "Save") { vm.saveDraft() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!(vm.draft?.canSave ?? false))
                    .opacity(vm.draft?.canSave ?? false ? 1 : 0.5)
            }
            HStack(spacing: 8) {
                field("Title", text: draft.title)
                    .focused($focus, equals: .title)
                HStack(spacing: 4) {
                    TextField("Category", text: draft.category, prompt: Text(PromptLibrary.defaultCategory))
                        .textFieldStyle(.plain).font(Theme.body).foregroundColor(Theme.fg)
                    Menu {
                        ForEach(vm.categoryChoices, id: \.self) { name in
                            Button(name) { vm.draft?.category = name }
                        }
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(Text("Choose a category"))
                }
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(width: 190)
                field("Tags, separated by commas", text: draft.tagsText)
                    .frame(width: 190)
            }
            TextEditor(text: draft.body)
                .scrollContentBackground(.hidden)
                .font(Theme.body).foregroundColor(Theme.fg)
                .padding(8)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .focused($focus, equals: .body)
                .frame(maxHeight: .infinity)
            if vm.pendingDraftBody != nil {
                StatusBar(text: String(localized: "Your unsaved prompt is kept. Replace it with the new text?"),
                          buttonTitle: "Replace") { vm.replaceDraftWithPending() } onDismiss: { vm.keepDraft() }
            }
            HStack(spacing: 10) {
                Toggle(isOn: draft.favorite) { Text("Favorite").font(Theme.label).foregroundColor(Theme.fgDim) }
                    .toggleStyle(.checkbox)
                Spacer()
                Text("Write {{name}} for a part you fill in each time.")
                    .font(Theme.caption).foregroundColor(Theme.fgMute)
                    .lineLimit(1)
            }
        }
        .onAppear { focus = vm.draft?.id == nil ? .title : .body }
    }

    private func field(_ placeholder: LocalizedStringKey, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(Theme.body).foregroundColor(Theme.fg)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Variables

/// Asks for each `{{variable}}`, shows the result, then copies or pastes it.
private struct PromptFillForm: View {
    @ObservedObject var vm: PromptsViewModel
    let close: () -> Void
    @FocusState private var focused: String?

    var body: some View {
        if let fill = vm.fill {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(fill.prompt.title).font(Theme.title).foregroundColor(Theme.fg).lineLimit(1)
                    Spacer()
                    GlassButton(title: "Cancel") { vm.fill = nil }
                        .keyboardShortcut(".", modifiers: .command)
                    PrimaryButton(title: fill.action == .copy ? "Copy" : "Paste") { vm.finishFill(close: close) }
                        .keyboardShortcut(.return, modifiers: .command)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(fill.names, id: \.self) { name in
                            HStack(spacing: 10) {
                                Text(verbatim: name).font(Theme.label).foregroundColor(Theme.fgDim)
                                    .lineLimit(1).truncationMode(.middle)
                                    .frame(width: 130, alignment: .trailing)
                                TextField(text: binding(name), prompt: Text(verbatim: name)) { Text(verbatim: name) }
                                    .textFieldStyle(.plain).font(Theme.body).foregroundColor(Theme.fg)
                                    .padding(.horizontal, 9).padding(.vertical, 6)
                                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .focused($focused, equals: name)
                                    .onSubmit { next(after: name, in: fill.names) }
                            }
                        }
                    }
                }
                .frame(maxHeight: CGFloat(min(fill.names.count, 4)) * 36)
                Text("Result").font(Theme.label).foregroundColor(Theme.fgMute)
                ScrollView {
                    Text(fill.text)
                        .font(Theme.body).foregroundColor(Theme.fgDim)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(maxHeight: .infinity)
            }
            .onAppear { focused = fill.names.first }
        }
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { vm.fill?.values[name] ?? "" }, set: { vm.fill?.values[name] = $0 })
    }

    /// Return moves to the next field, and from the last one copies or pastes.
    private func next(after name: String, in names: [String]) {
        if let i = names.firstIndex(of: name), i + 1 < names.count {
            focused = names[i + 1]
        } else {
            vm.finishFill(close: close)
        }
    }
}

// MARK: - Shared pieces

/// A one-line message under a list with an action, e.g. "Deleted … Undo".
struct StatusBar: View {
    let text: String
    let buttonTitle: LocalizedStringKey
    let action: () -> Void
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(Theme.caption).foregroundColor(Theme.fgDim)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Button(action: action) {
                Text(buttonTitle).font(Theme.label).foregroundColor(Theme.fg)
            }
            .buttonStyle(.plain)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.fgMute)
                }
                .buttonStyle(.plain)
                .help(Text("Dismiss"))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.surface, in: Capsule())
        .transition(.opacity)
    }
}

extension View {
    /// Keeps the panel open while this view shows, so pointer movement or a click in another app
    /// doesn't throw away what the user is doing. Esc and the shortcut still close it.
    func holdsPanelOpen(_ reason: String) -> some View {
        modifier(HoldsPanelOpen(reason: reason))
    }
}

private struct HoldsPanelOpen: ViewModifier {
    let reason: String
    @EnvironmentObject private var notch: NotchViewModel

    func body(content: Content) -> some View {
        content
            .onAppear { notch.holds.insert(reason) }
            .onDisappear { notch.holds.remove(reason) }
    }
}
