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
            HStack(spacing: 8) {
                Chip(text: TranslatorService.name(of: vm.sourceLang), active: true)
                Button { vm.swapLanguages() } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.fgDim)
                        .frame(width: 26, height: 26)
                        .glassChip(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                Chip(text: TranslatorService.name(of: vm.targetLang))
                Spacer()
                if vm.isTranslating { ProgressView().controlSize(.small) }
                PrimaryButton(title: "Translate") { translate() }
                    .disabled(vm.input.isEmpty || vm.isTranslating)
            }

            // Input
            TextEditor(text: $vm.input)
                .scrollContentBackground(.hidden)
                .padding(8)
                .font(Theme.body)
                .foregroundColor(Theme.fg)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(height: 130)
                .onChange(of: vm.input) { _, _ in
                    vm.refreshLanguages()
                }

            // Output
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.surface.opacity(0.6))
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
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(Theme.fg)
                                    .frame(width: 28, height: 28)
                                    .glassChip(in: Circle(), interactive: true)
                            }.buttonStyle(.plain)
                        }
                    }.padding(8)
                }
            }
            .frame(maxHeight: .infinity)
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
