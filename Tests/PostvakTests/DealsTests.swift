import Foundation
import Testing
import GRDB
@testable import PostvakCore
@testable import PostvakAI

@Suite(.serialized) struct DealsTests {
    func store(_ e: Engine, _ thread: String, _ messages: [[String: Any]]) async throws {
        let dto = try JSONDecoder().decode(GmailThreadDTO.self, from: JSONSerialization.data(withJSONObject: ["id": thread, "messages": messages]))
        try await GmailSync.store(db: e.db, accountId: "ann@solarco.be", dto: dto)
    }

    /// Ann sells for solarco.be. Jan at acme.be writes and gets an answer, Bob at other.be writes without one,
    /// Koen is a colleague, Ann also writes from an old Hotmail address, and a meeting with beta.be is booked.
    func seededEngine() async throws -> Engine {
        let e = try makeEngine(accounts: ["ann@solarco.be"])
        try await e.db.pool.write { db in
            try db.execute(sql: "UPDATE account SET displayName = 'Ann Smith'")
            try CalendarRecord(accountId: "ann@solarco.be", calendarId: "ann@solarco.be", summary: "Ann", colorHex: "#000", isPrimary: true,
                               isSelected: true, accessRole: "owner", syncToken: nil, lastFullSyncAt: nil).insert(db)
            let atts = [EventAttendee(email: "ann@solarco.be", isSelf: true), EventAttendee(email: "lead@beta.be", name: "Lea")]
            let json = String(decoding: try JSONEncoder().encode(atts), as: UTF8.self)
            let start = Date().addingTimeInterval(3 * 86400)
            try CalendarEvent(accountId: "ann@solarco.be", calendarId: "ann@solarco.be", eventId: "ev1", summary: "Demo for Beta", details: "",
                              location: "", startAt: start, endAt: start.addingTimeInterval(1800), isAllDay: false, status: "confirmed",
                              transparency: "opaque", organizerEmail: "ann@solarco.be", attendeesJSON: json, selfResponse: "accepted",
                              meetingLink: nil, htmlLink: nil, recurringEventId: nil).insert(db)
        }
        try await store(e, "t1", [
            gmailMessage(id: "m1", thread: "t1", from: "Jan <jan@acme.be>", to: "ann@solarco.be", subject: "Offerte",
                         body: "Dag Ann, kan je de offerte voor 40 panelen sturen?", labels: ["INBOX", "CATEGORY_PERSONAL"], hoursAgo: 48),
            gmailMessage(id: "m2", thread: "t1", from: "Ann Smith <ann@solarco.be>", to: "jan@acme.be", subject: "Re: Offerte",
                         body: "Dag Jan, hierbij: €2.400 voor de installatie.", labels: ["SENT"], hoursAgo: 40),
        ])
        try await store(e, "t2", [gmailMessage(id: "m3", thread: "t2", from: "Bob <bob@other.be>", to: "ann@solarco.be", subject: "Hallo",
                                               body: "Even hallo.", labels: ["INBOX", "CATEGORY_PERSONAL"], hoursAgo: 30)])
        try await store(e, "t3", [
            gmailMessage(id: "m4", thread: "t3", from: "Koen Willems <koen@solarco.be>", to: "ann@solarco.be", subject: "Planning",
                         body: "Zullen we morgen bellen?", labels: ["INBOX", "CATEGORY_PERSONAL"], hoursAgo: 20),
            gmailMessage(id: "m5", thread: "t3", from: "Ann Smith <ann@solarco.be>", to: "koen@solarco.be", subject: "Re: Planning",
                         body: "Ja, om 9u.", labels: ["SENT"], hoursAgo: 19),
        ])
        try await store(e, "t4", [gmailMessage(id: "m6", thread: "t4", from: "Smith, Ann <ann.old@hotmail.com>", to: "jan@acme.be",
                                               subject: "Nog iets", body: "Vanaf mijn oude adres.", labels: ["INBOX"], hoursAgo: 10)])
        return e
    }

    @Test func testCandidatesNeedTwoWayContactOrAMeeting() async throws {
        let e = try await seededEngine()
        let (identity, list) = try await Deals(db: e.db).candidates()
        let keys = Set(list.map(\.key))
        XCTAssertTrue(keys.contains("acme.be"), "Mail both ways")
        XCTAssertTrue(keys.contains("beta.be"), "A booked meeting is enough")
        XCTAssertFalse(keys.contains("other.be"), "Mail one way only")
        XCTAssertFalse(keys.contains("solarco.be"), "Colleagues are not deals")
        XCTAssertTrue(identity.isMe("ann.old@hotmail.com"), "An address writing under the user's own name is the user")
        let acme = list.first { $0.key == "acme.be" }
        XCTAssertEqual(acme?.mailsIn, 1)
        XCTAssertEqual(acme?.mailsOut, 2, "The reply and the mail from the old address both count as the user's")
        XCTAssertEqual(list.first { $0.key == "beta.be" }?.meetingsBooked, 1)
        XCTAssertEqual(acme?.latestThread, "ann@solarco.be/t4")
    }

    @Test func testKeysUseTheCompanyDomainExceptAtPersonalProviders() {
        XCTAssertEqual(Deals.key(for: "Jan@Acme.be"), "acme.be")
        XCTAssertEqual(Deals.key(for: "loran@gmail.com"), "loran@gmail.com")
        XCTAssertTrue(Deals.isAutomaticSubject("Accepted: Demo Zonnehoek @ Tue"))
        XCTAssertTrue(Deals.isAutomaticSubject("Geaccepteerd: Onboarding"))
        XCTAssertFalse(Deals.isAutomaticSubject("Re: Offerte"))
        XCTAssertFalse(Deals.isRobot("info@nulstroom.be"), "Small companies write from info@")
        XCTAssertTrue(Deals.isRobot("noreply@shop.be"))
    }

    @Test func testVentureNamesAreMergedAcrossBatches() {
        let map = Deals.canonicalVentures(["Zonnehoek": 12, "zonnehoek.be": 12, "Getbrightly": 3, "Brightly": 1, "gmail.com": 1, "Unclear": 2, "Notaflow": 1])
        XCTAssertEqual(map["zonnehoek.be"], "Zonnehoek")
        XCTAssertEqual(map["Zonnehoek"], "Zonnehoek")
        XCTAssertEqual(map["Getbrightly"], "Brightly", "The brand inside a domain like getbrightly.com")
        XCTAssertEqual(map["gmail.com"], "Unclear", "A personal provider is no venture")
        XCTAssertEqual(map["Notaflow"], "Notaflow")
    }

    @Test func testNewTextDropsTheQuotedThread() {
        XCTAssertEqual(Deals.newText("Dag Anna,\nPrima.\n\nVan: Jan\nVerzonden: maandag\nOnderwerp: Offerte"), "Dag Anna,\nPrima.")
        XCTAssertEqual(Deals.newText("Akkoord.\n________________________________\nFrom: Jan"), "Akkoord.")
        XCTAssertEqual(Deals.newText("Top!\n\nOp 3 nov. 2026 om 10:00 schreef Jan <jan@acme.be>:\n> oud"), "Top!")
        XCTAssertEqual(Deals.newText("From: the start of a forwarded note"), "From: the start of a forwarded note", "A header on the first line is the text itself")
    }

    @Test func testContactsKeepOnlyPeopleSeenAtTheCompany() {
        let people = ["Stig Verhoeven <stig.v@dealflow.be>", "Wim Claes <wim.c@dealflow.be>"]
        XCTAssertEqual(Deals.groundedContacts("Stig Verhoeven, Managing Director; Wim Claes, Managing Director; Mathijs De Maeyer", people: people),
                       "Stig Verhoeven, Managing Director; Wim Claes, Managing Director")
        XCTAssertEqual(Deals.groundedContacts("Mathijs De Maeyer", people: people), "", "A shared particle like De is no match")
        XCTAssertEqual(Deals.groundedContacts("Stig", people: ["stig.v@dealflow.be"]), "Stig", "An address alone still names the person")
        XCTAssertEqual(Deals.groundedContacts("Anna Vermeulen", people: []), "Anna Vermeulen", "Nothing to check against keeps it")
        XCTAssertEqual(Deals.groundedContacts("Anthony Lambert, installer", people: ["info@warmtewerk.com"],
                                              companyText: "Groeten,\n-- \nAnthony Marechal\nZaakvoerder"), "Anthony Lambert, installer",
                       "Someone signing mail from info@ works there")
        XCTAssertEqual(Deals.groundedContacts("Bram Vandenberg", people: ["bramvandenberg@outlook.com"]), "Bram Vandenberg")
        XCTAssertEqual(Deals.groundedContacts("Sven", people: ["info@tandpraktijk.be"], companyText: "Sven"), "Sven")
        XCTAssertEqual(Deals.greetedName("\nDag Sven,\n\nHierbij de nieuwe datum."), "Sven")
        XCTAssertEqual(Deals.greetedName("Hey,\nIk ben in contact met Mathijs De Maeyer."), nil, "A name further down is only mentioned")
        XCTAssertEqual(Deals.newText("Groeten,\n-- \nAnthony\n> oud", keepSignature: true), "Groeten,\n-- \nAnthony")
    }

    @Test func testImportanceRanksStageSizeAndAmount() {
        func deal(_ stage: DealRecord.Stage, size: String = "unknown", eur: Double = 0, risk: String = "") -> DealRecord {
            DealRecord(key: UUID().uuidString, isDeal: true, venture: "V", company: "C", contacts: "", stage: stage, risk: risk, nextStep: "",
                       owner: .none, due: "", amount: "", amountEUR: eur, size: size, sizeSource: "", latestThread: nil, activityKey: "", analyzedAt: Date())
        }
        XCTAssertTrue(deal(.proposal, size: "large", eur: 4000).importance > deal(.closing, size: "small").importance)
        XCTAssertTrue(deal(.closing).importance > deal(.proposal).importance)
        XCTAssertTrue(deal(.customer, risk: "Cancelling").importance > deal(.customer).importance)
        XCTAssertTrue(deal(.contacted).importance > deal(.lost).importance)
    }

    @Test func testTimelineMarksMailMeetingsAndBookings() async throws {
        let e = try await seededEngine()
        let now = Date()
        let marks = try await Deals(db: e.db).marks(for: ["acme.be", "beta.be"], from: now.addingTimeInterval(-10 * 86400), to: now.addingTimeInterval(10 * 86400))
        XCTAssertEqual(marks["acme.be"]?.map(\.kind), [.mailIn, .mailOut, .mailOut])
        XCTAssertEqual(marks["beta.be"]?.map(\.kind), [.booked])
    }

    @Test func testFirstMailsAreGroupedBySubjectAndCountReplies() async throws {
        let e = try makeEngine(accounts: ["ann@solarco.be"])
        var msgs: [[String: Any]] = []
        for (i, who) in ["a@one.be", "b@two.be", "c@three.be"].enumerated() {
            msgs.append(gmailMessage(id: "o\(i)", thread: "c\(i)", from: "Ann <ann@solarco.be>", to: who, subject: "Lagere kost per verkoop",
                                     body: "Dag,", labels: ["SENT"], hoursAgo: 24 * 20))
        }
        msgs.append(gmailMessage(id: "r0", thread: "c0", from: "A <a@one.be>", to: "ann@solarco.be", subject: "Re: Lagere kost per verkoop",
                                 body: "Interessant!", labels: ["INBOX", "CATEGORY_PERSONAL"], hoursAgo: 24 * 18))
        msgs.append(gmailMessage(id: "o9", thread: "c9", from: "Ann <ann@solarco.be>", to: "solo@four.be", subject: "Kennismaking",
                                 body: "Dag,", labels: ["SENT"], hoursAgo: 24 * 15))
        // A stored thread replaces its earlier copy, so each thread goes in once with all its messages.
        for (thread, group) in Dictionary(grouping: msgs, by: { $0["threadId"] as! String }) {
            try await store(e, thread, group)
        }
        let r = try await Deals(db: e.db).firstMailReplies()
        XCTAssertEqual(r.total.sent, 4)
        XCTAssertEqual(r.total.replied, 1)
        XCTAssertEqual(r.groups.first, Deals.FirstMailGroup(subject: "Lagere kost per verkoop", sent: 3, replied: 1))
        XCTAssertEqual(r.groups.last, Deals.FirstMailGroup(subject: "One-to-one first mails", sent: 1, replied: 0))
    }

    func claudeBody(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "stop_reason": "end_turn"]
    }

    @Test func testAnalyzerStoresDealsAndReadsOnlyWhatChanged() async throws {
        let e = try await seededEngine()
        let answer = """
        {"deals":[
         {"key":"acme.be","is_deal":true,"venture":"SolarCo","company":"Acme","contacts":"Jan, buyer; Mathijs De Maeyer, B2B lead","stage":"proposal","risk":"","next_step":"Jan to react to the €2,400 offer","owner":"them","due":"","amount":"€2,400 installation","amount_eur":2400,"size":"unknown","size_source":""},
         {"key":"beta.be","is_deal":true,"venture":"SolarCo","company":"Beta","contacts":"Lea","stage":"contacted","risk":"","next_step":"Demo for Beta","owner":"meeting","due":"In 3 days","amount":"","amount_eur":0,"size":"large","size_source":"general knowledge"},
         {"key":"stranger.be","is_deal":true,"venture":"X","company":"Not asked","contacts":"","stage":"lost","risk":"","next_step":"","owner":"none","due":"","amount":"","amount_eur":0,"size":"unknown","size_source":""}
        ]}
        """
        MockServer.reset { _ in (200, self.claudeBody(answer)) }
        let deals = Deals(db: e.db)
        let analyzer = DealAnalyzer(deals: deals, claude: ClaudeClient(session: MockServer.session) { "k" }, db: e.db)
        XCTAssertTrue(analyzer.isDue())
        let read = try await analyzer.run()
        XCTAssertEqual(read, 2, "Keys Claude was not asked about are ignored")
        let saved = try await deals.all().sorted { $0.key < $1.key }
        XCTAssertEqual(saved.map(\.key), ["acme.be", "beta.be"])
        XCTAssertEqual(saved.first?.stage, .proposal)
        XCTAssertEqual(saved.first?.amountEUR, 2400)
        XCTAssertEqual(saved.first?.latestThread, "ann@solarco.be/t4")
        XCTAssertEqual(saved.first?.contacts, "Jan, buyer", "Someone a mail only mentions is not a contact there")
        XCTAssertEqual(saved.last?.contacts, "Lea", "Invite guests count as people at the company")
        XCTAssertEqual(saved.last?.owner, .meeting)

        let body = try JSONSerialization.jsonObject(with: MockServer.recorded("/v1/messages")[0].body) as! [String: Any]
        let user = ((body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        XCTAssertTrue(user.contains("offerte voor 40 panelen"), "Mail text goes to Claude")
        XCTAssertTrue(user.contains("The user wrote from:"), "The address the user wrote from hints at the venture")
        XCTAssertTrue(user.contains("People at this company: Jan <jan@acme.be>\n"), "Claude gets the people who really work there, never the user")
        XCTAssertTrue(user.contains("People at this company: Lea <lead@beta.be>"))
        XCTAssertFalse(analyzer.isDue(), "Just ran")

        // Nothing new: nothing is read again.
        XCTAssertEqual(try await analyzer.run(), 0)
        XCTAssertEqual(MockServer.recorded("/v1/messages").count, 1)
        // A forced run reads everything again.
        XCTAssertEqual(try await analyzer.run(force: true), 2)
        XCTAssertEqual(MockServer.recorded("/v1/messages").count, 2)
        // Switched off in Settings: no reading at all.
        try e.db.setSetting("ai.deals", "0")
        XCTAssertEqual(try await analyzer.run(force: true), 0)
        XCTAssertEqual(MockServer.recorded("/v1/messages").count, 2)
    }
}
