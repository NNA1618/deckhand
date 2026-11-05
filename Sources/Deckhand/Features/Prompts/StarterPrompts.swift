import Foundation

/// Examples a new library starts with, in the app's language. Image and video prompts stay in
/// English because generators understand English best; their titles and categories are translated.
enum StarterPrompts {
    struct Starter {
        let title: String
        let body: String
        let category: String
        let tags: [String]
    }

    static var all: [Starter] {
        let media = String(localized: "prompts.category.media", defaultValue: "Image & Video")
        let code = String(localized: "prompts.category.code", defaultValue: "Code")
        let writing = String(localized: "prompts.category.writing", defaultValue: "Writing")
        return [
            Starter(title: String(localized: "starter.ugc.title", defaultValue: "Product UGC video"),
                    body: "UGC-style try-on video of the product below. Natural hand movements, authentic daylight, handheld 50mm look, one continuous take.\nProduct: {{product}}",
                    category: media, tags: ["ugc", "video"]),
            Starter(title: String(localized: "starter.hero.title", defaultValue: "Hero product shot"),
                    body: "Hero shot of {{product}} on a dark seamless background, single soft key light from the left, subtle rim light, shallow depth of field, premium commercial look.",
                    category: media, tags: ["product", "photo"]),
            Starter(title: String(localized: "starter.character.title", defaultValue: "Character sheet"),
                    body: "Character sheet of {{character}}: front, side, three-quarter and back views. Consistent proportions and lighting, neutral grey background.",
                    category: media, tags: ["character"]),
            Starter(title: String(localized: "starter.explain.title", defaultValue: "Explain this file"),
                    body: String(localized: "starter.explain.body", defaultValue: "Read this file and explain what it does as a short list. Point out the main functions and dependencies."),
                    category: code, tags: ["explain"]),
            Starter(title: String(localized: "starter.bugs.title", defaultValue: "Find bugs"),
                    body: String(localized: "starter.bugs.body", defaultValue: "Check this code for bugs, race conditions, leaks and unhandled edge cases. Be brief and list the most serious first."),
                    category: code, tags: ["review"]),
            Starter(title: String(localized: "starter.refactor.title", defaultValue: "Refactor"),
                    body: String(localized: "starter.refactor.body", defaultValue: "Refactor this code for readability without changing behavior. Explain each change in one line."),
                    category: code, tags: ["refactor"]),
            Starter(title: String(localized: "starter.points.title", defaultValue: "Key points"),
                    body: String(localized: "starter.points.body", defaultValue: "Pull the 5 to 7 key points out of this text, one line each."),
                    category: writing, tags: ["summary"]),
            Starter(title: String(localized: "starter.simple.title", defaultValue: "Explain like I'm ten"),
                    body: String(localized: "starter.simple.body", defaultValue: "Explain this so a ten-year-old would understand it, in simple words but without losing the point."),
                    category: writing, tags: ["explain"]),
        ]
    }
}
