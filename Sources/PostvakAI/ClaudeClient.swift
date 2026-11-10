import Foundation
import PostvakCore

public enum ClaudeError: Error, LocalizedError {
    case noKey
    case http(Int, String)
    case refused(String?)
    case truncated
    case badOutput(String)
    public var errorDescription: String? {
        switch self {
        case .noKey: "Add your Anthropic API key in Settings."
        case .http(let s, let m): "Claude API error \(s): \(m)"
        case .refused(let c): "Claude declined this request\(c.map { " (\($0))" } ?? "")."
        case .truncated: "Claude's answer was cut off at the token limit."
        case .badOutput(let m): "Claude returned unreadable output: \(m)"
        }
    }
    var isRetryable: Bool {
        if case .http(let s, _) = self { return s == 429 || s >= 500 }
        return false
    }
}

/// Raw HTTP call to the Messages API, because no official Swift SDK exists.
public final class ClaudeClient: Sendable {
    /// Every Postvak call uses Claude Haiku 5.5. It has no server-side fallback, so requests carry no `fallbacks`.
    public static let model = "claude-haiku-5-5"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    let keyProvider: @Sendable () -> String?
    let session: URLSession
    /// Told the tokens each answered request used: the feature that asked, the model that answered, the usage.
    let onUsage: (@Sendable (String, String, TokenUsage) -> Void)?

    public init(session: URLSession = .shared, key: @escaping @Sendable () -> String?,
                onUsage: (@Sendable (String, String, TokenUsage) -> Void)? = nil) {
        self.session = session
        keyProvider = key
        self.onUsage = onUsage
    }

    public var hasKey: Bool { !(keyProvider() ?? "").isEmpty }

    /// One request constrained to a JSON schema. Returns the decoded output. With `orderedFields` the schema's properties
    /// are sent in alphabetical order, which is the order the model writes them in. `model` overrides the default model.
    public func structured<T: Decodable>(system: String, user: String, schema: [String: Any], effort: String,
                                         maxTokens: Int, as type: T.Type, attempts: Int = 3, feature: String,
                                         orderedFields: Bool = false, model: String = ClaudeClient.model) async throws -> T {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
            "output_config": ["effort": effort, "format": ["type": "json_schema", "schema": schema]],
        ]
        return try Self.decode(try await post(body, attempts: attempts, feature: feature, sortedKeys: orderedFields), as: type)
    }

    /// One Messages API call with a body the caller builds. Returns the response object as is, so a conversation
    /// can pass its content back unchanged.
    public func message(_ body: [String: Any], attempts: Int = 3, feature: String) async throws -> [String: Any] {
        let data = try await post(body, attempts: attempts, feature: feature)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.badOutput(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return obj
    }

    private func post(_ body: [String: Any], attempts: Int, feature: String, sortedKeys: Bool = false) async throws -> Data {
        guard let key = keyProvider(), !key.isEmpty else { throw ClaudeError.noKey }
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: sortedKeys ? [.sortedKeys] : [])

        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, resp) = try await session.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    throw ClaudeError.http(status, Self.apiMessage(data) ?? "HTTP \(status)")
                }
                if let onUsage, let (model, usage) = Self.usage(data) { onUsage(feature, model, usage) }
                return data
            } catch let e as ClaudeError where e.isRetryable && attempt < attempts {
                try await Task.sleep(for: .seconds(Double(attempt) * 2))
            }
        }
    }

    /// The model that answered and the tokens it used, from the response's `usage`.
    static func usage(_ data: Data) -> (String, TokenUsage)? {
        struct R: Decodable {
            struct U: Decodable {
                let input_tokens: Int?; let output_tokens: Int?
                let cache_read_input_tokens: Int?; let cache_creation_input_tokens: Int?
            }
            let model: String?; let usage: U?
        }
        guard let r = try? JSONDecoder().decode(R.self, from: data), let u = r.usage else { return nil }
        return (r.model ?? model, TokenUsage(input: u.input_tokens ?? 0, output: u.output_tokens ?? 0,
                                             cacheRead: u.cache_read_input_tokens ?? 0, cacheWrite: u.cache_creation_input_tokens ?? 0))
    }

    static func apiMessage(_ data: Data) -> String? {
        struct E: Decodable { struct I: Decodable { let message: String? }; let error: I? }
        return (try? JSONDecoder().decode(E.self, from: data))?.error?.message
    }

    struct Response: Decodable {
        struct Block: Decodable { let type: String; let text: String? }
        struct Stop: Decodable { let category: String? }
        let content: [Block]?
        let stop_reason: String?
        let stop_details: Stop?
    }

    static func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        let r = try JSONDecoder().decode(Response.self, from: data)
        // The stop reason comes first: a refusal or cut-off has no usable content.
        switch r.stop_reason {
        case "refusal": throw ClaudeError.refused(r.stop_details?.category)
        case "max_tokens": throw ClaudeError.truncated
        default: break
        }
        let text = (r.content ?? []).filter { $0.type == "text" }.compactMap(\.text).joined()
        do {
            return try JSONDecoder().decode(T.self, from: Data(text.utf8))
        } catch {
            throw ClaudeError.badOutput(String(text.prefix(200)))
        }
    }
}
