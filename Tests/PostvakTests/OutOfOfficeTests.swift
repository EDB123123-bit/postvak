import Foundation
import Testing
@testable import PostvakCore
@testable import PostvakMCP

@Suite(.serialized) struct OutOfOfficeTests {
    static let company = "anna@zonnehoek.be"
    static let personal = "anna.vermeulen@gmail.com"

    /// A Gmail holding one vacation setting (every account's URL is users/me) that keeps what it was last given.
    final class Store: @unchecked Sendable { var vacation: [String: Any] = [:] }

    func setUp(_ initial: [String: Any] = ["enableAutoReply": false]) throws -> (Engine, Store) {
        let e = try makeEngine(accounts: [Self.company, Self.personal])
        let store = Store()
        store.vacation = initial
        MockServer.reset { c in
            if let b = baseAnswer(c) { return b }
            guard c.path.hasSuffix("/settings/vacation") else { return (404, ["error": ["message": "unhandled \(c.path)"]]) }
            if c.method == "PUT" { store.vacation = (try? JSONSerialization.jsonObject(with: c.body) as? [String: Any]) ?? [:] }
            return (200, store.vacation)
        }
        return (e, store)
    }

    @Test func testReadsGmailsSetting() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000), end = start.addingTimeInterval(7 * 86400)
        let (e, _) = try setUp(["enableAutoReply": true, "responseSubject": "Away", "responseBodyHtml": "<p>Back <b>Monday</b>.</p>",
                                "restrictToContacts": true, "startTime": String(Int64(start.timeIntervalSince1970 * 1000)),
                                "endTime": String(Int64(end.timeIntervalSince1970 * 1000))])
        let o = try await e.mail.outOfOffice(accountId: Self.company)
        XCTAssertTrue(o.enabled)
        XCTAssertEqual(o.subject, "Away")
        XCTAssertEqual(o.message, GmailParser.htmlToText("<p>Back <b>Monday</b>.</p>"), "Only HTML set in Gmail web: the text comes from it")
        XCTAssertTrue(o.contactsOnly)
        XCTAssertEqual(o.start, start)
        XCTAssertEqual(o.end, end)
        XCTAssertEqual(e.mail.cachedOutOfOffice(accountId: Self.company), o, "Kept on the Mac for showing at launch")
    }

    @Test func testSavesToGmail() async throws {
        let (e, _) = try setUp()
        var o = OutOfOffice(enabled: true, subject: "Out of office", message: "Away <until> Monday & then back.\nCall Jo.",
                            contactsOnly: false, domainOnly: true)
        let cal = Calendar.current
        let first = cal.date(from: DateComponents(year: 2026, month: 12, day: 21))!, last = cal.date(from: DateComponents(year: 2026, month: 12, day: 31))!
        o.setDays(first: first, last: last)
        let saved = try await e.mail.setOutOfOffice(accountId: Self.company, o)

        let put = MockServer.recorded("/settings/vacation", method: "PUT")
        XCTAssertEqual(put.count, 1)
        let body = try JSONSerialization.jsonObject(with: put[0].body) as! [String: Any]
        XCTAssertEqual(body["enableAutoReply"] as? Bool, true)
        XCTAssertEqual(body["responseBodyPlainText"] as? String, "Away <until> Monday & then back.\nCall Jo.")
        XCTAssertEqual(body["responseBodyHtml"] as? String, "Away &lt;until&gt; Monday &amp; then back.<br>Call Jo.")
        XCTAssertEqual(body["restrictToDomain"] as? Bool, true)
        XCTAssertEqual(body["startTime"] as? String, String(Int64(first.timeIntervalSince1970 * 1000)))
        let midnightAfter = cal.date(byAdding: .day, value: 1, to: last)!
        XCTAssertEqual(body["endTime"] as? String, String(Int64(midnightAfter.timeIntervalSince1970 * 1000)), "The last day is included")
        XCTAssertEqual(saved.lastDay(), last)
        XCTAssertEqual(e.mail.cachedOutOfOffice(accountId: Self.company)?.enabled, true)
    }

    @Test func testFreeGmailNeverLimitsToItsDomain() async throws {
        let (e, _) = try setUp()
        try await e.mail.setOutOfOffice(accountId: Self.personal, OutOfOffice(enabled: true, subject: "Away", message: "Away.", domainOnly: true))
        let body = try JSONSerialization.jsonObject(with: MockServer.recorded("/settings/vacation", method: "PUT")[0].body) as! [String: Any]
        XCTAssertEqual(body["restrictToDomain"] as? Bool, false, "Gmail refuses a domain limit on a gmail.com address")
        XCTAssertFalse(OutOfOffice.supportsDomainOnly(Self.personal))
        XCTAssertTrue(OutOfOffice.supportsDomainOnly(Self.company))
    }

    @Test func testUnchangedTextKeepsGmailsFormatting() async throws {
        let html = "<div>Back <b>Monday</b></div>"
        var o = OutOfOffice(enabled: true, subject: "Away", message: GmailParser.htmlToText(html), html: html)
        XCTAssertEqual(VacationDTO(o, accountId: Self.company).responseBodyHtml, html)
        o.message += " Thanks."
        XCTAssertEqual(VacationDTO(o, accountId: Self.company).responseBodyHtml, OutOfOffice.html(fromText: o.message), "Edited text replaces the old HTML")
    }

    @Test func testRefusesAnEmptyReplyOrBackwardDates() async throws {
        let (e, _) = try setUp()
        await #expect(throws: (any Error).self) {
            try await e.mail.setOutOfOffice(accountId: Self.company, OutOfOffice(enabled: true, subject: "Away", message: "  "))
        }
        var o = OutOfOffice(enabled: true, subject: "Away", message: "Away.")
        o.start = Date(); o.end = Date().addingTimeInterval(-86400)
        await #expect(throws: (any Error).self) { try await e.mail.setOutOfOffice(accountId: Self.company, o) }
        XCTAssertTrue(MockServer.recorded("/settings/vacation", method: "PUT").isEmpty, "Nothing reaches Gmail")
        // Turning off never needs a message.
        try await e.mail.setOutOfOffice(accountId: Self.company, OutOfOffice(enabled: false))
    }

    @Test func testTurnOffKeepsTextAndDates() async throws {
        let (e, _) = try setUp(["enableAutoReply": true, "responseSubject": "Away", "responseBodyPlainText": "Back Monday.", "endTime": "1900000000000"])
        let off = try await e.mail.turnOffOutOfOffice(accountId: Self.company)
        XCTAssertFalse(off.enabled)
        XCTAssertEqual(off.message, "Back Monday.")
        XCTAssertEqual(off.end, Date(timeIntervalSince1970: 1_900_000_000))
    }

    @Test func testStateAndStatus() {
        let now = Date()
        let cal = Calendar.current
        var o = OutOfOffice(enabled: false, message: "x")
        XCTAssertEqual(o.state(now: now), .off)
        XCTAssertEqual(o.statusText(now: now), "Off")
        o.enabled = true
        XCTAssertEqual(o.state(now: now), .on)
        XCTAssertEqual(o.statusText(now: now), "On, until you turn it off")
        o.setDays(first: cal.date(byAdding: .day, value: 2, to: now), last: cal.date(byAdding: .day, value: 4, to: now))
        XCTAssertEqual(o.state(now: now), .scheduled)
        XCTAssertFalse(o.isActive(now: now))
        XCTAssertTrue(o.statusText(now: now).hasPrefix("From "))
        XCTAssertTrue(o.isActive(now: cal.date(byAdding: .day, value: 3, to: now)!))
        o.setDays(first: nil, last: cal.date(byAdding: .day, value: -1, to: now))
        XCTAssertEqual(o.state(now: now), .ended)
        // The whole last day counts: still on at 23:00 on it.
        o.setDays(first: nil, last: now)
        XCTAssertTrue(o.isActive(now: cal.date(bySettingHour: 23, minute: 0, second: 0, of: now)!))
    }

    @Test func testMCPChangesOnlyWhatItIsGiven() async throws {
        let (e, _) = try setUp(["enableAutoReply": false, "responseSubject": "Away", "responseBodyPlainText": "Back soon.", "restrictToContacts": true])
        let s = MCPServer(tools: PostvakTools.all(engine: e, recorder: nil, ui: nil)) { "secret" }
        let req = HTTPRequest(method: "POST", path: "/mcp", query: [:], headers: ["authorization": "Bearer secret"],
                              body: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                                                 "params": ["name": "set_out_of_office",
                                                                                            "arguments": ["account": Self.company, "enabled": true,
                                                                                                          "first_day": "2026-12-21", "last_day": "2026-12-31"]]]))
        let r = await s.handle(req)
        let result = (try JSONSerialization.jsonObject(with: r.body) as! [String: Any])["result"] as! [String: Any]
        let text = (result["content"] as! [[String: Any]])[0]["text"] as! String
        XCTAssertEqual(result["isError"] as? Bool, false, text)
        let body = try JSONSerialization.jsonObject(with: MockServer.recorded("/settings/vacation", method: "PUT")[0].body) as! [String: Any]
        XCTAssertEqual(body["enableAutoReply"] as? Bool, true)
        XCTAssertEqual(body["responseSubject"] as? String, "Away", "Left out: kept")
        XCTAssertEqual(body["responseBodyPlainText"] as? String, "Back soon.")
        XCTAssertEqual(body["restrictToContacts"] as? Bool, true)
        let out = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        XCTAssertEqual((out["now"] as? [String: Any])?["last_day"] as? String, "2026-12-31")
        XCTAssertEqual((out["previous"] as? [String: Any])?["enabled"] as? Bool, false)
    }
}
