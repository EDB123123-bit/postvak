import Foundation
import GRDB

/// One Ask Meetings question with what came back.
public struct AskTurnRecord: PersistableModel, Identifiable, Hashable {
    public static let databaseTableName = "ask_turn"
    public var id: String
    public var chatId: String
    public var question: String
    public var answer: String?
    public var error: String?
    public var stepsJSON: String
    public var askedAt: Date

    public init(id: String, chatId: String, question: String, answer: String?, error: String?, steps: [String], askedAt: Date) {
        self.id = id; self.chatId = chatId; self.question = question; self.answer = answer; self.error = error
        self.stepsJSON = (try? String(decoding: JSONEncoder().encode(steps), as: UTF8.self)) ?? "[]"
        self.askedAt = askedAt
    }

    public var steps: [String] { (try? JSONDecoder().decode([String].self, from: Data(stepsJSON.utf8))) ?? [] }
}

/// A past chat as the history lists it: named after its first question.
public struct AskChatSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let questions: Int
    public let lastAskedAt: Date
}

/// Every Ask Meetings chat, kept on this Mac.
public final class AskHistory: Sendable {
    let db: AppDatabase

    public init(db: AppDatabase) { self.db = db }

    /// Adds a question, or updates it once its answer or failure is in.
    public func save(_ turn: AskTurnRecord) async throws {
        try await db.pool.write { try turn.save($0) }
    }

    /// Newest first.
    public static let chatsRequest = SQLRequest<Row>(sql: """
        SELECT chatId, MIN(askedAt) AS started, MAX(askedAt) AS last, COUNT(*) AS n,
               (SELECT question FROM ask_turn f WHERE f.chatId = t.chatId ORDER BY askedAt LIMIT 1) AS title
        FROM ask_turn t GROUP BY chatId ORDER BY last DESC
        """)

    public static func chats(_ db: Database) throws -> [AskChatSummary] {
        try chatsRequest.fetchAll(db).map { r in
            AskChatSummary(id: r["chatId"], title: r["title"], questions: r["n"], lastAskedAt: r["last"])
        }
    }

    public func turns(chatId: String) async throws -> [AskTurnRecord] {
        try await db.pool.read { try AskTurnRecord.filter(Column("chatId") == chatId).order(Column("askedAt")).fetchAll($0) }
    }

    public func deleteChat(_ chatId: String) async throws {
        _ = try await db.pool.write { try AskTurnRecord.filter(Column("chatId") == chatId).deleteAll($0) }
    }
}
