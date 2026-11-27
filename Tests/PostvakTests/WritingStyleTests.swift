import Foundation
import Testing
import GRDB
@testable import PostvakCore
@testable import PostvakAI

/// The writing style: the profile kept in the data folder, and the past mails picked as examples for a draft.
@Suite(.serialized) struct WritingStyleTests {
    static let me = "a@example.com"

    func sent(_ e: Engine, _ id: String, to: String, body: String, daysAgo: Double, thread: String? = nil, labels: String = "|SENT|") throws {
        try e.db.pool.write { db in
            try MailMessage(accountId: Self.me, messageId: id, threadId: thread ?? "t\(id)", rfcMessageId: "<\(id)@x>", inReplyTo: nil, referencesHeader: nil,
                            fromName: "", fromEmail: Self.me, toLine: to, ccLine: "", subject: "S", date: Date().addingTimeInterval(-daysAgo * 86400),
                            snippet: "", bodyText: body, bodyHtml: nil, labelIds: labels, hasListUnsubscribe: false).insert(db)
        }
    }

    static let dutch = "Hey Jan,\n\nBedankt voor het gesprek van gisteren. Zoals beloofd stuur ik je hierbij de offerte voor de panelen.\n\nGroeten,"
    static let french = "Salut Marie,\n\nMerci pour ton temps hier. Comme promis, je t'envoie la présentation et les prix dont on a parlé.\n\nBien à toi,"
    static let english = "Hi Tom,\n\nThanks for the call yesterday. As promised, here is the deck and the pricing we talked about.\n\nKind regards,"

    @Test func testProfileSavesLoadsAndDeletes() throws {
        let e = try makeEngine()
        let store = WritingStyle(paths: e.paths)
        XCTAssertEqual(store.load(), "")
        XCTAssertFalse(store.exists)
        try store.save("  - Greets with \"Hey [first name],\"\n")
        XCTAssertEqual(store.load(), "- Greets with \"Hey [first name],\"")
        XCTAssertNotNil(store.savedAt)
        let perms = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600, "Only the user can read it")
        try store.save("   ")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.path), "Saving nothing deletes it")
        try store.save("x")
        try store.delete()
        XCTAssertEqual(store.load(), "")
    }

    @Test func testExamplesPreferSamePersonThenCompanyThenLanguage() async throws {
        let e = try makeEngine()
        try sent(e, "1", to: "Tom <tom@other.com>", body: Self.english, daysAgo: 1)
        try sent(e, "2", to: "Marie <marie@client.fr>", body: Self.french, daysAgo: 2)
        try sent(e, "3", to: "Piet <piet@acme.be>", body: Self.dutch.replacingOccurrences(of: "Jan", with: "Piet"), daysAgo: 3)
        try sent(e, "4", to: "Jan <jan@acme.be>", body: Self.dutch, daysAgo: 30)
        try sent(e, "5", to: "x@gmail.com", body: "Ok merci!", daysAgo: 0.5)
        try sent(e, "6", to: "jan@acme.be", body: Self.dutch + " (draft)", daysAgo: 0.1, labels: "|SENT|DRAFT|")
        let picked = try await e.db.pool.read { db in
            try StyleExamples.pick(db, accountId: Self.me, recipients: ["jan@acme.be"], language: "nl", limit: 3)
        }
        XCTAssertEqual(picked.count, 3)
        XCTAssertTrue(picked[0].hasPrefix("Hey Jan"), "A mail to the same person comes first, however old")
        XCTAssertTrue(picked[1].hasPrefix("Hey Piet"), "Then the same company")
        XCTAssertFalse(picked.contains { $0.contains("(draft)") || $0 == "Ok merci!" }, "No drafts, nothing too short")
    }

    @Test func testExamplesFollowTheLanguageAndSkipTheThread() async throws {
        let e = try makeEngine()
        try sent(e, "1", to: "tom@other.com", body: Self.english, daysAgo: 1)
        try sent(e, "2", to: "marie@client.fr", body: Self.french, daysAgo: 5)
        try sent(e, "3", to: "jan@acme.be", body: Self.dutch, daysAgo: 6, thread: "current")
        let picked = try await e.db.pool.read { db in
            try StyleExamples.pick(db, accountId: Self.me, recipients: ["someone@gmail.com"],
                                   about: "Bonjour, est-ce que vous pouvez m'envoyer une offre pour notre bâtiment à Namur ?", excludingThread: "current")
        }
        XCTAssertEqual(picked.count, 2)
        XCTAssertTrue(picked[0].hasPrefix("Salut Marie"), "French first for a French thread, even though older")
        XCTAssertFalse(picked.contains { $0.hasPrefix("Hey Jan") }, "The thread being answered is already in the prompt")
    }

    @Test func testPromptsCarryTheStyleAndExamples() {
        let style = "- Dutch: opens with \"Hey [first name],\", closes with \"Groeten,\""
        let block = StylePrompt.block(style: style, samples: [Self.dutch])
        XCTAssertTrue(block.contains("THE USER'S WRITING STYLE"))
        XCTAssertTrue(block.contains(style))
        XCTAssertTrue(block.contains("Bedankt voor het gesprek"))
        XCTAssertEqual(StylePrompt.block(style: "  ", samples: []), "", "Nothing to add without a style or examples")
        XCTAssertFalse(StylePrompt.block(style: "", samples: ["x"]).contains("WRITING STYLE"))

        let m = MeetingRecord(title: "Kennismaking", startedAt: Date(), status: .ready, source: "calendar")
        let p = MeetingFollowUpWriter.prompt(meeting: m, summary: nil, me: nil, recipients: ["jan@acme.be"], lastInThread: nil,
                                             samples: [Self.dutch], style: style)
        XCTAssertTrue(p.contains(style) && p.contains("Bedankt voor het gesprek"))
        XCTAssertTrue(WritingStyleBuilder.prompt(samples: [Self.french]).contains("Merci pour ton temps"))
    }

    @Test func testProfileSamplesSkipShortMailsAndDuplicates() async throws {
        let e = try makeEngine()
        try sent(e, "1", to: "tom@other.com", body: Self.english, daysAgo: 1)
        try sent(e, "2", to: "tom@other.com", body: Self.english, daysAgo: 2)
        try sent(e, "3", to: "tom@other.com", body: "Thanks!", daysAgo: 3)
        try sent(e, "4", to: "jan@acme.be", body: Self.dutch + "\n\nOp ma 2 nov schreef Jan:\n> Hallo", daysAgo: 4)
        let samples = try await e.db.pool.read { db in try StyleExamples.forProfile(db, accountIds: [Self.me]) }
        XCTAssertEqual(samples.count, 2)
        XCTAssertFalse(samples.contains { $0.contains("> Hallo") }, "Quoted replies are cut off")
    }
}
