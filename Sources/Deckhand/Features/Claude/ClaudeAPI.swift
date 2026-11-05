import Foundation
import os

/// The models quick actions can use.
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

    /// The name people know: "Haiku 5.5".
    var label: String {
        switch self {
        case .haiku55: return "Haiku 5.5"
        case .sonnet55: return "Sonnet 5.5"
        case .opus55: return "Opus 5.5"
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

/// Minimal Anthropic Messages API client with no dependencies.
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
        set {
            Keychain.set(newValue, for: keychainAccount)
            keyState.withLock { $0 = nil }
        }
    }

    /// Whether a key is saved. Views ask on every redraw, so the Keychain is read once and cached.
    var hasAPIKey: Bool {
        if let known = keyState.withLock({ $0 }) { return known }
        let has = apiKey.map(Self.looksLikeKey) ?? false
        keyState.withLock { $0 = has }
        return has
    }

    private let keyState = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    /// Anthropic keys start with "sk-ant-".
    static func looksLikeKey(_ key: String) -> Bool {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return k.hasPrefix("sk-ant-") && k.count > 20 && !k.contains(where: \.isWhitespace)
    }

    // MARK: - Call

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Room for the answer and the model's thinking; quick actions on long text need more than 1024.
    static let maxTokens = 16000

    func complete(system: String?,
                  messages: [ClaudeMessage],
                  model: ClaudeModel = .sonnet55,
                  maxTokens: Int = ClaudeAPI.maxTokens) async throws -> String {
        try await send(system: system,
                       messages: messages.map { ["role": $0.role.rawValue, "content": $0.content] },
                       model: model, maxTokens: maxTokens)
    }

    /// Asks about an image. `png` should be at most about 2576 px on the long edge.
    func ask(about png: Data, question: String, model: ClaudeModel = .sonnet55) async throws -> String {
        let content: [[String: Any]] = [
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png.base64EncodedString()]],
            ["type": "text", "text": question],
        ]
        return try await send(
            system: "You look at screenshots for the user. Answer in the language of the question. Be concise and specific.",
            messages: [["role": "user", "content": content]],
            model: model, maxTokens: Self.maxTokens
        )
    }

    /// The request body; split out so the self-test can check it.
    static func body(system: String?, messages: [[String: Any]], model: ClaudeModel, maxTokens: Int) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": maxTokens,
            "messages": messages,
            // Quick actions are short edits: little thinking keeps them fast and cheap
            "output_config": ["effort": "low"],
        ]
        if let system, !system.isEmpty { body["system"] = system }
        return body
    }

    private func send(system: String?, messages: [[String: Any]], model: ClaudeModel, maxTokens: Int) async throws -> String {
        guard let key = apiKey, !key.isEmpty else {
            throw APIError(message: String(localized: "No API key. Add it in Settings → Claude."))
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(version, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.body(system: system, messages: messages, model: model, maxTokens: maxTokens))

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIError(message: String(localized: "Can't reach Claude. Check your internet connection."))
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError(message: String(localized: "No response from the API"))
        }
        return try Self.read(status: http.statusCode, data: data)
    }

    /// The answer text, or an error in the user's words. Pure, for the self-test.
    static func read(status: Int, data: Data) throws -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if status != 200 {
            let error = json?["error"] as? [String: Any]
            let type = error?["type"] as? String ?? ""
            let message = error?["message"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self)
            switch (status, type) {
            case (401, _), (_, "authentication_error"):
                throw APIError(message: String(localized: "The API key was not accepted. Check it in Settings → Claude."))
            case (403, _), (_, "permission_error"):
                throw APIError(message: String(localized: "This API key may not use this model."))
            case (429, _), (_, "rate_limit_error"):
                throw APIError(message: String(localized: "You've reached your API rate limit. Try again in a minute."))
            case (529, _), (_, "overloaded_error"):
                throw APIError(message: String(localized: "Claude is overloaded right now. Try again in a minute."))
            default:
                throw APIError(message: String(message.prefix(300)))
            }
        }
        guard let json, let content = json["content"] as? [[String: Any]] else {
            throw APIError(message: String(localized: "Could not read the API response"))
        }
        let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        switch json["stop_reason"] as? String {
        case "refusal":
            throw APIError(message: String(localized: "Claude declined to answer this."))
        case "max_tokens":
            if text.isEmpty { throw APIError(message: String(localized: "The answer was too long and got cut off.")) }
            return text + "\n\n" + String(localized: "[The answer was cut off]")
        default:
            if text.isEmpty { throw APIError(message: String(localized: "Claude returned an empty answer.")) }
            return text
        }
    }
}
