import Foundation
import GRDB

/// Tokens one Anthropic request used, as the response's `usage` reports them.
public struct TokenUsage: Sendable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public init(input: Int, output: Int, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }
    /// The whole prompt, which decides the rate card on models priced by prompt length.
    public var prompt: Int { input + cacheRead + cacheWrite }
}

/// Anthropic use per day, feature and model, added up as requests come back.
public struct ApiUsageRecord: PersistableModel, Hashable {
    public static let databaseTableName = "api_usage"
    /// yyyy-MM-dd, local time.
    public var day: String
    public var feature: String
    public var model: String
    public var requests: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    /// Estimated cost in millionths of a dollar, from the list prices below.
    public var costMicros: Int
}

public final class ApiUsage: Sendable {
    let db: AppDatabase

    public init(db: AppDatabase) { self.db = db }

    /// List prices in dollars per million tokens: input, output, cache read, 5-minute cache write.
    /// Claude Haiku 5.5 has a higher rate card for prompts over 100K tokens.
    public static func cost(model: String, _ u: TokenUsage) -> Double? {
        let p: (input: Double, output: Double)
        switch model {
        case let m where m.hasPrefix("claude-haiku-5-5"): p = u.prompt > 100_000 ? (0.50, 2.50) : (0.10, 0.50)
        case let m where m.hasPrefix("claude-opus-5-5"): p = (4.00, 20.00)
        case let m where m.hasPrefix("claude-sonnet-5-5"): p = (2.00, 10.00)
        default: return nil
        }
        let perToken = { (rate: Double, n: Int) in rate * Double(n) / 1_000_000 }
        return perToken(p.input, u.input) + perToken(p.output, u.output)
            + perToken(p.input * 0.1, u.cacheRead) + perToken(p.input * 1.25, u.cacheWrite)
    }

    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    public func record(feature: String, model: String, usage u: TokenUsage, at date: Date = Date()) async throws {
        let day = Self.dayKey(date)
        let micros = Int(((Self.cost(model: model, u) ?? 0) * 1_000_000).rounded())
        try await db.pool.write { db in
            try db.execute(sql: """
                INSERT INTO api_usage (day, feature, model, requests, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, costMicros)
                VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?)
                ON CONFLICT(day, feature, model) DO UPDATE SET requests = requests + 1,
                  inputTokens = inputTokens + excluded.inputTokens, outputTokens = outputTokens + excluded.outputTokens,
                  cacheReadTokens = cacheReadTokens + excluded.cacheReadTokens, cacheWriteTokens = cacheWriteTokens + excluded.cacheWriteTokens,
                  costMicros = costMicros + excluded.costMicros
                """, arguments: [day, feature, model, u.input, u.output, u.cacheRead, u.cacheWrite, micros])
        }
    }

    /// Totals per feature and model from `since` on, the most expensive first.
    public static func totals(_ db: Database, since: Date) throws -> [ApiUsageRecord] {
        try ApiUsageRecord.fetchAll(db, sql: """
            SELECT '' AS day, feature, model, SUM(requests) AS requests, SUM(inputTokens) AS inputTokens, SUM(outputTokens) AS outputTokens,
                   SUM(cacheReadTokens) AS cacheReadTokens, SUM(cacheWriteTokens) AS cacheWriteTokens, SUM(costMicros) AS costMicros
            FROM api_usage WHERE day >= ? GROUP BY feature, model ORDER BY SUM(costMicros) DESC
            """, arguments: [dayKey(since)])
    }
}
