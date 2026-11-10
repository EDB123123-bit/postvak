import Foundation
import Testing
import GRDB
@testable import PostvakCore
@testable import PostvakAI

/// Notes and done steps on deals, and the Supabase CRM they sync with. Fictional names only.
extension DealsTests {
    static let crmURL = "https://crm-test.supabase.co"

    func crm(_ e: Engine) throws -> SupabaseCRM {
        let c = SupabaseCRM(db: e.db, secrets: e.secrets, session: MockServer.session)
        try c.setConfig(.init(name: "Brightly CRM", url: Self.crmURL, key: "anon-key"))
        return c
    }

    /// A Supabase project with one lost lead at acme.be, one open lead at beta.be and a lead nobody mails.
    func crmServer(_ c: MockServer.Call) -> (Int, Any) {
        if c.path.hasSuffix("/auth/v1/token") {
            return (200, ["access_token": "jwt", "refresh_token": "r2", "expires_in": 3600, "user": ["id": "u1", "email": "anna@brightly.example"]])
        }
        if c.path.hasSuffix("/rest/v1/leads"), c.method == "GET" {
            return (200, [
                ["id": "L1", "user_id": "u1", "company_name": "Acme", "email": "jan@acme.be", "website": "", "stage": "Closed Lost", "project": "brightly", "last_activity_at": "2026-10-06T05:00:00Z"],
                ["id": "L2", "user_id": "u1", "company_name": "Beta", "email": "", "website": "www.beta.be", "stage": "Meeting Scheduled", "project": "brightly", "last_activity_at": "2026-11-01T05:00:00Z"],
                ["id": "L3", "user_id": "u1", "company_name": "Gamma", "email": "x@gamma.be", "website": nil as String? as Any, "stage": "New Lead", "project": "brightly", "last_activity_at": nil as String? as Any],
            ])
        }
        if c.path.hasSuffix("/rest/v1/activities"), c.method == "GET" {
            return (200, [
                ["lead_id": "L1", "date": "2026-10-06T05:22:00Z", "subject": "Note Oct 6", "notes": "They built it themselves"],
                ["lead_id": "L1", "date": "2026-10-07T05:22:00Z", "subject": SupabaseCRM.noteSubject, "notes": "Pushed by Postvak earlier"],
            ])
        }
        if c.path.hasSuffix("/rest/v1/lost_reasons"), c.method == "GET" { return (200, [] as [Any]) }
        if c.method == "POST" || c.method == "PATCH" { return (201, Data()) }
        return (404, ["message": "not mocked"])
    }

    @Test func testLeadsMatchDealsByDomainOrPersonalAddress() {
        func lead(_ email: String?, _ web: String?, at: String? = nil) -> SupabaseCRM.Lead {
            .init(id: UUID().uuidString, user_id: "u", company_name: nil, email: email, website: web, stage: nil, project: nil, last_activity_at: at)
        }
        XCTAssertEqual(SupabaseCRM.keys(for: lead("Jan@Acme.be", "")), ["acme.be"])
        XCTAssertEqual(SupabaseCRM.keys(for: lead(nil, "https://www.zonnehoek.be/contact")), ["zonnehoek.be"])
        XCTAssertEqual(SupabaseCRM.keys(for: lead(nil, "https:www.panelwerk.be")), ["panelwerk.be"], "A scheme typed without slashes")
        XCTAssertEqual(SupabaseCRM.keys(for: lead(nil, "luchtzuiver.be/")), ["luchtzuiver.be"])
        XCTAssertEqual(SupabaseCRM.keys(for: lead("loran@gmail.com", "gmail.com")), ["loran@gmail.com"], "A personal provider is no company")
        let old = lead("a@acme.be", nil, at: "2026-01-01"), new = lead("b@acme.be", nil, at: "2026-06-01")
        XCTAssertEqual(SupabaseCRM.match([old, new])["acme.be"]?.id, new.id, "The most recently active lead wins")
    }

    @Test func testCRMSyncRecordsStageAndNotesAndSendsTheUsersNotes() async throws {
        let e = try await seededEngine()
        try await Deals(db: e.db).save([
            DealRecord(key: "acme.be", isDeal: true, venture: "Brightly", company: "Acme", contacts: "", stage: .demo, risk: "", nextStep: "Follow up with Jan",
                       owner: .you, due: "", amount: "", amountEUR: 0, size: "unknown", sizeSource: "", latestThread: nil, activityKey: "a1", analyzedAt: Date()),
            DealRecord(key: "beta.be", isDeal: true, venture: "Brightly", company: "Beta", contacts: "", stage: .lost, risk: "", nextStep: "",
                       owner: .none, due: "", amount: "", amountEUR: 0, size: "unknown", sizeSource: "", latestThread: nil, activityKey: "b1", analyzedAt: Date()),
        ])
        MockServer.reset(crmServer)
        let c = try crm(e)
        XCTAssertFalse(c.isConnected)
        try await c.signIn(email: "anna@brightly.example", password: "pw")
        XCTAssertTrue(c.isConnected)
        XCTAssertEqual(e.secrets.get("crm.refresh.anna@brightly.example"), "r2", "Only the refresh token is kept")
        let signIn = MockServer.recorded("/auth/v1/token")[0]
        XCTAssertEqual(signIn.query["grant_type"], "password")
        XCTAssertEqual(signIn.headers["apikey"], "anon-key")

        let notes = DealNotes(db: e.db)
        try await notes.add("Lost on 6 Oct, they built it themselves", to: "acme.be")
        let r = try await c.sync()
        XCTAssertEqual(r.matched, 2, "Gamma has no deal here")
        XCTAssertEqual(r.changed, ["acme.be", "beta.be"], "A first sight counts as a change")
        XCTAssertEqual(r.pushed, 1)
        let acme = try await notes.state("acme.be")
        XCTAssertEqual(acme.crmStage, "Closed Lost")
        XCTAssertEqual(acme.crmLeadId, "L1")
        XCTAssertTrue(acme.crmContext?.contains("They built it themselves") ?? false)
        XCTAssertFalse(acme.crmContext?.contains("Pushed by Postvak") ?? true, "Postvak's own notes are not read back")
        XCTAssertEqual(MockServer.recorded("/rest/v1/leads")[0].headers["Authorization"], "Bearer jwt")

        let post = MockServer.recorded("/rest/v1/activities", method: "POST")
        XCTAssertEqual(post.count, 1)
        let row = try JSONSerialization.jsonObject(with: post[0].body) as! [String: Any]
        XCTAssertEqual(row["lead_id"] as? String, "L1")
        XCTAssertEqual(row["user_id"] as? String, "u1")
        XCTAssertEqual(row["type"] as? String, "note")
        XCTAssertEqual(row["project"] as? String, "brightly")
        XCTAssertEqual(row["notes"] as? String, "Lost on 6 Oct, they built it themselves")
        XCTAssertNotNil(try await notes.notes(for: "acme.be").first?.crmPushedAt)

        // Nothing changed: no deal is marked for a new reading, and the note is not sent twice.
        let again = try await c.sync()
        XCTAssertTrue(again.changed.isEmpty)
        XCTAssertEqual(MockServer.recorded("/rest/v1/activities", method: "POST").count, 1)

        // Claude reads Beta as lost while the CRM says Meeting Scheduled: Postvak asks before writing.
        let beta = try await Deals(db: e.db).all().first { $0.key == "beta.be" }!
        var betaState = try await notes.state("beta.be")
        XCTAssertEqual(SupabaseCRM.proposedStage(for: beta, state: betaState), SupabaseCRM.closedLost)
        XCTAssertNil(SupabaseCRM.proposedStage(for: try await Deals(db: e.db).all().first { $0.key == "acme.be" }!, state: acme), "A demo stage suggests nothing")
        try await c.setStage(SupabaseCRM.closedLost, for: "beta.be", reason: "Chose another supplier")
        let patch = MockServer.recorded("/rest/v1/leads", method: "PATCH")
        XCTAssertEqual(patch.count, 1)
        XCTAssertEqual(patch[0].query["id"], "eq.L2")
        XCTAssertEqual((try JSONSerialization.jsonObject(with: patch[0].body) as! [String: Any])["stage"] as? String, "Closed Lost")
        let lost = try JSONSerialization.jsonObject(with: MockServer.recorded("/rest/v1/lost_reasons", method: "POST")[0].body) as! [String: Any]
        XCTAssertEqual(lost["reason"] as? String, "Other")
        XCTAssertEqual(lost["notes"] as? String, "Chose another supplier")
        betaState = try await notes.state("beta.be")
        XCTAssertNil(SupabaseCRM.proposedStage(for: beta, state: betaState), "Asked and done")
        // Waved away: not asked again.
        try await notes.update("beta.be") { $0.crmStage = "Meeting Scheduled" }
        try await c.dismissProposal(SupabaseCRM.closedLost, for: "beta.be")
        XCTAssertNil(SupabaseCRM.proposedStage(for: beta, state: try await notes.state("beta.be")))
    }

    @Test func testDoneStepStaysHiddenUntilNewActivity() async throws {
        let e = try makeEngine()
        let now = Date()
        var d = DealRecord(key: "acme.be", isDeal: true, venture: "V", company: "Acme", contacts: "", stage: .demo, risk: "", nextStep: "Send the deck",
                           owner: .you, due: "", amount: "", amountEUR: 0, size: "unknown", sizeSource: "", latestThread: nil, activityKey: "a1",
                           analyzedAt: now.addingTimeInterval(-60))
        let notes = DealNotes(db: e.db)
        try await notes.markDone(d, now: now)
        XCTAssertTrue(try await notes.state("acme.be").isDone(d))
        // Read again for a note: the same step stays done, a new step Claude gives knowing that stands.
        d.analyzedAt = now.addingTimeInterval(60)
        XCTAssertTrue(try await notes.state("acme.be").isDone(d))
        d.nextStep = "Wait for Jan's answer to the deck"
        XCTAssertFalse(try await notes.state("acme.be").isDone(d))
        // New mail: back on the list.
        d.nextStep = "Send the deck"; d.activityKey = "a2"
        XCTAssertFalse(try await notes.state("acme.be").isDone(d))
        try await notes.undoDone("acme.be")
        d.activityKey = "a1"
        XCTAssertFalse(try await notes.state("acme.be").isDone(d))
    }

    @Test func testNotesDoneStepsAndCRMReachClaudeAndANoteTriggersARead() async throws {
        let e = try await seededEngine()
        let answer = """
        {"deals":[
         {"key":"acme.be","is_deal":true,"venture":"SolarCo","company":"Acme","contacts":"Jan","stage":"lost","risk":"","next_step":"","owner":"none","due":"","amount":"","amount_eur":0,"size":"unknown","size_source":""},
         {"key":"beta.be","is_deal":true,"venture":"SolarCo","company":"Beta","contacts":"Lea","stage":"contacted","risk":"","next_step":"Demo for Beta","owner":"meeting","due":"","amount":"","amount_eur":0,"size":"unknown","size_source":""}
        ]}
        """
        MockServer.reset { _ in (200, self.claudeBody(answer)) }
        let deals = Deals(db: e.db)
        let analyzer = DealAnalyzer(deals: deals, claude: ClaudeClient(session: MockServer.session) { "k" }, db: e.db)
        try await analyzer.run()
        XCTAssertEqual(MockServer.recorded("/v1/messages").count, 1)
        XCTAssertEqual(try await analyzer.run(), 0, "Nothing new")

        let notes = DealNotes(db: e.db)
        try await notes.add("Lost on 6 Oct, they built it themselves", to: "acme.be", now: Date().addingTimeInterval(5))
        try await notes.update("acme.be") { $0.doneStep = "Send Jan the offer"; $0.doneAt = Date(); $0.crmContext = "Stage in Brightly CRM: Closed Lost." }
        XCTAssertEqual(try await analyzer.run(), 1, "A note newer than the last reading makes just that deal stale")
        let body = try JSONSerialization.jsonObject(with: MockServer.recorded("/v1/messages")[1].body) as! [String: Any]
        let user = ((body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        XCTAssertTrue(user.contains("THE USER'S OWN NOTES"))
        XCTAssertTrue(user.contains("they built it themselves"))
        XCTAssertTrue(user.contains("DONE by the user on"))
        XCTAssertTrue(user.contains("Stage in Brightly CRM: Closed Lost."))
        XCTAssertFalse(user.contains("COMPANY key=beta.be"), "Only the deal with the note is read")
        let system = (body["system"] as? String) ?? String(describing: body["system"] ?? "")
        XCTAssertTrue(system.contains("override"), "Claude is told notes override the material")

        // Asked for one deal by key: read now, whatever its state, without touching the six-hourly clock.
        let last = e.db.setting("deals.lastRun")
        XCTAssertEqual(try await analyzer.run(keys: ["beta.be"]), 1)
        XCTAssertEqual(e.db.setting("deals.lastRun"), last)
    }
}
