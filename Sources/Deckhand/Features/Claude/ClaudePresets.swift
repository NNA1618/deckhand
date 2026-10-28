import Foundation

/// Quick actions on selected text, each with its own instruction and model.
struct ClaudePreset: Identifiable, Equatable {
    let id: String
    let name: String
    let symbol: String
    let system: String
    let preferredModel: ClaudeModel
}

enum Presets {
    private static let sameLanguage = "Reply in the same language as the input. Return only the result, with no preamble."

    static let all: [ClaudePreset] = [
        ClaudePreset(
            id: "rewrite", name: String(localized: "Rewrite"), symbol: "pencil.and.scribble",
            system: "Rewrite the text so it is clearer and reads better. Keep the meaning and the author's tone. \(sameLanguage)",
            preferredModel: .sonnet55
        ),
        ClaudePreset(
            id: "shorten", name: String(localized: "Shorten"), symbol: "arrow.down.right.and.arrow.up.left",
            system: "Make the text two to three times shorter and keep the key points. \(sameLanguage)",
            preferredModel: .haiku55
        ),
        ClaudePreset(
            id: "expand", name: String(localized: "Expand"), symbol: "arrow.up.left.and.arrow.down.right",
            system: "Expand the text with useful detail, examples and reasoning. Keep the author's tone. \(sameLanguage)",
            preferredModel: .sonnet55
        ),
        ClaudePreset(
            id: "fix", name: String(localized: "Fix Grammar"), symbol: "textformat.abc",
            system: "Fix spelling, punctuation and grammar. Do not change the style or meaning. \(sameLanguage)",
            preferredModel: .haiku55
        ),
        ClaudePreset(
            id: "explain", name: String(localized: "Explain"), symbol: "questionmark.bubble",
            system: "Explain in plain words what this is and how it works, in two to five sentences. Reply in the same language as the input.",
            preferredModel: .sonnet55
        ),
        ClaudePreset(
            id: "code-review", name: String(localized: "Review Code"), symbol: "chevron.left.forwardslash.chevron.right",
            system: "Review the code briefly: bugs first, then what to simplify, then style. Use a short list. If the code is fine, say so. Reply in the same language as any comments or question, otherwise in English.",
            preferredModel: .sonnet55
        ),
        ClaudePreset(
            id: "improve-prompt", name: String(localized: "Improve Prompt"), symbol: "wand.and.stars",
            system: """
            The input is a prompt for an AI model (image, video or text). Improve it: make it specific and well structured. \
            For image or video prompts add subject, composition, camera, lighting and style. \
            For text models add role, output format and constraints. Keep the prompt's language. Return only the improved prompt.
            """,
            preferredModel: .sonnet55
        ),
        ClaudePreset(
            id: "to-english", name: String(localized: "To English"), symbol: "character.textbox",
            system: "Translate the text into natural English. Keep the author's tone and formatting. Return only the translation.",
            preferredModel: .haiku55
        ),
    ]

    static func byId(_ id: String) -> ClaudePreset? {
        all.first { $0.id == id }
    }
}
