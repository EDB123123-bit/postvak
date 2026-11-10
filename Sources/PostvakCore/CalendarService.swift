import Foundation
import GRDB

struct CalListDTO: Codable {
    struct C: Codable {
        let id: String; let summary: String?; let summaryOverride: String?; let backgroundColor: String?
        let primary: Bool?; let selected: Bool?; let accessRole: String?
    }
    let items: [C]?; let nextPageToken: String?
}

struct EventDTO: Codable {
    struct When: Codable { let date: String?; let dateTime: String?; let timeZone: String? }
    struct Att: Codable { let email: String?; let displayName: String?; let responseStatus: String?; let `self`: Bool?; let organizer: Bool? }
    struct Org: Codable { let email: String? }
    struct Conf: Codable { struct E: Codable { let uri: String?; let entryPointType: String? }; let entryPoints: [E]? }
    let id: String
    let status: String?
    let summary: String?
    let description: String?
    let location: String?
    let start: When?
    let end: When?
    let transparency: String?
    let organizer: Org?
    let attendees: [Att]?
    let hangoutLink: String?
    let htmlLink: String?
    let recurringEventId: String?
    let conferenceData: Conf?
}
struct EventListDTO: Codable { let items: [EventDTO]?; let nextPageToken: String?; let nextSyncToken: String? }

public struct EventInput: Sendable {
    public var accountId: String
    public var calendarId: String
    public var summary: String
    public var details: String?
    public var location: String?
    public var start: Date
    public var end: Date
    public var isAllDay = false
    public var attendees: [String] = []
    public var recurrence: [String] = []
    public var addMeetLink = false
    public init(accountId: String, calendarId: String, summary: String, details: String? = nil, location: String? = nil,
                start: Date, end: Date, isAllDay: Bool = false, attendees: [String] = [], recurrence: [String] = [], addMeetLink: Bool = false) {
        self.accountId = accountId; self.calendarId = calendarId; self.summary = summary; self.details = details
        self.location = location; self.start = start; self.end = end; self.isAllDay = isAllDay
        self.attendees = attendees; self.recurrence = recurrence; self.addMeetLink = addMeetLink
    }
}

public struct EventPatch: Sendable {
    public var summary: String?
    public var details: String?
    public var location: String?
    public var start: Date?
    public var end: Date?
    public var isAllDay: Bool?
    public var attendees: [String]?
    public init(summary: String? = nil, details: String? = nil, location: String? = nil, start: Date? = nil, end: Date? = nil, isAllDay: Bool? = nil, attendees: [String]? = nil) {
        self.summary = summary; self.details = details; self.location = location; self.start = start
        self.end = end; self.isAllDay = isAllDay; self.attendees = attendees
    }
}

public struct FreeSlot: Codable, Sendable, Hashable {
    public let start: Date
    public let end: Date
}

public final class CalendarService: Sendable {
    let db: AppDatabase
    let api: GoogleAPI
    static let base = "https://www.googleapis.com/calendar/v3"

    public init(db: AppDatabase, api: GoogleAPI) { self.db = db; self.api = api }

    private func enc(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: date mapping

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    nonisolated(unsafe) static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static func dayFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f
    }
    static func parse(_ w: EventDTO.When?) -> (Date, Bool)? {
        guard let w else { return nil }
        if let s = w.dateTime, let d = iso.date(from: s) ?? isoFrac.date(from: s) { return (d, false) }
        if let s = w.date, let d = dayFormatter().date(from: s) { return (d, true) }
        return nil
    }

    static func record(_ dto: EventDTO, accountId: String, calendarId: String) -> CalendarEvent? {
        guard let (start, allDay) = parse(dto.start) else { return nil }
        let end = parse(dto.end)?.0 ?? start
        let atts = (dto.attendees ?? []).compactMap { a -> EventAttendee? in
            guard let e = a.email else { return nil }
            return EventAttendee(email: e.lowercased(), name: a.displayName, response: a.responseStatus ?? "needsAction",
                                 isSelf: a.`self` ?? false, isOrganizer: a.organizer ?? false)
        }
        let selfResp = atts.first(where: \.isSelf)?.response
        let video = dto.conferenceData?.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri
        let attJSON = String(decoding: (try? JSONEncoder().encode(atts)) ?? Data("[]".utf8), as: UTF8.self)
        return CalendarEvent(
            accountId: accountId, calendarId: calendarId, eventId: dto.id,
            summary: dto.summary ?? "(no title)", details: dto.description ?? "", location: dto.location ?? "",
            startAt: start, endAt: end, isAllDay: allDay, status: dto.status ?? "confirmed",
            transparency: dto.transparency ?? "opaque", organizerEmail: dto.organizer?.email?.lowercased() ?? "",
            attendeesJSON: attJSON, selfResponse: selfResp,
            meetingLink: dto.hangoutLink ?? video ?? Self.findMeetingLink(in: (dto.location ?? "") + " " + (dto.description ?? "")),
            htmlLink: dto.htmlLink, recurringEventId: dto.recurringEventId)
    }

    public static func findMeetingLink(in text: String) -> String? {
        let pattern = #"https://[\w.-]*(zoom\.us|teams\.microsoft\.com|teams\.live\.com|meet\.google\.com|webex\.com)/[^\s"<>]+"#
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[r])
    }

    // MARK: sync

    public func syncAll(accountId: String) async throws {
        try await syncCalendarList(accountId)
        let cals = try await db.pool.read { try CalendarRecord.filter(Column("accountId") == accountId).fetchAll($0) }
        for c in cals { try await syncEvents(c) }
    }

    func syncCalendarList(_ accountId: String) async throws {
        var token: String?
        var found: [CalListDTO.C] = []
        repeat {
            let d = try await api.call(account: accountId, url: Self.base + "/users/me/calendarList", query: ["pageToken": token])
            let page = try JSONDecoder().decode(CalListDTO.self, from: d)
            found += page.items ?? []
            token = page.nextPageToken
        } while token != nil
        let items = found
        try await db.pool.write { db in
            let existing = try CalendarRecord.filter(Column("accountId") == accountId).fetchAll(db)
            let known = Dictionary(uniqueKeysWithValues: existing.map { ($0.calendarId, $0) })
            let ids = items.map(\.id)
            try CalendarRecord.filter(Column("accountId") == accountId && !ids.contains(Column("calendarId"))).deleteAll(db)
            for c in items {
                let old = known[c.id]
                try CalendarRecord(accountId: accountId, calendarId: c.id, summary: c.summaryOverride ?? c.summary ?? c.id,
                                   colorHex: c.backgroundColor ?? "#4285F4", isPrimary: c.primary ?? false,
                                   isSelected: old?.isSelected ?? (c.selected ?? false), accessRole: c.accessRole ?? "reader",
                                   syncToken: old?.syncToken, lastFullSyncAt: old?.lastFullSyncAt).save(db)
            }
        }
    }

    func syncEvents(_ cal: CalendarRecord) async throws {
        var cal = cal
        // Sync tokens cannot widen the time window, so the window is rebuilt weekly as time moves on.
        let stale = cal.lastFullSyncAt.map { Date().timeIntervalSince($0) > 7 * 86400 } ?? true
        if stale { cal.syncToken = nil }
        do {
            try await fetchEvents(&cal)
        } catch let e as GoogleAPIError where e.status == 410 {
            cal.syncToken = nil
            try await fetchEvents(&cal)
        }
        let saved = cal
        try await db.pool.write { try saved.update($0) }
    }

    private func fetchEvents(_ cal: inout CalendarRecord) async throws {
        let full = cal.syncToken == nil
        var query: [String: String?] = ["singleEvents": "true", "maxResults": "250", "showDeleted": "true"]
        if full {
            let c = Calendar.current
            query["timeMin"] = Self.iso.string(from: Self.storedFrom())
            query["timeMax"] = Self.iso.string(from: c.date(byAdding: .month, value: 12, to: Date())!)
        } else {
            query["syncToken"] = cal.syncToken
        }
        var token: String?
        var collected: [EventDTO] = []
        var nextSync: String?
        repeat {
            query["pageToken"] = token
            let d = try await api.call(account: cal.accountId, url: Self.base + "/calendars/\(enc(cal.calendarId))/events", query: query)
            let page = try JSONDecoder().decode(EventListDTO.self, from: d)
            collected += page.items ?? []
            token = page.nextPageToken
            nextSync = page.nextSyncToken ?? nextSync
        } while token != nil

        let accountId = cal.accountId, calendarId = cal.calendarId, items = collected
        try await db.pool.write { db in
            if full { try CalendarEvent.filter(Column("accountId") == accountId && Column("calendarId") == calendarId).deleteAll(db) }
            for dto in items {
                if dto.status == "cancelled" {
                    _ = try CalendarEvent.deleteOne(db, key: ["accountId": accountId, "calendarId": calendarId, "eventId": dto.id])
                } else if let r = Self.record(dto, accountId: accountId, calendarId: calendarId) {
                    try r.save(db)
                }
            }
        }
        cal.syncToken = nextSync
        if full { cal.lastFullSyncAt = Date() }
    }

    // MARK: reads

    public func calendars(accountId: String? = nil) async throws -> [CalendarRecord] {
        try await db.pool.read { db in
            var r = CalendarRecord.order(Column("accountId"), Column("isPrimary").desc, Column("summary"))
            if let accountId { r = r.filter(Column("accountId") == accountId) }
            return try r.fetchAll(db)
        }
    }

    /// One calendar is often visible through several accounts (shared or subscribed), each with its own copy of every event.
    /// The copy to show and write through is the one whose account has the most access, preferring the calendar's own account.
    static let accessOrderSQL = "CASE c.accessRole WHEN 'owner' THEN 0 WHEN 'writer' THEN 1 WHEN 'reader' THEN 2 ELSE 3 END, (event.accountId = event.calendarId) DESC, event.accountId"

    static func accessRank(_ c: CalendarRecord) -> (Int, Int, String) {
        let role = switch c.accessRole { case "owner": 0; case "writer": 1; case "reader": 2; default: 3 }
        return (role, c.accountId == c.calendarId ? 0 : 1, c.accountId)
    }

    /// Events in a range, one copy per calendar event.
    public static func eventsRequest(from: Date, to: Date, accountId: String? = nil, onlySelected: Bool = true) -> SQLRequest<CalendarEvent> {
        var inner = "SELECT event.*, ROW_NUMBER() OVER (PARTITION BY event.calendarId, event.eventId ORDER BY \(accessOrderSQL)) AS copyRank"
            + " FROM event JOIN calendar c ON c.accountId = event.accountId AND c.calendarId = event.calendarId WHERE event.endAt > ? AND event.startAt < ?"
        var args: [DatabaseValueConvertible] = [from, to]
        if onlySelected { inner += " AND c.isSelected = 1" }
        if let accountId { inner += " AND event.accountId = ?"; args.append(accountId) }
        let sql = "SELECT * FROM (\(inner)) WHERE copyRank = 1 ORDER BY startAt"
        return SQLRequest<CalendarEvent>(sql: sql, arguments: StatementArguments(args))
    }

    /// The account to change an event through: the given one when it may write to the calendar, otherwise the
    /// connected account with the most access. Fails before calling Google when no account may write to it.
    public func writeAccount(preferred: String, calendarId: String) async throws -> String {
        let cals = try await db.pool.read { try CalendarRecord.filter(Column("calendarId") == calendarId).fetchAll($0) }
        // Not synced yet: let Google decide.
        if cals.isEmpty { return preferred }
        if cals.first(where: { $0.accountId == preferred })?.canWrite == true { return preferred }
        if let best = cals.filter(\.canWrite).min(by: { Self.accessRank($0) < Self.accessRank($1) }) { return best.accountId }
        throw MailError.invalid("This calendar is read only for all your accounts, so the event can't be changed here.")
    }

    public func events(from: Date, to: Date, accountId: String? = nil, onlySelected: Bool = true) async throws -> [CalendarEvent] {
        try await db.pool.read { try Self.eventsRequest(from: from, to: to, accountId: accountId, onlySelected: onlySelected).fetchAll($0) }
    }

    // MARK: search

    /// Events are stored from three months back to a year ahead. Anything earlier is only found through Google.
    public static func storedFrom(_ now: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .month, value: -3, to: now)!
    }

    /// The words of a search, so "an gent" finds "Plaatsing Gent" with An Peeters as a guest.
    public static func searchWords(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Stored events, each once, on the calendars shown, where every word appears somewhere:
    /// title, place, notes, organizer, or a guest's name or address. Nil when there is nothing to search for.
    public static func searchRequest(_ text: String, limit: Int = 500) -> SQLRequest<CalendarEvent>? {
        let words = searchWords(text)
        guard !words.isEmpty else { return nil }
        var inner = "SELECT event.*, ROW_NUMBER() OVER (PARTITION BY event.calendarId, event.eventId ORDER BY \(accessOrderSQL)) AS copyRank"
            + " FROM event JOIN calendar c ON c.accountId = event.accountId AND c.calendarId = event.calendarId"
            + " WHERE c.isSelected = 1 AND event.status != 'cancelled'"
        var args: [DatabaseValueConvertible] = []
        for w in words {
            let fields = ["summary", "location", "details", "organizerEmail", "attendeesJSON"]
            inner += " AND (" + fields.map { "event.\($0) LIKE ? ESCAPE '\\'" }.joined(separator: " OR ") + ")"
            let pattern = "%" + w.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_") + "%"
            args += Array(repeating: pattern, count: fields.count)
        }
        let sql = "SELECT * FROM (\(inner)) WHERE copyRank = 1 ORDER BY startAt LIMIT \(limit)"
        return SQLRequest<CalendarEvent>(sql: sql, arguments: StatementArguments(args))
    }

    public func search(_ text: String) async throws -> [CalendarEvent] {
        guard let r = Self.searchRequest(text) else { return [] }
        return try await db.pool.read { try r.fetchAll($0) }
    }

    /// Google's own search for events before `before`, going back `years`, on every calendar shown,
    /// through the account with the most access to it. The results are not stored: sync keeps its own window.
    public func searchOlder(_ text: String, before: Date, years: Int = 5) async throws -> [CalendarEvent] {
        guard !Self.searchWords(text).isEmpty else { return [] }
        let all = try await db.pool.read { try CalendarRecord.filter(Column("isSelected") == true).fetchAll($0) }
        // Free/busy access shows no titles, so there is nothing to search in.
        let cals = Dictionary(grouping: all.filter { $0.accessRole != "freeBusyReader" }, by: \.calendarId)
            .compactMap { $0.value.min { Self.accessRank($0) < Self.accessRank($1) } }
        let from = Calendar.current.date(byAdding: .year, value: -years, to: before)!
        var found: [CalendarEvent] = []
        var failure: Error?
        await withTaskGroup(of: Result<[CalendarEvent], Error>.self) { group in
            for c in cals {
                group.addTask { [self] in
                    do { return .success(try await searchOlder(text, in: c, from: from, to: before)) }
                    catch { return .failure(error) }
                }
            }
            for await r in group {
                switch r {
                case .success(let e): found += e
                case .failure(let e): failure = failure ?? e
                }
            }
        }
        // One calendar failing still shows what the others found.
        if found.isEmpty, let failure { throw failure }
        return found.sorted { $0.startAt > $1.startAt }
    }

    private func searchOlder(_ text: String, in cal: CalendarRecord, from: Date, to: Date) async throws -> [CalendarEvent] {
        var query: [String: String?] = ["q": text, "singleEvents": "true", "orderBy": "startTime", "maxResults": "250",
                                        "timeMin": Self.iso.string(from: from), "timeMax": Self.iso.string(from: to)]
        var out: [CalendarEvent] = []
        var token: String?
        var pages = 0
        repeat {
            query["pageToken"] = token
            let d = try await api.call(account: cal.accountId, url: Self.base + "/calendars/\(enc(cal.calendarId))/events", query: query)
            let page = try JSONDecoder().decode(EventListDTO.self, from: d)
            out += (page.items ?? []).compactMap { Self.record($0, accountId: cal.accountId, calendarId: cal.calendarId) }
            token = page.nextPageToken
            pages += 1
        } while token != nil && pages < 4
        return out.filter { $0.status != "cancelled" }
    }

    public func setSelected(accountId: String, calendarId: String, selected: Bool) async throws {
        try await db.pool.write { db in
            guard var c = try CalendarRecord.fetchOne(db, key: ["accountId": accountId, "calendarId": calendarId]) else { return }
            c.isSelected = selected
            try c.update(db)
        }
    }

    /// Free slots across every selected calendar of every account.
    /// With `workingHours`, slots are clipped to those hours on weekdays.
    public func availability(from: Date, to: Date, minMinutes: Int = 30, workingHours: ClosedRange<Int>? = nil,
                             calendar: Calendar = .current) async throws -> [FreeSlot] {
        let busy = try await events(from: from, to: to).filter { $0.isBusy && !$0.isAllDay }
        return Self.freeSlots(busy: busy.map { ($0.startAt, $0.endAt) }, from: from, to: to, minMinutes: minMinutes,
                              workingHours: workingHours, calendar: calendar)
    }

    public static func freeSlots(busy: [(Date, Date)], from: Date, to: Date, minMinutes: Int,
                                 workingHours: ClosedRange<Int>?, calendar: Calendar) -> [FreeSlot] {
        var free: [(Date, Date)] = []
        var cursor = from
        for (s, e) in busy.sorted(by: { $0.0 < $1.0 }) {
            if s > cursor { free.append((cursor, min(s, to))) }
            cursor = max(cursor, e)
            if cursor >= to { break }
        }
        if cursor < to { free.append((cursor, to)) }

        var out: [FreeSlot] = []
        let minLen = TimeInterval(minMinutes * 60)
        for (s, e) in free {
            guard let hours = workingHours else {
                if e.timeIntervalSince(s) >= minLen { out.append(FreeSlot(start: s, end: e)) }
                continue
            }
            var day = calendar.startOfDay(for: s)
            while day < e {
                defer { day = calendar.date(byAdding: .day, value: 1, to: day)! }
                let weekday = calendar.component(.weekday, from: day)
                if weekday == 1 || weekday == 7 { continue }
                let ws = calendar.date(bySettingHour: hours.lowerBound, minute: 0, second: 0, of: day)!
                let we = calendar.date(bySettingHour: hours.upperBound, minute: 0, second: 0, of: day)!
                let a = max(s, ws), b = min(e, we)
                if b.timeIntervalSince(a) >= minLen { out.append(FreeSlot(start: a, end: b)) }
            }
        }
        return out
    }

    // MARK: writes

    private func when(_ d: Date, allDay: Bool) -> [String: Any] {
        if allDay { return ["date": Self.dayFormatter().string(from: d)] }
        return ["dateTime": Self.iso.string(from: d), "timeZone": TimeZone.current.identifier]
    }

    /// Saves Google's answer, and updates the copies other accounts hold of the same event so none of them shows the old version.
    private func store(_ data: Data, accountId: String, calendarId: String) async throws -> CalendarEvent {
        let dto = try JSONDecoder().decode(EventDTO.self, from: data)
        guard let r = Self.record(dto, accountId: accountId, calendarId: calendarId) else { throw MailError.invalid("Google returned an unreadable event.") }
        try await db.pool.write { db in
            try r.save(db)
            let others = try String.fetchAll(db, sql: "SELECT accountId FROM event WHERE calendarId = ? AND eventId = ? AND accountId != ?",
                                              arguments: [calendarId, r.eventId, accountId])
            for other in others {
                var copy = r
                copy.accountId = other
                try copy.save(db)
            }
        }
        return r
    }

    public func create(_ i: EventInput) async throws -> CalendarEvent {
        var body: [String: Any] = ["summary": i.summary, "start": when(i.start, allDay: i.isAllDay), "end": when(i.end, allDay: i.isAllDay)]
        if let d = i.details { body["description"] = d }
        if let l = i.location { body["location"] = l }
        if !i.attendees.isEmpty { body["attendees"] = i.attendees.map { ["email": GmailParser.parseAddress($0).email] } }
        if !i.recurrence.isEmpty { body["recurrence"] = i.recurrence }
        let query: [String: String?] = ["sendUpdates": i.attendees.isEmpty ? "none" : "all"]
        let url = Self.base + "/calendars/\(enc(i.calendarId))/events"
        let d: Data
        if i.addMeetLink {
            var withMeet = body
            withMeet["conferenceData"] = ["createRequest": ["requestId": UUID().uuidString, "conferenceSolutionKey": ["type": "hangoutsMeet"]]]
            var meetQuery = query
            meetQuery["conferenceDataVersion"] = "1"
            do {
                d = try await api.call(account: i.accountId, method: "POST", url: url, query: meetQuery, json: withMeet)
            } catch let e as GoogleAPIError where e.status == 400 && e.message.lowercased().contains("conference") {
                // Some calendars do not allow Meet (a Workspace with Meet switched off, for one).
                // The event still gets made, just without a link.
                d = try await api.call(account: i.accountId, method: "POST", url: url, query: query, json: body)
            }
        } else {
            d = try await api.call(account: i.accountId, method: "POST", url: url, query: query, json: body)
        }
        let event = try await store(d, accountId: i.accountId, calendarId: i.calendarId)
        // Recurring events arrive as expanded instances through the next sync.
        if !i.recurrence.isEmpty, let c = try await db.pool.read({ try CalendarRecord.fetchOne($0, key: ["accountId": i.accountId, "calendarId": i.calendarId]) }) {
            try? await syncEvents(c)
        }
        return event
    }

    public func update(accountId: String, calendarId: String, eventId: String, patch: EventPatch) async throws -> CalendarEvent {
        var body: [String: Any] = [:]
        if let v = patch.summary { body["summary"] = v }
        if let v = patch.details { body["description"] = v }
        if let v = patch.location { body["location"] = v }
        if let v = patch.start { body["start"] = when(v, allDay: patch.isAllDay ?? false) }
        if let v = patch.end { body["end"] = when(v, allDay: patch.isAllDay ?? false) }
        if let v = patch.attendees { body["attendees"] = v.map { ["email": GmailParser.parseAddress($0).email] } }
        let via = try await writeAccount(preferred: accountId, calendarId: calendarId)
        let d = try await api.call(account: via, method: "PATCH", url: Self.base + "/calendars/\(enc(calendarId))/events/\(enc(eventId))",
                                   query: ["sendUpdates": "all"], json: body)
        return try await store(d, accountId: via, calendarId: calendarId)
    }

    public func delete(accountId: String, calendarId: String, eventId: String) async throws {
        let via = try await writeAccount(preferred: accountId, calendarId: calendarId)
        _ = try await api.call(account: via, method: "DELETE", url: Self.base + "/calendars/\(enc(calendarId))/events/\(enc(eventId))",
                               query: ["sendUpdates": "all"])
        // Every account's copy goes, or another one would take its place in the agenda until the next sync.
        try await db.pool.write { db in
            _ = try CalendarEvent.filter(Column("calendarId") == calendarId && Column("eventId") == eventId).deleteAll(db)
        }
    }

    /// `response` is accepted, declined or tentative. Google needs the full attendee list back.
    public func respond(accountId: String, calendarId: String, eventId: String, response: String) async throws -> CalendarEvent {
        guard ["accepted", "declined", "tentative"].contains(response) else { throw MailError.invalid("Response must be accepted, declined or tentative.") }
        guard let e = try await db.pool.read({ try CalendarEvent.fetchOne($0, key: ["accountId": accountId, "calendarId": calendarId, "eventId": eventId]) }) else {
            throw MailError.notFound("event \(eventId)")
        }
        var atts = e.attendees
        let me = accountId.lowercased()
        if let i = atts.firstIndex(where: { $0.isSelf || $0.email == me }) { atts[i].response = response }
        else { atts.append(EventAttendee(email: me, response: response, isSelf: true)) }
        let body: [String: Any] = ["attendees": atts.map { ["email": $0.email, "responseStatus": $0.response] }]
        let via = try await writeAccount(preferred: accountId, calendarId: calendarId)
        let d = try await api.call(account: via, method: "PATCH", url: Self.base + "/calendars/\(enc(calendarId))/events/\(enc(eventId))",
                                   query: ["sendUpdates": "all"], json: body)
        return try await store(d, accountId: via, calendarId: calendarId)
    }
}
