import SwiftUI
import ApplicationServices

/// Translate tab: the text and its source language on the left, the translation and its target
/// language on the right. All state lives in `TranslatorViewModel.shared`, so it survives the panel closing.
struct TranslatorView: View {
    @ObservedObject private var vm = TranslatorViewModel.shared
    @ObservedObject private var settings = TranslateSettings.shared
    @ObservedObject private var catalog = TranslationCatalog.shared
    @EnvironmentObject private var notch: NotchViewModel
    @State private var picking: Side?
    @FocusState private var inputFocused: Bool

    enum Side { case source, target }
    /// The space between the two columns, where Swap sits.
    private let gap: CGFloat = 36

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                sourceHeader.frame(maxWidth: .infinity, alignment: .leading)
                swapButton.frame(width: gap)
                targetHeader.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 0) {
                inputCard.frame(maxWidth: .infinity, maxHeight: .infinity)
                Color.clear.frame(width: gap)
                outputCard.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay { languageListOverlay }
        }
        .onAppear {
            catalog.loadIfNeeded()
            vm.prefillIfNeeded()
            inputFocused = true
        }
    }

    // MARK: - Headers

    private var sourceHeader: some View {
        LanguageButton(title: sourceTitle, open: picking == .source) { toggle(.source) }
            .help(vm.sourceMode == .detect ? Text("Detected automatically. Click to choose the language.") : Text("Language of the text"))
    }

    private var sourceTitle: String {
        guard vm.sourceMode == .detect else { return vm.source.map { TranslationLanguages.name(of: $0) } ?? "" }
        guard let detected = vm.detected else { return String(localized: "Detect Language") }
        return String(localized: "\(TranslationLanguages.name(of: detected)) (detected)")
    }

    private var swapButton: some View {
        Button { vm.swap() } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.fgDim)
                .frame(width: 26, height: 26)
                .glassChip(in: Circle(), interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(Text("Swap languages"))
        .accessibilityLabel(Text("Swap languages"))
    }

    private var targetHeader: some View {
        HStack(spacing: 6) {
            LanguageButton(title: TranslationLanguages.name(of: vm.target), open: picking == .target) { toggle(.target) }
                .help(Text("Language of the translation"))
            ViewThatFits(in: .horizontal) {
                favoriteChips(3)
                favoriteChips(2)
                favoriteChips(1)
                Color.clear.frame(width: 0, height: 0)
            }
            Spacer(minLength: 0)
            if vm.phase == .translating || vm.phase == .downloading {
                ProgressView().controlSize(.small)
            }
        }
    }

    /// One-click targets: favorite languages other than the current ones.
    private func favoriteChips(_ count: Int) -> some View {
        let codes = settings.favorites
            .filter { $0 != vm.target && $0 != vm.source && catalog.codes.contains($0) }
            .prefix(count)
        return HStack(spacing: 4) {
            ForEach(Array(codes), id: \.self) { code in
                Button { vm.chooseTarget(code) } label: {
                    Text(TranslationLanguages.name(of: code))
                        .font(Theme.label)
                        .foregroundColor(Theme.fgDim)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Theme.surface))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(Text("Translate into \(TranslationLanguages.name(of: code))"))
            }
        }
    }

    // MARK: - Input

    private var inputCard: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $vm.input)
                    .scrollContentBackground(.hidden)
                    .font(Theme.body)
                    .foregroundColor(Theme.fg)
                    .focused($inputFocused)
                    .padding(8)
                if vm.input.isEmpty {
                    Text("Type or paste text")
                        .font(Theme.body)
                        .foregroundColor(Theme.fgMute)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: 8) {
                if let notice = vm.notice { noticeView(notice) }
                Spacer(minLength: 0)
                if !vm.input.isEmpty {
                    Button { vm.input = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.fgMute)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text("Clear"))
                    .accessibilityLabel(Text("Clear"))
                }
                PrimaryButton(title: "\(String(localized: "translate.action", defaultValue: "Translate"))") {
                    vm.translate(force: true)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(vm.input.isEmpty)
                .opacity(vm.input.isEmpty ? 0.5 : 1)
                .help(Text("Translate now (\("⌘↩"))"))
            }
            .padding(8)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func noticeView(_ notice: TranslatorViewModel.Notice) -> some View {
        HStack(spacing: 6) {
            Text(noticeText(notice))
                .font(Theme.caption)
                .foregroundColor(notice == .usedClipboard || notice == .nothingSelected ? Theme.fgMute : Theme.warn)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if notice == .selectionNeedsAccessibility || notice == .pasteNeedsAccessibility {
                Button {
                    AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                } label: {
                    Text("Allow").font(Theme.label).foregroundColor(Theme.fg)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .glassChip(in: Capsule(), interactive: true)
                        .fixedSize()
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func noticeText(_ notice: TranslatorViewModel.Notice) -> LocalizedStringKey {
        switch notice {
        case .usedClipboard: return "Nothing was selected, so this is the copied text."
        case .nothingSelected: return "Select text in any app, then press the shortcut."
        case .selectionNeedsAccessibility: return "To read selected text, allow Deckhand in Accessibility."
        case .pasteNeedsAccessibility: return "To paste into other apps, allow Deckhand in Accessibility."
        }
    }

    // MARK: - Output

    private var outputCard: some View {
        VStack(spacing: 0) {
            Group {
                if case .failed(let failure) = vm.phase {
                    failureView(failure)
                } else if vm.phase == .downloading {
                    statusLine("Waiting for the download…")
                } else if !vm.output.isEmpty {
                    ScrollView {
                        Text(vm.output)
                            .font(Theme.body)
                            .foregroundColor(Theme.fg)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Lines up with the text in the input field
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                    }
                    .opacity(vm.phase == .translating ? 0.55 : 1)
                } else if vm.phase == .translating {
                    statusLine("Translating…")
                } else {
                    Text("The translation appears here")
                        .font(Theme.body)
                        .foregroundColor(Theme.fgMute)
                        .padding(12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if showsOutputActions { outputActions }
        }
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var showsOutputActions: Bool {
        if case .failed = vm.phase { return false }
        return !vm.output.isEmpty && vm.phase != .downloading
    }

    private var outputActions: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Button { vm.speak() } label: {
                Image(systemName: vm.speaker.isSpeaking ? "stop.fill" : "speaker.wave.2")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.fg)
                    .frame(width: 26, height: 26)
                    .glassChip(in: Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!vm.canSpeak)
            .opacity(vm.canSpeak ? 1 : 0.4)
            .help(vm.canSpeak ? speakLabel : Text("No voice for this language"))
            .accessibilityLabel(speakLabel)
            GlassButton(title: "Paste", symbol: "arrow.down.doc") {
                vm.pasteOutput { notch.requestClose() }
            }
            .help(pasteHelp)
            GlassButton(title: vm.justCopied ? "Copied" : "Copy", symbol: vm.justCopied ? "checkmark" : "doc.on.doc") {
                vm.copyOutput()
            }
            .help(Text("Copy the translation"))
        }
        .padding(8)
    }

    private var speakLabel: Text { vm.speaker.isSpeaking ? Text("Stop") : Text("Speak") }

    private var pasteHelp: Text {
        if let name = TranslatorCoordinator.pasteTarget?.localizedName {
            return Text("Paste into \(name)")
        }
        return Text("Paste into the app you were using")
    }

    private func statusLine(_ text: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(Theme.body).foregroundColor(Theme.fgMute)
        }
        .padding(12)
    }

    private func failureView(_ failure: TranslationFailure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(failureText(failure))
                .font(Theme.body)
                .foregroundColor(Theme.fgDim)
                .fixedSize(horizontal: false, vertical: true)
            switch failure {
            case .needsDownload:
                Text("Translation works offline after a one-time download.")
                    .font(Theme.caption)
                    .foregroundColor(Theme.fgMute)
                    .fixedSize(horizontal: false, vertical: true)
                PrimaryButton(title: "Download…") {
                    notch.requestClose()
                    vm.downloadLanguages { TranslatorCoordinator.showTab() }
                }
            case .timedOut, .failed:
                GlassButton(title: "Try Again", symbol: "arrow.clockwise") { vm.translate(force: true) }
            case .unsupported, .sameLanguage, .unrecognized:
                EmptyView()
            }
        }
        .padding(12)
    }

    private func failureText(_ failure: TranslationFailure) -> String {
        let source = vm.source.map { TranslationLanguages.name(of: $0) } ?? ""
        let target = TranslationLanguages.name(of: vm.target)
        switch failure {
        case .needsDownload: return String(localized: "\(source) → \(target) isn't downloaded on this Mac yet.")
        case .unsupported: return String(localized: "Apple Translation can't translate from \(source) into \(target).")
        case .sameLanguage: return String(localized: "Choose two different languages.")
        case .unrecognized: return String(localized: "Couldn't recognize the language. Choose it above.")
        case .timedOut: return String(localized: "Translation is taking too long.")
        case .failed: return String(localized: "Couldn't translate this text.")
        }
    }

    // MARK: - Language list

    private func toggle(_ side: Side) {
        withAnimation(.easeOut(duration: 0.15)) { picking = picking == side ? nil : side }
    }

    @ViewBuilder
    private var languageListOverlay: some View {
        if let side = picking {
            GeometryReader { geo in
                let width = (geo.size.width - gap) / 2
                ZStack(alignment: .topLeading) {
                    // A click anywhere else closes the list
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { toggle(side) }
                    LanguageList(
                        side: side,
                        codes: catalog.codes,
                        selected: side == .source ? (vm.sourceMode == .detect ? nil : vm.source) : vm.target,
                        detected: vm.detected,
                        settings: settings
                    ) { code in
                        if side == .source {
                            vm.chooseSource(code.map(TranslatorViewModel.SourceMode.fixed) ?? .detect)
                        } else if let code {
                            vm.chooseTarget(code)
                        }
                        withAnimation(.easeOut(duration: 0.15)) { picking = nil }
                    }
                    .frame(width: width, height: geo.size.height)
                    .offset(x: side == .source ? 0 : width + gap)
                }
            }
            .transition(.opacity)
        }
    }
}

/// The language name with a chevron; opens the language list.
private struct LanguageButton: View {
    let title: String
    let open: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(Theme.label)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .foregroundColor(Theme.fg)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .glassChip(in: Capsule(), interactive: true)
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
    }
}

/// A searchable list of languages: Detect (for the source), favorites, recent, then all by name.
private struct LanguageList: View {
    let side: TranslatorView.Side
    let codes: [String]
    /// The chosen language; nil while the source is detected.
    let selected: String?
    let detected: String?
    @ObservedObject var settings: TranslateSettings
    /// nil picks "Detect Language".
    let pick: (String?) -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(Theme.fgMute)
                TextField("Search languages", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .foregroundColor(Theme.fg)
                    .focused($searchFocused)
                    .onSubmit {
                        // Return picks the first match of a search, never a language the user didn't look for
                        if !query.isEmpty, let first = matches.first { pick(first) }
                    }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.surface2, in: Capsule())
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if query.isEmpty {
                        if side == .source {
                            LanguageRow(title: detectTitle, checked: selected == nil, favorite: nil) { pick(nil) }
                        }
                        let groups = TranslationLanguages.grouped(all: codes, favorites: settings.favorites,
                                                                  recent: settings.recent)
                        section("Favorites", groups.favorites)
                        section("Recent", groups.recent)
                        section("All Languages", groups.rest)
                    } else if matches.isEmpty {
                        Text("No languages found")
                            .font(Theme.caption).foregroundColor(Theme.fgMute)
                            .padding(8)
                    } else {
                        rows(matches)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.1)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border))
        .onAppear { searchFocused = true }
    }

    private var matches: [String] {
        TranslationLanguages.matching(query, in: TranslationLanguages.sortedByName(codes))
    }

    private var detectTitle: String {
        guard let detected else { return String(localized: "Detect Language") }
        return String(localized: "Detect Language (\(TranslationLanguages.name(of: detected)))")
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ items: [String]) -> some View {
        if !items.isEmpty {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.fgMute)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 2)
            rows(items)
        }
    }

    private func rows(_ items: [String]) -> some View {
        ForEach(items, id: \.self) { code in
            LanguageRow(title: TranslationLanguages.name(of: code), checked: selected == code,
                        favorite: settings.favorites.contains(code)) { pick(code) } toggleFavorite: {
                settings.toggleFavorite(code)
            }
        }
    }
}

private struct LanguageRow: View {
    let title: String
    let checked: Bool
    /// nil hides the star.
    let favorite: Bool?
    let action: () -> Void
    var toggleFavorite: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .opacity(checked ? 1 : 0)
                .frame(width: 12)
            Text(title).font(Theme.body).lineLimit(1)
            Spacer(minLength: 4)
            if let favorite, favorite || hovering {
                Button(action: toggleFavorite) {
                    Image(systemName: favorite ? "star.fill" : "star")
                        .font(.system(size: 10))
                        .foregroundColor(favorite ? Theme.fgDim : Theme.fgMute)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(favorite ? Text("Remove from Favorites") : Text("Add to Favorites"))
            }
        }
        .foregroundColor(Theme.fg)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.surface2 : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(checked ? [.isButton, .isSelected] : .isButton)
    }
}
