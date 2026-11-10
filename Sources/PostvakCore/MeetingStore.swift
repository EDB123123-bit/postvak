import Foundation
import GRDB

public struct ImportedSegment: Codable, Sendable {
    public var start: Double?
    public var end: Double?
    public var speaker: String?
    public var text: String
    public init(start: Double? = nil, end: Double? = nil, speaker: String? = nil, text: String) {
        self.start = start; self.end = end; self.speaker = speaker; self.text = text
    }
}

public struct ImportedMeeting: Codable, Sendable {
    public var source: String
    public var sourceId: String
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var attendees: [String]?
    public var language: String?
    public var summary: String?
    public var segments: [ImportedSegment]?
    public var actionItems: [ActionItem]?
    public var decisions: [String]?
    public init(source: String, sourceId: String, title: String, startedAt: Date, endedAt: Date? = nil, attendees: [String]? = nil,
                language: String? = nil, summary: String? = nil, segments: [ImportedSegment]? = nil, actionItems: [ActionItem]? = nil, decisions: [String]? = nil) {
        self.source = source; self.sourceId = sourceId; self.title = title; self.startedAt = startedAt; self.endedAt = endedAt
        self.attendees = attendees; self.language = language; self.summary = summary; self.segments = segments
        self.actionItems = actionItems; self.decisions = decisions
    }
}

public struct TranscriptHit: Codable, Sendable {
    public let meetingId: String
    public let meetingTitle: String
    public let startedAt: Date
    public let speaker: String
    public let startSeconds: Double
    public let text: String
}

public final class MeetingStore: Sendable {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    public func list(from: Date? = nil, to: Date? = nil, text: String? = nil, project: String? = nil, limit: Int = 100) async throws -> [MeetingRecord] {
        try await db.pool.read { db in
            var sql = "SELECT * FROM meeting WHERE 1=1"
            var args: [DatabaseValueConvertible] = []
            if let from { sql += " AND startedAt >= ?"; args.append(from) }
            if let to { sql += " AND startedAt < ?"; args.append(to) }
            if let t = text, !t.isEmpty { sql += " AND (title LIKE ? OR attendeesJSON LIKE ?)"; args.append("%\(t)%"); args.append("%\(t)%") }
            if let p = project, !p.isEmpty {
                if p.lowercased() == "unfiled" { sql += " AND project IS NULL" } else { sql += " AND lower(project) = lower(?)"; args.append(p) }
            }
            sql += " ORDER BY startedAt DESC LIMIT ?"
            args.append(limit)
            return try MeetingRecord.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    public func get(_ id: String) async throws -> (MeetingRecord, MeetingSummaryRecord?)? {
        try await db.pool.read { db in
            guard let m = try MeetingRecord.fetchOne(db, key: id) else { return nil }
            return (m, try MeetingSummaryRecord.fetchOne(db, key: id))
        }
    }

    public func segments(meetingId: String, offset: Int = 0, limit: Int = 100_000) async throws -> [TranscriptSegmentRecord] {
        try await db.pool.read { db in
            try TranscriptSegmentRecord.filter(Column("meetingId") == meetingId).order(Column("position")).limit(limit, offset: offset).fetchAll(db)
        }
    }

    public func segmentCount(meetingId: String) async throws -> Int {
        try await db.pool.read { try TranscriptSegmentRecord.filter(Column("meetingId") == meetingId).fetchCount($0) }
    }

    public func search(_ text: String, limit: Int = 30) async throws -> [TranscriptHit] {
        guard let match = ftsQuery(text) else { return [] }
        return try await db.pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.meetingId, m.title, m.startedAt, s.speaker, s.startSeconds, s.text
                FROM transcript_segment s
                JOIN transcript_ft ON transcript_ft.rowid = s.rowid
                JOIN meeting m ON m.id = s.meetingId
                WHERE transcript_ft MATCH ? ORDER BY m.startedAt DESC LIMIT ?
                """, arguments: [match, limit])
            return rows.map { TranscriptHit(meetingId: $0["meetingId"], meetingTitle: $0["title"], startedAt: $0["startedAt"],
                                            speaker: $0["speaker"], startSeconds: $0["startSeconds"], text: $0["text"]) }
        }
    }

    public func save(_ m: MeetingRecord) async throws { try await db.pool.write { try m.save($0) } }

    /// The title and guests the user gave a recording after stopping it, as "Name <address>" or bare addresses.
    /// The guest list becomes exactly what was given (the user stays); then the meeting is filed and its speakers
    /// named again with it.
    public func setDetails(meetingId: String, title: String, guests: [String]) async throws {
        try await db.pool.write { db in
            guard var m = try MeetingRecord.fetchOne(db, key: meetingId) else { return }
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { m.title = t }
            var given: [(name: String, email: String)] = []
            for g in guests {
                let p = GmailParser.parseAddress(g)
                let e = p.email.lowercased()
                if e.contains("@"), !given.contains(where: { $0.email == e }) { given.append((p.name, e)) }
            }
            let wanted = Set(given.map(\.email))
            var list = m.attendees.filter { $0.isSelf || wanted.contains($0.email.lowercased()) }
            let have = Set(list.map { $0.email.lowercased() })
            for g in given where !have.contains(g.email) {
                list.append(EventAttendee(email: g.email, name: g.name.isEmpty ? nil : g.name, response: "accepted"))
            }
            m.attendeesJSON = String(decoding: try JSONEncoder().encode(list), as: UTF8.self)
            try m.save(db)
        }
        try await fileMeetings(onlyNew: false, ids: [meetingId])
        try await assignSpeakers(meetingId: meetingId)
    }

    public func setStatus(_ id: String, _ s: MeetingRecord.Status, detail: String? = nil) async throws {
        try await db.pool.write { db in
            guard var m = try MeetingRecord.fetchOne(db, key: id) else { return }
            m.status = s
            m.statusDetail = detail
            try m.update(db)
        }
    }

    public func replaceSegments(meetingId: String, _ segments: [TranscriptSegmentRecord]) async throws {
        try await db.pool.write { db in
            try TranscriptSegmentRecord.filter(Column("meetingId") == meetingId).deleteAll(db)
            for s in segments { try s.insert(db) }
        }
    }

    public func saveSummary(_ s: MeetingSummaryRecord) async throws { try await db.pool.write { try s.save($0) } }

    public func updateSummaryText(meetingId: String, summary: String) async throws {
        try await db.pool.write { db in
            guard var s = try MeetingSummaryRecord.fetchOne(db, key: meetingId) else { return }
            s.summary = summary
            s.editedAt = Date()
            try s.update(db)
        }
    }

    public func delete(_ id: String) async throws {
        let m = try await db.pool.write { db -> MeetingRecord? in
            let m = try MeetingRecord.fetchOne(db, key: id)
            try m?.delete(db)
            return m
        }
        for p in [m?.micAudioPath, m?.systemAudioPath].compactMap({ $0 }) { try? FileManager.default.removeItem(atPath: p) }
    }

    /// The meeting recorded or imported for a calendar event: the one linked to it, from any account's copy,
    /// or else an unlinked one that started near it: a recording between 15 minutes before the event and its end, an
    /// imported meeting within 15 minutes of its start.
    public func meeting(for e: CalendarEvent) async throws -> MeetingRecord? {
        try await db.pool.read { db in
            if let linked = try MeetingRecord.filter(Column("eventCalendarId") == e.calendarId && Column("eventId") == e.eventId)
                .order(Column("startedAt").desc).fetchOne(db) { return linked }
            guard !e.isAllDay else { return nil }
            // A recording may start late into the event. An imported meeting must start close to it, or a call held halfway
            // through a long calendar block would show as that block's meeting.
            let near = Column("startedAt") >= e.startAt.addingTimeInterval(-Self.importLinkWindow)
            let recording = Column("source") == "recorded" && near && Column("startedAt") < e.endAt
            let imported = Column("source") != "recorded" && near && Column("startedAt") <= e.startAt.addingTimeInterval(Self.importLinkWindow)
            return try MeetingRecord.filter(Column("eventId") == nil && (recording || imported))
                .order(Column("startedAt")).fetchOne(db)
        }
    }

    /// Links a meeting to the event overlapping it most, and copies title and attendees when the meeting has none yet.
    @discardableResult
    public func linkToBestEvent(meetingId: String) async throws -> CalendarEvent? {
        try await db.pool.write { db in
            guard var m = try MeetingRecord.fetchOne(db, key: meetingId) else { return nil }
            let end = m.endedAt ?? Date()
            let candidates = try CalendarEvent.fetchAll(db, sql: "SELECT * FROM event WHERE endAt > ? AND startAt < ? AND isAllDay = 0", arguments: [m.startedAt, end])
            guard let found = Self.bestEvent(start: m.startedAt, end: end, events: candidates) else { return nil }
            let best = try Self.fullestCopy(of: found, db)
            m.eventAccountId = best.accountId
            m.eventCalendarId = best.calendarId
            m.eventId = best.eventId
            if m.attendees.isEmpty { m.attendeesJSON = best.attendeesJSON }
            if m.title.isEmpty || m.title == MeetingRecord.untitled { m.title = best.summary }
            try m.update(db)
            return best
        }
    }

    /// Links imported meetings to the event they were held for: one starting within 15 minutes of the meeting. An event
    /// goes to one imported meeting only, the one starting closest to it, so the outcome does not depend on the order they
    /// came in. Events linked to Postvak's own recordings stay theirs. A call recorded halfway through a long calendar
    /// block is not that block, so it stays unlinked. Returns the meetings whose link changed.
    @discardableResult
    public func linkImportedMeetings() async throws -> [String] {
        try await db.pool.write { db in
            let imported = try MeetingRecord.filter(Column("source") != "recorded").fetchAll(db)
            guard let first = imported.map(\.startedAt).min(), let last = imported.map(\.startedAt).max() else { return [] }
            let window = Self.importLinkWindow
            let taken = Set(try Row.fetchAll(db, sql: "SELECT eventCalendarId, eventId FROM meeting WHERE eventId IS NOT NULL AND source = 'recorded'")
                .map { "\($0["eventCalendarId"] as String? ?? "")/\($0["eventId"] as String)" })
            let events = try CalendarEvent.fetchAll(db, sql: "SELECT * FROM event WHERE isAllDay = 0 AND startAt >= ? AND startAt <= ?",
                                                    arguments: [first.addingTimeInterval(-window), last.addingTimeInterval(window)])
                .filter { $0.selfResponse != "declined" && $0.status != "cancelled" && !taken.contains("\($0.calendarId)/\($0.eventId)") }
            var pairs: [(distance: TimeInterval, meeting: Int, event: CalendarEvent)] = []
            for (i, m) in imported.enumerated() {
                for e in events {
                    let d = abs(e.startAt.timeIntervalSince(m.startedAt))
                    if d <= window { pairs.append((d, i, e)) }
                }
            }
            // Closest first; ties go to the earlier meeting and event, so every run picks the same.
            pairs.sort { ($0.distance, $0.meeting, $0.event.eventId) < ($1.distance, $1.meeting, $1.event.eventId) }
            var choice: [Int: CalendarEvent] = [:], usedEvents = Set<String>()
            for p in pairs {
                let key = "\(p.event.calendarId)/\(p.event.eventId)"
                guard choice[p.meeting] == nil, !usedEvents.contains(key) else { continue }
                choice[p.meeting] = p.event
                usedEvents.insert(key)
            }
            var changed: [String] = []
            for (i, var m) in imported.enumerated() {
                let e = choice[i]
                guard m.eventCalendarId != e?.calendarId || m.eventId != e?.eventId else { continue }
                if let e {
                    let best = try Self.fullestCopy(of: e, db)
                    m.eventAccountId = best.accountId
                    m.eventCalendarId = best.calendarId
                    m.eventId = best.eventId
                    if m.attendees.isEmpty { m.attendeesJSON = best.attendeesJSON }
                    if m.title.isEmpty || m.title == MeetingRecord.untitled { m.title = best.summary }
                } else {
                    // Guests copied from the event it loses go with it.
                    if let c = m.eventCalendarId, let id = m.eventId,
                       try CalendarEvent.filter(Column("eventId") == id && Column("calendarId") == c && Column("attendeesJSON") == m.attendeesJSON).fetchCount(db) > 0 {
                        m.attendeesJSON = "[]"
                    }
                    m.eventAccountId = nil; m.eventCalendarId = nil; m.eventId = nil
                }
                try m.update(db)
                changed.append(m.id)
            }
            return changed
        }
    }

    static let importLinkWindow: TimeInterval = 15 * 60

    /// The copy of an event that lists its guests. A calendar shared into another account shows the same event without
    /// them, so the copy with the most attendees is the real one.
    public static func fullestCopy(of e: CalendarEvent, _ db: Database) throws -> CalendarEvent {
        let copies = try CalendarEvent.filter(Column("eventId") == e.eventId && Column("calendarId") == e.calendarId).fetchAll(db)
        return copies.max { $0.attendees.count < $1.attendees.count } ?? e
    }

    /// Meetings linked to a guest-less copy of their event get the guests of the full copy. Returns the meetings changed.
    @discardableResult
    public func repairEventAttendees() async throws -> [String] {
        try await db.pool.write { db in
            var changed: [String] = []
            for var m in try MeetingRecord.filter(Column("eventId") != nil && Column("attendeesJSON") == "[]").fetchAll(db) {
                guard let c = m.eventCalendarId, let id = m.eventId,
                      let full = try CalendarEvent.filter(Column("eventId") == id && Column("calendarId") == c).fetchAll(db)
                        .max(by: { $0.attendees.count < $1.attendees.count }), !full.attendees.isEmpty else { continue }
                m.eventAccountId = full.accountId
                m.attendeesJSON = full.attendeesJSON
                try m.update(db)
                changed.append(m.id)
            }
            return changed
        }
    }

    public static func bestEvent(start: Date, end: Date, events: [CalendarEvent]) -> CalendarEvent? {
        var best: CalendarEvent?
        var bestOverlap: TimeInterval = 0
        for e in events where e.selfResponse != "declined" {
            let overlap = min(end, e.endAt).timeIntervalSince(max(start, e.startAt))
            if overlap > bestOverlap { bestOverlap = overlap; best = e }
        }
        return best
    }

    /// Idempotent import keyed on source and source id. Returns true when the meeting was new.
    @discardableResult
    public func importMeeting(_ i: ImportedMeeting) async throws -> Bool {
        let (id, isNew) = try await db.pool.write { db -> (String, Bool) in
            let existing = try MeetingRecord.filter(Column("source") == i.source && Column("sourceId") == i.sourceId).fetchOne(db)
            var m = existing ?? MeetingRecord(title: i.title, startedAt: i.startedAt, endedAt: i.endedAt, status: .ready, source: i.source, sourceId: i.sourceId)
            m.title = i.title
            m.startedAt = i.startedAt
            m.endedAt = i.endedAt
            m.language = i.language
            m.status = .ready
            m.transcriptEngine = i.source
            let atts = (i.attendees ?? []).map { raw -> EventAttendee in
                let (n, e) = GmailParser.parseAddress(raw)
                return EventAttendee(email: e, name: n.isEmpty ? nil : n)
            }
            m.attendeesJSON = String(decoding: (try? JSONEncoder().encode(atts)) ?? Data("[]".utf8), as: UTF8.self)
            try m.save(db)
            if let segs = i.segments {
                try TranscriptSegmentRecord.filter(Column("meetingId") == m.id).deleteAll(db)
                for (idx, s) in segs.enumerated() {
                    try TranscriptSegmentRecord(meetingId: m.id, position: idx, startSeconds: s.start ?? 0, endSeconds: s.end ?? s.start ?? 0,
                                                speaker: s.speaker ?? "Unknown", text: s.text).insert(db)
                }
            }
            if let summary = i.summary, !summary.isEmpty {
                try MeetingSummaryRecord(meetingId: m.id, summary: summary, decisions: i.decisions ?? [], actionItems: i.actionItems ?? [],
                                         openQuestions: [], model: i.source).save(db)
            }
            return (m.id, existing == nil)
        }
        try await linkImportedMeetings()
        try await fileMeetings(onlyNew: false, ids: [id])
        return isNew
    }
}

/// One place in a meeting where search words were found.
public struct MeetingSearchHit: Sendable {
    public enum Kind: String, Sendable { case transcript, summary, decision, actionItem = "action item", openQuestion = "open question", title }
    public let meetingId: String
    public let meetingTitle: String
    public let startedAt: Date
    public let kind: Kind
    public let speaker: String?
    public let startSeconds: Double?
    public let text: String
    /// How many of the search words this hit contains.
    public let matched: Int
}

public extension MeetingStore {
    /// Searches transcripts, summaries, decisions, action items, open questions, titles and attendees. Each word matches
    /// on its own as a word prefix, ignoring case and accents, and hits containing more of the words come first.
    func searchEverywhere(_ text: String, from: Date? = nil, to: Date? = nil, limit: Int = 30) async throws -> [MeetingSearchHit] {
        let words = Self.searchWords(text)
        guard !words.isEmpty else { return [] }
        return try await db.pool.read { db in
            var dateSQL = ""
            var dateArgs: [DatabaseValueConvertible] = []
            if let from { dateSQL += " AND m.startedAt >= ?"; dateArgs.append(from) }
            if let to { dateSQL += " AND m.startedAt < ?"; dateArgs.append(to) }
            var hits: [MeetingSearchHit] = []

            // Transcripts can be long, so the full-text index finds the segments containing any of the words.
            let match = words.map { "\"\($0)\"*" }.joined(separator: " OR ")
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.meetingId, m.title, m.startedAt, s.speaker, s.startSeconds, s.text
                FROM transcript_ft
                JOIN transcript_segment s ON s.rowid = transcript_ft.rowid
                JOIN meeting m ON m.id = s.meetingId
                WHERE transcript_ft MATCH ?\(dateSQL) ORDER BY rank LIMIT 500
                """, arguments: StatementArguments([match] + dateArgs))
            for r in rows {
                let t: String = r["text"]
                hits.append(MeetingSearchHit(meetingId: r["meetingId"], meetingTitle: r["title"], startedAt: r["startedAt"], kind: .transcript,
                                             speaker: r["speaker"], startSeconds: r["startSeconds"], text: t, matched: Self.matchCount(words, in: t)))
            }

            // Summaries and titles are short enough to scan.
            let meetings = try MeetingRecord.fetchAll(db, sql: "SELECT m.* FROM meeting m WHERE 1=1\(dateSQL)", arguments: StatementArguments(dateArgs))
            var summaries: [String: MeetingSummaryRecord] = [:]
            for s in try MeetingSummaryRecord.fetchAll(db) { summaries[s.meetingId] = s }
            for m in meetings {
                let people = m.attendees.map { [$0.name, $0.email].compactMap { $0 }.joined(separator: " ") }.joined(separator: ", ")
                var chunks: [(MeetingSearchHit.Kind, String)] = [(.title, people.isEmpty ? m.title : "\(m.title) (\(people))")]
                if let s = summaries[m.id] {
                    chunks += Self.passages(s.summary).map { (.summary, $0) }
                    chunks += s.decisions.map { (.decision, $0) }
                    chunks += s.actionItems.map { a in
                        (.actionItem, ([a.task] + [a.owner.map { "owner: \($0)" }, a.due.map { "due: \($0)" }].compactMap { $0 }).joined(separator: "; "))
                    }
                    chunks += s.openQuestions.map { (.openQuestion, $0) }
                }
                for (kind, t) in chunks {
                    let n = Self.matchCount(words, in: t)
                    if n > 0 {
                        hits.append(MeetingSearchHit(meetingId: m.id, meetingTitle: m.title, startedAt: m.startedAt, kind: kind,
                                                     speaker: nil, startSeconds: nil, text: t, matched: n))
                    }
                }
            }
            hits.sort { ($0.matched, $0.startedAt) > ($1.matched, $1.startedAt) }
            return Array(hits.prefix(limit))
        }
    }

    /// Which meetings have a summary, and how many transcript segments each has.
    func contentInfo() async throws -> (summaries: Set<String>, segments: [String: Int]) {
        try await db.pool.read { db in
            let summaries = Set(try String.fetchAll(db, sql: "SELECT meetingId FROM meeting_summary"))
            var segments: [String: Int] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT meetingId, COUNT(*) AS n FROM transcript_segment GROUP BY meetingId") {
                segments[r["meetingId"]] = r["n"]
            }
            return (summaries, segments)
        }
    }

    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    static func searchWords(_ text: String) -> [String] {
        var seen = Set<String>()
        return fold(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 2 && seen.insert($0).inserted }
    }

    static func matchCount(_ words: [String], in text: String) -> Int {
        let tokens = fold(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.filter { w in tokens.contains { $0.hasPrefix(w) } }.count
    }

    /// A summary split into paragraphs, and long paragraphs into sentences, so a hit quotes only the relevant part.
    static func passages(_ text: String) -> [String] {
        var out: [String] = []
        for p in text.split(whereSeparator: \.isNewline) {
            let para = p.trimmingCharacters(in: .whitespaces)
            if para.isEmpty { continue }
            if para.count <= 400 { out.append(para); continue }
            para.enumerateSubstrings(in: para.startIndex..., options: .bySentences) { s, _, _, _ in
                if let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty { out.append(s) }
            }
        }
        return out
    }
}

public extension MeetingRecord {
    static let untitled = "Untitled meeting"
}
