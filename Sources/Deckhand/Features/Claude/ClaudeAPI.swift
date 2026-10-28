import Foundation

/// Minimal Anthropic Messages API client with no dependencies.
///
enum ClaudeModel: String, CaseIterable, Codable {
    case haiku55 = "claude-haiku-5-5"
    case sonnet55 = "claude-sonnet-5-5"
    case opus55 = "claude-opus-5-5"

    var displayName: String {
        switch self {
        case .haiku55: return "haiku 5.5"
        case .sonnet55: return "sonnet 5.5"
        case .opus55: return "opus 5.5"
        }
    }
}

struct ClaudeMessage: Codable, Equatable, Identifiable {
    enum Role: String, Codable { case user, assistant }
    let id: UUID
    let role: Role
    var content: String

    init(id: UUID = UUID(), role: Role, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

final class ClaudeAPI: @unchecked Sendable {
    static let shared = ClaudeAPI()

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let version = "2023-06-01"

    // MARK: - API key storage

    private let keychainAccount = "anthropic-api-key"

    /// The key lives in the Keychain. A legacy key from UserDefaults is moved there once and erased.
    var apiKey: String? {
        get {
            if let key = Keychain.get(keychainAccount) { return key }
            for (domain, name) in [("com.fringe.app", "FringeAnthropicAPIKey"), (AppPaths.bundleId, "DeckhandAnthropicAPIKey")] {
                let defaults = domain == AppPaths.bundleId ? UserDefaults.standard : UserDefaults(suiteName: domain)
                if let legacy = defaults?.string(forKey: name), !legacy.isEmpty {
                    Keychain.set(legacy, for: keychainAccount)
                    defaults?.removeObject(forKey: name)
                    return legacy
                }
            }
            return nil
        }
        set { Keychain.set(newValue, for: keychainAccount) }
    }

    var hasAPIKey: Bool {
        guard let k = apiKey else { return false }
        return !k.isEmpty && k.hasPrefix("sk-")
    }

    // MARK: - Call

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func complete(system: String?,
                  messages: [ClaudeMessage],
                  model: ClaudeModel = .sonnet55,
                  maxTokens: Int = 1024) async throws -> String {
        try await send(system: system,
                       messages: messages.map { ["role": $0.role.rawValue, "content": $0.content] },
                       model: model, maxTokens: maxTokens)
    }

    /// Asks about an image. `png` should be at most about 1568 px on the long edge.
    func ask(about png: Data, question: String, model: ClaudeModel = .sonnet55) async throws -> String {
        let content: [[String: Any]] = [
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png.base64EncodedString()]],
            ["type": "text", "text": question],
        ]
        return try await send(
            system: "You look at screenshots for the user. Answer in the language of the question. Be concise and specific.",
            messages: [["role": "user", "content": content]],
            model: model, maxTokens: 1024
        )
    }

    private func send(system: String?, messages: [[String: Any]], model: ClaudeModel, maxTokens: Int) async throws -> String {
        guard let key = apiKey, !key.isEmpty else {
            throw APIError(message: String(localized: "No API key. Add it in Settings → Claude."))
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(version, forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": maxTokens,
            "messages": messages,
        ]
        if let system, !system.isEmpty {
            body["system"] = system
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(message: String(localized: "No response from the API"))
        }

        if http.statusCode != 200 {
            let text = String(data: data, encoding: .utf8) ?? "unknown error"
            throw APIError(message: "HTTP \(http.statusCode): \(text.prefix(400))")
        }

        // Response shape: { content: [{type: "text", text: "..."}], ... }
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let contentArr = json["content"] as? [[String: Any]] {
            let text = contentArr.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return text
        }
        throw APIError(message: String(localized: "Could not read the API response"))
    }
}
