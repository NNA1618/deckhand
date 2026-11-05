import SwiftUI

/// Quick actions on text. Chat lives in the Claude app, which the tab opens.
/// One shared instance, so a running action and its result survive closing the panel and switching tabs.
@MainActor
final class ClaudeViewModel: ObservableObject {
    static let shared = ClaudeViewModel()

    @Published var selectedPresetId: String = Presets.all.first?.id ?? ""
    @Published var inputText: String = ""
    @Published var outputText: String = ""
    @Published private(set) var isRunning = false
    @Published var error: String?

    private var job: Task<Void, Never>?
    private var current: UUID?

    var selectedPreset: ClaudePreset? {
        let visible = ClaudeSettings.shared.visiblePresets
        return visible.first { $0.id == selectedPresetId } ?? visible.first
    }

    var canRun: Bool { !isRunning && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedPreset != nil }

    func loadFromClipboardIfEmpty() {
        guard Settings.shared.prefillFromClipboard, inputText.isEmpty, !isRunning,
              let s = NSPasteboard.general.prefillText else { return }
        inputText = s
    }

    func runPreset() {
        guard canRun, let preset = selectedPreset else { return }
        isRunning = true
        error = nil
        outputText = ""
        let input = inputText
        let model = ClaudeSettings.shared.model(for: preset)
        let run = UUID()
        current = run
        job = Task { @MainActor in
            var result: String?, failure: String?
            do {
                result = try await ClaudeEngine.complete(system: preset.system, input: input, model: model)
            } catch is CancellationError {
                // Stopped by the user
            } catch {
                failure = error.localizedDescription
            }
            // A stopped run that ends late must not touch a newer one
            guard current == run, !Task.isCancelled else { return }
            outputText = result ?? ""
            self.error = failure
            isRunning = false
            job = nil
        }
    }

    /// Stops the running action; Claude Code is told to quit.
    func stop() {
        job?.cancel()
        job = nil
        current = nil
        isRunning = false
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
