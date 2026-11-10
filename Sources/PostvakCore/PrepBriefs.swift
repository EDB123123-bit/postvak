import Foundation
import GRDB

/// A finished prep brief, kept so reopening an event doesn't write it again.
public struct PrepBriefRecord: PersistableModel, Hashable {
    public static let databaseTableName = "prep_brief"
    /// accountId/calendarId/eventId
    public var eventKey: String
    public var text: String
    public var createdAt: Date
    public init(eventKey: String, text: String, createdAt: Date) {
        self.eventKey = eventKey; self.text = text; self.createdAt = createdAt
    }
}

/// What Postvak knows about the people in a meeting, gathered for its prep brief.
public struct PrepContext: Sendable {
    public struct Thread: Sendable {
        public let id: String   // ACCOUNT/THREAD
        public let subject: String
        public let lastAt: Date
        public let messages: [(from: String, date: Date, text: String)]
    }
    public struct Meeting: Sendable {
        public let id: String
        public let title: String
        public let startedAt: Date
        public let summary: MeetingSummaryRecord?
    }
    public var guests: [EventAttendee]
    public var threads: [Thread]
    public var meetings: [Meeting]
    public var reminders: [FollowUpRecord]
    public var isEmpty: Bool { threads.isEmpty && meetings.isEmpty && reminders.isEmpty }
}

public final class PrepBriefs: Sendable {
    let db: AppDatabase

    public init(db: AppDatabase) { self.db = db }

    public static func key(_ e: CalendarEvent) -> String { "\(e.accountId)/\(e.calendarId)/\(e.eventId)" }

    /// A meeting that has ended shows its summary instead of a brief.
    public static func isOver(_ e: CalendarEvent, now: Date = Date()) -> Bool { e.endAt <= now }

    /// Meetings that get a brief: with at least one other guest, not all day, not declined.
    public static func wantsBrief(_ e: CalendarEvent) -> Bool {
        !e.isAllDay && e.selfResponse != "declined" && e.status != "cancelled" && e.attendees.contains { !$0.isSelf }
    }

    /// Addresses at these providers say nothing about someone's company.
    static let personalDomains: Set<String> = Matching.genericDomains

    public func cached(_ e: CalendarEvent) async throws -> PrepBriefRecord? {
        try await db.pool.read { try PrepBriefRecord.fetchOne($0, key: Self.key(e)) }
    }

    public func save(_ e: CalendarEvent, text: String) async throws {
        let r = PrepBriefRecord(eventKey: Self.key(e), text: text, createdAt: Date())
        try await db.pool.write { try r.save($0) }
    }

    /// Recent mail with the guests or their colleagues, earlier meetings with them and open reminders to them.
    public func context(for e: CalendarEvent, now: Date = Date()) async throws -> PrepContext {
        let ownAccounts = try await db.pool.read { try Account.fetchAll($0).map { $0.id.lowercased() } }
        let guests = e.attendees.filter { !$0.isSelf && !ownAccounts.contains($0.email.lowercased()) }
        let emails = guests.map { $0.email.lowercased() }
        let domains = Set(emails.compactMap { $0.split(separator: "@").last.map(String.init) }).subtracting(Self.personalDomains)
        guard !emails.isEmpty else { return PrepContext(guests: guests, threads: [], meetings: [], reminders: []) }
        let since = Calendar.current.date(byAdding: .day, value: -180, to: now)!

        return try await db.pool.read { db in
            // Mail from, to or copied to a guest, or from someone at their company.
            var who: [String] = []
            var args: [DatabaseValueConvertible] = [since]
            for m in emails {
                // Exact addresses: looking for jan@acme.be must not find dejan@acme.be.
                who.append("lower(fromEmail) = ? OR (lower(toLine) LIKE ? AND pv_has_address(toLine, ?)) OR (lower(ccLine) LIKE ? AND pv_has_address(ccLine, ?))")
                args += [m, "%\(m)%", m, "%\(m)%", m]
            }
            for d in domains {
                who.append("lower(fromEmail) LIKE ?")
                args.append("%@\(d)")
            }
            let threadRows = try Row.fetchAll(db, sql: """
                SELECT accountId, threadId, MAX(date) AS last FROM message
                WHERE date >= ? AND labelIds NOT LIKE '%|DRAFT|%' AND labelIds NOT LIKE '%|SPAM|%' AND labelIds NOT LIKE '%|TRASH|%'
                AND (\(who.joined(separator: " OR "))) GROUP BY accountId, threadId ORDER BY last DESC LIMIT 6
                """, arguments: StatementArguments(args))
            var threads: [PrepContext.Thread] = []
            for r in threadRows {
                let a: String = r["accountId"], t: String = r["threadId"]
                let msgs = try MailMessage.filter(Column("accountId") == a && Column("threadId") == t && !Column("labelIds").like("%|DRAFT|%"))
                    .order(Column("date").desc).limit(3).fetchAll(db).reversed()
                threads.append(PrepContext.Thread(id: "\(a)/\(t)", subject: msgs.last?.subject ?? "", lastAt: r["last"],
                                                  messages: msgs.map { (from: $0.senderDisplay, date: $0.date, text: String($0.bodyText.prefix(900))) }))
            }

            // Earlier meetings that had a guest in them, newest first.
            let meetingClauses = emails.map { _ in "lower(attendeesJSON) LIKE ?" }.joined(separator: " OR ")
            // The quotes around the address in the JSON make it an exact match.
            let meetings = try MeetingRecord.fetchAll(db, sql: """
                SELECT * FROM meeting WHERE startedAt < ? AND (\(meetingClauses)) ORDER BY startedAt DESC LIMIT 4
                """, arguments: StatementArguments([e.startAt] + emails.map { "%\"\($0)\"%" }))
            let withSummaries = try meetings.map { m in
                PrepContext.Meeting(id: m.id, title: m.title, startedAt: m.startedAt, summary: try MeetingSummaryRecord.fetchOne(db, key: m.id))
            }

            let reminders = try FollowUpRecord.filter([FollowUpRecord.Status.waiting.rawValue, FollowUpRecord.Status.due.rawValue].contains(Column("status")))
                .fetchAll(db).filter { f in !Matching.addresses(in: f.recipients).isDisjoint(with: emails) }

            return PrepContext(guests: guests, threads: threads, meetings: withSummaries, reminders: reminders)
        }
    }
}
