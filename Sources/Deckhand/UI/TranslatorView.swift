import SwiftUI
#if canImport(Translation)
@preconcurrency import Translation
#endif

struct TranslatorView: View {
    @StateObject private var vm = TranslatorViewModel()
    #if canImport(Translation)
    @State private var sessionConfig: TranslationSession.Configuration?
    #endif
    @State private var pendingText: String = ""

    var body: some View {
        VStack(spacing: 10) {
            // Lang row
            HStack(spacing: 10) {
                Text(TranslatorService.name(of: vm.sourceLang))
                    .font(Theme.monoSmall)
                    .foregroundColor(Theme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.1))
                    .cornerRadius(6)
                Button(action: { vm.swapLanguages() }) {
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundColor(Theme.fgDim)
                        .font(.system(size: 11))
                }.buttonStyle(.plain)
                Text(TranslatorService.name(of: vm.targetLang))
                    .font(Theme.monoSmall)
                    .foregroundColor(Theme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.1))
                    .cornerRadius(6)
                Spacer()
                if vm.isTranslating {
                    ProgressView().controlSize(.small)
                }
                Button(action: translate) {
                    Text("Translate")
                        .font(Theme.monoSmall)
                        .foregroundColor(Theme.bg)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.accent)
                        .cornerRadius(6)
                }.buttonStyle(.plain)
                    .disabled(vm.input.isEmpty || vm.isTranslating)
            }

            // Input
            TextEditor(text: $vm.input)
                .scrollContentBackground(.hidden)
                .padding(8)
                .font(Theme.body)
                .foregroundColor(Theme.fg)
                .background(Theme.surface2)
                .cornerRadius(8)
                .frame(minHeight: 100, maxHeight: 160)
                .onChange(of: vm.input) { _, _ in
                    vm.refreshLanguages()
                }

            // Output
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.surface2.opacity(0.5))
                    .frame(minHeight: 100)
                if vm.output.isEmpty {
                    Text(vm.error.map { LocalizedStringKey($0) } ?? "The translation appears here")
                        .font(Theme.body)
                        .foregroundColor(vm.error != nil ? Theme.warn : Theme.fgMute)
                        .padding(12)
                } else {
                    ScrollView {
                        Text(vm.output)
                            .font(Theme.body)
                            .foregroundColor(Theme.fg)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        if !vm.output.isEmpty {
                            Button(action: { vm.copyOutput() }) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.fgDim)
                                    .padding(6)
                                    .background(Theme.surface)
                                    .cornerRadius(6)
                            }.buttonStyle(.plain)
                        }
                    }.padding(6)
                }
            }
        }
        .onAppear {
            vm.loadFromClipboardIfEmpty()
        }
        #if canImport(Translation)
        .translationTask(sessionConfig) { session in
            do {
                let response = try await session.translate(pendingText)
                vm.output = response.targetText
            } catch {
                vm.error = error.localizedDescription
            }
            vm.isTranslating = false
        }
        #endif
    }

    private func translate() {
        guard !vm.input.isEmpty else { return }
        vm.isTranslating = true
        vm.error = nil
        vm.output = ""
        pendingText = vm.input

        #if canImport(Translation)
        let src = Locale.Language(identifier: vm.sourceLang)
        let tgt = Locale.Language(identifier: vm.targetLang)
        sessionConfig = TranslationSession.Configuration(source: src, target: tgt)
        #else
        vm.error = String(localized: "Translation is not available on this Mac")
        vm.isTranslating = false
        #endif
    }
}
