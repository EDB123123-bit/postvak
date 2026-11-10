import Foundation
import GRDB

/// An email thread with the people of a meeting, around the time it took place.
public struct RelatedThread: Sendable, Hashable, Identifiable {
    public let accountId: String
    public let threadId: String
    public let subject: String
    /// The latest message in the window.
    public let lastAt: Date
    public let sent: Int
    public let received: Int
    public let lastFromMe: Bool
    /// How many of the meeting's guests, by exact address, are in the thread. Zero means only colleagues at their company are.
    public let guestsInThread: Int
    /// The latest message in the window, the one a reply in the thread answers.
    public let lastMessageId: String
    public var id: String { "\(accountId)/\(threadId)" }
}

public enum RelatedMail {
    /// How far around a meeting mail counts as related to it.
    public static let daysBefore = 30
    public static let daysAfter = 14

    /// Calendar mail: invitations, updates and answers. Related by its guests, but not a conversation.
    static let calendarSubject = try! NSRegularExpression(pattern: #"^(invitation|updated invitation|uitnodiging|bijgewerkte uitnodiging|invitation mise à jour|accepted|declined|tentative|tentatively accepted|geaccepteerd|geweigerd|voorlopig geaccepteerd|accepté|refusé|accepté provisoirement|canceled event|cancelled event|geannuleerde afspraak|événement annulé)\b"#, options: [.caseInsensitive])

    /// An invitation quoted further along, as in "Automatic reply: Invitation: Demo" or "Jaarlijks verlof Re: Uitnodiging: …".
    static let quotedInvitation = try! NSRegularExpression(pattern: #"\b(invitation|uitnodiging|updated invitation|bijgewerkte uitnodiging|invitation mise à jour)\s*:"#, options: [.caseInsensitive])
    /// Out-of-office and other automatic answers.
    static let automaticReply = try! NSRegularExpression(pattern: #"^(automatic reply|auto-reply|autoreply|automatisch antwoord|réponse automatique|out of office|afwezig|absent)\b"#, options: [.caseInsensitive])

    public static func isCalendarSubject(_ s: String) -> Bool {
        let r = NSRange(s.startIndex..., in: s)
        return [calendarSubject, quotedInvitation, automaticReply].contains { $0.firstMatch(in: s, range: r) != nil }
    }

    /// Threads with a guest's exact address, or with someone at a guest's company domain, from `daysBefore` days before the
    /// meeting to `daysAfter` days after it. Calendar invitations are left out. Threads with the guests themselves come first,
    /// then the most recent.
    public static func threads(_ db: Database, guests: [String], around date: Date, limit: Int = 12) throws -> [RelatedThread] {
        let own = try Matching.ownAddresses(db)
        let exact = Set(guests.map { $0.lowercased() }.filter { $0.contains("@") && !own.contains($0) })
        let domains = Set(exact.compactMap(Matching.companyDomain)).subtracting(own.compactMap(Matching.companyDomain))
        guard !exact.isEmpty else { return [] }
        let from = Calendar.current.date(byAdding: .day, value: -daysBefore, to: date)!
        let to = Calendar.current.date(byAdding: .day, value: daysAfter, to: date)!

        // A fast LIKE finds candidates; the addresses are then checked exactly below.
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = [from, to]
        for e in exact {
            clauses.append("lower(fromEmail) = ? OR lower(toLine) LIKE ? OR lower(ccLine) LIKE ?")
            args += [e, "%\(e)%", "%\(e)%"]
        }
        for d in domains {
            clauses.append("lower(fromEmail) LIKE ? OR lower(toLine) LIKE ? OR lower(ccLine) LIKE ?")
            args += ["%@\(d)", "%@\(d)%", "%@\(d)%"]
        }
        let rows = try Row.fetchAll(db, sql: """
            SELECT accountId, threadId, messageId, rfcMessageId, lower(fromEmail) AS f, toLine, ccLine, subject, date FROM message
            WHERE date >= ? AND date <= ? AND labelIds NOT LIKE '%|DRAFT|%' AND labelIds NOT LIKE '%|SPAM|%' AND labelIds NOT LIKE '%|TRASH|%'
            AND (\(clauses.joined(separator: " OR "))) ORDER BY date
            """, arguments: StatementArguments(args))

        struct Acc { var subject = ""; var last = Date.distantPast; var lastId = ""; var lastRfc = ""; var sent = 0; var received = 0; var lastFromMe = false
                     var guests = Set<String>(); var calendar = false }
        var threads: [String: Acc] = [:]
        var keys: [String: (String, String)] = [:]
        for r in rows {
            let from: String = r["f"]
            let people = Matching.addresses(in: (r["toLine"] as String? ?? "") + ", " + (r["ccLine"] as String? ?? "")).union([from])
            let guestsHere = people.intersection(exact)
            let colleague = people.contains { Matching.companyDomain($0).map(domains.contains) == true }
            guard !guestsHere.isEmpty || colleague else { continue }
            let a: String = r["accountId"], t: String = r["threadId"], key = "\(a)/\(t)"
            keys[key] = (a, t)
            var acc = threads[key] ?? Acc()
            let subject: String = r["subject"], date: Date = r["date"]
            if Self.isCalendarSubject(subject) { acc.calendar = true; threads[key] = acc; continue }
            let mine = own.contains(from)
            if mine { acc.sent += 1 } else { acc.received += 1 }
            acc.guests.formUnion(guestsHere)
            if date >= acc.last {
                acc.last = date; acc.lastId = r["messageId"]; acc.subject = subject; acc.lastFromMe = mine
                acc.lastRfc = (r["rfcMessageId"] as String?) ?? "\(key)/\(acc.lastId)"
            }
            threads[key] = acc
        }
        // The same conversation kept in two accounts shows once: the copy with the most messages.
        var seenLast: [String: String] = [:]
        for (key, acc) in threads.sorted(by: { $0.value.sent + $0.value.received > $1.value.sent + $1.value.received }) where acc.sent + acc.received > 0 {
            if seenLast[acc.lastRfc] != nil { threads[key]?.sent = 0; threads[key]?.received = 0 } else { seenLast[acc.lastRfc] = key }
        }
        var out: [RelatedThread] = []
        for (key, acc) in threads where acc.sent + acc.received > 0 {
            let (a, t) = keys[key]!
            // An invitation sent as a calendar file is calendar mail whatever its subject.
            let ics = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM attachment x JOIN message m ON m.accountId = x.accountId AND m.messageId = x.messageId
                WHERE m.accountId = ? AND m.threadId = ? AND (lower(x.filename) LIKE '%.ics' OR lower(x.mimeType) LIKE 'text/calendar%')
                """, arguments: [a, t]) ?? 0
            if ics > 0 && acc.sent + acc.received <= 1 { continue }
            out.append(RelatedThread(accountId: a, threadId: t, subject: acc.subject, lastAt: acc.last, sent: acc.sent, received: acc.received,
                                     lastFromMe: acc.lastFromMe, guestsInThread: acc.guests.count, lastMessageId: acc.lastId))
        }
        out.sort { ($0.guestsInThread > 0 ? 1 : 0, $0.lastAt) > ($1.guestsInThread > 0 ? 1 : 0, $1.lastAt) }
        return Array(out.prefix(limit))
    }
}

public extension MeetingStore {
    /// The email threads related to a meeting: with its guests, around its date.
    func relatedThreads(meetingId: String, limit: Int = 12) async throws -> [RelatedThread] {
        try await db.pool.read { db in
            guard let m = try MeetingRecord.fetchOne(db, key: meetingId) else { return [] }
            let guests = m.attendees.filter { !$0.isSelf && $0.response != "declined" }.map(\.email)
            return try RelatedMail.threads(db, guests: guests, around: m.startedAt, limit: limit)
        }
    }
}
