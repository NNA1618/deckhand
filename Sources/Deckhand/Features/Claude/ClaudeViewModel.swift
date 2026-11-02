import SwiftUI

/// Quick actions on text. Chat lives in the Claude app, which the tab opens.
@MainActor
final class ClaudeViewModel: ObservableObject {
    @Published var selectedPresetId: String = Presets.all.first?.id ?? ""
    @Published var inputText: String = ""
    @Published var outputText: String = ""
    @Published var isRunning: Bool = false
    @Published var error: String?

    func loadFromClipboardIfEmpty() {
        guard inputText.isEmpty, let s = NSPasteboard.general.prefillText else { return }
        inputText = s
    }

    func runPreset() {
        guard let preset = Presets.byId(selectedPresetId), !inputText.isEmpty, !isRunning else { return }
        isRunning = true
        error = nil
        outputText = ""
        let input = inputText
        Task { @MainActor in
            do {
                outputText = try await ClaudeEngine.complete(system: preset.system, input: input, model: preset.preferredModel)
            } catch {
                self.error = error.localizedDescription
            }
            isRunning = false
        }
    }

    func copyOutput() {
        guard !outputText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(outputText, forType: .string)
    }

    /// Puts the result in place of the input, to run another action on it.
    func useOutput() {
        guard !outputText.isEmpty else { return }
        inputText = outputText
        outputText = ""
    }
}
