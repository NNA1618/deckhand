import SwiftUI

@MainActor
final class ClaudeViewModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case presets, chat
        var id: String { rawValue }
        var title: String { self == .presets ? String(localized: "Presets") : String(localized: "Chat") }
    }

    @Published var mode: Mode = .presets

    // Presets mode
    @Published var selectedPresetId: String = Presets.all.first?.id ?? ""
    @Published var inputText: String = ""
    @Published var outputText: String = ""
    @Published var isRunning: Bool = false
    @Published var error: String?

    // Chat mode
    @Published var messages: [ClaudeMessage] = []
    @Published var chatInput: String = ""
    @Published var chatModel: ClaudeModel = .sonnet55

    private let api = ClaudeAPI.shared

    func loadFromClipboardIfEmpty() {
        guard inputText.isEmpty else { return }
        if let s = NSPasteboard.general.string(forType: .string), !s.isEmpty {
            inputText = s
        }
    }

    // MARK: - Presets

    func runPreset() {
        guard let preset = Presets.byId(selectedPresetId) else { return }
        guard !inputText.isEmpty else { return }
        isRunning = true
        error = nil
        outputText = ""

        let input = inputText
        let system = preset.system
        let model = preset.preferredModel

        Task { @MainActor in
            do {
                let result = try await api.complete(
                    system: system,
                    messages: [.init(role: .user, content: input)],
                    model: model
                )
                self.outputText = result
            } catch {
                self.error = error.localizedDescription
            }
            self.isRunning = false
        }
    }

    func copyOutput() {
        guard !outputText.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(outputText, forType: .string)
    }

    // MARK: - Chat

    func sendChat() {
        let text = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        messages.append(.init(role: .user, content: text))
        chatInput = ""
        isRunning = true
        error = nil

        let msgs = messages
        let model = chatModel

        Task { @MainActor in
            do {
                let reply = try await api.complete(
                    system: Settings.shared.claudeInstructions.isEmpty ? nil : Settings.shared.claudeInstructions,
                    messages: msgs,
                    model: model
                )
                self.messages.append(.init(role: .assistant, content: reply))
            } catch {
                self.error = error.localizedDescription
            }
            self.isRunning = false
        }
    }

    func clearChat() {
        messages.removeAll()
        error = nil
    }
}
