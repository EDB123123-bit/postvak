import Foundation
import Testing
import GRDB
@testable import PostvakCore
@testable import PostvakAI

/// The follow-up review: when it runs, which threads and meetings it drafts for, and the list of drafts awaiting review.
@Suite(.serialized) struct FollowUpReviewTests {
    static let personal = "anna@gmail.com", company = "anna@zonnehoek.be"
    let now = ISO8601DateFormatter().date(from: "2026-11-09T09:00:00Z")!   // a Monday

    func engine() throws -> Engine {
        let e = try makeEngine(accounts: [Self.personal, Self.company])
        let config = ProjectConfig(projects: [ProjectRule(name: "Personal", accounts: [Self.personal]),
                                              ProjectRule(name: "Zonnehoek", accounts: [Self.company], domains: ["zonnehoek.be"])])
        try e.db.pool.write { db in
            try db.execute(sql: "INSERT INTO setting (key, value) VALUES (?, ?)",
                           arguments: [ProjectConfig.settingKey, String(data: try JSONEncoder().encode(config), encoding: .utf8)!])
        }
        return e
    }

    func msg(_ e: Engine, _ id: String, thread: String, account: String = personal, from: String, to: String,
             daysAgo: Double, labels: String? = nil, unsubscribe: Bool = false, subject: String = "Offerte") throws {
        let own = from == Self.personal || from == Self.company
        try e.db.pool.write { db in
            try MailMessage(accountId: account, messageId: id, threadId: thread, rfcMessageId: "<\(id)@x>", inReplyTo: nil, referencesHeader: nil,
                            fromName: "", fromEmail: from, toLine: to, ccLine: "", subject: subject, date: now.addingTimeInterval(-daysAgo * 86400),
                            snippet: "", bodyText: "Tekst", bodyHtml: nil, labelIds: labels ?? (own ? "|SENT|" : "|INBOX|"),
                            hasListUnsubscribe: unsubscribe).insert(db)
        }
    }

    // MARK: schedule

    @Test func testWeeklyRunsOnceFromMondayMorning() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Brussels")!
        let iso = ISO8601DateFormatter()
        let monday0810 = iso.date(from: "2026-11-09T07:10:00Z")!, monday0820 = iso.date(from: "2026-11-09T07:20:00Z")!
        let wednesday = iso.date(from: "2026-11-11T12:00:00Z")!
        XCTAssertFalse(FollowUpReview.isDue(.weekly, lastRun: iso.date(from: "2026-11-02T08:00:00Z"), now: monday0810, calendar: cal), "Not before 8:15")
        XCTAssertTrue(FollowUpReview.isDue(.weekly, lastRun: iso.date(from: "2026-11-02T08:00:00Z"), now: monday0820, calendar: cal))
        XCTAssertFalse(FollowUpReview.isDue(.weekly, lastRun: monday0820, now: wednesday, calendar: cal), "Once a week")
        XCTAssertTrue(FollowUpReview.isDue(.weekly, lastRun: iso.date(from: "2026-11-02T08:00:00Z"), now: wednesday, calendar: cal),
                      "A Mac that slept through Monday catches up")
        XCTAssertTrue(FollowUpReview.isDue(.daily, lastRun: monday0820, now: iso.date(from: "2026-11-10T07:30:00Z")!, calendar: cal))
        XCTAssertFalse(FollowUpReview.isDue(.daily, lastRun: iso.date(from: "2026-11-13T07:30:00Z")!, now: iso.date(from: "2026-11-14T10:00:00Z")!, calendar: cal),
                       "No run on Saturday after Friday's")
        XCTAssertFalse(FollowUpReview.isDue(.off, lastRun: nil, now: monday0820, calendar: cal))
    }

    // MARK: threads

    @Test func testFindsWhatWaitsAndSkipsWhatWasHandled() async throws {
        let e = try engine()
        // Waiting on you: a prospect asked something three days ago.
        try msg(e, "a1", thread: "ta", from: "jo@panelwerk.be", to: Self.personal, daysAgo: 3)
        // Followed up some other way: a new mail from the company account this morning.
        try msg(e, "b1", thread: "tb", from: "jan@stroomlijn.be", to: Self.personal, daysAgo: 4)
        try msg(e, "b2", thread: "tb2", account: Self.company, from: Self.company, to: "Jan <jan@stroomlijn.be>", daysAgo: 0.04)
        // Waiting on them: sent from the company account a week ago, no answer.
        try msg(e, "c1", thread: "tc", account: Self.company, from: Self.company, to: "tom@voltwerk.be", daysAgo: 7)
        // Too fresh to chase.
        try msg(e, "d1", thread: "td", from: Self.personal, to: "lien@brightly.be", daysAgo: 1)
        // A newsletter, a machine and calendar traffic.
        try msg(e, "e1", thread: "te", from: "hello@dealflow.be", to: Self.personal, daysAgo: 3, unsubscribe: true)
        try msg(e, "f1", thread: "tf", from: "noreply@bank.be", to: Self.personal, daysAgo: 3)
        try msg(e, "g1", thread: "tg", from: "an@luchtzuiver.be", to: Self.personal, daysAgo: 3, subject: "Invitation: Demo @ Thu")
        // A draft already waits in the thread.
        try msg(e, "h1", thread: "th", from: "piet@panelwerk.be", to: Self.personal, daysAgo: 3)
        try msg(e, "h2", thread: "th", from: Self.personal, to: "piet@panelwerk.be", daysAgo: 0.5, labels: "|DRAFT|")
        // Copied on a mail to someone else, then they answered elsewhere.
        try msg(e, "i1", thread: "ti", from: Self.personal, to: "tom@zonnepark.be", daysAgo: 6)
        try msg(e, "i2", thread: "ti2", from: "tom@zonnepark.be", to: Self.personal, daysAgo: 2)
        // A mail still queued to them.
        try msg(e, "j1", thread: "tj", from: "els@groenlicht.be", to: Self.personal, daysAgo: 3)
        _ = try await e.outbox.enqueue(OutgoingMail(accountId: Self.company, to: ["Els <els@groenlicht.be>"], subject: "Re", textBody: "t"),
                                       sendAt: now.addingTimeInterval(3600))
        try await e.db.pool.write { db in
            try db.execute(sql: """
                INSERT INTO deal (key, isDeal, venture, company, contacts, stage, risk, nextStep, owner, due, amount, amountEUR, size, sizeSource, activityKey, analyzedAt)
                VALUES ('voltwerk.be', 1, 'Zonnehoek', 'Voltwerk', '', 'proposal', '', '', '', '', '', 0, '', '', '', ?)
                """, arguments: [Date()])
        }

        let found = try await e.db.pool.read { try FollowUpReview.candidates($0, now: now) }
        let threads = found.map(\.last.threadId)
        XCTAssertEqual(Set(threads), ["ta", "tc", "ti2"], "\(threads)")
        XCTAssertEqual(found.first?.last.threadId, "tc", "A deal goes first")
        XCTAssertEqual(found.first { $0.last.threadId == "tc" }?.kind, .waitingOnThem)
        XCTAssertEqual(found.first { $0.last.threadId == "ta" }?.kind, .waitingOnYou)
    }

    // MARK: meetings

    @Test func testMeetingWithNoMailSinceGetsAFollowUp() async throws {
        let e = try engine()
        var m = MeetingRecord(title: "Demo Panelwerk", startedAt: now.addingTimeInterval(-3 * 86400), endedAt: now.addingTimeInterval(-3 * 86400 + 3600), status: .ready)
        m.attendeesJSON = String(data: try JSONEncoder().encode([EventAttendee(email: "jo@panelwerk.be", name: "Jo"),
                                                                 EventAttendee(email: Self.company, isSelf: true)]), encoding: .utf8)!
        m.project = "Zonnehoek"
        try await e.meetings.save(m)
        try await e.meetings.saveSummary(MeetingSummaryRecord(meetingId: m.id, summary: "Demo", decisions: [], actionItems: [ActionItem(task: "Offerte sturen", owner: "Me")],
                                                              openQuestions: [], model: "x"))
        var found = try await e.db.pool.read { try FollowUpReview.meetingCandidates($0, now: now) }
        XCTAssertEqual(found.map(\.id), [m.id])
        // A mail to someone at the company since the meeting means it was followed up.
        try msg(e, "k1", thread: "tk", account: Self.company, from: Self.company, to: "Lien <lien@panelwerk.be>", daysAgo: 1)
        found = try await e.db.pool.read { try FollowUpReview.meetingCandidates($0, now: now) }
        XCTAssertTrue(found.isEmpty)
    }

    // MARK: review list

    @Test func testDraftsHandledElsewhereLeaveTheReview() async throws {
        let e = try engine()
        try msg(e, "l1", thread: "tl", from: Self.personal, to: "jo@panelwerk.be", daysAgo: 0, labels: "|DRAFT|")
        let kept = try await e.autoDrafts.record(AutoDraftRecord(accountId: Self.personal, draftId: "d1", threadId: "tl", fromEmail: Self.company,
                                                                 recipients: "jo@panelwerk.be", subject: "Re", source: .review, reason: "r",
                                                                 createdAt: Date().addingTimeInterval(-3600)))
        let gone = try await e.autoDrafts.record(AutoDraftRecord(accountId: Self.personal, draftId: "d2", threadId: "tm", fromEmail: Self.personal,
                                                                 recipients: "x@y.be", subject: "Re", source: .claude, reason: "r",
                                                                 createdAt: Date().addingTimeInterval(-3600)))
        let fresh = try await e.autoDrafts.record(AutoDraftRecord(accountId: Self.personal, draftId: "d3", threadId: "tn", fromEmail: Self.personal,
                                                                  recipients: "x@y.be", subject: "Re", source: .claude, reason: "r"))
        XCTAssertEqual(try await e.autoDrafts.reconcile(), 1)
        XCTAssertEqual(Set(try await e.autoDrafts.pending().map(\.id)), [kept.id, fresh.id], "A fresh one waits for its thread to sync")
        _ = gone
        try await e.autoDrafts.setStatus(kept.id, .kept)
        XCTAssertEqual(try await e.autoDrafts.pending().map(\.id), [fresh.id])
    }

    @Test func testBlanksToFillAreFound() {
        XCTAssertEqual(FollowUpReviewWriter.placeholders(in: "De prijs is [prijs bevestigen] per kaart.\n[x]"), ["[prijs bevestigen]", "[x]"])
        XCTAssertTrue(FollowUpReviewWriter.placeholders(in: "Geen haakjes hier.").isEmpty)
    }

    @Test func testReplyToYourOwnMailSentAsAnAliasGoesToThem() async throws {
        let e = try engine()
        try msg(e, "n1", thread: "tn", from: Self.company, to: "Jo <jo@panelwerk.be>", daysAgo: 5, labels: "|SENT|")
        let addr = try await e.mail.replyAddressing(accountId: Self.personal, messageId: "n1", replyAll: true)
        XCTAssertEqual(addr.to, ["Jo <jo@panelwerk.be>"], "Not back to the user's own company address")
        XCTAssertTrue(addr.cc.isEmpty)
    }
}
