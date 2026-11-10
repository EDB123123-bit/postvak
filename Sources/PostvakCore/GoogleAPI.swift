import Foundation

public struct GoogleAPIError: Error, LocalizedError {
    public let status: Int
    public let message: String
    public var errorDescription: String? { "Google API error \(status): \(message)" }
}

/// Counts quota refusals per account, so long-running work can slow itself down.
public final class RateLimitLog: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func record(_ account: String) { lock.lock(); counts[account, default: 0] += 1; lock.unlock() }
    func count(_ account: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[account] ?? 0 }
}

public protocol AccessTokenProvider: Sendable {
    func accessToken(for account: String) async throws -> String
    func invalidate(_ account: String) async
}
extension GoogleAuth: AccessTokenProvider {}

/// Authorized JSON calls with one token refresh on 401 and backoff on 5xx and spent quotas.
public final class GoogleAPI: Sendable {
    let tokens: AccessTokenProvider
    let session: URLSession
    let rateLimits = RateLimitLog()
    public init(tokens: AccessTokenProvider, session: URLSession = .shared) {
        self.tokens = tokens
        self.session = session
    }

    public func call(account: String, method: String = "GET", url: String, query: [String: String?] = [:],
                     json: Any? = nil, body: (data: Data, contentType: String)? = nil, maxAttempts: Int = 5) async throws -> Data {
        var comps = URLComponents(string: url)!
        let items = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
        if !items.isEmpty { comps.queryItems = items }
        var refreshed = false
        var attempt = 0
        while true {
            attempt += 1
            var req = URLRequest(url: comps.url!)
            req.httpMethod = method
            // A mail with several megabytes of attachments needs longer than a minute on a slow line.
            req.timeoutInterval = (body?.data.count ?? 0) > 1_000_000 ? 300 : 60
            let token = try await tokens.accessToken(for: account)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let json {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: json)
            } else if let body {
                req.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
                req.httpBody = body.data
            }
            let data: Data, resp: URLResponse
            do {
                (data, resp) = try await session.data(for: req)
            } catch {
                if attempt >= maxAttempts { throw error }
                try await Task.sleep(for: .seconds(Self.backoff(attempt)))
                continue
            }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return data }
            let message = Self.errorMessage(data) ?? "HTTP \(status)"
            if status == 401, !refreshed {
                refreshed = true
                await tokens.invalidate(account)
                continue
            }
            let rateLimited = Self.isRateLimit(status: status, data: data, message: message)
            if rateLimited { rateLimits.record(account) }
            if rateLimited, attempt < maxAttempts {
                let retryAfter = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                let wait = Self.backoffDisabled ? 0 : Self.rateLimitDelay(attempt: attempt, retryAfter: retryAfter)
                try await Task.sleep(for: .seconds(wait))
                continue
            }
            if status >= 500, attempt < maxAttempts {
                try await Task.sleep(for: .seconds(Self.backoff(attempt)))
                continue
            }
            throw GoogleAPIError(status: status, message: message)
        }
    }

    static var backoffDisabled: Bool { ProcessInfo.processInfo.environment["POSTVAK_NO_BACKOFF"] != nil }

    /// Google reports a spent quota as 429, or as 403 with one of several wordings.
    static func isRateLimit(status: Int, data: Data, message: String) -> Bool {
        if status == 429 { return true }
        guard status == 403 else { return false }
        struct E: Decodable {
            struct I: Decodable {
                struct R: Decodable { let reason: String? }
                let status: String?
                let errors: [R]?
            }
            let error: I?
        }
        let error = (try? JSONDecoder().decode(E.self, from: data))?.error
        if error?.status == "RESOURCE_EXHAUSTED" { return true }
        let reasons: Set<String> = ["rateLimitExceeded", "userRateLimitExceeded", "quotaExceeded", "dailyLimitExceeded"]
        if error?.errors?.contains(where: { reasons.contains($0.reason ?? "") }) == true { return true }
        let text = message.lowercased()
        return text.contains("quota exceeded") || text.contains("rate limit")
    }

    /// Gmail's quotas are per minute, so a short backoff would just fail again. Four waits span over two minutes.
    static func rateLimitDelay(attempt: Int, retryAfter: String?) -> Double {
        let steps: [Double] = [15, 30, 60, 60]
        let planned = steps[min(max(attempt, 1) - 1, steps.count - 1)]
        let asked = retryAfter.flatMap(Double.init) ?? 0
        return min(120, max(planned, asked)) + Double.random(in: 0...3)
    }

    static func backoff(_ attempt: Int) -> Double {
        if backoffDisabled { return 0 }
        return min(30, pow(2, Double(attempt - 1))) + Double.random(in: 0...0.5)
    }

    static func errorMessage(_ data: Data) -> String? {
        struct E: Decodable { struct I: Decodable { let message: String? }; let error: I? }
        return (try? JSONDecoder().decode(E.self, from: data))?.error?.message
    }
}
