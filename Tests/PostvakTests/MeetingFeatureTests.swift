import Foundation
import Testing
import GRDB
@testable import PostvakCore
@testable import PostvakAI
@testable import PostvakMCP

/// Shared set-up for the meeting features: a recorded call with the user and guests, and a transcript.
enum MeetingFixture {
    static func atts(_ guests: [(String, String?)]) -> String {
        let all = [EventAttendee(email: "a@example.com", isSelf: true)] + guests.map { EventAttendee(email: $0.0, name: $0.1, response: "accepted") }
        return String(decoding: try! JSONEncoder().encode(all), as: UTF8.self)
    }

    /// A recorded meeting. `call` gives it a system audio track, which makes it a call rather than a room recording.
    static func meeting(_ e: Engine, guests: [(String, String?)], labels: [String], call: Bool = true, text: [String]? = nil) async throws -> MeetingRecord {
        try await e.db.pool.write { db in
            try db.execute(sql: "UPDATE account SET displayName = 'Anna Vermeulen'")
        }
        var m = MeetingRecord(title: "Call", startedAt: Date().addingTimeInterval(-3600), endedAt: Date().addingTimeInterval(-1800), status: .ready)
        m.attendeesJSON = atts(guests)
        m.micAudioPath = "/tmp/mic.m4a"
        if call { m.systemAudioPath = "/tmp/system.m4a" }
        try await e.meetings.save(m)
        let segs = labels.enumerated().map { i, l in
            TranscriptSegmentRecord(meetingId: m.id, position: i, startSeconds: Double(i * 10), endSeconds: Double(i * 10 + 9), speaker: l,
                                    text: text?[i] ?? "Zin \(i)")
        }
        try await e.meetings.replaceSegments(meetingId: m.id, segs)
        return m
    }
}

@Suite(.serialized) struct SpeakerTests {
    let jan = SpeakerCandidate(name: "Jan Peeters", email: "jan@acme.be")
    let me = SpeakerCandidate(name: "Anna Vermeulen", email: "a@example.com")

    @Test func testRuleNamesOnlyWhatCannotBeAnyoneElse() {
        let piet = SpeakerCandidate(name: "Piet", email: "piet@acme.be")
        // One guest, one voice on the call: both sides are known.
        let one = SpeakerNames.rule(labels: ["Me", "Others"], isCall: true, me: me, guests: [jan])
        XCTAssertEqual(one["Me"], me)
        XCTAssertEqual(one["Others"], jan)
        // Two guests on the call audio could be either one.
        let two = SpeakerNames.rule(labels: ["Me", "Others"], isCall: true, me: me, guests: [jan, piet])
        XCTAssertEqual(two.count, 1)
        XCTAssertNil(two["Others"])
        // The call audio is the other side: with one guest, every voice the separation found there is that guest.
        let split = SpeakerNames.rule(labels: ["Me", "Speaker 1", "Speaker 2", "Unknown"], isCall: true, me: me, guests: [jan])
        XCTAssertEqual(split["Speaker 1"], jan)
        XCTAssertEqual(split["Speaker 2"], jan)
        XCTAssertEqual(split["Unknown"], jan)
        XCTAssertNil(SpeakerNames.rule(labels: ["Me", "Speaker 1", "Speaker 2"], isCall: true, me: me, guests: [jan, piet])["Speaker 1"])
        // A room recording has everyone on one microphone: no names by rule.
        XCTAssertTrue(SpeakerNames.rule(labels: ["Speaker 1", "Speaker 2"], isCall: false, me: me, guests: [jan]).isEmpty)
    }

    @Test func testCallWithOneGuestGetsNames() async throws {
        let e = try makeEngine()
        let m = try await MeetingFixture.meeting(e, guests: [("jan@acme.be", "Jan Peeters")], labels: ["Me", "Others", "Me"])
        try await e.meetings.assignSpeakers(meetingId: m.id)
        let names = try await e.meetings.speakerNames(meetingId: m.id)
        XCTAssertEqual(names["Me"], "Anna Vermeulen")
        XCTAssertEqual(names["Others"], "Jan Peeters")
    }

    @Test func testGuestWithoutNameInInviteIsNamedFromMail() async throws {
        let e = try makeEngine()
        try await e.db.pool.write { db in
            try MailMessage(accountId: "a@example.com", messageId: "m1", threadId: "t1", rfcMessageId: nil, inReplyTo: nil, referencesHeader: nil,
                            fromName: "Jan Peeters", fromEmail: "jan@acme.be", toLine: "a@example.com", ccLine: "", subject: "Offerte",
                            date: Date(), snippet: "", bodyText: "", bodyHtml: nil, labelIds: "|INBOX|", hasListUnsubscribe: false).insert(db)
        }
        let m = try await MeetingFixture.meeting(e, guests: [("jan@acme.be", nil)], labels: ["Me", "Others"])
        try await e.meetings.assignSpeakers(meetingId: m.id)
        XCTAssertEqual(try await e.meetings.speakerNames(meetingId: m.id)["Others"], "Jan Peeters")
    }

    @Test func testRenameCarriesIntoSummaryWithoutRewriting() async throws {
        let e = try makeEngine()
        let m = try await MeetingFixture.meeting(e, guests: [("jan@acme.be", "Jan Peeters"), ("piet@acme.be", "Piet")], labels: ["Me", "Speaker 2", "Speaker 21"])
        try await e.meetings.saveSummary(MeetingSummaryRecord(
            meetingId: m.id, summary: "Speaker 2 stuurt de offerte. Speaker 21 wacht.", decisions: ["Speaker 2 beslist mee"],
            actionItems: [ActionItem(task: "Speaker 2 bevestigt de datum", owner: "Speaker 2"), ActionItem(task: "Plannen", owner: "Me")],
            openQuestions: [], model: "claude-haiku-5-5"))

        try await e.meetings.renameSpeaker(meetingId: m.id, label: "Speaker 2", name: "Jan Peeters", email: "jan@acme.be")
        var s = try await e.meetings.get(m.id)!.1!
        XCTAssertEqual(s.summary, "Jan Peeters stuurt de offerte. Speaker 21 wacht.")
        XCTAssertEqual(s.decisions, ["Jan Peeters beslist mee"])
        XCTAssertEqual(s.actionItems[0].owner, "Jan Peeters")
        XCTAssertEqual(s.actionItems[0].task, "Jan Peeters bevestigt de datum")

        // A wrong name corrected, then taken away again.
        try await e.meetings.renameSpeaker(meetingId: m.id, label: "Speaker 2", name: "Piet")
        s = try await e.meetings.get(m.id)!.1!
        XCTAssertEqual(s.summary, "Piet stuurt de offerte. Speaker 21 wacht.")
        try await e.meetings.renameSpeaker(meetingId: m.id, label: "Speaker 2", name: nil)
        s = try await e.meetings.get(m.id)!.1!
        XCTAssertEqual(s.summary, "Speaker 2 stuurt de offerte. Speaker 21 wacht.")
        XCTAssertEqual(s.actionItems[0].owner, "Speaker 2")

        // "Me" is also a word, so only the owner field changes.
        try await e.meetings.renameSpeaker(meetingId: m.id, label: "Me", name: "Anna")
        s = try await e.meetings.get(m.id)!.1!
        XCTAssertEqual(s.actionItems[1].owner, "Anna")
    }

    @Test func testUserNamesSurviveTheRuleAndNewTranscripts() async throws {
        let e = try makeEngine()
        let m = try await MeetingFixture.meeting(e, guests: [("jan@acme.be", "Jan Peeters")], labels: ["Me", "Others"])
        try await e.meetings.renameSpeaker(meetingId: m.id, label: "Others", name: "Jan en Piet")
        try await e.meetings.assignSpeakers(meetingId: m.id)
        XCTAssertEqual(try await e.meetings.speakerNames(meetingId: m.id)["Others"], "Jan en Piet", "The rule never overwrites the user")

        try await e.meetings.renameSpeaker(meetingId: m.id, label: "Speaker 3", name: "Piet")
        try await e.meetings.resetSpeakers(meetingId: m.id, labels: ["Me", "Others", "Speaker 3"])
        let after = try await e.meetings.speakerNames(meetingId: m.id)
        XCTAssertEqual(after["Others"], "Jan en Piet", "A track label is the same voice in a new transcript")
        XCTAssertNil(after["Speaker 3"], "A separated voice may be someone else in a new transcript")
    }

    @Test func testSuggestionsOnlyNameGuestsAndWaitForConfirmation() async throws {
        let e = try makeEngine()
        let m = try await MeetingFixture.meeting(e, guests: [("jan@acme.be", "Jan Peeters"), ("piet@acme.be", "Piet Claes")],
                                                 labels: ["Me", "Speaker 1", "Speaker 2"])
        try await e.meetings.assignSpeakers(meetingId: m.id)
        try await e.meetings.suggestSpeakers(meetingId: m.id, [(label: "Speaker 1", name: "Jan Peeters"), (label: "Speaker 2", name: "Marie Dubois"),
                                                               (label: "Me", name: "Piet Claes")])
        let rows = try await e.meetings.speakers(meetingId: m.id)
        XCTAssertEqual(rows.first { $0.label == "Speaker 1" }?.source, .suggested)
        XCTAssertNil(rows.first { $0.label == "Speaker 2" }, "Nobody called Marie was invited")
        XCTAssertEqual(rows.first { $0.label == "Me" }?.source, .auto, "A named speaker gets no suggestion")
        XCTAssertNil(try await e.meetings.speakerNames(meetingId: m.id)["Speaker 1"], "A suggestion is not applied")
    }

    @Test func testSummaryPromptUsesNamesAndStoresSuggestions() async throws {
        let e = try makeEngine()
        let m = try await MeetingFixture.meeting(e, guests: [("jan@acme.be", "Jan Peeters"), ("piet@acme.be", "Piet Claes")],
                                                 labels: ["Me", "Speaker 1"], text: ["Dag Jan, hoe gaat het?", "Goed, dank je."])
        try await e.meetings.assignSpeakers(meetingId: m.id)
        MockServer.reset { c in
            let body = try! JSONSerialization.jsonObject(with: c.body) as! [String: Any]
            let user = (body["messages"] as! [[String: Any]])[0]["content"] as! String
            XCTAssertTrue(user.contains("Anna Vermeulen:"), "The recorder's lines carry their name")
            XCTAssertTrue(user.contains("Speaker 1:"))
            let reply = #"{"summary":"Speaker 1 is tevreden.","decisions":[],"action_items":[],"open_questions":[],"speakers":[{"label":"Speaker 1","attendee":"Jan Peeters"}]}"#
            return (200, ["content": [["type": "text", "text": reply]], "stop_reason": "end_turn"])
        }
        try await MeetingSummarizer(claude: ClaudeClient(session: MockServer.session) { "k" }, store: e.meetings).summarize(meetingId: m.id)
        let row = try await e.meetings.speakers(meetingId: m.id).first { $0.label == "Speaker 1" }
        XCTAssertEqual(row?.source, .suggested)
        // Confirming the suggestion puts the name in the summary.
        try await e.meetings.renameSpeaker(meetingId: m.id, label: "Speaker 1", name: row!.name, email: row!.email)
        XCTAssertEqual(try await e.meetings.get(m.id)!.1!.summary, "Jan Peeters is tevreden.")
    }
}

@Suite(.serialized) struct ProjectTests {
    static let config = ProjectConfig(projects: [
        ProjectRule(name: "Zonnehoek", accounts: ["anna@zonnehoek.be"], addresses: ["info@zonnehoek.be"], domains: ["zonnehoek.be", "panelwerk.de"]),
        ProjectRule(name: "Brightly", accounts: ["anna@getbrightly.com"], domains: ["getbrightly.com"]),
        ProjectRule(name: "Personal", accounts: ["a@example.com"]),
    ])

    func engine() async throws -> Engine {
        let e = try makeEngine(accounts: ["a@example.com", "anna@zonnehoek.be", "anna@getbrightly.com"])
        try await e.meetings.saveProjectConfig(Self.config)
        return e
    }

    func mail(_ e: Engine, account: String, from: String, to: String, n: Int) async throws {
        try await e.db.pool.write { db in
            for i in 0..<n {
                try MailMessage(accountId: account, messageId: "\(account)-\(from)-\(to)-\(i)", threadId: "t\(i)", rfcMessageId: nil, inReplyTo: nil,
                                referencesHeader: nil, fromName: "", fromEmail: from, toLine: to, ccLine: "", subject: "S", date: Date(), snippet: "",
                                bodyText: "", bodyHtml: nil, labelIds: "|INBOX|", hasListUnsubscribe: false).insert(db)
            }
        }
    }

    func classify(_ e: Engine, _ emails: [String]) async throws -> Projects.Filing {
        try await e.db.pool.read { try Projects.classify($0, config: Self.config, emails: emails) }
    }

    @Test func testGuestDomainAndInvitedAddressDecide() async throws {
        let e = try await engine()
        XCTAssertEqual(try await classify(e, ["jan@panelwerk.de", "a@example.com"]).project, "Zonnehoek", "A listed domain wins over the invited account")
        XCTAssertEqual(try await classify(e, ["piet@acme.be", "anna@getbrightly.com"]).project, "Brightly", "The account the invite went to")
        XCTAssertEqual(try await classify(e, ["info@zonnehoek.be", "piet@acme.be"]).project, "Zonnehoek", "An own alias counts as the invited address")
        let both = try await classify(e, ["jan@panelwerk.de", "x@getbrightly.com"])
        XCTAssertNil(both.project, "Two projects: unfiled rather than guess")
        XCTAssertEqual(both.source, "none")
    }

    @Test func testGenericDomainsAndNamesNeverMatch() async throws {
        let e = try await engine()
        var c = Self.config
        c.projects[0].domains.append("gmail.com")
        XCTAssertFalse(c.projects[0].cleaned.domains.contains("gmail.com"), "A generic provider is never a company domain")
        // Someone at gmail.com says nothing, and the mail history is too thin.
        XCTAssertNil(try await classify(e, ["zonnehoek.fan@gmail.com"]).project)
    }

    @Test func testMailHistoryFilesByWhereTheMailLives() async throws {
        let e = try await engine()
        try await mail(e, account: "anna@zonnehoek.be", from: "jan@acme.be", to: "anna@zonnehoek.be", n: 4)
        let f = try await classify(e, ["jan@acme.be"])
        XCTAssertEqual(f.project, "Zonnehoek")
        XCTAssertEqual(f.source, "mail")
        // Mail split between two projects is no answer.
        try await mail(e, account: "anna@getbrightly.com", from: "piet@acme.be", to: "anna@getbrightly.com", n: 4)
        XCTAssertNil(try await classify(e, ["jan@acme.be"]).project)
        // An exact address at a generic provider counts only its own mail, never "dejan@gmail.com".
        try await mail(e, account: "a@example.com", from: "a@example.com", to: "Dejan <dejan@gmail.com>", n: 5)
        XCTAssertNil(try await classify(e, ["jan@gmail.com"]).project)
        try await mail(e, account: "a@example.com", from: "jan@gmail.com", to: "a@example.com", n: 3)
        XCTAssertEqual(try await classify(e, ["jan@gmail.com"]).project, "Personal")
    }

    @Test func testAGmailHubOnlyCountsWhenNoCompanyAddressShows() async throws {
        let e = try makeEngine(accounts: ["me@gmail.com", "anna@zonnehoek.be"])
        let c = ProjectConfig(projects: [ProjectRule(name: "Personal", accounts: ["me@gmail.com"]),
                                         ProjectRule(name: "Zonnehoek", accounts: ["anna@zonnehoek.be"], addresses: ["info@zonnehoek.be"])])
        // Most mail with Tim sits in Gmail, but some of it went out as info@zonnehoek.be: that is Zonnehoek business.
        try await mail(e, account: "me@gmail.com", from: "tim@brightgrid.eu", to: "me@gmail.com", n: 10)
        try await mail(e, account: "me@gmail.com", from: "info@zonnehoek.be", to: "tim@brightgrid.eu", n: 2)
        // A friend who only ever wrote to Gmail is personal.
        try await mail(e, account: "me@gmail.com", from: "friend@corp.be", to: "me@gmail.com", n: 5)
        let read = { (emails: [String]) in try await e.db.pool.read { try Projects.classify($0, config: c, emails: emails) } }
        XCTAssertEqual(try await read(["tim@brightgrid.eu", "me@gmail.com"]).project, "Zonnehoek")
        XCTAssertEqual(try await read(["friend@corp.be", "me@gmail.com"]).project, "Personal")
        XCTAssertNil(try await read(["new@prospect.be", "me@gmail.com"]).project, "An invite to Gmail alone says nothing")
    }

    @Test func testBackfillAndOverrides() async throws {
        let e = try await engine()
        var m1 = MeetingRecord(title: "Demo", startedAt: Date(), status: .ready, source: "granola", sourceId: "1")
        m1.attendeesJSON = MeetingFixture.atts([("jan@panelwerk.de", "Jan")])
        var m2 = MeetingRecord(title: "Intern", startedAt: Date(), status: .ready, source: "granola", sourceId: "2")
        m2.attendeesJSON = MeetingFixture.atts([("x@getbrightly.com", nil)])
        try await e.meetings.save(m1)
        try await e.meetings.save(m2)
        try await e.meetings.fileMeetings(onlyNew: true)
        XCTAssertEqual(try await e.meetings.get(m1.id)!.0.project, "Zonnehoek")
        XCTAssertEqual(try await e.meetings.list(project: "brightly").map(\.id), [m2.id])

        // The user's choice holds when the rules change.
        try await e.meetings.setProject(meetingId: m1.id, project: "Personal", manual: true)
        var c = Self.config
        c.projects[0].domains = []
        try await e.meetings.saveProjectConfig(c)
        XCTAssertEqual(try await e.meetings.get(m1.id)!.0.project, "Personal")
        XCTAssertEqual(try await e.meetings.get(m1.id)!.0.projectSource, "manual")
        // Back to automatic: with no domain for panelwerk.de, the invite to the user's own Personal address decides.
        try await e.meetings.setProject(meetingId: m1.id, project: nil, manual: false)
        XCTAssertEqual(try await e.meetings.get(m1.id)!.0.project, "Personal")
        XCTAssertEqual(try await e.meetings.get(m1.id)!.0.projectSource, "rules")
        // A meeting without anyone in it stays unfiled.
        let lone = MeetingRecord(title: "Memo", startedAt: Date(), status: .ready)
        try await e.meetings.save(lone)
        try await e.meetings.fileMeetings(onlyNew: true)
        XCTAssertEqual(try await e.meetings.list(project: "unfiled").map(\.id), [lone.id])
    }

    @Test func testImportedMeetingIsFiled() async throws {
        let e = try await engine()
        try await e.meetings.importMeeting(ImportedMeeting(source: "granola", sourceId: "g9", title: "Call", startedAt: Date(), attendees: ["Jan <jan@panelwerk.de>"]))
        XCTAssertEqual(try await e.meetings.list().first?.project, "Zonnehoek")
    }

    @Test func testImportedMeetingsLinkToTheirEvent() async throws {
        let e = try await engine()
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        func event(_ id: String, _ title: String, at: TimeInterval, minutes: Double, account: String = "anna@zonnehoek.be", guests: String = "[]") throws -> CalendarEvent {
            try CalendarEvent(accountId: account, calendarId: "anna@zonnehoek.be", eventId: id, summary: title, details: "", location: "",
                              startAt: day.addingTimeInterval(at), endAt: day.addingTimeInterval(at + minutes * 60), isAllDay: false, status: "confirmed",
                              transparency: "opaque", organizerEmail: "anna@zonnehoek.be", attendeesJSON: guests, selfResponse: "accepted",
                              meetingLink: nil, htmlLink: nil, recurringEventId: nil)
        }
        let guests = String(decoding: try JSONEncoder().encode([EventAttendee(email: "jan@panelwerk.de", name: "Jan")]), as: UTF8.self)
        try await e.db.pool.write { db in
            for account in ["anna@getbrightly.com", "anna@zonnehoek.be"] {
                try CalendarRecord(accountId: account, calendarId: "anna@zonnehoek.be", summary: "Anna", colorHex: "#000", isPrimary: account == "anna@zonnehoek.be",
                                   isSelected: true, accessRole: "owner", syncToken: nil, lastFullSyncAt: nil).insert(db)
            }
            try event("demo", "Demo Panelwerk", at: 0, minutes: 30, account: "anna@getbrightly.com").insert(db)
            try event("demo", "Demo Panelwerk", at: 0, minutes: 30, guests: guests).insert(db)   // the same event seen from a second account
            try event("block", "Focus block", at: 3600, minutes: 180).insert(db)
            try event("rec", "Already recorded", at: 4 * 3600, minutes: 30).insert(db)
        }
        var recorded = MeetingRecord(title: "Already recorded", startedAt: day.addingTimeInterval(4 * 3600), status: .ready)
        recorded.eventCalendarId = "anna@zonnehoek.be"; recorded.eventId = "rec"
        try await e.meetings.save(recorded)

        let at = { (s: TimeInterval) in day.addingTimeInterval(s) }
        try await e.meetings.importMeeting(ImportedMeeting(source: "granola", sourceId: "early", title: "Quick call", startedAt: at(-130)))
        try await e.meetings.importMeeting(ImportedMeeting(source: "granola", sourceId: "demo", title: "[Zonnehoek] Demo", startedAt: at(0)))
        try await e.meetings.importMeeting(ImportedMeeting(source: "anarlog", sourceId: "adhoc", title: "Call in between", startedAt: at(5400)))
        try await e.meetings.importMeeting(ImportedMeeting(source: "anarlog", sourceId: "dup", title: "Second copy", startedAt: at(4 * 3600 + 60)))

        let all = Dictionary(uniqueKeysWithValues: try await e.meetings.list(limit: 50).map { ($0.sourceId ?? $0.id, $0) })
        XCTAssertEqual(all["demo"]?.eventId, "demo", "The meeting starting with the event gets it")
        XCTAssertEqual(all["demo"]?.attendees.map(\.email), ["jan@panelwerk.de"], "Guests come from the copy that lists them")
        XCTAssertNil(all["early"]?.eventId, "A call just before goes unlinked: the closer meeting has the event")
        XCTAssertEqual(all["early"]?.attendees.count, 0, "It no longer carries the guests of the event it held for a while")
        XCTAssertNil(all["adhoc"]?.eventId, "A call halfway through a long block is not that block")
        XCTAssertNil(all["dup"]?.eventId, "An event that already has a meeting keeps it")

        let block = try await e.db.pool.read { db in try CalendarEvent.filter(Column("eventId") == "block").fetchOne(db)! }
        XCTAssertNil(try await e.meetings.meeting(for: block), "The calendar does not show the in-between call on the block")
        let demo = try await e.db.pool.read { db in try CalendarEvent.filter(Column("eventId") == "demo").fetchOne(db)! }
        XCTAssertEqual(try await e.meetings.meeting(for: demo)?.sourceId, "demo")
    }

    @Test func testDefaultsComeFromTheAccounts() {
        let d = ProjectConfig.defaults(accounts: ["me@gmail.com", "anna@getbrightly.com", "anna@zonnehoek.be"])
        XCTAssertEqual(Set(d.names), ["Zonnehoek", "Getbrightly", "Personal"], "A company account is named after its domain")
        XCTAssertEqual(d.projects.first { $0.name == "Zonnehoek" }?.domains, ["zonnehoek.be"])
        XCTAssertEqual(d.projects.first { $0.name == "Zonnehoek" }?.addresses, [], "Aliases such as info@ are added in Settings")
        XCTAssertEqual(d.projects.first { $0.name == "Personal" }?.domains, [])
    }
}

@Suite(.serialized) struct ActionItemTests {
    func segs(_ texts: [String]) -> [TranscriptSegmentRecord] {
        texts.enumerated().map { TranscriptSegmentRecord(meetingId: "m", position: $0, startSeconds: Double($0 * 10), endSeconds: Double($0 * 10 + 9), speaker: "Me", text: $1) }
    }

    @Test func testAnchorKeepsGoodCitationsAndRepairsBadOnes() {
        let t = segs(["Goedemorgen allemaal", "Hoe gaat het met jullie", "Over de planning", "Ik stuur jullie vrijdag de offerte voor de omvormers",
                      "Prima", "Dan plannen we de installatie in week 48", "Tot dan"])
        XCTAssertEqual(TranscriptAnchor.anchor(3, text: "Offerte omvormers sturen", segments: t), 3, "A good citation stays")
        XCTAssertEqual(TranscriptAnchor.anchor(4, text: "Offerte omvormers sturen", segments: t), 3, "Off by one: the neighbour that says it")
        XCTAssertEqual(TranscriptAnchor.anchor(0, text: "Installatie plannen in week 48", segments: t), 5, "Further off: the match nearby")
        XCTAssertEqual(TranscriptAnchor.anchor(99, text: "Offerte omvormers sturen", segments: t), 3, "Not a real segment: the best match")
        XCTAssertNil(TranscriptAnchor.anchor(99, text: "Budget goedkeuren", segments: t), "Nothing in the transcript says it")
        XCTAssertEqual(TranscriptAnchor.anchor(2, text: "Budget goedkeuren", segments: t), 2, "A real citation with no better match stays")
    }

    @Test func testOldDecisionsStillRead() throws {
        var s = MeetingSummaryRecord(meetingId: "m", summary: "", decisions: ["Week 48"], actionItems: [ActionItem(task: "Bellen")], openQuestions: [], model: "granola")
        XCTAssertEqual(s.decisionItems, [DecisionItem(text: "Week 48")])
        XCTAssertNil(s.actionItems[0].status)
        s.setDecisions([DecisionItem(text: "Week 49", segment: 3)])
        XCTAssertEqual(s.decisions, ["Week 49"])
        XCTAssertEqual(s.decisionItems.first?.segment, 3)
    }

    @Test func testSummaryKeepsStatusAndCheckedSources() async throws {
        let e = try makeEngine()
        let m = try await MeetingFixture.meeting(e, guests: [("jan@acme.be", "Jan Peeters")], labels: ["Me", "Others", "Me", "Others"],
                                                 text: ["Zullen we de demo herhalen?", "Misschien, ik denk erover na.", "Ik stuur je morgen de offerte voor de batterij.", "Top, dank je."])
        try await e.meetings.assignSpeakers(meetingId: m.id)
        MockServer.reset { c in
            let body = try! JSONSerialization.jsonObject(with: c.body) as! [String: Any]
            let user = (body["messages"] as! [[String: Any]])[0]["content"] as! String
            XCTAssertTrue(user.contains("[2] Ik stuur je morgen de offerte"), "Lines carry their number")
            let reply = #"""
            {"summary":"Anna stuurt de offerte. Er werd geen beslissing genomen.","decisions":[],
             "action_items":[{"task":"Offerte batterij sturen","owner":"Anna Vermeulen","due":"morgen","status":"agreed","segment":3},
                             {"task":"Demo herhalen","owner":null,"due":null,"status":"suggested","segment":0}],
             "open_questions":[],"speakers":[]}
            """#
            return (200, ["content": [["type": "text", "text": reply]], "stop_reason": "end_turn"])
        }
        try await MeetingSummarizer(claude: ClaudeClient(session: MockServer.session) { "k" }, store: e.meetings).summarize(meetingId: m.id)
        let s = try await e.meetings.get(m.id)!.1!
        XCTAssertTrue(s.decisionItems.isEmpty, "An exploratory call has no decisions")
        XCTAssertEqual(s.actionItems[0].status, .agreed)
        XCTAssertEqual(s.actionItems[0].segment, 2, "The citation was one line off and is repaired")
        XCTAssertEqual(s.actionItems[1].status, .suggested)
        XCTAssertEqual(s.actionItems[1].segment, 0)

        // A speaker rename keeps every source.
        try await e.meetings.renameSpeaker(meetingId: m.id, label: "Me", name: "Anna")
        XCTAssertEqual(try await e.meetings.get(m.id)!.1!.actionItems[0].segment, 2)
    }

    @Test func testMCPGivesEachPointItsMoment() async throws {
        let e = try makeEngine()
        let m = try await MeetingFixture.meeting(e, guests: [("jan@acme.be", "Jan")], labels: ["Me", "Others"], text: ["Ik bel je vrijdag", "Goed"])
        var s = MeetingSummaryRecord(meetingId: m.id, summary: "Kort.", decisions: [],
                                     actionItems: [ActionItem(task: "Vrijdag bellen", status: .agreed, segment: 0)], openQuestions: [], model: "claude-haiku-5-5")
        s.setDecisions([])
        try await e.meetings.saveSummary(s)
        let server = MCPServer(tools: PostvakTools.all(engine: e, recorder: nil, ui: nil)) { "secret" }
        let body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "get_meeting", "arguments": ["meeting_id": m.id]]]
        let r = await server.handle(HTTPRequest(method: "POST", path: "/mcp", query: [:], headers: ["authorization": "Bearer secret"],
                                                body: try JSONSerialization.data(withJSONObject: body)))
        let text = ((try JSONSerialization.jsonObject(with: r.body) as! [String: Any])["result"] as! [String: Any])["content"] as! [[String: Any]]
        let out = try JSONSerialization.jsonObject(with: Data((text[0]["text"] as! String).utf8)) as! [String: Any]
        let item = (out["action_items"] as! [[String: Any]])[0]
        XCTAssertEqual(item["status"] as? String, "agreed")
        XCTAssertEqual((item["source"] as? [String: Any])?["quote"] as? String, "Ik bel je vrijdag")
        XCTAssertEqual(out["decisions_note"] as? String, "No decision taken.")
    }
}

@Suite(.serialized) struct RelatedMailTests {
    static func msg(_ e: Engine, id: String, thread: String, from: String, to: String, subject: String, daysFromMeeting: Double, meeting: Date,
                    account: String = "a@example.com") async throws {
        try await e.db.pool.write { db in
            try MailMessage(accountId: account, messageId: id, threadId: thread, rfcMessageId: "<\(id)@x>", inReplyTo: nil, referencesHeader: nil,
                            fromName: "", fromEmail: from, toLine: to, ccLine: "", subject: subject, date: meeting.addingTimeInterval(daysFromMeeting * 86400),
                            snippet: "", bodyText: "Tekst", bodyHtml: nil, labelIds: from == account ? "|SENT|" : "|INBOX|", hasListUnsubscribe: false).insert(db)
        }
    }

    @Test func testRelatedThreadsAroundTheMeeting() async throws {
        let e = try makeEngine()
        let m = try await MeetingFixture.meeting(e, guests: [("jan@acme.be", "Jan")], labels: ["Me"])
        let d = m.startedAt
        try await Self.msg(e, id: "1", thread: "offer", from: "jan@acme.be", to: "a@example.com", subject: "Offerte", daysFromMeeting: -3, meeting: d)
        try await Self.msg(e, id: "2", thread: "offer", from: "a@example.com", to: "Jan <jan@acme.be>", subject: "Re: Offerte", daysFromMeeting: -2, meeting: d)
        try await Self.msg(e, id: "3", thread: "inv", from: "jan@acme.be", to: "a@example.com", subject: "Invitation: Demo @ Mon", daysFromMeeting: -5, meeting: d)
        try await Self.msg(e, id: "4", thread: "coll", from: "piet@acme.be", to: "a@example.com", subject: "Factuur", daysFromMeeting: 1, meeting: d)
        try await Self.msg(e, id: "5", thread: "old", from: "jan@acme.be", to: "a@example.com", subject: "Lang geleden", daysFromMeeting: -60, meeting: d)
        try await Self.msg(e, id: "6", thread: "other", from: "a@example.com", to: "dejan@other.be", subject: "Iets anders", daysFromMeeting: 0, meeting: d)
        try await Self.msg(e, id: "7", thread: "ooo", from: "jan@acme.be", to: "a@example.com", subject: "Automatic reply: Invitation: Demo", daysFromMeeting: -4, meeting: d)

        let r = try await e.meetings.relatedThreads(meetingId: m.id)
        XCTAssertEqual(r.map(\.threadId), ["offer", "coll"], "Guests first, then colleagues; no invitations, nothing outside the window")
        XCTAssertEqual(r[0].sent, 1)
        XCTAssertEqual(r[0].received, 1)
        XCTAssertTrue(r[0].lastFromMe)
        XCTAssertEqual(r[0].lastMessageId, "2")
        XCTAssertEqual(r[1].guestsInThread, 0)
    }

    @Test func testAThreadInTwoAccountsShowsOnce() async throws {
        let e = try makeEngine(accounts: ["a@example.com", "b@example.org"])
        let m = try await MeetingFixture.meeting(e, guests: [("jan@acme.be", "Jan")], labels: ["Me"])
        for acct in ["a@example.com", "b@example.org"] {
            try await Self.msg(e, id: "1", thread: "t-\(acct)", from: "jan@acme.be", to: "a@example.com, b@example.org", subject: "Planning",
                               daysFromMeeting: -1, meeting: m.startedAt, account: acct)
        }
        XCTAssertEqual(try await e.meetings.relatedThreads(meetingId: m.id).count, 1)
    }

    @Test func testNoGuestsNoMail() async throws {
        let e = try makeEngine()
        let m = try await MeetingFixture.meeting(e, guests: [], labels: ["Me"])
        XCTAssertTrue(try await e.meetings.relatedThreads(meetingId: m.id).isEmpty)
    }
}

@Suite(.serialized) struct MeetingFollowUpTests {
    func t(_ id: String, guests: Int, daysAgo: Double, account: String = "a@example.com") -> RelatedThread {
        RelatedThread(accountId: account, threadId: id, subject: id, lastAt: Date().addingTimeInterval(-daysAgo * 86400), sent: 1, received: 1,
                      lastFromMe: false, guestsInThread: guests, lastMessageId: "\(id)-last")
    }

    @Test func testThreadWithMostGuestsWinsAndTiesAreAsked() {
        guard case .reply(let best) = MeetingFollowUp.target([t("a", guests: 1, daysAgo: 1), t("b", guests: 2, daysAgo: 9)]) else {
            XCTFail("One thread holds the most guests"); return
        }
        XCTAssertEqual(best.threadId, "b")
        guard case .choose(let list) = MeetingFollowUp.target([t("a", guests: 1, daysAgo: 5), t("b", guests: 1, daysAgo: 1), t("c", guests: 0, daysAgo: 0)]) else {
            XCTFail("A tie is the user's call"); return
        }
        XCTAssertEqual(list.map(\.threadId), ["b", "a"], "Newest first, colleague-only threads left out")
        XCTAssertEqual(MeetingFollowUp.target([t("c", guests: 0, daysAgo: 0)]), .new, "Colleagues only: a new mail")
        XCTAssertEqual(MeetingFollowUp.target([]), .new)
    }

    @Test func testRecipientsAndAccountForANewMail() async throws {
        let e = try makeEngine(accounts: ["a@example.com", "anna@zonnehoek.be"])
        try await e.meetings.saveProjectConfig(ProjectConfig(projects: [ProjectRule(name: "Zonnehoek", accounts: ["anna@zonnehoek.be"], domains: ["acme.be"])]))
        var m = try await MeetingFixture.meeting(e, guests: [("jan@acme.be", "Jan Peeters"), ("anna@zonnehoek.be", nil)], labels: ["Me"])
        m.attendeesJSON = String(decoding: try JSONEncoder().encode(m.attendees + [EventAttendee(email: "piet@acme.be", response: "declined")]), as: UTF8.self)
        try await e.meetings.save(m)
        try await e.meetings.fileMeetings(onlyNew: false)
        let m2 = try await e.meetings.get(m.id)!.0
        let (to, account) = try await e.db.pool.read { (try MeetingFollowUp.recipients(m2, $0), try MeetingFollowUp.account(m2, $0)) }
        XCTAssertEqual(to, ["Jan Peeters <jan@acme.be>"], "Not the user's own address, not someone who declined")
        XCTAssertEqual(account, "anna@zonnehoek.be", "The project's account")
    }

    @Test func testWriterGetsOnlyAgreedStepsInTheMeetingsLanguage() async throws {
        var m = MeetingRecord(title: "Demo", startedAt: Date(), status: .ready)
        m.language = "nl"
        var s = MeetingSummaryRecord(meetingId: m.id, summary: "Demo gegeven.", decisions: [], actionItems: [], openQuestions: [], model: "claude-haiku-5-5")
        s.setActionItems([ActionItem(task: "Offerte sturen", owner: "Anna", due: "vrijdag", status: .agreed), ActionItem(task: "Tweede demo", status: .suggested)])
        s.setDecisions([])
        MockServer.reset { c in
            let body = try! JSONSerialization.jsonObject(with: c.body) as! [String: Any]
            let user = (body["messages"] as! [[String: Any]])[0]["content"] as! String
            XCTAssertTrue(user.contains("LANGUAGE: Dutch"))
            XCTAssertTrue(user.contains("Decisions: none were taken"))
            XCTAssertTrue(user.contains("- Offerte sturen (owner: Anna) (due: vrijdag)"))
            XCTAssertTrue(user.contains("Only suggested, not agreed (mention as open at most):\n- Tweede demo"))
            XCTAssertTrue(user.contains("CC (the user's colleagues, not greeted): Piet <piet@zonnehoek.be>"))
            XCTAssertTrue(user.contains("TRANSCRIPT\n\nAnna Vermeulen: Ik stuur de offerte. \nSpeaker 1: Graag."))
            XCTAssertTrue(user.contains("- \"Speaker 1\" has no name (1 lines)"))
            XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5", "Follow-ups use Sonnet")
            XCTAssertTrue(user.contains("- Attendees not yet matched to a voice: Jan (guest), Piet (colleague in CC)"))
            XCTAssertTrue(String(decoding: c.body, as: UTF8.self).contains(#"{"_voices""#) || String(decoding: c.body, as: UTF8.self).contains(#""properties":{"_voices""#),
                          "The voices are written first")
            let parts = #"{"_voices":[],"pain_points":["Prijs"],"subject":"Opvolging demo","greeting":"Dag Jan,","thanks":"Bedankt voor de demo.","recap_heading":"Wat we bespraken:","recap":[{"side":"guests","text":"Jullie groeien snel."},{"side":"us","text":"Wij koppelen zes scanners."}],"shown":"Ik toonde de planning.","questions_heading":"Jullie vragen:","questions":[{"topic":"Prijs","answer":"Volgt vrijdag.","quote":"offerte"}],"next_steps_heading":"Volgende stappen:","next_steps":["Ik stuur je vrijdag de offerte."],"proposal":"Past een korte call volgende week?","closing":"Groeten,"}"#
            return (200, ["content": [["type": "text", "text": parts]], "stop_reason": "end_turn"])
        }
        let segs = [TranscriptSegmentRecord(meetingId: m.id, position: 0, startSeconds: 0, endSeconds: 1, speaker: "Me", text: "Ik stuur de offerte."),
                    TranscriptSegmentRecord(meetingId: m.id, position: 1, startSeconds: 1, endSeconds: 2, speaker: "Speaker 1", text: "Graag.")]
        let out = try await MeetingFollowUpWriter(claude: ClaudeClient(session: MockServer.session) { "k" })
            .write(meeting: m, summary: s, segments: segs, names: ["Me": "Anna Vermeulen"], me: "Anna",
                   recipients: ["Jan <jan@acme.be>"], cc: ["Piet <piet@zonnehoek.be>"], lastInThread: nil, samples: [])
        XCTAssertEqual(out.subject, "Opvolging demo")
        XCTAssertEqual(out.text, """
            Dag Jan,

            Bedankt voor de demo.

            Wat we bespraken:
            - Jullie groeien snel.
            - Ik toonde de planning.

            Jullie vragen:
            - Prijs: Volgt vrijdag.

            Volgende stappen:
            - Ik stuur je vrijdag de offerte.

            Past een korte call volgende week?

            Groeten,
            """, "Built in code; a fact about our own product stays out of the recap of theirs")
    }

    @Test func testTheOneUnnamedVoiceIsTheOneAttendeeWithoutAVoice() {
        let p = MeetingFollowUpWriter.people(recipients: ["David <david@lab.be>"], cc: ["Igor <igor@ours.com>"],
                                             names: ["Me": "Anna Vermeulen"], hints: ["Speaker 2": "David"],
                                             voices: ["Speaker 1": 600, "Speaker 2": 350, "Speaker 3": 5])
        XCTAssertTrue(p.contains("\"Speaker 1\" has no name (600 lines), probably Igor"), p)
        XCTAssertTrue(p.contains("\"Speaker 2\" has no name (350 lines), probably David"))
        XCTAssertFalse(p.contains("Speaker 3\" has no name (5 lines), probably"), "A voice that barely spoke is not paired")
        XCTAssertFalse(p.contains("not yet matched"))
    }

    @Test func testDetailsGivenAfterStoppingReplaceTheGuests() async throws {
        let e = try makeEngine(accounts: ["anna@zonnehoek.be"])
        let m = try await MeetingFixture.meeting(e, guests: [("anna@zonnehoek.be", nil), ("old@acme.be", "Oud")], labels: ["Me", "Speaker 1"])
        try await e.meetings.setDetails(meetingId: m.id, title: "  Demo Zonnehoek ",
                                        guests: ["Jan Peeters <JAN@acme.be>", "piet@panelwerk.be", "jan@acme.be", "geen adres"])
        let saved = try await e.meetings.get(m.id)!.0
        XCTAssertEqual(saved.title, "Demo Zonnehoek")
        XCTAssertEqual(saved.attendees.filter { !$0.isSelf }.map(\.email), ["jan@acme.be", "piet@panelwerk.be"], "Exactly the guests given, once each")
        XCTAssertEqual(saved.attendees.first { $0.email == "jan@acme.be" }?.name, "Jan Peeters")
        try await e.meetings.setDetails(meetingId: m.id, title: "", guests: [])
        XCTAssertEqual(try await e.meetings.get(m.id)!.0.title, "Demo Zonnehoek", "An empty title keeps the old one")
    }

    @Test func testColleaguesGoInCc() async throws {
        let e = try makeEngine(accounts: ["anna@zonnehoek.be"])
        let m = try await MeetingFixture.meeting(e, guests: [("jan@acme.be", "Jan Peeters"), ("anna@zonnehoek.be", nil), ("piet@zonnehoek.be", "Piet")], labels: ["Me"])
        let (to, cc) = try await e.db.pool.read { try MeetingFollowUp.addressees(m, $0) }
        XCTAssertEqual(to, ["Jan Peeters <jan@acme.be>"])
        XCTAssertEqual(cc, ["Piet <piet@zonnehoek.be>"], "Someone at the user's own company is a colleague")
    }

    @Test func testFollowUpWithoutRecordingInventsNothing() {
        let m = MeetingRecord(title: "Kennismaking Zonnehoek", startedAt: Date(), status: .ready, source: "calendar")
        let p = MeetingFollowUpWriter.prompt(meeting: m, summary: nil, invite: "Agenda: offerte panelen", me: nil,
                                             recipients: ["Jan <jan@acme.be>"], lastInThread: nil, samples: ["Dag Piet, tot morgen."])
        XCTAssertTrue(p.contains("NO RECORDING"))
        XCTAssertTrue(p.contains("Invitation: Agenda: offerte panelen"))
        XCTAssertTrue(p.contains("Dag Piet, tot morgen."))
        XCTAssertFalse(p.contains("Agreed action items"))
    }
}

@Suite(.serialized) struct PrepBriefMatchingTests {
    @Test func testGuestsMatchByExactAddress() async throws {
        let e = try makeEngine()
        let now = Date()
        try await RelatedMailTests.msg(e, id: "1", thread: "jan", from: "a@example.com", to: "Jan <jan@other.be>", subject: "Voor Jan", daysFromMeeting: -2, meeting: now)
        try await RelatedMailTests.msg(e, id: "2", thread: "dejan", from: "a@example.com", to: "Dejan <dejan@other.be>", subject: "Voor Dejan", daysFromMeeting: -1, meeting: now)
        let event = CalendarEvent(accountId: "a@example.com", calendarId: "c", eventId: "e", summary: "Call", details: "", location: "",
                                  startAt: now.addingTimeInterval(3600), endAt: now.addingTimeInterval(7200), isAllDay: false, status: "confirmed",
                                  transparency: "opaque", organizerEmail: "a@example.com", attendeesJSON: MeetingFixture.atts([("jan@other.be", "Jan")]),
                                  selfResponse: "accepted", meetingLink: nil, htmlLink: nil, recurringEventId: nil)
        let c = try await PrepBriefs(db: e.db).context(for: event, now: now)
        XCTAssertEqual(c.threads.map(\.subject), ["Voor Jan"], "Mail to dejan@other.be is not mail with jan@other.be")
    }
}

@Suite(.serialized) struct MeetingRepairTests {
    func event(_ account: String, guests: [(String, String?)]) -> CalendarEvent {
        let start = Date().addingTimeInterval(-3600)
        return CalendarEvent(accountId: account, calendarId: "anna@zonnehoek.be", eventId: "ev1", summary: "Discovery x Luchtzuiver", details: "",
                             location: "", startAt: start, endAt: start.addingTimeInterval(1800), isAllDay: false, status: "confirmed", transparency: "opaque",
                             organizerEmail: guests.isEmpty ? "" : "anna@zonnehoek.be",
                             attendeesJSON: guests.isEmpty ? "[]" : MeetingFixture.atts(guests), selfResponse: nil, meetingLink: nil, htmlLink: nil, recurringEventId: nil)
    }

    @Test func testRecordingLinksToTheCopyWithGuests() async throws {
        let e = try makeEngine(accounts: ["a@example.com", "anna@zonnehoek.be"])
        // The shared copy in the other account has no guests; the owner's copy has them.
        try await e.db.pool.write { db in
            for a in ["a@example.com", "anna@zonnehoek.be"] {
                try CalendarRecord(accountId: a, calendarId: "anna@zonnehoek.be", summary: "Zonnehoek", colorHex: "#000", isPrimary: false,
                                   isSelected: true, accessRole: a == "a@example.com" ? "reader" : "owner", syncToken: nil, lastFullSyncAt: nil).insert(db)
            }
            try event("a@example.com", guests: []).insert(db)
            try event("anna@zonnehoek.be", guests: [("simon@luchtzuiver.be", nil)]).insert(db)
        }
        var m = MeetingRecord(title: MeetingRecord.untitled, startedAt: Date().addingTimeInterval(-3500), endedAt: Date().addingTimeInterval(-1900), status: .ready)
        m.micAudioPath = "/tmp/m"; m.systemAudioPath = "/tmp/s"
        try await e.meetings.save(m)
        try await e.meetings.linkToBestEvent(meetingId: m.id)
        XCTAssertEqual(try await e.meetings.get(m.id)!.0.attendees.map(\.email).contains("simon@luchtzuiver.be"), true)
    }

    @Test func testMeetingLinkedToTheEmptyCopyIsRepairedAndNamed() async throws {
        let e = try makeEngine(accounts: ["a@example.com", "anna@zonnehoek.be"])
        try await e.db.pool.write { db in
            for a in ["a@example.com", "anna@zonnehoek.be"] {
                try CalendarRecord(accountId: a, calendarId: "anna@zonnehoek.be", summary: "Zonnehoek", colorHex: "#000", isPrimary: false,
                                   isSelected: true, accessRole: a == "a@example.com" ? "reader" : "owner", syncToken: nil, lastFullSyncAt: nil).insert(db)
            }
            try event("a@example.com", guests: []).insert(db)
            try event("anna@zonnehoek.be", guests: [("simon@luchtzuiver.be", nil)]).insert(db)
        }
        var m = try await MeetingFixture.meeting(e, guests: [], labels: ["Me", "Speaker 1", "Speaker 4", "Unknown"])
        m.attendeesJSON = "[]"; m.eventAccountId = "a@example.com"; m.eventCalendarId = "anna@zonnehoek.be"; m.eventId = "ev1"
        try await e.meetings.save(m)
        try await e.meetings.saveSummary(MeetingSummaryRecord(meetingId: m.id, summary: "Speaker 1 wil een demo.", decisions: [],
                                                              actionItems: [], openQuestions: [], model: "claude-haiku-5-5"))
        XCTAssertEqual(try await e.meetings.repairEventAttendees(), [m.id])
        try await e.meetings.assignSpeakersEverywhere()
        let names = try await e.meetings.speakerNames(meetingId: m.id)
        XCTAssertEqual(names["Speaker 4"], "simon@luchtzuiver.be", "No name in the invite or mail: the address")
        XCTAssertEqual(try await e.meetings.get(m.id)!.1!.summary, "simon@luchtzuiver.be wil een demo.")
    }

    @Test func testOlderSummariesGetSourcesByMatchingWords() async throws {
        let e = try makeEngine()
        let m = try await MeetingFixture.meeting(e, guests: [("jan@acme.be", "Jan")], labels: ["Me", "Others", "Me"],
                                                 text: ["Welkom", "Ik bezorg de offerte voor de batterijen tegen vrijdag", "Prima"])
        try await e.meetings.saveSummary(MeetingSummaryRecord(meetingId: m.id, summary: "", decisions: ["Installatie batterijen in december"],
                                                              actionItems: [ActionItem(task: "Offerte batterijen bezorgen", owner: "Jan"),
                                                                            ActionItem(task: "Budget bespreken")],
                                                              openQuestions: [], model: "claude-haiku-5-5"))
        try await e.meetings.anchorUnsourcedPoints()
        let s = try await e.meetings.get(m.id)!.1!
        XCTAssertEqual(s.actionItems[0].segment, 1)
        XCTAssertNil(s.actionItems[1].segment, "Nothing in the transcript says it, so no made-up link")
        XCTAssertNil(s.actionItems[0].status, "The status is not guessed afterwards")
    }
}

@Suite(.serialized) struct CallTrackRepairTests {
    @Test func testDetectsTheMislabelledRate() {
        XCTAssertTrue(MeetingStore.isMislabelled(callSeconds: 821.824, micSeconds: 895.879), "Luchtzuiver")
        XCTAssertTrue(MeetingStore.isMislabelled(callSeconds: 3787.4, micSeconds: 4120.9), "Groenlicht")
        XCTAssertFalse(MeetingStore.isMislabelled(callSeconds: 894.5, micSeconds: 895.9), "Already right")
        XCTAssertEqual(MeetingStore.callOffset(micSeconds: 895.9, callSeconds: 894.5), 1.4, accuracy: 0.001)
        XCTAssertEqual(MeetingStore.callOffset(micSeconds: 900, callSeconds: 820), 0, "A big gap is not a head start")
    }

    @Test func testStretchPutsTheOtherSideBackInTimeAndKeepsLinks() async throws {
        let e = try makeEngine()
        let m = try await MeetingFixture.meeting(e, guests: [("simon@luchtzuiver.be", nil)], labels: ["Me", "Me", "Me"], text: ["Hallo", "Offerte", "Dag"])
        // Stored as squeezed: the other side's lines at 0.92 of their real time, so they sort too early.
        try await e.meetings.replaceSegments(meetingId: m.id, [
            TranscriptSegmentRecord(meetingId: m.id, position: 0, startSeconds: 0, endSeconds: 5, speaker: "Me", text: "Hallo Simon"),
            TranscriptSegmentRecord(meetingId: m.id, position: 1, startSeconds: 91.875, endSeconds: 95, speaker: "Speaker 1", text: "Ik wil een offerte"),
            TranscriptSegmentRecord(meetingId: m.id, position: 2, startSeconds: 98, endSeconds: 99, speaker: "Me", text: "Die stuur ik morgen"),
        ])
        var s = MeetingSummaryRecord(meetingId: m.id, summary: "", decisions: [], actionItems: [ActionItem(task: "Offerte", segment: 1), ActionItem(task: "Sturen", segment: 2)],
                                     openQuestions: [], model: "claude-haiku-5-5")
        s.setDecisions([DecisionItem(text: "Offerte", segment: 1)])
        try await e.meetings.saveSummary(s)

        XCTAssertTrue(try await e.meetings.stretchCallTrack(meetingId: m.id, factor: 48_000 / 44_100, offset: 1))
        let segs = try await e.meetings.segments(meetingId: m.id)
        XCTAssertEqual(segs.map(\.text), ["Hallo Simon", "Die stuur ik morgen", "Ik wil een offerte"], "Back in the order it was said")
        XCTAssertEqual(segs[2].startSeconds, 101, accuracy: 0.001)
        let fixed = try await e.meetings.get(m.id)!.1!
        XCTAssertEqual(fixed.actionItems.map(\.segment), [2, 1], "Links follow their lines")
        XCTAssertEqual(fixed.decisionItems.first?.segment, 2)
        XCTAssertFalse(try await e.meetings.stretchCallTrack(meetingId: m.id, factor: 48_000 / 44_100, offset: 1), "Runs once")
    }
}

/// A track's language comes from windows across the whole recording, not its often silent first 30 seconds.
@Suite struct LanguageVoteTests {
    @Test func testWindowsSpreadOverTheWholeTrack() {
        XCTAssertEqual(LanguageVote.starts(duration: 3600, count: 7), [0, 595, 1190, 1785, 2380, 2975, 3570])
        XCTAssertEqual(LanguageVote.starts(duration: 95, count: 7), [0, 33, 65], "A short track gets as many windows as fit")
        XCTAssertEqual(LanguageVote.starts(duration: 20, count: 7), [0])
    }

    @Test func testAQuietOpeningDoesNotDecide() {
        // This morning's meeting: Whisper heard English in the near-silent opening, Dutch everywhere people spoke.
        let samples: [LanguageVote.Sample] = [.init(start: 0, language: "en", confidence: 0.62),
                                              .init(start: 564, language: "nl", confidence: 0.99),
                                              .init(start: 1128, language: "nl", confidence: 0.99)]
        XCTAssertEqual(LanguageVote.winner(samples), "nl")
        XCTAssertEqual(LanguageVote.winner([.init(start: 0, language: "fr", confidence: 0.3), .init(start: 60, language: "nl", confidence: 0.9),
                                            .init(start: 90, language: "fr", confidence: 0.8)]), "fr", "Summed confidence, not one sure window")
        XCTAssertNil(LanguageVote.winner([]))
    }

    @Test func testSilenceIsNotSpeech() {
        let silence = [Float](repeating: 0.001, count: 16000 * 30)
        #expect(LanguageVote.speechShare(silence) < LanguageVote.minSpeechShare)
        var talk = silence
        for i in 0..<(16000 * 10) { talk[i] = sin(Float(i) / 8) * 0.1 }   // ten seconds of sound in thirty
        #expect(abs(LanguageVote.speechShare(talk) - 1.0 / 3) < 0.01)
    }
}

/// Some meetings need more than a paragraph. The long summary is a choice per meeting, kept on every rewrite.
@Suite(.serialized) struct DetailedSummaryTests {
    @Test func testMoreDetailSticksToTheMeeting() async throws {
        let e = try makeEngine()
        let m = try await MeetingFixture.meeting(e, guests: [("jan@acme.be", "Jan Peeters")], labels: ["Me", "Others"],
                                                 text: ["De pilot kost 4000 euro per maand.", "Te duur, we bekijken eerst de planning."])
        var asked: [Bool] = []
        MockServer.reset { c in
            asked.append(String(decoding: c.body, as: UTF8.self).contains("Write a detailed summary"))
            let reply = #"{"summary":"Pilot besproken.","decisions":[],"action_items":[],"open_questions":[],"speakers":[]}"#
            return (200, ["content": [["type": "text", "text": reply]], "stop_reason": "end_turn"])
        }
        let s = MeetingSummarizer(claude: ClaudeClient(session: MockServer.session) { "k" }, store: e.meetings)
        try await s.summarize(meetingId: m.id)
        try await s.summarize(meetingId: m.id, detailed: true)
        XCTAssertTrue(try await e.meetings.get(m.id)!.0.detailedSummary)
        try await s.summarize(meetingId: m.id)   // Write Summary Again, or a new transcript
        try await s.summarize(meetingId: m.id, detailed: false)
        XCTAssertEqual(asked, [false, true, true, false])
        XCTAssertFalse(try await e.meetings.get(m.id)!.0.detailedSummary)
    }
}
