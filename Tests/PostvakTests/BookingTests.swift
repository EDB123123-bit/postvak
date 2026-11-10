import Foundation
import Testing
@testable import PostvakCore

@Suite(.serialized) struct BookingTests {
    let brussels = TimeZone(identifier: "Europe/Brussels")!
    let meet = CalEventType(id: 1, username: "ed", slug: "demo", title: "Demo <B2C>", minutes: 30, video: "Google Meet")

    @Test func testCalLinkParsing() {
        XCTAssertEqual(CalLink("https://cal.com/ed/demo")?.username, "ed")
        XCTAssertEqual(CalLink("cal.com/ed/demo?month=2026-11")?.slug, "demo")
        XCTAssertEqual(CalLink("cal.com/ed")?.slug, nil)
        XCTAssertEqual(CalLink("ed-123")?.username, "ed-123")
        XCTAssertEqual(CalLink(" https://cal.com/ed ")?.profileURL.absoluteString, "https://cal.com/ed")
        XCTAssertNil(CalLink("https://calendly.com/ed"))
        XCTAssertNil(CalLink("https://cal.com/team/acme/demo"))
        XCTAssertNil(CalLink(""))
    }

    @Test func testReadsMeetingTypesAndNextFreeTimes() async throws {
        MockServer.reset { c in
            if c.path.hasSuffix("/v2/event-types") {
                XCTAssertEqual(c.headers["cal-api-version"], "2024-06-14")
                XCTAssertEqual(c.query["username"], "ed")
                return (200, ["status": "success", "data": [
                    ["id": 1, "slug": "demo", "title": "Demo", "lengthInMinutes": 30, "locations": [["type": "integration", "integration": "google-meet"]]],
                    ["id": 2, "slug": "flex", "title": "Flex", "lengthInMinutes": 45, "locations": [["type": "integration", "integration": "cal-video"]]],
                    ["id": 3, "slug": "secret", "title": "Hidden", "lengthInMinutes": 15, "hidden": true],
                ]])
            }
            if c.path.hasSuffix("/v2/slots") {
                XCTAssertEqual(c.headers["cal-api-version"], "2024-09-04")
                XCTAssertEqual(c.query["eventTypeSlug"], "demo")
                XCTAssertEqual(c.query["timeZone"], "Europe/Brussels")
                let day = { (d: String, hours: [Int]) in hours.map { ["start": String(format: "%@T%02d:00:00.000+01:00", d, $0)] } }
                return (200, ["status": "success", "data": [
                    "2026-11-06": day("2026-11-06", [8, 12, 15]),
                    "2026-11-09": day("2026-11-09", [9, 10, 11, 12, 13, 14, 15, 16]),
                    "2026-11-10": day("2026-11-10", [9]),
                    "2026-11-11": day("2026-11-11", [9]),
                ]])
            }
            return (404, [:])
        }
        let client = CalComClient(session: MockServer.session)
        let types = try await client.eventTypes(username: "ed")
        XCTAssertEqual(types.map(\.slug), ["demo", "flex"], "Hidden types stay off the menu")
        XCTAssertEqual(types.map(\.video), ["Google Meet", "Cal Video"])
        // 10:00 Brussels on 6 November: the 08:00 slot has passed.
        let now = ISO8601DateFormatter().date(from: "2026-11-06T09:00:00Z")!
        let card = try await client.card(for: types[0], language: .nl, timeZone: brussels, now: now)
        XCTAssertEqual(card.days.map(\.day), ["2026-11-06", "2026-11-09", "2026-11-10"], "Three days at most")
        XCTAssertEqual(card.days[0].slots.count, 2)
        XCTAssertEqual(card.days[1].slots.count, 5, "Five times a day at most, one row in the card")
    }

    @Test func testCalComErrorsReadClearly() async throws {
        MockServer.reset { _ in (503, ["error": "down"]) }
        do {
            _ = try await CalComClient(session: MockServer.session).eventTypes(username: "ed")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("503"))
        }
    }

    @Test func testCardLinksOpenTheChosenTime() throws {
        let slot = ISO8601DateFormatter().date(from: "2026-11-10T08:00:00Z")!
        let url = BookingCardRenderer.slotURL(meet, slot: slot, timeZone: brussels)
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertTrue(url.absoluteString.hasPrefix("https://cal.com/ed/demo?"))
        XCTAssertEqual(q["slot"], "2026-11-10T08:00:00.000Z")
        XCTAssertEqual(q["date"], "2026-11-10")
        XCTAssertEqual(q["month"], "2026-11")
        XCTAssertEqual(q["duration"], "30")
        XCTAssertEqual(q["cal.tz"], "Europe/Brussels")

        let card = BookingCard(event: meet, days: [BookingDay(day: "2026-11-10", slots: [slot])], timeZone: brussels, language: .nl)
        let html = BookingCardRenderer.html(card)
        XCTAssertTrue(html.contains("Demo &lt;B2C&gt;"), "The title is escaped")
        XCTAssertTrue(html.contains("30 minuten"))
        XCTAssertTrue(html.contains("Videogesprek via Google Meet"))
        XCTAssertTrue(html.contains("Dinsdag 10 november"))
        XCTAssertTrue(html.contains(">09:00</a>"), "Times are shown in Brussels time")
        XCTAssertTrue(html.contains("slot=2026-11-10T08:00:00.000Z"))
        XCTAssertTrue(html.contains("href=\"https://cal.com/ed/demo\""))
        XCTAssertTrue(html.contains("Alle beschikbare momenten"))
        XCTAssertEqual(BookingCardRenderer.text(card), "Demo <B2C> (30 minuten)\nKies een moment: https://cal.com/ed/demo")

        let empty = BookingCard(event: meet, days: [], timeZone: brussels, language: .en)
        let e = BookingCardRenderer.html(empty)
        XCTAssertFalse(e.contains("slot="))
        XCTAssertTrue(e.contains(">Pick a time</a>"), "Without free times the button is the only way in")
    }

    @Test func testCardSitsBeforeSignatureAndSurvivesReopening() async throws {
        let e = try makeEngine()
        try e.db.setSetting("signature.a@example.com", "<b>Anna</b>")
        let card = BookingCard(event: meet, days: [BookingDay(day: "2026-11-10", slots: [Date(timeIntervalSince1970: 1_794_297_600)])],
                               timeZone: brussels, language: .nl)
        let insert = BookingCardRenderer.insert(card)
        var i = ComposeInput(accountId: "a@example.com", to: ["b@x.be"], subject: "Demo", text: "Dag Bert,\n\nPlan gerust een moment.")
        i.booking = insert
        let mail = try await e.mail.prepare(i)
        let html = mail.htmlBody!
        let cardAt = html.range(of: "Videogesprek via Google Meet")!.lowerBound
        XCTAssertTrue(html.range(of: "Plan gerust")!.lowerBound < cardAt)
        XCTAssertTrue(cardAt < html.range(of: "gmail_signature")!.lowerBound)
        XCTAssertTrue(mail.textBody.contains("Kies een moment: https://cal.com/ed/demo\n\n-- \n"))

        let back = try await e.mail.editable(mail)
        XCTAssertEqual(back.text, "Dag Bert,\n\nPlan gerust een moment.", "No second copy of the card's text")
        XCTAssertEqual(back.booking, insert)
    }
}
