import Foundation
import Testing
@testable import PostvakCore
@testable import PostvakAI

private func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
private func json(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:] }

private final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

/// An imported meeting with only a summary, and a recorded one with only a transcript.
private func seed(_ e: Engine) async throws -> (imported: String, recorded: String) {
    try await e.meetings.importMeeting(ImportedMeeting(
        source: "granola", sourceId: "g1", title: "Partnership Panelwerk", startedAt: at("2026-10-06T09:00:00Z"),
        attendees: ["Jan Peeters <jan@panelwerk.be>"],
        summary: "We bespraken de marges op omvormers.\nPanelwerk wil een proefperiode van drie maanden.",
        actionItems: [ActionItem(task: "Prijsvoorstel sturen", owner: "Me", due: "vrijdag")],
        decisions: ["Proefperiode start in januari"]))
    let imported = try await e.meetings.list(text: "Panelwerk")[0].id
    let m = MeetingRecord(title: "Lunch Groenlicht", startedAt: at("2026-11-05T11:00:00Z"), status: .ready)
    try await e.meetings.save(m)
    try await e.meetings.replaceSegments(meetingId: m.id, [
        TranscriptSegmentRecord(meetingId: m.id, position: 0, startSeconds: 65, endSeconds: 70, speaker: "Ruben", text: "De premie voor de verzekering is te hoog."),
        TranscriptSegmentRecord(meetingId: m.id, position: 1, startSeconds: 71, endSeconds: 75, speaker: "Me", text: "Dat begrijp ik."),
    ])
    return (imported, m.id)
}

@Suite(.serialized) struct MeetingChatTests {
    func client() -> ClaudeClient { ClaudeClient(session: MockServer.session) { "k" } }
    func answer(_ text: String) -> (Int, Any) { (200, ["content": [["type": "text", "text": text]], "stop_reason": "end_turn"]) }

    @Test func testSearchCoversSummariesAndTranscriptsIgnoringCaseAndAccents() async throws {
        let e = try makeEngine()
        let ids = try await seed(e)
        var hits = try await e.meetings.searchEverywhere("PROEFPERIODE panelwerk")
        XCTAssertEqual(hits.first?.meetingId, ids.imported)
        XCTAssertEqual(hits.first?.kind, .summary, "The passage with both words beats the title with one")
        XCTAssertEqual(hits.first?.text, "Panelwerk wil een proefperiode van drie maanden.")

        hits = try await e.meetings.searchEverywhere("prémie")
        XCTAssertEqual(hits.map(\.kind), [.transcript])
        XCTAssertEqual(hits.first?.speaker, "Ruben")
        XCTAssertEqual(hits.first?.startSeconds, 65)

        XCTAssertEqual(try await e.meetings.searchEverywhere("prijsvoorstel").map(\.kind), [.actionItem])
        XCTAssertEqual(try await e.meetings.searchEverywhere("panelwerk.be").first?.kind, .title, "Attendee addresses are searchable")
        XCTAssertTrue(try await e.meetings.searchEverywhere("panelwerk", from: at("2026-11-01T00:00:00Z")).isEmpty)
        XCTAssertTrue(try await e.meetings.searchEverywhere("de").allSatisfy { $0.matched == 1 })
    }

    @Test func testToolLoopEchoesTheAssistantTurnAndKeepsHistory() async throws {
        let e = try makeEngine()
        let ids = try await seed(e)
        nonisolated(unsafe) var n = 0
        MockServer.reset { c in
            n += 1
            if n == 1 {
                return (200, ["content": [
                    ["type": "thinking", "thinking": "", "signature": "sig1"],
                    ["type": "tool_use", "id": "tu1", "name": "search_meetings", "input": ["query": "proefperiode"]],
                    ["type": "tool_use", "id": "tu2", "name": "read_meeting", "input": ["meeting_id": ids.imported]],
                    ["type": "tool_use", "id": "tu3", "name": "read_meeting", "input": ["meeting_id": ids.recorded]],
                ], "stop_reason": "tool_use"] as [String: Any])
            }
            return self.answer("Drie maanden, volgens [Partnership Panelwerk](postvak://meeting/\(ids.imported)).")
        }
        let chat = MeetingChat(claude: client(), store: e.meetings)
        let steps = Steps()
        let reply = try await chat.ask("Hoe lang duurt de proefperiode?") { steps.add($0) }
        XCTAssertTrue(reply.hasPrefix("Drie maanden"))
        XCTAssertEqual(steps.all, ["Searching for “proefperiode”", "Reading “Partnership Panelwerk”", "Reading “Lunch Groenlicht”"])

        let calls = MockServer.recorded("/v1/messages")
        XCTAssertEqual(calls.count, 2)
        let first = json(calls[0].body)
        XCTAssertEqual(first["model"] as? String, "claude-haiku-5-5")
        XCTAssertNil(first["fallbacks"], "Haiku 5.5 has no server-side fallback")
        XCTAssertNil(first["thinking"])
        XCTAssertNil(first["tool_choice"])
        XCTAssertEqual((first["output_config"] as? [String: Any])?["effort"] as? String, "medium")
        XCTAssertEqual((first["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["search_meetings", "read_meeting", "list_meetings"])
        let system = first["system"] as? String ?? ""
        XCTAssertTrue(system.contains("\(ids.imported) | 2026-10-06"), "The catalog lists each meeting with its id")
        XCTAssertTrue(system.contains("Partnership Panelwerk | Jan Peeters | summary"))
        XCTAssertTrue(system.contains("Lunch Groenlicht | - | transcript"))

        let msgs = json(calls[1].body)["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(msgs.count, 3)
        let echoed = msgs[1]["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(echoed.count, 4, "The assistant turn goes back whole")
        XCTAssertEqual(echoed.first?["signature"] as? String, "sig1", "Thinking goes back unchanged")
        let results = msgs[2]["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(results.compactMap { $0["tool_use_id"] as? String }, ["tu1", "tu2", "tu3"], "All results in one message")
        let search = results[0]["content"] as? String ?? ""
        XCTAssertTrue(search.contains("summary: Panelwerk wil een proefperiode van drie maanden."))
        let imported = results[1]["content"] as? String ?? ""
        XCTAssertTrue(imported.contains("- Prijsvoorstel sturen (owner: Me; due: vrijdag)"))
        XCTAssertTrue(imported.contains("Transcript: none"))
        let recorded = results[2]["content"] as? String ?? ""
        XCTAssertTrue(recorded.contains("[01:05] Ruben: De premie voor de verzekering is te hoog."))
        XCTAssertTrue(recorded.contains("Summary: none."))

        // A follow-up sends the whole history with the same system prompt, so the cache holds.
        _ = try await chat.ask("Wie was erbij?")
        let third = json(MockServer.recorded("/v1/messages")[2].body)
        XCTAssertEqual((third["messages"] as? [[String: Any]])?.count, 5)
        XCTAssertEqual(third["system"] as? String, system)
    }

    @Test func testFailedQuestionLeavesNoHalfTurnBehind() async throws {
        let e = try makeEngine()
        nonisolated(unsafe) var n = 0
        MockServer.reset { _ in
            n += 1
            if n == 1 {
                return (200, ["content": [["type": "tool_use", "id": "tu1", "name": "list_meetings", "input": [:] as [String: Any]]], "stop_reason": "tool_use"] as [String: Any])
            }
            if n == 2 { return (400, ["error": ["message": "bad request"]]) }
            return self.answer("ok")
        }
        let chat = MeetingChat(claude: client(), store: e.meetings)
        do { _ = try await chat.ask("Eerste vraag"); XCTFail("should throw") } catch {}
        _ = try await chat.ask("Tweede vraag")
        let last = json(MockServer.recorded("/v1/messages").last!.body)
        let msgs = last["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(msgs.count, 1, "The failed question and its lookups are gone")
        XCTAssertEqual(msgs.first?["content"] as? String, "Tweede vraag")
    }

    @Test func testMailIsSearchedAndReadAlongsideMeetings() async throws {
        let e = try makeEngine()
        let dto = try JSONDecoder().decode(GmailThreadDTO.self, from: JSONSerialization.data(withJSONObject: ["id": "t9", "messages": [
            gmailMessage(id: "m9", thread: "t9", from: "Jan <jan@panelwerk.be>", subject: "Offerte omvormers", body: "Wij bieden 40 omvormers aan voor €9.800.")]]))
        try await GmailSync.store(db: e.db, accountId: "a@example.com", dto: dto)
        let chat = MeetingChat(claude: client(), store: e.meetings, mail: e.mail)
        let hits = try await chat.execute("search_mail", ["query": "omvormers panelwerk"], step: { _ in })
        XCTAssertTrue(hits.hasPrefix("a@example.com/t9 | "), hits)
        let thread = try await chat.execute("read_mail", ["thread_id": "a@example.com/t9"], step: { _ in })
        XCTAssertTrue(thread.contains("€9.800"), thread)
        // The tools and the link format are offered only when mail is connected.
        MockServer.reset { _ in self.answer("ok") }
        _ = try await chat.ask("Wat kostten de omvormers?")
        let body = json(MockServer.recorded("/v1/messages").last!.body)
        XCTAssertTrue((body["tools"] as? [[String: Any]])?.contains { $0["name"] as? String == "search_mail" } == true)
        XCTAssertTrue((body["system"] as? String)?.contains("postvak://mail/") == true)
        let meetingsOnly = try await MeetingChat.systemPrompt(store: e.meetings, now: Date())
        XCTAssertFalse(meetingsOnly.contains("postvak://mail/"))
    }

    @Test func testReopenedChatAsksOnWithItsEarlierAnswers() async throws {
        let e = try makeEngine()
        MockServer.reset { _ in self.answer("Week 48.") }
        let chat = MeetingChat(claude: client(), store: e.meetings)
        _ = try await chat.ask("Iets anders")
        await chat.restore([(question: "Wanneer plaatsen we in Gent?", answer: "In week 47.")])
        _ = try await chat.ask("En als het regent?")
        let msgs = json(MockServer.recorded("/v1/messages").last!.body)["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(msgs.compactMap { $0["content"] as? String }, ["Wanneer plaatsen we in Gent?", "In week 47.", "En als het regent?"],
                       "The reopened chat, not the one before it")
        XCTAssertEqual(msgs.map { $0["role"] as? String ?? "" }, ["user", "assistant", "user"])
    }

    @Test func testRefusalIsReportedAndForgotten() async throws {
        let e = try makeEngine()
        MockServer.reset { _ in (200, ["content": [] as [Any], "stop_reason": "refusal", "stop_details": ["category": "cyber"]] as [String: Any]) }
        let chat = MeetingChat(claude: client(), store: e.meetings)
        do { _ = try await chat.ask("x"); XCTFail("should throw") } catch { XCTAssertTrue("\(error)".contains("refused")) }
        MockServer.reset { _ in self.answer("ok") }
        _ = try await chat.ask("y")
        XCTAssertEqual((json(MockServer.recorded("/v1/messages")[0].body)["messages"] as? [[String: Any]])?.count, 1)
    }

    @Test func testToolRoundsAreCapped() async throws {
        let e = try makeEngine()
        nonisolated(unsafe) var n = 0
        MockServer.reset { c in
            n += 1
            if json(c.body)["tool_choice"] != nil { return self.answer("Met wat ik vond: niets.") }
            return (200, ["content": [["type": "tool_use", "id": "tu\(n)", "name": "search_meetings", "input": ["query": "x\(n)"]]], "stop_reason": "tool_use"] as [String: Any])
        }
        let reply = try await MeetingChat(claude: client(), store: e.meetings).ask("?")
        XCTAssertEqual(reply, "Met wat ik vond: niets.")
        let calls = MockServer.recorded("/v1/messages")
        XCTAssertEqual(calls.count, MeetingChat.maxToolRounds + 1)
        XCTAssertEqual((json(calls.last!.body)["tool_choice"] as? [String: Any])?["type"] as? String, "none")
    }

    @Test func testBadToolInputComesBackAsAnError() async throws {
        let e = try makeEngine()
        let chat = MeetingChat(claude: client(), store: e.meetings)
        do { _ = try await chat.execute("read_meeting", ["meeting_id": "nope"], step: { _ in }); XCTFail("should throw") }
        catch { XCTAssertTrue(error.localizedDescription.contains("No meeting")) }
        do { _ = try await chat.execute("search_meetings", ["query": "x", "from": "last week"], step: { _ in }); XCTFail("should throw") }
        catch { XCTAssertTrue(error.localizedDescription.contains("YYYY-MM-DD")) }
    }
}

@Suite(.serialized) struct AskHistoryTests {
    @Test func testChatsAreNamedAfterTheirFirstQuestionNewestFirst() async throws {
        let e = try makeEngine()
        let h = AskHistory(db: e.db)
        try await h.save(AskTurnRecord(id: "1", chatId: "a", question: "Wat beloofde ik Panelwerk?", answer: nil, error: nil, steps: [], askedAt: at("2026-11-05T09:00:00Z")))
        try await h.save(AskTurnRecord(id: "2", chatId: "b", question: "Wie was er bij de demo?", answer: "An en Bert.", error: nil, steps: ["Searching"], askedAt: at("2026-11-05T10:00:00Z")))
        try await h.save(AskTurnRecord(id: "3", chatId: "a", question: "En de prijs?", answer: "€200.", error: nil, steps: [], askedAt: at("2026-11-06T09:00:00Z")))
        // The first question gets its answer later: saved again, not twice.
        try await h.save(AskTurnRecord(id: "1", chatId: "a", question: "Wat beloofde ik Panelwerk?", answer: "Een offerte.", error: nil, steps: ["Reading"], askedAt: at("2026-11-05T09:00:00Z")))

        let chats = try await e.db.pool.read { try AskHistory.chats($0) }
        XCTAssertEqual(chats.map(\.id), ["a", "b"], "Asked in most recently first")
        XCTAssertEqual(chats.first?.title, "Wat beloofde ik Panelwerk?")
        XCTAssertEqual(chats.first?.questions, 2)
        let turns = try await h.turns(chatId: "a")
        XCTAssertEqual(turns.map(\.answer), ["Een offerte.", "€200."])
        XCTAssertEqual(turns.first?.steps, ["Reading"])

        try await h.deleteChat("a")
        XCTAssertEqual(try await e.db.pool.read { try AskHistory.chats($0) }.map(\.id), ["b"])
    }
}

@Suite(.serialized) struct PrepBriefTests {
    func client() -> ClaudeClient { ClaudeClient(session: MockServer.session) { "k" } }

    func event(_ guests: String) -> CalendarEvent {
        CalendarEvent(accountId: "a@example.com", calendarId: "c", eventId: "e1", summary: "Follow-up Panelwerk", details: "", location: "",
                      startAt: at("2026-11-10T09:00:00Z"), endAt: at("2026-11-10T10:00:00Z"), isAllDay: false, status: "confirmed",
                      transparency: "opaque", organizerEmail: "a@example.com", attendeesJSON: guests, selfResponse: "accepted",
                      meetingLink: nil, htmlLink: nil, recurringEventId: nil)
    }
    let guests = "[{\"email\":\"a@example.com\",\"response\":\"accepted\",\"isSelf\":true,\"isOrganizer\":true},{\"email\":\"jan@panelwerk.be\",\"name\":\"Jan\",\"response\":\"accepted\",\"isSelf\":false,\"isOrganizer\":false}]"

    @Test func testContextFindsMailMeetingsAndRemindersWithTheGuests() async throws {
        let e = try makeEngine()
        let now = at("2026-11-09T09:00:00Z")
        func thread(_ id: String, from: String, subject: String) throws -> GmailThreadDTO {
            try JSONDecoder().decode(GmailThreadDTO.self, from: JSONSerialization.data(withJSONObject: ["id": id, "messages": [
                gmailMessage(id: "m-\(id)", thread: id, from: from, subject: subject, hoursAgo: 48)]]))
        }
        try await GmailSync.store(db: e.db, accountId: "a@example.com", dto: try thread("t1", from: "Jan <jan@panelwerk.be>", subject: "Offerte"))
        // A colleague at the same company counts; someone at gmail.com doesn't.
        try await GmailSync.store(db: e.db, accountId: "a@example.com", dto: try thread("t2", from: "Piet <piet@panelwerk.be>", subject: "Levering"))
        try await GmailSync.store(db: e.db, accountId: "a@example.com", dto: try thread("t3", from: "Other <someone@gmail.com>", subject: "Iets anders"))
        try await e.followUps.track(FollowUpRecord(id: "s1", accountId: "a@example.com", threadId: "t1", subject: "Offerte",
                                                   recipients: "jan@panelwerk.be", sentAt: now, dueAt: now.addingTimeInterval(86400)))
        let c = try await PrepBriefs(db: e.db).context(for: event(guests), now: Date())
        XCTAssertEqual(Set(c.threads.map(\.id)), ["a@example.com/t1", "a@example.com/t2"])
        XCTAssertEqual(c.reminders.map(\.id), ["s1"])
        XCTAssertEqual(c.guests.map(\.email), ["jan@panelwerk.be"], "You are not a guest of your own meeting")
        XCTAssertTrue(PrepBriefs.wantsBrief(event(guests)))
        XCTAssertFalse(PrepBriefs.wantsBrief(event("[]")), "Nobody else, no brief")
        let ev = event(guests)
        XCTAssertFalse(PrepBriefs.isOver(ev, now: ev.endAt.addingTimeInterval(-60)), "Still running: the brief stays")
        XCTAssertTrue(PrepBriefs.isOver(ev, now: ev.endAt), "Ended: the summary takes its place")
    }

    @Test func testBriefIsWrittenFromTheContextOrSkippedWithoutOne() async throws {
        let e = try makeEngine()
        MockServer.reset { _ in (200, ["content": [["type": "text", "text": "{\"brief\":\"- Jan wacht op de offerte [Offerte](postvak://mail/a@example.com/t1), 7 Nov\"}"]], "stop_reason": "end_turn"]) }
        let empty = try await PrepBriefWriter(claude: client()).brief(for: event(guests), context: PrepContext(guests: [], threads: [], meetings: [], reminders: []))
        XCTAssertEqual(empty, "No earlier email or meetings with these guests yet.")
        XCTAssertEqual(MockServer.recorded("/v1/messages").count, 0, "Nothing to go on, so no call")

        let ctx = PrepContext(guests: event(guests).attendees.filter { !$0.isSelf },
                              threads: [.init(id: "a@example.com/t1", subject: "Offerte", lastAt: Date(), messages: [(from: "Jan", date: Date(), text: "Graag een offerte.")])],
                              meetings: [], reminders: [])
        let text = try await PrepBriefWriter(claude: client()).brief(for: event(guests), context: ctx)
        XCTAssertTrue(text.contains("postvak://mail/a@example.com/t1"))
        let body = json(MockServer.recorded("/v1/messages")[0].body)
        let user = ((body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        XCTAssertTrue(user.contains("EMAIL THREAD id=a@example.com/t1") && user.contains("Graag een offerte."), user)

        // Kept, so opening the event again reads it back.
        let briefs = PrepBriefs(db: e.db)
        try await briefs.save(event(guests), text: text)
        XCTAssertEqual(try await briefs.cached(event(guests))?.text, text)
    }
}
