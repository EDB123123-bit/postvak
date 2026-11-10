import Foundation
import GRDB

/// When to bring a sent mail back if nobody answers: after some working days, or on a chosen date.
public enum FollowUpRule: Codable, Hashable, Sendable {
    case workingDays(Int)
    case date(Date)

    public func due(after sent: Date) -> Date {
        switch self {
        case .date(let d): return d
        case .workingDays(let n): return FollowUps.workingDays(n, after: sent)
        }
    }
}

/// A sent mail Postvak watches for a reply.
public struct FollowUpRecord: PersistableModel, Identifiable, Hashable {
    public static let databaseTableName = "follow_up"
    public enum Status: String, Codable, Sendable {
        /// Waiting for a reply until `dueAt`.
        case waiting
        /// No reply came: the thread is back on top of the inbox.
        case due
        /// Someone answered, so the reminder ended by itself.
        case replied
        /// You followed up, or dismissed or cancelled it.
        case done
    }
    /// The Gmail id of the sent message.
    public var id: String
    public var accountId: String
    public var threadId: String
    public var subject: String
    public var recipients: String
    public var sentAt: Date
    public var dueAt: Date
    public var status: Status
    /// When it fell due, which is where the thread now sorts in the inbox.
    public var firedAt: Date?
    /// The nudge drafted for it, so it is written only once.
    public var nudgeDraftId: String?

    public init(id: String, accountId: String, threadId: String, subject: String, recipients: String, sentAt: Date, dueAt: Date) {
        self.id = id; self.accountId = accountId; self.threadId = threadId; self.subject = subject; self.recipients = recipients
        self.sentAt = sentAt; self.dueAt = dueAt; self.status = .waiting
    }
}

/// Follow-up reminders: only for mails where you asked for one.
public final class FollowUps: Sendable {
    let db: AppDatabase
    let mail: MailService

    public init(db: AppDatabase, mail: MailService) { self.db = db; self.mail = mail }

    /// `n` working days later at the same time of day. Saturdays and Sundays don't count.
    public static func workingDays(_ n: Int, after start: Date, calendar: Calendar = .current) -> Date {
        var d = start
        var left = n
        while left > 0 {
            d = calendar.date(byAdding: .day, value: 1, to: d)!
            if !calendar.isDateInWeekend(d) { left -= 1 }
        }
        return d
    }

    public func track(_ r: FollowUpRecord) async throws {
        try await db.pool.write { try r.save($0) }
    }

    /// Someone other than you wrote in the thread after `date`.
    static func replied(_ db: Database, _ f: FollowUpRecord, since date: Date) throws -> Bool {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM message WHERE accountId = ? AND threadId = ? AND date > ?
            AND lower(fromEmail) != lower(?) AND labelIds NOT LIKE '%|DRAFT|%'
            """, arguments: [f.accountId, f.threadId, date, f.accountId]) ?? 0 > 0
    }

    /// You sent something else in the thread after `date`, such as the nudge.
    static func followedUp(_ db: Database, _ f: FollowUpRecord, since date: Date) throws -> Bool {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM message WHERE accountId = ? AND threadId = ? AND date > ?
            AND lower(fromEmail) = lower(?) AND labelIds NOT LIKE '%|DRAFT|%'
            """, arguments: [f.accountId, f.threadId, date, f.accountId]) ?? 0 > 0
    }

    /// Ends reminders that got an answer and brings back those that didn't. Returns the ones that just fell due.
    @discardableResult
    public func check(now: Date = Date()) async -> [FollowUpRecord] {
        let open = (try? await db.pool.read {
            try FollowUpRecord.filter([FollowUpRecord.Status.waiting.rawValue, FollowUpRecord.Status.due.rawValue].contains(Column("status"))).fetchAll($0)
        }) ?? []
        var fell: [FollowUpRecord] = []
        for var f in open {
            let current = f
            let next: FollowUpRecord.Status? = (try? await db.pool.read { db -> FollowUpRecord.Status? in
                let f = current
                if try Self.replied(db, f, since: f.sentAt) { return .replied }
                if f.status == .due, let fired = f.firedAt, try Self.followedUp(db, f, since: fired) { return .done }
                if f.status == .waiting, f.dueAt <= now { return .due }
                return nil
            }) ?? nil
            guard let next else { continue }
            f.status = next
            if next == .due {
                f.firedAt = now
                // Back in the inbox, unread, even if it was archived meanwhile.
                try? await mail.modify(accountId: f.accountId, threadId: f.threadId, add: [GmailLabel.inbox, GmailLabel.unread])
                fell.append(f)
            }
            let saved = f
            try? await db.pool.write { try saved.update($0) }
        }
        return fell
    }

    public func setNudgeDraft(id: String, draftId: String) async throws {
        try await db.pool.write { db in
            guard var f = try FollowUpRecord.fetchOne(db, key: id) else { return }
            f.nudgeDraftId = draftId
            try f.update(db)
        }
    }

    /// Stops watching, or takes a due one off the top of the inbox.
    public func dismiss(id: String) async throws {
        try await db.pool.write { db in
            guard var f = try FollowUpRecord.fetchOne(db, key: id) else { return }
            f.status = .done
            try f.update(db)
        }
    }

    /// The reminder on a thread that is still waiting or due, if any.
    public static func open(_ db: Database, accountId: String, threadId: String) throws -> FollowUpRecord? {
        try FollowUpRecord.filter(Column("accountId") == accountId && Column("threadId") == threadId
                                  && [FollowUpRecord.Status.waiting.rawValue, FollowUpRecord.Status.due.rawValue].contains(Column("status")))
            .order(Column("sentAt").desc).fetchOne(db)
    }
}
