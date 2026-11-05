import Foundation

/// Settings of the Claude area that `Settings` doesn't hold, shown in Settings → Claude.
@MainActor
final class ClaudeSettings: ObservableObject {
    static let shared = ClaudeSettings()
    private let d = UserDefaults.standard

    /// Answer Claude Code's permission prompts from the notch. Off by default: while it is on,
    /// Claude Code shows its own prompt only after `approvalWait` seconds without an answer.
    @Published var approveFromNotch: Bool { didSet { d.set(approveFromNotch, forKey: "claudeApproveFromNotch") } }
    /// Seconds Claude Code waits for an answer from the notch.
    @Published var approvalWait: Int { didSet { d.set(approvalWait, forKey: "claudeApprovalWait") } }
    /// The `claude` binary chosen by hand; empty means find it automatically.
    @Published var cliPath: String { didSet { d.set(cliPath, forKey: "claudeCLIPath") } }
    /// One model for every quick action; empty means each action's own model.
    @Published var model: String { didSet { d.set(model, forKey: "claudeModel") } }
    /// Quick actions in the panel, in order, and the ones turned off.
    @Published var presetOrder: [String] { didSet { d.set(presetOrder, forKey: "claudePresetOrder") } }
    @Published var hiddenPresets: [String] { didSet { d.set(hiddenPresets, forKey: "claudeHiddenPresets") } }

    static let approvalWaits = [15, 30, 60]

    private init() {
        d.register(defaults: [
            "claudeApproveFromNotch": false,
            "claudeApprovalWait": 30,
            "claudeCLIPath": "",
            "claudeModel": "",
            "claudePresetOrder": [String](),
            "claudeHiddenPresets": [String](),
        ])
        approveFromNotch = d.bool(forKey: "claudeApproveFromNotch")
        approvalWait = d.integer(forKey: "claudeApprovalWait")
        cliPath = d.string(forKey: "claudeCLIPath") ?? ""
        model = d.string(forKey: "claudeModel") ?? ""
        presetOrder = d.stringArray(forKey: "claudePresetOrder") ?? []
        hiddenPresets = d.stringArray(forKey: "claudeHiddenPresets") ?? []
    }

    /// The model a preset runs with: the one chosen here, or the preset's own.
    func model(for preset: ClaudePreset) -> ClaudeModel {
        ClaudeModel(rawValue: model) ?? preset.preferredModel
    }

    /// All presets in the user's order; ones added in a later version go at the end.
    var orderedPresets: [ClaudePreset] { Self.ordered(Presets.all, order: presetOrder) }

    /// The presets shown in the panel.
    var visiblePresets: [ClaudePreset] { orderedPresets.filter { !hiddenPresets.contains($0.id) } }

    nonisolated static func ordered(_ presets: [ClaudePreset], order: [String]) -> [ClaudePreset] {
        let known = order.compactMap { id in presets.first { $0.id == id } }
        return known + presets.filter { !order.contains($0.id) }
    }
}
