import Foundation
import GRDB

/// A draft Postvak wrote on its own: in the follow-up review, for a reminder, after a meeting, or for Claude through MCP.
/// It stays listed until the user sends, edits or deletes it, so no draft sits unseen in Drafts.
public struct AutoDraftRecord: PersistableModel, Identifiable, Hashable {
    public static let databaseTableName = "auto_draft"
    public enum Source: String, Codable, Sendable {
        case review, reminder, meeting, claude
        public var title: String {
            switch self {
            case .review: "Follow-up review"
            case .reminder: "Reminder"
            case .meeting: "Meeting follow-up"
            case .claude: "Claude"
            }
        }
    }
    public enum Status: String, Codable, Sendable {
        case pending
        case sent
        case deleted
        /// Left in Drafts on purpose: out of the review, still in Gmail.
        case kept
        /// No longer in Drafts: sent from the composer, or deleted in Gmail itself.
        case gone
    }
    public var id: String
    public var accountId: String
    public var draftId: String
    public var threadId: String?
    /// The address it goes out as: the account, or one of its send-as addresses.
    public var fromEmail: String
    public var recipients: String
    public var subject: String
    public var source: Source
    /// Why it was written, in one line: who waits for what, since when.
    public var reason: String
    public var meetingId: String?
    public var createdAt: Date
    public var status: Status
    public var reviewedAt: Date?

    public init(id: String = UUID().uuidString, accountId: String, draftId: String, threadId: String?, fromEmail: String, recipients: String,
                subject: String, source: Source, reason: String, meetingId: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.accountId = accountId; self.draftId = draftId; self.threadId = threadId; self.fromEmail = fromEmail
        self.recipients = recipients; self.subject = subject; self.source = source; self.reason = reason; self.meetingId = meetingId
        self.createdAt = createdAt; self.status = .pending
    }
}

/// The list of drafts waiting for review.
public final class AutoDrafts: Sendable {
    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    @discardableResult
    public func record(_ r: AutoDraftRecord) async throws -> AutoDraftRecord {
        try await db.pool.write { try r.insert($0) }
        return r
    }

    public func pending() async throws -> [AutoDraftRecord] {
        try await db.pool.read { try AutoDraftRecord.filter(Column("status") == AutoDraftRecord.Status.pending.rawValue).order(Column("createdAt")).fetchAll($0) }
    }

    public func setStatus(_ id: String, _ status: AutoDraftRecord.Status, now: Date = Date()) async throws {
        try await db.pool.write { db in
            try db.execute(sql: "UPDATE auto_draft SET status = ?, reviewedAt = ? WHERE id = ?", arguments: [status.rawValue, now, id])
        }
    }

    /// Drafts that left Gmail's Drafts some other way (sent from the composer, deleted in Gmail) leave the review.
    /// A fresh one is left alone for a few minutes, in case its thread hasn't synced yet.
    @discardableResult
    public func reconcile(now: Date = Date()) async throws -> Int {
        try await db.pool.write { db in
            try db.execute(sql: """
                UPDATE auto_draft SET status = 'gone', reviewedAt = ?
                WHERE status = 'pending' AND threadId IS NOT NULL AND createdAt < ?
                AND NOT EXISTS (SELECT 1 FROM message m WHERE m.accountId = auto_draft.accountId AND m.threadId = auto_draft.threadId
                                AND m.labelIds LIKE '%|DRAFT|%')
                """, arguments: [now, now.addingTimeInterval(-600)])
            return db.changesCount
        }
    }
}

/// A thread the follow-up review looks at: someone waits on the user, or the user's own mail got no answer.
public struct FollowUpCandidate: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
        /// They wrote last, to the user, and got no answer.
        case waitingOnYou
        /// The user wrote last, at least three working days ago, and nobody answered.
        case waitingOnThem
    }
    public var kind: Kind
    /// The message to answer or follow up on.
    public var last: MailMessage
    /// The other side: the sender, or the people the user wrote to.
    public var people: [String]
    /// A recipient's company is an open deal, which puts it first.
    public var isDeal: Bool
    public var id: String { last.id }
}

/// Finds what needs a follow-up, without Claude: Claude then judges each thread and writes the draft.
public enum FollowUpReview {
    public enum Frequency: String, CaseIterable, Sendable {
        case off, daily, weekly
        public var title: String {
            switch self {
            case .off: "Off"
            case .daily: "Every weekday morning"
            case .weekly: "Monday mornings"
            }
        }
    }
    public static let settingKey = "ai.followUpReview"
    public static let lastRunKey = "followUpReview.lastRun"
    /// After mail scheduled for 08:00 went out, so that one counts as sent.
    static let slotHour = 8, slotMinute = 15

    /// The latest morning slot at or before `now`: weekdays for daily, Mondays for weekly.
    public static func slot(_ f: Frequency, now: Date, calendar: Calendar = .current) -> Date? {
        guard f != .off else { return nil }
        var day = calendar.startOfDay(for: now)
        for _ in 0..<8 {
            let wd = calendar.component(.weekday, from: day)
            let ok = f == .weekly ? wd == 2 : (2...6).contains(wd)
            if ok, let s = calendar.date(bySettingHour: slotHour, minute: slotMinute, second: 0, of: day), s <= now { return s }
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return nil
    }

    /// Due once per slot. A Mac that was asleep at 08:15 runs it at the first mail sync after it wakes.
    public static func isDue(_ f: Frequency, lastRun: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let s = slot(f, now: now, calendar: calendar) else { return false }
        return (lastRun ?? .distantPast) < s
    }

    /// Senders and subjects that are machines or calendar traffic, never worth a personal follow-up.
    static func automated(_ address: String) -> Bool {
        let local = address.split(separator: "@").first.map { $0.lowercased() } ?? ""
        return ["noreply", "no-reply", "donotreply", "do-not-reply", "notification", "mailer-daemon", "postmaster", "bounce",
                "calendar", "invitations", "newsletter", "news", "marketing", "support", "billing", "invoice", "receipts"]
            .contains { local.contains($0) }
    }
    static func calendarTraffic(_ subject: String) -> Bool {
        let s = subject.lowercased()
        return ["invitation:", "updated invitation", "accepted:", "declined:", "tentatively accepted", "uitnodiging:", "bijgewerkte uitnodiging",
                "geaccepteerd:", "afgewezen:", "invitation mise à jour", "accepté :", "refusé :", "invitation :"].contains { s.hasPrefix($0) }
    }

    /// An address and, for a company address, its domain: mail to anyone at that company counts.
    static func keys(_ address: String) -> [String] {
        let a = address.lowercased()
        return [a] + (Matching.companyDomain(a).map { ["@" + $0] } ?? [])
    }

    static func recipients(_ m: MailMessage) -> [String] {
        Matching.addresses(in: m.toLine + ", " + m.ccLine).map { $0.lowercased() }
    }

    /// Threads from the last `days` that wait on someone. Left out: newsletters and notifications, machines, calendar mail,
    /// threads with a draft already, snoozed threads, threads a follow-up reminder already watches, and anything the user
    /// followed up some other way since: a mail to the same person or company from any account, or one still queued.
    public static func candidates(_ db: Database, now: Date = Date(), days: Int = 14, limit: Int = 20) throws -> [FollowUpCandidate] {
        let since = now.addingTimeInterval(-Double(days) * 86400)
        let config = try ProjectConfig.load(db)
        let own = try Matching.ownAddresses(db).union(config.projects.flatMap { $0.accounts + $0.addresses }.map { $0.lowercased() })
        let msgs = try MailMessage.filter(Column("date") >= since)
            .filter(!Column("labelIds").like("%|SPAM|%") && !Column("labelIds").like("%|TRASH|%"))
            .order(Column("date")).fetchAll(db)
        var bucket: [String: String] = [:]
        for r in try Row.fetchAll(db, sql: "SELECT accountId, threadId, bucket FROM thread WHERE lastMessageAt >= ?", arguments: [since]) {
            if let b: String = r["bucket"] { bucket["\(r["accountId"] as String)/\(r["threadId"] as String)"] = b }
        }
        let snoozed = Set(try SnoozeRow.fetchAll(db).map { "\($0.accountId)/\($0.threadId)" })
        let watched = Set(try String.fetchAll(db, sql: "SELECT accountId || '/' || threadId FROM follow_up WHERE status IN ('waiting', 'due')"))
        let deals = Set(try String.fetchAll(db, sql: "SELECT key FROM deal WHERE isDeal = 1"))

        // Who the user wrote to, and who wrote to the user, with the latest date, by address and company.
        var wroteTo: [String: Date] = [:], heardFrom: [String: Date] = [:]
        func note(_ map: inout [String: Date], _ address: String, _ d: Date) {
            for k in keys(address) where (map[k] ?? .distantPast) < d { map[k] = d }
        }
        for m in msgs where !m.isDraft {
            if own.contains(m.fromEmail.lowercased()) || m.labels.contains(GmailLabel.sent) {
                for r in recipients(m) where !own.contains(r) { note(&wroteTo, r, m.date) }
            } else {
                note(&heardFrom, m.fromEmail, m.date)
            }
        }
        // Mail still in the outbox counts as written now.
        for r in try OutboxRow.fetchAll(db) {
            guard let mail = try? JSONDecoder().decode(OutgoingMail.self, from: r.payload) else { continue }
            for a in mail.to + mail.cc { note(&wroteTo, GmailParser.parseAddress(a).email, .distantFuture) }
        }
        func later(_ map: [String: Date], _ people: [String], than d: Date) -> Bool {
            people.contains { p in keys(p).contains { (map[$0] ?? .distantPast) > d } }
        }

        var out: [FollowUpCandidate] = []
        for (key, list) in Dictionary(grouping: msgs, by: { "\($0.accountId)/\($0.threadId)" }) {
            if snoozed.contains(key) || watched.contains(key) || list.contains(where: \.isDraft) { continue }
            if let b = bucket[key], b == InboxBucket.newsletters.rawValue || b == InboxBucket.notifications.rawValue { continue }
            guard let last = list.last, !last.hasListUnsubscribe, !calendarTraffic(last.subject) else { continue }
            let from = last.fromEmail.lowercased()
            let mine = own.contains(from) || last.labels.contains(GmailLabel.sent)
            var c: FollowUpCandidate
            if mine {
                guard FollowUps.workingDays(3, after: last.date) <= now else { continue }
                let people = recipients(last).filter { !own.contains($0) && !automated($0) }
                guard !people.isEmpty, !later(wroteTo, people, than: last.date), !later(heardFrom, people, than: last.date) else { continue }
                c = FollowUpCandidate(kind: .waitingOnThem, last: last, people: people, isDeal: false)
            } else {
                guard !automated(from), now.timeIntervalSince(last.date) >= 20 * 3600,
                      recipients(last).contains(where: own.contains), !later(wroteTo, [from], than: last.date) else { continue }
                c = FollowUpCandidate(kind: .waitingOnYou, last: last, people: [from], isDeal: false)
            }
            c.isDeal = c.people.contains { Matching.companyDomain($0).map(deals.contains) ?? deals.contains($0) }
            out.append(c)
        }
        return Array(out.sorted { ($0.isDeal ? 1 : 0, $0.last.date) > ($1.isDeal ? 1 : 0, $1.last.date) }.prefix(limit))
    }

    /// Business meetings of the last `days` with a summary and outside guests, after which no mail went to any guest
    /// and no draft was written yet: each gets a follow-up from its agreed next steps.
    public static func meetingCandidates(_ db: Database, now: Date = Date(), days: Int = 14, limit: Int = 5) throws -> [MeetingRecord] {
        let since = now.addingTimeInterval(-Double(days) * 86400)
        let config = try ProjectConfig.load(db)
        let own = try Matching.ownAddresses(db).union(config.projects.flatMap { $0.accounts + $0.addresses }.map { $0.lowercased() })
        let summarized = Set(try String.fetchAll(db, sql: "SELECT meetingId FROM meeting_summary"))
        let drafted = Set(try String.fetchAll(db, sql: "SELECT meetingId FROM auto_draft WHERE meetingId IS NOT NULL"))
        var out: [MeetingRecord] = []
        for m in try MeetingRecord.filter(Column("startedAt") >= since).order(Column("startedAt").desc).fetchAll(db) {
            guard let end = m.endedAt, now.timeIntervalSince(end) >= 20 * 3600, summarized.contains(m.id), !drafted.contains(m.id),
                  m.project != "Personal" else { continue }
            let guests = m.attendees.filter { !$0.isSelf }.map { $0.email.lowercased() }.filter { !own.contains($0) && !automated($0) }
            guard guests.contains(where: { Matching.companyDomain($0) != nil }) else { continue }
            let guestKeys = Set(guests.flatMap(keys))
            // Any mail or draft to a guest or their company since the meeting means it was followed up, or is being.
            let after = try MailMessage.filter(Column("date") > end).filter(sql: "labelIds LIKE '%|SENT|%' OR labelIds LIKE '%|DRAFT|%'").fetchAll(db)
            if after.contains(where: { recipients($0).contains { keys($0).contains(where: guestKeys.contains) } }) { continue }
            let queued = try OutboxRow.fetchAll(db).compactMap { try? JSONDecoder().decode(OutgoingMail.self, from: $0.payload) }
            if queued.contains(where: { ($0.to + $0.cc).contains { keys(GmailParser.parseAddress($0).email).contains(where: guestKeys.contains) } }) { continue }
            out.append(m)
            if out.count >= limit { break }
        }
        return out
    }
}
