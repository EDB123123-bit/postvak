import Foundation
import Testing
import GRDB
@testable import PostvakCore
@testable import PostvakAI
@testable import PostvakMCP

@Suite(.serialized) struct CalendarTests {
    let cal = Calendar(identifier: .gregorian)

    @Test func testFreeSlotsMergeAccountsAndClipToWork() {
        // Wednesday 5 November 2025.
        var c = cal; c.timeZone = TimeZone(identifier: "Europe/Brussels")!
        let day = c.date(from: DateComponents(year: 2025, month: 11, day: 5))!
        func at(_ h: Int, _ m: Int = 0) -> Date { c.date(bySettingHour: h, minute: m, second: 0, of: day)! }
        let busy = [(at(10), at(11)), (at(10, 30), at(12)), (at(14), at(14, 15))]
        let slots = CalendarService.freeSlots(busy: busy, from: at(0), to: at(23, 59), minMinutes: 30, workingHours: 9...18, calendar: c)
        XCTAssertEqual(slots.map(\.start), [at(9), at(12), at(14, 15)])
        XCTAssertEqual(slots.map(\.end), [at(10), at(14), at(18)])
    }

    @Test func testWeekendIsNotWork() {
        var c = cal; c.timeZone = TimeZone(identifier: "Europe/Brussels")!
        let sat = c.date(from: DateComponents(year: 2025, month: 11, day: 8))!
        let slots = CalendarService.freeSlots(busy: [], from: sat, to: c.date(byAdding: .day, value: 2, to: sat)!, minMinutes: 30, workingHours: 9...18, calendar: c)
        XCTAssertTrue(slots.isEmpty)
    }

    @Test func testSyncCreatesReadsAndHandlesExpiredToken() async throws {
        let e = try makeEngine()
        nonisolated(unsafe) var eventCalls = 0
        MockServer.reset { c in
            if let b = baseAnswer(c) { return b }
            if c.path.hasSuffix("/calendarList") { return (200, ["items": [["id": "a@example.com", "summary": "Mine", "primary": true, "selected": true, "accessRole": "owner", "backgroundColor": "#112233"]]]) }
            if c.path.hasSuffix("/events"), c.method == "GET" {
                eventCalls += 1
                if c.query["syncToken"] == "old" { return (410, ["error": ["message": "gone"]]) }
                XCTAssertNotNil(c.query["timeMin"])
                return (200, ["nextSyncToken": "new", "items": [
                    ["id": "e1", "summary": "Call", "start": ["dateTime": "2026-11-05T10:00:00+01:00"], "end": ["dateTime": "2026-11-05T11:00:00+01:00"], "hangoutLink": "https://meet.google.com/x",
                     "attendees": [["email": "a@example.com", "self": true, "responseStatus": "needsAction"], ["email": "b@x.be", "responseStatus": "accepted"]]],
                    ["id": "e2", "summary": "Fair", "start": ["date": "2026-11-06"], "end": ["date": "2026-11-07"], "transparency": "transparent"],
                    ["id": "gone", "status": "cancelled"],
                ]])
            }
            return (404, ["error": ["message": "unhandled"]])
        }
        try await e.calendar.syncAll(accountId: "a@example.com")
        // A rejected sync token falls back to a full fetch.
        try await e.db.pool.write { db in
            var c = try CalendarRecord.fetchOne(db, key: ["accountId": "a@example.com", "calendarId": "a@example.com"])!
            c.syncToken = "old"
            try c.update(db)
        }
        try await e.calendar.syncAll(accountId: "a@example.com")
        XCTAssertEqual(eventCalls, 3)
        let f = ISO8601DateFormatter()
        let events = try await e.calendar.events(from: f.date(from: "2026-11-01T00:00:00Z")!, to: f.date(from: "2026-11-30T00:00:00Z")!)
        XCTAssertEqual(events.map(\.eventId), ["e1", "e2"])
        XCTAssertEqual(events[0].selfResponse, "needsAction")
        XCTAssertEqual(events[0].meetingLink, "https://meet.google.com/x")
        XCTAssertTrue(events[1].isAllDay)
        XCTAssertFalse(events[1].isBusy)
    }

    @Test func testRespondKeepsOtherAttendees() async throws {
        let e = try makeEngine()
        try await e.db.pool.write { db in
            try CalendarRecord(accountId: "a@example.com", calendarId: "c", summary: "c", colorHex: "#000", isPrimary: true, isSelected: true, accessRole: "owner", syncToken: nil, lastFullSyncAt: nil).insert(db)
            let atts = String(decoding: try JSONEncoder().encode([EventAttendee(email: "a@example.com", isSelf: true), EventAttendee(email: "b@x.be", response: "accepted")]), as: UTF8.self)
            try CalendarEvent(accountId: "a@example.com", calendarId: "c", eventId: "e", summary: "s", details: "", location: "", startAt: Date(), endAt: Date(), isAllDay: false, status: "confirmed", transparency: "opaque", organizerEmail: "b@x.be", attendeesJSON: atts, selfResponse: "needsAction", meetingLink: nil, htmlLink: nil, recurringEventId: nil).insert(db)
        }
        MockServer.reset { c in
            if let b = baseAnswer(c) { return b }
            return (200, ["id": "e", "summary": "s", "start": ["dateTime": "2026-11-05T10:00:00Z"], "end": ["dateTime": "2026-11-05T11:00:00Z"],
                          "attendees": [["email": "a@example.com", "self": true, "responseStatus": "accepted"], ["email": "b@x.be", "responseStatus": "accepted"]]])
        }
        let r = try await e.calendar.respond(accountId: "a@example.com", calendarId: "c", eventId: "e", response: "accepted")
        XCTAssertEqual(r.selfResponse, "accepted")
        let body = try JSONSerialization.jsonObject(with: MockServer.recorded("/events/e", method: "PATCH")[0].body) as! [String: Any]
        XCTAssertEqual((body["attendees"] as? [[String: String]])?.count, 2)
    }

    // One calendar seen through three accounts, as when calendars are shared between them.
    static let shared = ["a@example.com": "reader", "b@example.com": "owner", "c@example.com": "freeBusyReader"]

    func sharedCalendar(roles: [String: String] = shared) throws -> Engine {
        let e = try makeEngine(accounts: ["a@example.com", "b@example.com", "c@example.com"])
        let start = ISO8601DateFormatter().date(from: "2026-11-10T09:30:00Z")!
        try e.db.pool.write { db in
            for (acct, role) in roles {
                try CalendarRecord(accountId: acct, calendarId: "b@example.com", summary: "b", colorHex: "#000", isPrimary: acct == "b@example.com",
                                   isSelected: true, accessRole: role, syncToken: nil, lastFullSyncAt: nil).insert(db)
                try CalendarEvent(accountId: acct, calendarId: "b@example.com", eventId: "demo", summary: role == "freeBusyReader" ? "(no title)" : "Demo",
                                  details: "", location: "", startAt: start, endAt: start.addingTimeInterval(3600), isAllDay: false, status: "confirmed",
                                  transparency: "opaque", organizerEmail: "b@example.com", attendeesJSON: "[]", selfResponse: nil,
                                  meetingLink: nil, htmlLink: nil, recurringEventId: nil).insert(db)
            }
        }
        return e
    }

    var week: (Date, Date) {
        let f = ISO8601DateFormatter()
        return (f.date(from: "2026-11-09T00:00:00Z")!, f.date(from: "2026-11-16T00:00:00Z")!)
    }

    @Test func testSharedCalendarShowsEachEventOnce() async throws {
        let e = try sharedCalendar()
        let all = try await e.calendar.events(from: week.0, to: week.1)
        XCTAssertEqual(all.count, 1, "One copy, not one per account")
        XCTAssertEqual(all.first?.accountId, "b@example.com", "The copy of the account that owns the calendar")
        XCTAssertEqual(all.first?.summary, "Demo")
        // Asking for one account still gives that account's copy.
        let onlyA = try await e.calendar.events(from: week.0, to: week.1, accountId: "a@example.com")
        XCTAssertEqual(onlyA.map(\.accountId), ["a@example.com"])
    }

    @Test func testSharedCalendarPrefersItsOwnAccountAmongOwners() async throws {
        let e = try sharedCalendar(roles: ["a@example.com": "owner", "b@example.com": "owner"])
        XCTAssertEqual(try await e.calendar.events(from: week.0, to: week.1).map(\.accountId), ["b@example.com"])
    }

    @Test func testEditFromReadOnlyCopyGoesThroughAccountThatCanWrite() async throws {
        let e = try sharedCalendar()
        MockServer.reset { c in
            if let b = baseAnswer(c) { return b }
            return (200, ["id": "demo", "summary": "Demo", "start": ["dateTime": "2026-11-10T15:00:00Z"], "end": ["dateTime": "2026-11-10T16:00:00Z"]])
        }
        let moved = try await e.calendar.update(accountId: "a@example.com", calendarId: "b@example.com", eventId: "demo",
                                                patch: EventPatch(start: ISO8601DateFormatter().date(from: "2026-11-10T15:00:00Z")!))
        XCTAssertEqual(moved.accountId, "b@example.com")
        XCTAssertEqual(MockServer.recorded("/events/demo", method: "PATCH").count, 1)
        let refresh = MockServer.recorded("/token").map { String(decoding: $0.body, as: UTF8.self) }
        XCTAssertTrue(refresh.contains { $0.contains("b%40example.com") || $0.contains("b@example.com") }, "Signed in as the owner")
        XCTAssertFalse(refresh.contains { $0.contains("a%40example.com") || $0.contains("a@example.com") }, "Not as the read-only account")
        // Every account's copy shows the new time, so no stale copy turns up later.
        let copies = try await e.db.pool.read { try CalendarEvent.filter(Column("eventId") == "demo").fetchAll($0) }
        XCTAssertEqual(copies.count, 3)
        XCTAssertTrue(copies.allSatisfy { $0.startAt == moved.startAt })
    }

    @Test func testReadOnlyCalendarIsRefusedBeforeGoogle() async throws {
        let e = try sharedCalendar(roles: ["a@example.com": "reader", "c@example.com": "freeBusyReader"])
        MockServer.reset { c in
            if let b = baseAnswer(c) { return b }
            XCTFail("Google should not be called"); return (403, [:])
        }
        do {
            _ = try await e.calendar.update(accountId: "a@example.com", calendarId: "b@example.com", eventId: "demo", patch: EventPatch(summary: "x"))
            XCTFail("should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("read only"), error.localizedDescription)
        }
        XCTAssertEqual(MockServer.recorded("/events", method: "PATCH").count, 0)
    }

    @Test func testEventFindsItsMeeting() async throws {
        let e = try sharedCalendar()
        let event = try await e.calendar.events(from: week.0, to: week.1)[0]
        XCTAssertNil(try await e.meetings.meeting(for: event))
        // An imported meeting without a link is found by its start time.
        let loose = MeetingRecord(title: "Imported", startedAt: event.startAt.addingTimeInterval(120), status: .ready, source: "granola")
        try await e.meetings.save(loose)
        XCTAssertEqual(try await e.meetings.meeting(for: event)?.id, loose.id)
        // A meeting linked to the event wins, whichever account's copy it was linked through.
        var linked = MeetingRecord(title: "Recorded", startedAt: event.startAt.addingTimeInterval(-3600 * 5), status: .ready)
        linked.eventAccountId = "a@example.com"; linked.eventCalendarId = "b@example.com"; linked.eventId = "demo"
        try await e.meetings.save(linked)
        XCTAssertEqual(try await e.meetings.meeting(for: event)?.id, linked.id)
    }

    @Test func testDeleteRemovesEveryAccountsCopy() async throws {
        let e = try sharedCalendar()
        MockServer.reset { c in baseAnswer(c) ?? (204, Data()) }
        try await e.calendar.delete(accountId: "a@example.com", calendarId: "b@example.com", eventId: "demo")
        XCTAssertEqual(MockServer.recorded("/events/demo", method: "DELETE").count, 1)
        XCTAssertEqual(try await e.calendar.events(from: week.0, to: week.1, onlySelected: false).count, 0)
        XCTAssertEqual(try await e.db.pool.read { try CalendarEvent.fetchCount($0) }, 0)
    }

    // MARK: search

    func searchEngine() throws -> Engine {
        let e = try sharedCalendar()
        let start = ISO8601DateFormatter().date(from: "2026-11-12T09:00:00Z")!
        let guests = "[{\"email\":\"an.peeters@example.net\",\"name\":\"An Peeters\",\"response\":\"accepted\",\"isSelf\":false,\"isOrganizer\":false}]"
        try e.db.pool.write { db in
            try CalendarRecord(accountId: "b@example.com", calendarId: "hidden", summary: "Hidden", colorHex: "#000", isPrimary: false,
                               isSelected: false, accessRole: "owner", syncToken: nil, lastFullSyncAt: nil).insert(db)
            func add(_ id: String, _ summary: String, calendar: String = "b@example.com", location: String = "", attendees: String = "[]",
                     status: String = "confirmed") throws {
                try CalendarEvent(accountId: "b@example.com", calendarId: calendar, eventId: id, summary: summary, details: "Offerte 100% groene stroom",
                                  location: location, startAt: start, endAt: start.addingTimeInterval(3600), isAllDay: false, status: status,
                                  transparency: "opaque", organizerEmail: "b@example.com", attendeesJSON: attendees, selfResponse: nil,
                                  meetingLink: nil, htmlLink: nil, recurringEventId: nil).insert(db)
            }
            try add("gent", "Plaatsing", location: "Gent", attendees: guests)
            try add("brugge", "Plaatsing", location: "Brugge")
            try add("gone", "Plaatsing Gent", status: "cancelled")
            try add("secret", "Plaatsing Gent", calendar: "hidden")
        }
        return e
    }

    @Test func testSearchNeedsEveryWordAnywhereInTheEvent() async throws {
        let e = try searchEngine()
        // "an" is in a guest's name, "gent" in the place, "plaatsing" in the title.
        XCTAssertEqual(try await e.calendar.search("plaatsing GENT an").map(\.eventId), ["gent"])
        XCTAssertEqual(Set(try await e.calendar.search("plaatsing").map(\.eventId)), ["gent", "brugge"], "Not cancelled, not on a hidden calendar")
        XCTAssertEqual(try await e.calendar.search("   ").count, 0)
    }

    @Test func testSearchShowsSharedEventOnceAndTreatsWildcardsAsText() async throws {
        let e = try searchEngine()
        // The shared calendar has a copy of "Demo" in three accounts.
        XCTAssertEqual(try await e.calendar.search("demo").map(\.accountId), ["b@example.com"])
        XCTAssertEqual(Set(try await e.calendar.search("100%").map(\.eventId)), ["gent", "brugge"])
        XCTAssertEqual(try await e.calendar.search("10_%").count, 0, "_ is a letter here, not any character")
    }

    @Test func testSearchOlderAsksGoogleOncePerCalendar() async throws {
        let e = try searchEngine()
        MockServer.reset { c in
            if let b = baseAnswer(c) { return b }
            return (200, ["items": [
                ["id": "old", "summary": "Plaatsing Gent 2024", "start": ["dateTime": "2024-03-01T09:00:00Z"], "end": ["dateTime": "2024-03-01T10:00:00Z"]],
                ["id": "older", "summary": "Plaatsing Gent 2023", "start": ["dateTime": "2023-03-01T09:00:00Z"], "end": ["dateTime": "2023-03-01T10:00:00Z"]],
                ["id": "x", "status": "cancelled"],
            ]])
        }
        let before = ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z")!
        let found = try await e.calendar.searchOlder("plaatsing gent", before: before)
        XCTAssertEqual(found.map(\.eventId), ["old", "older"], "Newest first, cancelled left out")
        let calls = MockServer.recorded("/events", method: "GET")
        XCTAssertEqual(calls.count, 1, "Only the shown calendar, through one account")
        XCTAssertEqual(calls.first?.query["q"], "plaatsing gent")
        XCTAssertEqual(calls.first?.query["timeMax"], "2026-08-01T00:00:00Z")
        XCTAssertEqual(found.first?.accountId, "b@example.com", "The owner's copy")
    }
}

@Suite(.serialized) struct MeetingTests {
    @Test func testMergeDropsEchoAndKeepsOrder() {
        let mic = [TrackSegment(start: 0, end: 2, speaker: "Me", text: "Goedemorgen allemaal"),
                   TrackSegment(start: 5, end: 8, speaker: "Me", text: "de plaatsing schuift naar week 48")]
        let sys = [TrackSegment(start: 5.2, end: 8, speaker: "Others", text: "De plaatsing schuift naar week 48."),
                   TrackSegment(start: 3, end: 4, speaker: "Others", text: "Dag Anna")]
        let out = TranscriptMerger.merge(mic: mic, system: sys)
        XCTAssertEqual(out.map(\.text), ["Goedemorgen allemaal", "Dag Anna", "De plaatsing schuift naar week 48."])
    }

    @Test func testNoiseFilter() {
        XCTAssertTrue(TranscriptMerger.isNoise("[BLANK_AUDIO]"))
        XCTAssertTrue(TranscriptMerger.isNoise("(muziek)"))
        XCTAssertFalse(TranscriptMerger.isNoise("Goedemorgen"))
    }

    @Test func testLinkPicksLargestOverlapAndSkipsDeclined() async throws {
        let e = try makeEngine()
        let start = Date()
        func ev(_ id: String, _ s: Double, _ d: Double, _ resp: String? = nil) -> CalendarEvent {
            CalendarEvent(accountId: "a@example.com", calendarId: "c", eventId: id, summary: id, details: "", location: "", startAt: start.addingTimeInterval(s), endAt: start.addingTimeInterval(s + d), isAllDay: false, status: "confirmed", transparency: "opaque", organizerEmail: "", attendeesJSON: "[{\"email\":\"b@x.be\",\"response\":\"accepted\",\"isSelf\":false,\"isOrganizer\":false}]", selfResponse: resp, meetingLink: nil, htmlLink: nil, recurringEventId: nil)
        }
        try await e.db.pool.write { db in
            try CalendarRecord(accountId: "a@example.com", calendarId: "c", summary: "c", colorHex: "#000", isPrimary: true, isSelected: true, accessRole: "owner", syncToken: nil, lastFullSyncAt: nil).insert(db)
            try ev("small", -1700, 1800).insert(db)
            try ev("big", 300, 3600).insert(db)
            try ev("declined", 0, 3600, "declined").insert(db)
        }
        let m = MeetingRecord(title: MeetingRecord.untitled, startedAt: start, endedAt: start.addingTimeInterval(1800))
        try await e.meetings.save(m)
        let best = try await e.meetings.linkToBestEvent(meetingId: m.id)
        XCTAssertEqual(best?.eventId, "big")
        let saved = try await e.meetings.get(m.id)?.0
        XCTAssertEqual(saved?.title, "big")
        XCTAssertEqual(saved?.attendees.first?.email, "b@x.be")
    }

    @Test func testImportIsIdempotentAndSearchable() async throws {
        let e = try makeEngine()
        let i = ImportedMeeting(source: "granola", sourceId: "g1", title: "Kickoff", startedAt: Date(), attendees: ["An <an@x.be>"], summary: "Samenvatting",
                                segments: [.init(start: 1, speaker: "An", text: "We starten met de offerte")])
        let first = try await e.meetings.importMeeting(i)
        let second = try await e.meetings.importMeeting(i)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        let list = try await e.meetings.list()
        XCTAssertEqual(list.count, 1)
        let hits = try await e.meetings.search("offerte")
        XCTAssertEqual(hits.first?.meetingTitle, "Kickoff")
        let count = try await e.meetings.segmentCount(meetingId: list[0].id)
        XCTAssertEqual(count, 1)
    }
}

@Suite(.serialized) struct ClaudeTests {
    func claudeBody(_ text: String, stop: String = "end_turn") -> [String: Any] {
        ["content": [["type": "thinking", "thinking": ""], ["type": "text", "text": text]], "stop_reason": stop]
    }
    func client(key: String? = "k") -> ClaudeClient { ClaudeClient(session: MockServer.session) { key } }

    @Test func testForgottenAttachmentInThreeLanguages() {
        XCTAssertTrue(SendCheck.forgottenAttachment(text: "Dag An,\nZie bijlage voor de offerte.", hasFiles: false))
        XCTAssertTrue(SendCheck.forgottenAttachment(text: "Vous trouverez le devis ci-joint.", hasFiles: false))
        XCTAssertTrue(SendCheck.forgottenAttachment(text: "I've attached the quote.", hasFiles: false))
        XCTAssertFalse(SendCheck.forgottenAttachment(text: "I've attached the quote.", hasFiles: true))
        XCTAssertFalse(SendCheck.forgottenAttachment(text: "He stays unattached to the outcome.", hasFiles: false), "Whole words only")
        XCTAssertFalse(SendCheck.forgottenAttachment(text: "Tot donderdag!", hasFiles: false))
    }

    @Test func testSendReviewSeesTheThreadAndReturnsFindings() async throws {
        MockServer.reset { _ in (200, self.claudeBody("{\"findings\":[\"Je schrijft Panelwerck, in de mails is het Panelwerk.\"]}")) }
        let e = try makeEngine()
        let dto = try JSONDecoder().decode(GmailThreadDTO.self, from: JSONSerialization.data(withJSONObject: ["id": "t", "messages": [
            gmailMessage(id: "m1", thread: "t", from: "Jan <jan@panelwerk.be>", subject: "Prijs", body: "Wij rekenen €200 per analyse. Groet, Jan (Panelwerk)")]]))
        try await GmailSync.store(db: e.db, accountId: "a@example.com", dto: dto)
        let thread = try await e.mail.detail(accountId: "a@example.com", threadId: "t").messages
        let draft = SendCheck.Draft(to: ["jan@panelwerk.be"], cc: [], subject: "Re: Prijs", text: "Dag Jan, akkoord voor Panelwerck.", hasFiles: false, thread: thread)
        let found = await SendCheck(claude: client()).review(draft)
        XCTAssertEqual(found, ["Je schrijft Panelwerck, in de mails is het Panelwerk."])
        let body = try JSONSerialization.jsonObject(with: MockServer.recorded("/v1/messages")[0].body) as! [String: Any]
        let user = ((body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        XCTAssertTrue(user.contains("€200 per analyse"), "The earlier message is part of the check")
        // Without a key nothing is asked, and sending isn't held up.
        XCTAssertEqual(await SendCheck(claude: client(key: nil)).review(draft), [])
    }

    @Test func testRequestShape() async throws {
        MockServer.reset { _ in (200, self.claudeBody("{\"results\":[]}")) }
        _ = try await client().structured(system: "s", user: "u", schema: InboxClassifier.schema, effort: "low", maxTokens: 100, as: InboxClassifier.Output.self, feature: "Test")
        let call = MockServer.recorded("/v1/messages")[0]
        let body = try JSONSerialization.jsonObject(with: call.body) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "claude-haiku-5-5")
        XCTAssertNil(body["fallbacks"], "Haiku 5.5 has no server-side fallback")
        XCTAssertNil(body["thinking"], "Thinking config is omitted on this model")
        let config = body["output_config"] as! [String: Any]
        XCTAssertEqual(config["effort"] as? String, "low")
        XCTAssertEqual((config["format"] as? [String: Any])?["type"] as? String, "json_schema")
        XCTAssertNil(call.headers["anthropic-beta"])
        XCTAssertEqual(call.headers["x-api-key"], "k")
    }

    @Test func testEveryAnswerIsCountedPerFeature() async throws {
        let e = try makeEngine()
        let usage = ApiUsage(db: e.db)
        MockServer.reset { _ in (200, ["model": "claude-haiku-5-5", "stop_reason": "end_turn",
                                       "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": "{\"results\":[]}"]],
                                       "usage": ["input_tokens": 2000, "output_tokens": 400, "cache_read_input_tokens": 10_000, "cache_creation_input_tokens": 0]]) }
        let client = ClaudeClient(session: MockServer.session, key: { "k" }, onUsage: { f, m, u in
            Task { try? await usage.record(feature: f, model: m, usage: u) }
        })
        for _ in 0..<2 {
            _ = try await client.structured(system: "s", user: "u", schema: InboxClassifier.schema, effort: "low", maxTokens: 100,
                                            as: InboxClassifier.Output.self, feature: "Inbox sorting")
        }
        try await Task.sleep(for: .milliseconds(200))
        let rows = try await e.db.pool.read { try ApiUsage.totals($0, since: Date().addingTimeInterval(-86400)) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.feature, "Inbox sorting")
        XCTAssertEqual(rows.first?.requests, 2)
        XCTAssertEqual(rows.first?.inputTokens, 4000)
        XCTAssertEqual(rows.first?.cacheReadTokens, 20_000)
        // Per request: 2000 × $0.10 + 400 × $0.50 + 10,000 cache reads × $0.01, per million = $0.0005.
        XCTAssertEqual(rows.first?.costMicros, 1000)
    }

    @Test func testCostFollowsTheModelAndPromptLength() {
        // Over 100K tokens of prompt, the higher rate card.
        XCTAssertEqual(ApiUsage.cost(model: "claude-haiku-5-5", TokenUsage(input: 1_000_000, output: 1_000_000)) ?? 0, 3.00, accuracy: 0.0001)
        XCTAssertEqual(ApiUsage.cost(model: "claude-haiku-5-5", TokenUsage(input: 50_000, output: 10_000)) ?? 0, 0.01, accuracy: 0.0001)
        XCTAssertEqual(ApiUsage.cost(model: "claude-opus-5-5", TokenUsage(input: 50_000, output: 10_000)) ?? 0, 0.40, accuracy: 0.0001)
        XCTAssertTrue(ApiUsage.cost(model: "something-else", TokenUsage(input: 1, output: 1)) == nil)
    }

    @Test func testRefusalAndCutoffThrow() async {
        MockServer.reset { _ in (200, ["content": [], "stop_reason": "refusal", "stop_details": ["category": "cyber"]]) }
        do {
            _ = try await client().structured(system: "", user: "", schema: [:], effort: "low", maxTokens: 1, as: InboxClassifier.Output.self, feature: "Test")
            XCTFail("should throw")
        } catch { XCTAssertTrue("\(error)".contains("refused")) }
        MockServer.reset { _ in (200, self.claudeBody("{\"res", stop: "max_tokens")) }
        do {
            _ = try await client().structured(system: "", user: "", schema: [:], effort: "low", maxTokens: 1, as: InboxClassifier.Output.self, feature: "Test")
            XCTFail("should throw")
        } catch { XCTAssertTrue("\(error)".contains("truncated")) }
    }

    @Test func testRetriesOverload() async throws {
        nonisolated(unsafe) var n = 0
        MockServer.reset { _ in
            n += 1
            if n == 1 { return (529, ["error": ["message": "overloaded"]]) }
            return (200, self.claudeBody("{\"results\":[]}"))
        }
        _ = try await client().structured(system: "", user: "", schema: [:], effort: "low", maxTokens: 1, as: InboxClassifier.Output.self, feature: "Test")
        XCTAssertEqual(n, 2)
    }

    func seedThreads(_ e: Engine, count: Int) async throws {
        for i in 0..<count {
            let dto = try JSONDecoder().decode(GmailThreadDTO.self, from: JSONSerialization.data(withJSONObject: ["id": "t\(i)", "messages": [gmailMessage(id: "m\(i)", thread: "t\(i)", from: "Person \(i) <p\(i)@x.be>", labels: ["INBOX", "CATEGORY_PROMOTIONS"])]]))
            try await GmailSync.store(db: e.db, accountId: "a@example.com", dto: dto)
        }
    }

    @Test func testClassifierBatchesAndStores() async throws {
        let e = try makeEngine()
        try await seedThreads(e, count: 25)
        let waiting = try await e.db.pool.read { try MailThread.filter(Column("needsAIClassification") == true).fetchCount($0) }
        XCTAssertEqual(waiting, 25, "People in Promotions wait for Claude")
        MockServer.reset { c in
            let body = try! JSONSerialization.jsonObject(with: c.body) as! [String: Any]
            let user = ((body["messages"] as! [[String: Any]])[0]["content"] as! String)
            let n = user.components(separatedBy: "id: ").count - 1
            XCTAssertLessThanOrEqual(n, 20)
            let items = (0..<n).map { ["id": String($0), "bucket": "people"] }
            let text = String(decoding: try! JSONSerialization.data(withJSONObject: ["results": items]), as: UTF8.self)
            return (200, self.claudeBody(text))
        }
        let c = InboxClassifier(db: e.db, claude: client())
        let done = try await c.run()
        XCTAssertEqual(done, 25)
        XCTAssertEqual(MockServer.recorded("/v1/messages").count, 2)
        let people = try await e.mail.threads(ThreadQuery(folder: .inbox, bucket: .people))
        XCTAssertEqual(people.count, 25)
        // Resync keeps Claude's verdict and asks nothing again.
        try await seedThreads(e, count: 25)
        let again = try await c.run()
        XCTAssertEqual(again, 0)
    }

    @Test func testClassifierSkipsWithoutKeyAndWhenOff() async throws {
        let e = try makeEngine()
        try await seedThreads(e, count: 1)
        MockServer.reset { _ in (500, [:]) }
        let none = try await InboxClassifier(db: e.db, claude: client(key: nil)).run()
        XCTAssertEqual(none, 0)
        try e.db.setSetting("ai.classify", "0")
        let off = try await InboxClassifier(db: e.db, claude: client()).run()
        XCTAssertEqual(off, 0)
        XCTAssertTrue(MockServer.recorded("/v1/messages").isEmpty)
    }

    @Test func testSkippedThreadIsNotBilledTwice() async throws {
        let e = try makeEngine()
        try await seedThreads(e, count: 2)
        MockServer.reset { _ in (200, self.claudeBody("{\"results\":[{\"id\":\"0\",\"bucket\":\"people\"}]}")) }
        _ = try await InboxClassifier(db: e.db, claude: client()).run()
        XCTAssertEqual(MockServer.recorded("/v1/messages").count, 1)
    }

    @Test func testClassifierOnlyPaysForTheLast30Days() async throws {
        let e = try makeEngine()
        try await seedThreads(e, count: 3)
        let ids = try await e.db.pool.read { try MailThread.fetchAll($0).map(\.threadId) }
        let day = 86400.0
        try await e.db.pool.write { db in
            try db.execute(sql: "UPDATE thread SET lastMessageAt = ? WHERE threadId = ?", arguments: [Date().addingTimeInterval(-31 * day), ids[0]])
            try db.execute(sql: "UPDATE thread SET lastMessageAt = ? WHERE threadId = ?", arguments: [Date().addingTimeInterval(-29 * day), ids[1]])
        }
        MockServer.reset { c in
            let body = try! JSONSerialization.jsonObject(with: c.body) as! [String: Any]
            let user = ((body["messages"] as! [[String: Any]])[0]["content"] as! String)
            let n = user.components(separatedBy: "id: ").count - 1
            XCTAssertEqual(n, 2, "Only the two recent threads are sent")
            let items = (0..<n).map { ["id": String($0), "bucket": "people"] }
            let text = String(decoding: try! JSONSerialization.data(withJSONObject: ["results": items]), as: UTF8.self)
            return (200, self.claudeBody(text))
        }
        let done = try await InboxClassifier(db: e.db, claude: client()).run()
        XCTAssertEqual(done, 2)
        XCTAssertEqual(MockServer.recorded("/v1/messages").count, 1, "Old threads never trigger another call")
        let old = try await e.db.pool.read { try MailThread.filter(Column("threadId") == ids[0]).fetchOne($0) }
        XCTAssertEqual(old?.bucketSource, "gmail", "Old threads keep Gmail's sorting")
    }

    @Test func testSummaryStoredAndTitleDerived() async throws {
        let e = try makeEngine()
        let m = MeetingRecord(title: MeetingRecord.untitled, startedAt: Date(), status: .summarizing)
        try await e.meetings.save(m)
        try await e.meetings.replaceSegments(meetingId: m.id, [TranscriptSegmentRecord(meetingId: m.id, position: 0, startSeconds: 0, endSeconds: 1, speaker: "Me", text: "Week 48")])
        MockServer.reset { _ in
            (200, self.claudeBody(#"{"summary":"De plaatsing schuift. Verder niets.","decisions":[{"text":"Week 48","segment":0}],"action_items":[{"task":"Bevestigen","owner":"An","due":null,"status":"agreed","segment":0}],"open_questions":[],"speakers":[]}"#))
        }
        try await MeetingSummarizer(claude: client(), store: e.meetings).summarize(meetingId: m.id)
        let (saved, s) = try await e.meetings.get(m.id)!
        XCTAssertEqual(saved.title, "De plaatsing schuift")
        XCTAssertEqual(s?.decisions, ["Week 48"])
        XCTAssertEqual(s?.actionItems.first?.owner, "An")
        XCTAssertNil(s?.actionItems.first?.due)
    }
}

@Suite(.serialized) struct MCPTests {
    final class UI: MCPUIHooks, @unchecked Sendable {
        var queued: [OutboxRow] = []
        func didQueueSend(_ row: OutboxRow, mail: OutgoingMail) async { queued.append(row) }
    }

    func server(_ e: Engine, ui: MCPUIHooks? = nil) -> MCPServer {
        MCPServer(tools: PostvakTools.all(engine: e, recorder: nil, ui: ui)) { "secret" }
    }
    func req(_ body: Any, token: String? = "secret", origin: String? = nil) -> HTTPRequest {
        var h: [String: String] = [:]
        if let token { h["authorization"] = "Bearer \(token)" }
        if let origin { h["origin"] = origin }
        return HTTPRequest(method: "POST", path: "/mcp", query: [:], headers: h, body: try! JSONSerialization.data(withJSONObject: body))
    }
    func call(_ s: MCPServer, _ tool: String, _ args: [String: Any]) async -> (text: String, isError: Bool) {
        let r = await s.handle(req(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": args]]))
        let j = try! JSONSerialization.jsonObject(with: r.body) as! [String: Any]
        let result = j["result"] as! [String: Any]
        return (((result["content"] as! [[String: Any]])[0]["text"] as! String), result["isError"] as! Bool)
    }

    @Test func testAuthAndOrigin() async throws {
        let s = server(try makeEngine())
        let initMsg: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "ping"]
        let a = await s.handle(req(initMsg, token: nil)); XCTAssertEqual(a.status, 401)
        let b = await s.handle(req(initMsg, token: "wrong")); XCTAssertEqual(b.status, 401)
        let c = await s.handle(req(initMsg, origin: "https://evil.example")); XCTAssertEqual(c.status, 403)
        let d = await s.handle(req(initMsg, origin: "http://localhost:3000")); XCTAssertEqual(d.status, 200)
        let e = await s.handle(HTTPRequest(method: "GET", path: "/mcp", query: [:], headers: ["authorization": "Bearer secret"], body: Data())); XCTAssertEqual(e.status, 405)
    }

    @Test func testHandshakeAndList() async throws {
        let s = server(try makeEngine())
        let r = await s.handle(req(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]]))
        let j = try JSONSerialization.jsonObject(with: r.body) as! [String: Any]
        XCTAssertEqual((j["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        let n = await s.handle(req(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        XCTAssertEqual(n.status, 202)
        let l = await s.handle(req(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))
        let tools = ((try JSONSerialization.jsonObject(with: l.body) as! [String: Any])["result"] as! [String: Any])["tools"] as! [[String: Any]]
        let names = Set(tools.map { $0["name"] as! String })
        for expected in ["list_accounts", "search_mail", "get_thread", "get_attachment", "create_draft", "send_mail", "reply", "list_scheduled", "archive", "label", "mark_read", "snooze", "get_signature", "set_signature",
                         "list_calendars", "list_events", "get_availability", "create_event", "update_event", "delete_event", "respond_to_invite",
                         "list_meetings", "get_meeting", "get_transcript", "search_transcripts", "start_recording", "stop_recording"] {
            XCTAssertTrue(names.contains(expected), expected)
        }
    }

    @Test func testSendNeedsConfirmAndUsesUndoWindow() async throws {
        let e = try makeEngine()
        let ui = UI()
        let s = server(e, ui: ui)
        try e.db.setSetting("signature.a@example.com", "")
        let refused = await call(s, "send_mail", ["account": "a@example.com", "to": ["b@x.be"], "subject": "Hi", "body": "t", "confirm_send": false])
        XCTAssertTrue(refused.isError)
        var rows = try await e.outbox.rows()
        XCTAssertTrue(rows.isEmpty)
        let ok = await call(s, "send_mail", ["account": "a@example.com", "to": ["b@x.be"], "subject": "Hi", "body": "t", "confirm_send": true])
        XCTAssertFalse(ok.isError, ok.text)
        rows = try await e.outbox.rows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isUndoWindow)
        XCTAssertEqual(ui.queued.count, 1, "The app shows its undo toast")
        let id = rows[0].id
        let cancel = await call(s, "cancel_send", ["outbox_id": id])
        XCTAssertTrue(cancel.text.contains("true"))
    }

    /// Answers event creation like Google does: a Meet request comes back with its link.
    func createAnswer(_ c: MockServer.Call, meetAllowed: Bool = true) -> (Int, Any) {
        if let b = baseAnswer(c) { return b }
        guard c.path.hasSuffix("/events"), c.method == "POST" else { return (404, ["error": ["message": "unhandled"]]) }
        let body = (try? JSONSerialization.jsonObject(with: c.body) as? [String: Any]) ?? [:]
        var event: [String: Any] = ["id": "new\(MockServer.recorded("/events", method: "POST").count)", "summary": body["summary"] ?? "", "start": body["start"] ?? [:], "end": body["end"] ?? [:]]
        if body["conferenceData"] != nil {
            if !meetAllowed { return (400, ["error": ["message": "Invalid conference type value."]]) }
            event["hangoutLink"] = "https://meet.google.com/new-link-abc"
        }
        return (200, event)
    }

    func withCalendar(_ e: Engine) throws -> Engine {
        try e.db.pool.write { db in
            try CalendarRecord(accountId: "a@example.com", calendarId: "c", summary: "c", colorHex: "#000", isPrimary: true, isSelected: true, accessRole: "owner", syncToken: nil, lastFullSyncAt: nil).insert(db)
        }
        return e
    }

    @Test func testCreateEventAddsMeetByDefault() async throws {
        let s = server(try withCalendar(makeEngine()))
        MockServer.reset { self.createAnswer($0) }
        let timed = await call(s, "create_event", ["account": "a@example.com", "calendar_id": "c", "summary": "Call",
                                                   "start": "2026-11-10T10:00:00+01:00", "end": "2026-11-10T11:00:00+01:00"])
        XCTAssertFalse(timed.isError, timed.text)
        XCTAssertTrue(timed.text.contains("new-link-abc"), timed.text)
        var posts = MockServer.recorded("/events", method: "POST")
        XCTAssertEqual(posts.last?.query["conferenceDataVersion"], "1")

        let allDay = await call(s, "create_event", ["account": "a@example.com", "calendar_id": "c", "summary": "Fair", "all_day": true,
                                                    "start": "2026-11-12", "end": "2026-11-13"])
        XCTAssertFalse(allDay.isError, allDay.text)
        posts = MockServer.recorded("/events", method: "POST")
        XCTAssertNil(posts.last?.query["conferenceDataVersion"], "All-day events get no link unless asked")

        let optOut = await call(s, "create_event", ["account": "a@example.com", "calendar_id": "c", "summary": "Lunch", "add_meet_link": false,
                                                    "start": "2026-11-10T12:00:00+01:00", "end": "2026-11-10T13:00:00+01:00"])
        XCTAssertFalse(optOut.isError, optOut.text)
        posts = MockServer.recorded("/events", method: "POST")
        XCTAssertNil(posts.last?.query["conferenceDataVersion"])
    }

    @Test func testCreateEventWithoutMeetSupportStillCreates() async throws {
        let e = try withCalendar(makeEngine())
        MockServer.reset { self.createAnswer($0, meetAllowed: false) }
        let made = try await e.calendar.create(EventInput(accountId: "a@example.com", calendarId: "c", summary: "Call",
                                                          start: Date(), end: Date().addingTimeInterval(3600), addMeetLink: true))
        XCTAssertNil(made.meetingLink)
        let posts = MockServer.recorded("/events", method: "POST")
        XCTAssertEqual(posts.count, 2, "Retried once without the Meet request")
        XCTAssertNil(posts.last?.query["conferenceDataVersion"])
    }

    @Test func testDeleteEventNeedsConfirm() async throws {
        let s = server(try makeEngine())
        MockServer.reset { _ in XCTFail("no API call"); return (500, [:]) }
        let r = await call(s, "delete_event", ["account": "a@example.com", "calendar_id": "c", "event_id": "e", "confirm_delete": false])
        XCTAssertTrue(r.isError)
    }

    @Test func testSearchAndThreadRoundTrip() async throws {
        let e = try makeEngine()
        let dto = try JSONDecoder().decode(GmailThreadDTO.self, from: JSONSerialization.data(withJSONObject: ["id": "t", "messages": [gmailMessage(id: "m", thread: "t", subject: "Offerte", body: "De prijs is 4000 euro")]]))
        try await GmailSync.store(db: e.db, accountId: "a@example.com", dto: dto)
        let s = server(e)
        let found = await call(s, "search_mail", ["query": "prijs"])
        XCTAssertTrue(found.text.contains("Offerte"), found.text)
        let thread = await call(s, "get_thread", ["account": "a@example.com", "thread_id": "t"])
        XCTAssertTrue(thread.text.contains("4000 euro"))
        let bad = await call(s, "list_events", ["from": "gisteren", "to": "morgen"])
        XCTAssertTrue(bad.isError)
    }

    @Test func testRealSocketRoundTrip() async throws {
        let s = server(try makeEngine())
        try await s.start(port: 0)
        defer { s.stop() }
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(s.port)/mcp")!)
        r.httpMethod = "POST"
        r.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let (data, resp) = try await URLSession.shared.data(for: r)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("search_mail"))
    }
}

@Suite(.serialized) struct AuthTests {
    @Test func testPKCEShape() {
        let (v, c) = GoogleAuth.pkcePair()
        XCTAssertGreaterThanOrEqual(v.count, 43)
        XCTAssertFalse(c.contains("="))
        XCTAssertFalse(c.contains("+"))
    }

    @Test func testExpired401RefreshesOnce() async throws {
        let e = try makeEngine()
        nonisolated(unsafe) var profileCalls = 0
        MockServer.reset { c in
            if c.path.hasSuffix("/token") { return (200, ["access_token": "tok\(MockServer.recorded("/token").count)", "expires_in": 3600]) }
            profileCalls += 1
            return profileCalls == 1 ? (401, ["error": ["message": "expired"]]) : (200, ["emailAddress": "a@example.com", "historyId": "1"])
        }
        let p = try await e.gmail.profile("a@example.com")
        XCTAssertEqual(p.historyId, "1")
        XCTAssertEqual(MockServer.recorded("/token").count, 2)
    }

    @Test func testRevokedSignInFlagsAccount() async throws {
        let e = try makeEngine()
        MockServer.reset { c in
            if c.path.hasSuffix("/token") { return (400, ["error": "invalid_grant"]) }
            return (200, [:])
        }
        await e.syncMail(accountId: "a@example.com")
        let a = try await e.db.pool.read { try Account.fetchOne($0, key: "a@example.com") }
        XCTAssertEqual(a?.needsReauth, true)
    }
}

@Suite(.serialized) struct HTTPParseTests {
    @Test func testPartialThenComplete() {
        let head = "POST /mcp?x=1 HTTP/1.1\r\nContent-Length: 4\r\nAuthorization: Bearer t\r\n\r\n"
        if case .needMore = LoopbackHTTPServer.parse(Data((head + "ab").utf8), maxBody: 100) {} else { XCTFail() }
        guard case .complete(let r) = LoopbackHTTPServer.parse(Data((head + "abcd").utf8), maxBody: 100) else { return XCTFail() }
        XCTAssertEqual(r.path, "/mcp")
        XCTAssertEqual(r.query["x"], "1")
        XCTAssertEqual(r.headers["authorization"], "Bearer t")
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "abcd")
        if case .invalid(413) = LoopbackHTTPServer.parse(Data("POST / HTTP/1.1\r\nContent-Length: 999\r\n\r\n".utf8), maxBody: 100) {} else { XCTFail() }
    }
}

@Suite struct AutoRecordTests {
    let now = ISO8601DateFormatter().date(from: "2026-11-10T10:02:00Z")!
    let guests = "[{\"email\":\"me@x.be\",\"response\":\"accepted\",\"isSelf\":true,\"isOrganizer\":true},{\"email\":\"an@x.be\",\"response\":\"accepted\",\"isSelf\":false,\"isOrganizer\":false}]"

    func event(_ id: String, start: Int = 0, minutes: Int = 60, link: String? = nil, guests: Bool = true,
               response: String? = "accepted", allDay: Bool = false, free: Bool = false) -> CalendarEvent {
        let s = ISO8601DateFormatter().date(from: "2026-11-10T10:00:00Z")!.addingTimeInterval(TimeInterval(start * 60))
        return CalendarEvent(accountId: "a", calendarId: "c", eventId: id, summary: id, details: "", location: "", startAt: s,
                             endAt: s.addingTimeInterval(TimeInterval(minutes * 60)), isAllDay: allDay, status: "confirmed",
                             transparency: free ? "transparent" : "opaque", organizerEmail: "me@x.be", attendeesJSON: guests ? self.guests : "[]",
                             selfResponse: response, meetingLink: link, htmlLink: nil, recurringEventId: nil)
    }

    @Test func testMeetingAppsAlwaysRecordAndFindTheirMeeting() {
        let r = AutoRecord.call(app: "Zoom", events: [], now: now)
        XCTAssertTrue(r.record)
        XCTAssertTrue(r.meeting == nil)
        // The meeting with a video link wins over one without, even if the other starts closer to now.
        let found = AutoRecord.call(app: "Microsoft Teams", events: [event("room", start: 2), event("call", start: -10, link: "https://teams.microsoft.com/l/x")], now: now)
        XCTAssertEqual(found.meeting?.eventId, "call")
    }

    @Test func testBrowserAndFaceTimeRecordOnlyDuringACalendarMeeting() {
        XCTAssertFalse(AutoRecord.call(app: "a browser call", events: [], now: now).record, "Dictation in a browser is not a meeting")
        XCTAssertFalse(AutoRecord.call(app: "FaceTime", events: [event("lunch", guests: false)], now: now).record, "A personal event is not a meeting")
        XCTAssertFalse(AutoRecord.call(app: "a browser call", events: [event("declined", link: "https://meet.google.com/a", response: "declined")], now: now).record)
        let meet = AutoRecord.call(app: "a browser call", events: [event("standup", start: 10, link: "https://meet.google.com/abc")], now: now)
        XCTAssertTrue(meet.record, "Joining a few minutes early counts")
        XCTAssertEqual(meet.meeting?.eventId, "standup")
    }

    @Test func testRoomMeetingStartsOnlyInItsFirstMinutes() {
        XCTAssertEqual(AutoRecord.roomMeeting(events: [event("room")], now: now, alreadyStarted: [])?.eventId, "room")
        XCTAssertTrue(AutoRecord.roomMeeting(events: [event("room", start: -10)], now: now, alreadyStarted: []) == nil, "Opening Postvak halfway through doesn't start it")
        XCTAssertTrue(AutoRecord.roomMeeting(events: [event("room", start: 5)], now: now, alreadyStarted: []) == nil, "Not before it starts")
        XCTAssertTrue(AutoRecord.roomMeeting(events: [event("room")], now: now, alreadyStarted: ["a/c/room"]) == nil, "Stopped by hand stays stopped")
    }

    @Test func testRoomMeetingNeedsAcceptedGuestsAndNoVideoLink() {
        for e in [event("call", link: "https://meet.google.com/a"), event("alone", guests: false), event("maybe", response: "needsAction"),
                  event("free", free: true), event("day", allDay: true)] {
            XCTAssertTrue(AutoRecord.roomMeeting(events: [e], now: now, alreadyStarted: []) == nil, e.eventId)
        }
    }
}
