import Foundation
import Combine

/// Settings of the Prompts tab, in UserDefaults. Shown in Settings → Prompts.
@MainActor
final class PromptSettings: ObservableObject {
    static let shared = PromptSettings()
    private let d = UserDefaults.standard

    @Published var clickAction: PromptClickAction { didSet { d.set(clickAction.rawValue, forKey: "promptClickAction") } }
    /// Ask for `{{variables}}` before copying or pasting a prompt that has them.
    @Published var fillVariables: Bool { didSet { d.set(fillVariables, forKey: "promptFillVariables") } }
    @Published var sort: PromptSort { didSet { d.set(sort.rawValue, forKey: "promptSort") } }

    private init() {
        d.register(defaults: [
            "promptClickAction": PromptClickAction.copy.rawValue,
            "promptFillVariables": true,
            "promptSort": PromptSort.favoritesAndUsage.rawValue,
        ])
        clickAction = PromptClickAction(rawValue: d.string(forKey: "promptClickAction") ?? "") ?? .copy
        fillVariables = d.bool(forKey: "promptFillVariables")
        sort = PromptSort(rawValue: d.string(forKey: "promptSort") ?? "") ?? .favoritesAndUsage
    }
}
