import Foundation
import Testing
import GRDB
import AppKit
@testable import PostvakCore
@testable import PostvakAI
@testable import PostvakMCP

@Suite(.serialized) struct MIMETests {
    func decodeBody(_ raw: Data) -> String { String(decoding: raw, as: UTF8.self) }

    @Test func testReplyHeadersAndEncoding() throws {
        let mail = OutgoingMail(accountId: "a@example.com", fromName: "Édouard", to: ["Ann <ann@example.net>"], subject: "Déjeuner jeudi ?",
                                textBody: "Salut", htmlBody: "<b>Salut</b>", threadId: "t1", inReplyTo: "<m1@x>", references: "<m0@x> <m1@x>")
        let s = decodeBody(try MIMEBuilder.build(mail))
        XCTAssertTrue(s.contains("In-Reply-To: <m1@x>"))
        XCTAssertTrue(s.contains("References: <m0@x> <m1@x>"))
        XCTAssertTrue(s.contains("Subject: =?UTF-8?B?"))
        XCTAssertTrue(s.contains("From: =?UTF-8?B?"))
        XCTAssertTrue(s.contains("multipart/alternative"))
        XCTAssertTrue(s.contains(Data("<b>Salut</b>".utf8).base64EncodedString()))
    }

    @Test func testHeaderInjectionIsNeutralised() throws {
        let mail = OutgoingMail(accountId: "a@example.com", to: ["b@example.com"], subject: "Hi\r\nBcc: evil@example.com", textBody: "x")
        let s = decodeBody(try MIMEBuilder.build(mail))
        XCTAssertFalse(s.contains("\r\nBcc: evil"))
    }

    @Test func testAttachmentIsMixedAndBase64Wrapped() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        try Data(repeating: 65, count: 300).write(to: f)
        let mail = OutgoingMail(accountId: "a@example.com", to: ["b@example.com"], subject: "s", textBody: "t", htmlBody: "<p>t</p>",
                                attachments: [OutgoingAttachment(filename: "offerte.pdf", mimeType: "application/pdf", path: f.path)])
        let s = decodeBody(try MIMEBuilder.build(mail))
        XCTAssertTrue(s.contains("multipart/mixed"))
        XCTAssertTrue(s.contains("filename=\"offerte.pdf\""))
        for line in s.components(separatedBy: "\r\n") where line.hasPrefix("QUFB") { XCTAssertLessThanOrEqual(line.count, 76) }
    }

    @Test func testPictureInTheTextTravelsInlineNextToTheHTML() throws {
        let png = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Data(repeating: 1, count: 50).write(to: png)
        let pdf = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data(repeating: 2, count: 50).write(to: pdf)
        let picture = OutgoingAttachment(filename: "image-1.png", mimeType: "image/png", path: png.path, contentId: "pic1@postvak")
        let file = OutgoingAttachment(filename: "offerte.pdf", mimeType: "application/pdf", path: pdf.path)

        let onlyPicture = decodeBody(try MIMEBuilder.build(OutgoingMail(accountId: "a@example.com", to: ["b@example.com"], subject: "s", textBody: "[image]",
                                                                      htmlBody: "<img src=\"cid:pic1@postvak\">", attachments: [picture])))
        XCTAssertTrue(onlyPicture.contains("Content-Type: multipart/related"), onlyPicture)
        XCTAssertFalse(onlyPicture.contains("multipart/mixed"), "No separate attachment, so nothing to mix")
        XCTAssertTrue(onlyPicture.contains("Content-ID: <pic1@postvak>"))
        XCTAssertTrue(onlyPicture.contains("Content-Disposition: inline; filename=\"image-1.png\""))

        let both = decodeBody(try MIMEBuilder.build(OutgoingMail(accountId: "a@example.com", to: ["b@example.com"], subject: "s", textBody: "[image]",
                                                               htmlBody: "<img src=\"cid:pic1@postvak\">", attachments: [picture, file])))
        let mixed = both.range(of: "multipart/mixed")!, related = both.range(of: "multipart/related")!, pdfPart = both.range(of: "filename=\"offerte.pdf\"")!
        XCTAssertTrue(mixed.lowerBound < related.lowerBound && related.lowerBound < pdfPart.lowerBound, "Text and picture together, the file after")
        XCTAssertTrue(both.contains("Content-Disposition: attachment; filename=\"offerte.pdf\""))
    }
}

@Suite(.serialized) struct ParserTests {
    @Test func testAddresses() {
        XCTAssertEqual(GmailParser.parseAddress("\"Peeters, An\" <AN@Example.net>").email, "an@example.net")
        XCTAssertEqual(GmailParser.parseAddress("\"Peeters, An\" <AN@Example.net>").name, "Peeters, An")
        XCTAssertEqual(GmailParser.splitAddresses("\"Peeters, An\" <an@x.be>, bob@x.be").count, 2)
        // Lists pasted from Outlook, Teams or a spreadsheet.
        XCTAssertEqual(GmailParser.splitAddresses("an@x.be; bob@x.be;cid@x.be"), ["an@x.be", "bob@x.be", "cid@x.be"])
        XCTAssertEqual(GmailParser.splitAddresses("an@x.be\nbob@x.be\r\n\tcid@x.be\n"), ["an@x.be", "bob@x.be", "cid@x.be"])
        XCTAssertEqual(GmailParser.splitAddresses("\"Peeters; An\" <an@x.be>; bob@x.be").count, 2)
    }

    @Test func testNestedMultipartWithAttachment() {
        let part = GmailPart(partId: "", mimeType: "multipart/mixed", filename: "", headers: [GmailHeader(name: "From", value: "A <a@x>"), GmailHeader(name: "List-Unsubscribe", value: "<x>")], body: nil, parts: [
            GmailPart(partId: "0", mimeType: "multipart/alternative", filename: "", headers: nil, body: nil, parts: [
                GmailPart(partId: "0.0", mimeType: "text/plain", filename: "", headers: nil, body: GmailBody(attachmentId: nil, size: 2, data: b64("plain")), parts: nil),
                GmailPart(partId: "0.1", mimeType: "text/html", filename: "", headers: nil, body: GmailBody(attachmentId: nil, size: 2, data: b64("<b>html</b>")), parts: nil),
            ]),
            GmailPart(partId: "1", mimeType: "application/pdf", filename: "f.pdf", headers: nil, body: GmailBody(attachmentId: "att", size: 9, data: nil), parts: nil),
        ])
        let (m, a) = GmailParser.parse(GmailMessage(id: "m", threadId: "t", labelIds: ["INBOX"], snippet: "a &amp; b", historyId: nil, internalDate: "1000", payload: part), accountId: "x", threadId: "t")
        XCTAssertEqual(m.bodyText, "plain")
        XCTAssertEqual(m.bodyHtml, "<b>html</b>")
        XCTAssertEqual(m.snippet, "a & b")
        XCTAssertTrue(m.hasListUnsubscribe)
        XCTAssertEqual(a.first?.filename, "f.pdf")
    }

    @Test func testFirstPassBuckets() {
        XCTAssertEqual(GmailParser.firstPassBucket(labels: ["CATEGORY_PERSONAL"], senderIsAutomated: false).bucket, .people)
        XCTAssertEqual(GmailParser.firstPassBucket(labels: ["CATEGORY_UPDATES"], senderIsAutomated: true).bucket, .notifications)
        XCTAssertEqual(GmailParser.firstPassBucket(labels: ["CATEGORY_PROMOTIONS"], senderIsAutomated: true).bucket, .newsletters)
        XCTAssertFalse(GmailParser.firstPassBucket(labels: ["CATEGORY_PROMOTIONS"], senderIsAutomated: true).askAI)
        XCTAssertTrue(GmailParser.firstPassBucket(labels: ["CATEGORY_PROMOTIONS"], senderIsAutomated: false).askAI, "A person in Promotions goes to Claude")
        XCTAssertTrue(GmailParser.firstPassBucket(labels: ["CATEGORY_PERSONAL"], senderIsAutomated: true).askAI, "An automated sender in Personal goes to Claude")
    }

    @Test func testFTSQueryIsSafe() {
        XCTAssertEqual(ftsQuery("offerte gent"), "\"offerte\"* \"gent\"*")
        XCTAssertNil(ftsQuery("\"*()"))
    }
}

@Suite(.serialized) struct SyncTests {
    @Test func testInitialThenIncrementalMirrorsGmail() async throws {
        let e = try makeEngine()
        var inboxLabels = ["INBOX", "UNREAD"]
        nonisolated(unsafe) var useHistory = false
        MockServer.reset { c in
            if let b = baseAnswer(c) { return b }
            if c.path.hasSuffix("/profile") { return (200, ["emailAddress": "a@example.com", "historyId": "100"]) }
            if c.path.hasSuffix("/threads"), c.method == "GET" {
                XCTAssertEqual(c.query["includeSpamTrash"], "true")
                return (200, ["threads": [["id": "t1"], ["id": "spam1"]]])
            }
            if c.path.hasSuffix("/threads/t1") { return (200, ["id": "t1", "messages": [gmailMessage(id: "m1", thread: "t1", labels: inboxLabels)]]) }
            if c.path.hasSuffix("/threads/spam1") { return (200, ["id": "spam1", "messages": [gmailMessage(id: "m2", thread: "spam1", subject: "Prize", labels: ["SPAM"])]]) }
            if c.path.hasSuffix("/history") {
                if !useHistory { return (200, ["historyId": "100"]) }
                let change: [String: Any] = ["labelsRemoved": [["message": ["id": "m1", "threadId": "t1"]]]]
                return (200, ["historyId": "200", "history": [change]] as [String: Any])
            }
            return (404, ["error": ["message": "unhandled \(c.path)"]])
        }
        try await e.sync.sync(accountId: "a@example.com")
        var inbox = try await e.mail.threads(ThreadQuery(folder: .inbox))
        XCTAssertEqual(inbox.map(\.threadId), ["t1"])
        XCTAssertTrue(inbox[0].isUnread)
        let spam = try await e.mail.threads(ThreadQuery(folder: .spam))
        XCTAssertEqual(spam.map(\.threadId), ["spam1"], "Spam is a visible folder")

        // Archived in Gmail web: the next pass removes it from the inbox here.
        inboxLabels = []
        useHistory = true
        try await e.sync.sync(accountId: "a@example.com")
        inbox = try await e.mail.threads(ThreadQuery(folder: .inbox))
        XCTAssertTrue(inbox.isEmpty)
        let acct = try await e.db.pool.read { try Account.fetchOne($0, key: "a@example.com") }
        XCTAssertEqual(acct?.historyId, "200")
    }

    @Test func testNewMailArrivesWhileInitialPassIsStillRunning() async throws {
        let e = try makeEngine()
        nonisolated(unsafe) var passBlocked = true
        MockServer.reset { c in
            if let b = baseAnswer(c) { return b }
            if c.path.hasSuffix("/profile") { return (200, ["emailAddress": "a@example.com", "historyId": "100"]) }
            if c.path.hasSuffix("/threads"), c.method == "GET" {
                if c.query["pageToken"] == "p2" {
                    return passBlocked ? (400, ["error": ["message": "pass still running"]]) : (200, ["threads": [["id": "old2"]]])
                }
                return (200, ["threads": [["id": "old1"]], "nextPageToken": "p2"] as [String: Any])
            }
            for id in ["old1", "old2", "new"] where c.path.hasSuffix("/threads/\(id)") {
                return (200, ["id": id, "messages": [gmailMessage(id: "m-\(id)", thread: id)]])
            }
            if c.path.hasSuffix("/history") {
                guard c.query["startHistoryId"] == "100" else { return (200, ["historyId": "150"]) }
                let added: [String: Any] = ["messagesAdded": [["message": ["id": "m-new", "threadId": "new"]]]]
                return (200, ["historyId": "150", "history": [added]] as [String: Any])
            }
            return (404, ["error": ["message": "unhandled \(c.path)"]])
        }

        // The pass stops after its first page, as if it still had hours to go.
        do { try await e.sync.sync(accountId: "a@example.com"); XCTFail("page 2 should fail") } catch {}
        var inbox = try await e.mail.threads(ThreadQuery(folder: .inbox))
        XCTAssertEqual(Set(inbox.map(\.threadId)), ["old1", "new"], "New mail must not wait for the initial pass")
        var acct = try await e.db.pool.read { try Account.fetchOne($0, key: "a@example.com") }
        XCTAssertEqual(acct?.initialSyncDone, false)
        XCTAssertEqual(acct?.historyId, "150", "A later pass must not replay what was already fetched")
        XCTAssertNotNil(acct?.lastSyncAt)

        // A later tick resumes where the pass stopped and finishes it.
        passBlocked = false
        try await e.sync.sync(accountId: "a@example.com")
        inbox = try await e.mail.threads(ThreadQuery(folder: .inbox))
        XCTAssertEqual(Set(inbox.map(\.threadId)), ["old1", "old2", "new"])
        acct = try await e.db.pool.read { try Account.fetchOne($0, key: "a@example.com") }
        XCTAssertEqual(acct?.initialSyncDone, true)
    }

    @Test func testExpiredHistoryDuringInitialPassRestartsIt() async throws {
        let e = try makeEngine()
        try await e.db.pool.write { db in
            var a = try Account.fetchOne(db, key: "a@example.com")!
            a.historyId = "1"
            a.initialPageToken = "stale"
            try a.update(db)
        }
        MockServer.reset { c in
            if let b = baseAnswer(c) { return b }
            if c.path.hasSuffix("/history") {
                if c.query["startHistoryId"] == "1" { return (404, ["error": ["message": "gone"]]) }
                return (200, ["historyId": "50"])
            }
            if c.path.hasSuffix("/profile") { return (200, ["emailAddress": "a@example.com", "historyId": "50"]) }
            if c.path.hasSuffix("/threads") {
                XCTAssertNil(c.query["pageToken"], "The restart begins at the newest page")
                return (200, ["threads": [["id": "t9"]]])
            }
            if c.path.hasSuffix("/threads/t9") { return (200, ["id": "t9", "messages": [gmailMessage(id: "m9", thread: "t9")]]) }
            return (404, ["error": ["message": "unhandled"]])
        }
        try await e.sync.sync(accountId: "a@example.com")
        let acct = try await e.db.pool.read { try Account.fetchOne($0, key: "a@example.com") }
        XCTAssertEqual(acct?.initialSyncDone, true)
        XCTAssertEqual(acct?.historyId, "50")
    }

    @Test func testExpiredHistoryRestartsInitialSync() async throws {
        let e = try makeEngine()
        try await e.db.pool.write { db in
            var a = try Account.fetchOne(db, key: "a@example.com")!
            a.initialSyncDone = true
            a.historyId = "1"
            try a.update(db)
        }
        nonisolated(unsafe) var historyCalls = 0
        MockServer.reset { c in
            if let b = baseAnswer(c) { return b }
            if c.path.hasSuffix("/history") {
                historyCalls += 1
                if c.query["startHistoryId"] == "1" { return (404, ["error": ["message": "gone"]]) }
                return (200, ["historyId": "50"])
            }
            if c.path.hasSuffix("/profile") { return (200, ["emailAddress": "a@example.com", "historyId": "50"]) }
            if c.path.hasSuffix("/threads") { return (200, ["threads": [["id": "t9"]]]) }
            if c.path.hasSuffix("/threads/t9") { return (200, ["id": "t9", "messages": [gmailMessage(id: "m9", thread: "t9")]]) }
            return (404, ["error": ["message": "unhandled"]])
        }
        try await e.sync.sync(accountId: "a@example.com")
        let t = try await e.mail.threads(ThreadQuery(folder: .inbox))
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(historyCalls, 2)
    }

    @Test func testSearchFindsBodyAcrossAccentsAndDeletesFollowThread() async throws {
        let e = try makeEngine()
        let dto = try JSONDecoder().decode(GmailThreadDTO.self, from: JSONSerialization.data(withJSONObject: ["id": "t", "messages": [gmailMessage(id: "m", thread: "t", subject: "Déjeuner", body: "rendez-vous à l'hôtel")]]))
        try await GmailSync.store(db: e.db, accountId: "a@example.com", dto: dto)
        let r1 = try await e.mail.threads(ThreadQuery(folder: .all, text: "hotel"))
        XCTAssertEqual(r1.count, 1)
        let r2 = try await e.mail.threads(ThreadQuery(folder: .all, text: "dejeuner"))
        XCTAssertEqual(r2.count, 1)
        let r3 = try await e.mail.threads(ThreadQuery(folder: .all, text: "nietsgevonden"))
        XCTAssertEqual(r3.count, 0)
    }

    @Test func testArchiveRollsBackWhenGmailRefuses() async throws {
        let e = try makeEngine()
        let dto = try JSONDecoder().decode(GmailThreadDTO.self, from: JSONSerialization.data(withJSONObject: ["id": "t", "messages": [gmailMessage(id: "m", thread: "t")]]))
        try await GmailSync.store(db: e.db, accountId: "a@example.com", dto: dto)
        MockServer.reset { c in
            if let b = baseAnswer(c) { return b }
            if c.path.hasSuffix("/modify") { return (403, ["error": ["message": "forbidden"]]) }
            if c.path.hasSuffix("/threads/t") { return (200, ["id": "t", "messages": [gmailMessage(id: "m", thread: "t")]]) }
            return (404, [:])
        }
        do { try await e.mail.archive(accountId: "a@example.com", threadId: "t"); XCTFail("should throw") } catch {}
        let inbox = try await e.mail.threads(ThreadQuery(folder: .inbox))
        XCTAssertEqual(inbox.count, 1, "Failed archive restores the real state")
    }
}

@Suite(.serialized) struct OutboxTests {
    func sendAnswers() {
        MockServer.reset { c in
            if let b = baseAnswer(c) { return b }
            if c.path.hasSuffix("/messages/send") { return (200, ["id": "sent1", "threadId": "t1"]) }
            if c.path.hasSuffix("/threads/t1") { return (200, ["id": "t1", "messages": [gmailMessage(id: "sent1", thread: "t1", from: "a@example.com", labels: ["SENT"])]]) }
            return (404, ["error": ["message": "unhandled \(c.path)"]])
        }
    }
    let mail = OutgoingMail(accountId: "a@example.com", to: ["b@example.com"], subject: "Hi", textBody: "text")

    @Test func testQueueKeepsAPictureInline() async throws {
        let e = try makeEngine()
        let png = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Data(repeating: 1, count: 20).write(to: png)
        var m = mail
        m.attachments = [OutgoingAttachment(filename: "image-1.png", mimeType: "image/png", path: png.path, contentId: "pic1@postvak")]
        let row = try await e.outbox.enqueue(m)
        let queued = try await e.outbox.cancel(id: row.id)
        XCTAssertEqual(queued?.attachments.first?.contentId, "pic1@postvak")
        XCTAssertTrue(queued?.attachments.first?.path != png.path, "The queue keeps its own copy")
    }

    @Test func testUndoInsideWindowSendsNothing() async throws {
        let e = try makeEngine()
        sendAnswers()
        let row = try await e.outbox.enqueue(mail)
        XCTAssertEqual(row.sendAt.timeIntervalSinceNow, 5, accuracy: 0.5)
        await e.outbox.tick()
        XCTAssertTrue(MockServer.recorded("/messages/send").isEmpty, "Not due yet")
        let cancelled = try await e.outbox.cancel(id: row.id)
        XCTAssertEqual(cancelled?.subject, "Hi")
        await e.outbox.tick(now: Date().addingTimeInterval(60))
        XCTAssertTrue(MockServer.recorded("/messages/send").isEmpty)
    }

    @Test func testSendsAfterWindowOnceAndKeepsThread() async throws {
        let e = try makeEngine()
        sendAnswers()
        var m = mail
        m.threadId = "t1"
        _ = try await e.outbox.enqueue(m)
        await e.outbox.tick(now: Date().addingTimeInterval(6))
        await e.outbox.tick(now: Date().addingTimeInterval(7))
        let sends = MockServer.recorded("/messages/send")
        XCTAssertEqual(sends.count, 1)
        let json = try JSONSerialization.jsonObject(with: sends[0].body) as! [String: Any]
        XCTAssertEqual(json["threadId"] as? String, "t1")
        let rows = try await e.outbox.rows()
        XCTAssertTrue(rows.isEmpty)
    }

    @Test func testSendingADraftDeletesItAndTakesItOutOfDrafts() async throws {
        let e = try makeEngine()
        // The draft of a new mail sits in a thread of its own.
        let dto = try JSONDecoder().decode(GmailThreadDTO.self, from: JSONSerialization.data(withJSONObject: ["id": "td", "messages": [gmailMessage(id: "dm", thread: "td", labels: ["DRAFT"])]]))
        try await GmailSync.store(db: e.db, accountId: "a@example.com", dto: dto)
        XCTAssertEqual(try await e.mail.threads(ThreadQuery(folder: .drafts)).count, 1)
        MockServer.reset { c in
            if let b = baseAnswer(c) { return b }
            if c.path.hasSuffix("/messages/send") { return (200, ["id": "sent1", "threadId": "t1"]) }
            if c.path.hasSuffix("/drafts/d1"), c.method == "DELETE" { return (204, Data()) }
            if c.path.hasSuffix("/threads/t1") { return (200, ["id": "t1", "messages": [gmailMessage(id: "sent1", thread: "t1", from: "a@example.com", labels: ["SENT"])]]) }
            return (404, ["error": ["message": "not found"]])
        }
        var m = mail
        m.draftId = "d1"
        m.draftThreadId = "td"
        _ = try await e.outbox.enqueue(m)
        await e.outbox.tick(now: Date().addingTimeInterval(6))
        XCTAssertEqual(MockServer.recorded("/drafts/d1", method: "DELETE").count, 1)
        XCTAssertEqual(try await e.mail.threads(ThreadQuery(folder: .drafts)).count, 0, "Gone from Drafts without waiting for the next sync")
    }

    @Test func testDraftReopensAsReplyWithoutASecondSignature() async throws {
        let e = try makeEngine()
        let dto = try JSONDecoder().decode(GmailThreadDTO.self, from: JSONSerialization.data(withJSONObject: ["id": "t", "messages": [gmailMessage(id: "m1", thread: "t", subject: "Offerte")]]))
        try await GmailSync.store(db: e.db, accountId: "a@example.com", dto: dto)
        try e.db.setSetting("signature.a@example.com", "<b>Anna</b>")
        try e.db.setSetting("sendAsName.a@example.com", "Anna")
        let original = try await e.db.pool.read { try MailMessage.fetchOne($0, key: ["accountId": "a@example.com", "messageId": "m1"]) }!
        var input = ComposeInput(accountId: "a@example.com", to: ["Ann <ann@example.net>"], subject: "Re: Offerte", text: "Dag Ann")
        input.replyTo = ("a@example.com", "m1")
        input.quotedHtml = e.mail.quotedBlock(message: original)
        // What Save Draft puts in Gmail, read back as the draft message.
        let saved = try await e.mail.prepare(input)
        var draft = original
        draft.messageId = "d1"
        draft.bodyText = saved.textBody
        draft.bodyHtml = saved.htmlBody
        draft.inReplyTo = saved.inReplyTo
        draft.toLine = "Ann <ann@example.net>"
        let reopened = try await e.mail.editableDraft(draft)
        XCTAssertEqual(reopened.text, "Dag Ann", "The signature comes off, as sending adds it again")
        XCTAssertEqual(reopened.replyTo?.messageId, "m1", "Still a reply in the same conversation")
        XCTAssertEqual(reopened.quotedHtml, input.quotedHtml)
        XCTAssertEqual(reopened.to, "Ann <ann@example.net>")
    }

    @Test func testFailedSendStaysForADecision() async throws {
        let e = try makeEngine()
        MockServer.reset { c in
            if let b = baseAnswer(c) { return b }
            return (400, ["error": ["message": "Invalid To header"]])
        }
        _ = try await e.outbox.enqueue(mail)
        await e.outbox.tick(now: Date().addingTimeInterval(6))
        let rows = try await e.outbox.rows()
        XCTAssertEqual(rows.first?.status, .failed)
        XCTAssertEqual(rows.first?.lastError?.contains("Invalid To header"), true)
    }

    @Test func testOverdueScheduledMailWaitsAfterRestart() async throws {
        let e = try makeEngine()
        sendAnswers()
        _ = try await e.outbox.enqueue(mail, sendAt: Date().addingTimeInterval(-3600))
        try await e.outbox.markOverdueAtLaunch()
        await e.outbox.tick()
        XCTAssertTrue(MockServer.recorded("/messages/send").isEmpty, "Never goes out unannounced")
        let rows = try await e.outbox.rows()
        XCTAssertEqual(rows.first?.status, .overdue)
        try await e.outbox.sendNow(id: rows[0].id)
        await e.outbox.tick()
        XCTAssertEqual(MockServer.recorded("/messages/send").count, 1)
    }

    @Test func testEditingPausesAScheduledMail() async throws {
        let e = try makeEngine()
        sendAnswers()
        let row = try await e.outbox.enqueue(mail, sendAt: Date().addingTimeInterval(60))
        let taken = try await e.outbox.takeForEdit(id: row.id)
        XCTAssertEqual(taken?.row.status, .pending, "Hands back the row as it was, so the composer knows it was scheduled")
        XCTAssertEqual(taken?.mail.subject, "Hi")
        XCTAssertEqual(try await e.outbox.rows().first?.status, .held)
        await e.outbox.tick(now: Date().addingTimeInterval(120))
        XCTAssertTrue(MockServer.recorded("/messages/send").isEmpty, "Never goes out under an open edit")
        let sentNow = try await e.outbox.sendNow(id: row.id)
        let moved = try await e.outbox.reschedule(id: row.id, to: Date())
        XCTAssertFalse(sentNow || moved, "Send Now and Reschedule leave an edited mail alone")
        // Closed without sending, saving or discarding: back on its schedule.
        try await e.outbox.release(id: row.id)
        XCTAssertEqual(try await e.outbox.rows().first?.status, .pending)
        await e.outbox.tick(now: Date().addingTimeInterval(120))
        XCTAssertEqual(MockServer.recorded("/messages/send").count, 1)
    }

    @Test func testEditClosedAfterItsTimeWaitsForADecision() async throws {
        let e = try makeEngine()
        sendAnswers()
        let row = try await e.outbox.enqueue(mail, sendAt: Date().addingTimeInterval(60))
        _ = try await e.outbox.takeForEdit(id: row.id)
        try await e.outbox.release(id: row.id, now: Date().addingTimeInterval(120))
        await e.outbox.tick(now: Date().addingTimeInterval(180))
        XCTAssertTrue(MockServer.recorded("/messages/send").isEmpty, "Never goes out late unannounced")
        XCTAssertEqual(try await e.outbox.rows().first?.status, .overdue)
    }

    @Test func testEditingAnOverdueMailDoesNotPauseIt() async throws {
        let e = try makeEngine()
        let row = try await e.outbox.enqueue(mail, sendAt: Date().addingTimeInterval(-60))
        try await e.outbox.markOverdueAtLaunch()
        let taken = try await e.outbox.takeForEdit(id: row.id)
        XCTAssertEqual(taken?.row.status, .overdue)
        XCTAssertEqual(try await e.outbox.rows().first?.status, .overdue, "Already waiting, it stays in the banner")
    }

    @Test func testPausedMailReturnsToItsScheduleAfterRestart() async throws {
        let e = try makeEngine()
        let ahead = try await e.outbox.enqueue(mail, sendAt: Date().addingTimeInterval(3600))
        let past = try await e.outbox.enqueue(mail, sendAt: Date().addingTimeInterval(60))
        _ = try await e.outbox.takeForEdit(id: ahead.id)
        _ = try await e.outbox.takeForEdit(id: past.id)
        try await e.outbox.markOverdueAtLaunch(now: Date().addingTimeInterval(120))
        let status = Dictionary(uniqueKeysWithValues: try await e.outbox.rows().map { ($0.id, $0.status) })
        XCTAssertEqual(status[ahead.id], .pending)
        XCTAssertEqual(status[past.id], .overdue)
    }

    @Test func testRescheduleMovesTheSendTime() async throws {
        let e = try makeEngine()
        sendAnswers()
        let row = try await e.outbox.enqueue(mail, sendAt: Date().addingTimeInterval(3600))
        let moved = try await e.outbox.reschedule(id: row.id, to: Date().addingTimeInterval(60))
        XCTAssertTrue(moved)
        await e.outbox.tick(now: Date().addingTimeInterval(120))
        XCTAssertEqual(MockServer.recorded("/messages/send").count, 1)
        let gone = try await e.outbox.reschedule(id: row.id, to: Date())
        XCTAssertFalse(gone, "Already sent")
    }

    @Test func testRescheduleBringsBackAFailedMail() async throws {
        let e = try makeEngine()
        let row = try await e.outbox.enqueue(mail, sendAt: Date().addingTimeInterval(-60))
        try await e.db.pool.write { try $0.execute(sql: "UPDATE outbox SET status = 'failed', lastError = 'boom' WHERE id = ?", arguments: [row.id]) }
        let later = Date().addingTimeInterval(3600)
        XCTAssertTrue(try await e.outbox.reschedule(id: row.id, to: later))
        let r = try await e.outbox.rows().first
        XCTAssertEqual(r?.status, .pending)
        XCTAssertNil(r?.lastError)
        XCTAssertEqual(r?.sendAt.timeIntervalSince(later) ?? 99, 0, accuracy: 0.01)
    }

    func offlineAnswers() { MockServer.reset { _ in (MockServer.offline, [:]) } }

    @Test func testMailDueWhileOfflineGoesWhenTheNetworkIsBack() async throws {
        let e = try makeEngine()
        offlineAnswers()
        _ = try await e.outbox.enqueue(mail, sendAt: Date().addingTimeInterval(-60))
        await e.outbox.tick()
        let r = try await e.outbox.rows().first
        XCTAssertEqual(r?.status, .waiting, "No connection is not a failure")
        XCTAssertEqual(r?.lastError, URLError(.notConnectedToInternet).localizedDescription)
        XCTAssertTrue(MockServer.recorded("/messages/send").isEmpty, "The sign-in token couldn't be fetched, so nothing was sent")
        sendAnswers()
        await e.outbox.networkChanged(available: true)
        await e.outbox.tick()
        XCTAssertEqual(MockServer.recorded("/messages/send").count, 1)
        XCTAssertTrue(try await e.outbox.rows().isEmpty)
    }

    @Test func testOfflineSendIsTriedAgainEveryHalfMinute() async throws {
        let e = try makeEngine()
        // The token is at hand; the send itself finds no network.
        MockServer.reset { c in baseAnswer(c) ?? (MockServer.offline, [:]) }
        _ = try await e.outbox.enqueue(mail, sendAt: Date().addingTimeInterval(-60))
        await e.outbox.tick()
        XCTAssertEqual(try await e.outbox.rows().first?.status, .waiting)
        sendAnswers()
        await e.outbox.tick(now: Date().addingTimeInterval(10))
        XCTAssertTrue(MockServer.recorded("/messages/send").isEmpty, "Not tried again straight away")
        await e.outbox.tick(now: Date().addingTimeInterval(31))
        XCTAssertEqual(MockServer.recorded("/messages/send").count, 1)
    }

    @Test func testNoRetryWhileMacOSSaysTheNetworkIsDown() async throws {
        let e = try makeEngine()
        offlineAnswers()
        await e.outbox.networkChanged(available: false)
        _ = try await e.outbox.enqueue(mail, sendAt: Date().addingTimeInterval(-60))
        await e.outbox.tick()
        XCTAssertEqual(try await e.outbox.rows().first?.status, .waiting)
        sendAnswers()
        await e.outbox.tick(now: Date().addingTimeInterval(120))
        XCTAssertTrue(MockServer.recorded("/messages/send").isEmpty)
        await e.outbox.networkChanged(available: true)
        await e.outbox.tick()
        XCTAssertEqual(MockServer.recorded("/messages/send").count, 1, "Goes the moment the network is back")
    }

    @Test func testDroppedConnectionWhileSendingNeedsADecision() async throws {
        let e = try makeEngine()
        MockServer.reset { c in baseAnswer(c) ?? (MockServer.connectionLost, [:]) }
        _ = try await e.outbox.enqueue(mail, sendAt: Date().addingTimeInterval(-60))
        await e.outbox.tick()
        let r = try await e.outbox.rows().first
        XCTAssertEqual(r?.status, .failed, "It may have gone out, so it never goes again by itself")
        XCTAssertEqual(r?.lastError?.contains("check Sent"), true)
    }

    @Test func testWaitingMailPausesForEditingAndAsksAfterARestart() async throws {
        let e = try makeEngine()
        offlineAnswers()
        let a = try await e.outbox.enqueue(mail, sendAt: Date().addingTimeInterval(-60))
        await e.outbox.tick()
        let taken = try await e.outbox.takeForEdit(id: a.id)
        XCTAssertEqual(taken?.row.status, .waiting)
        XCTAssertEqual(try await e.outbox.rows().first?.status, .held, "Can't go out under an open edit")
        try await e.outbox.release(id: a.id)
        XCTAssertEqual(try await e.outbox.rows().first?.status, .overdue, "Closed after its time, it waits for a decision")
        let b = try await e.outbox.enqueue(mail, sendAt: Date().addingTimeInterval(-30))
        await e.outbox.tick()
        let waiting = try await e.outbox.rows().first { $0.id == b.id }
        XCTAssertEqual(waiting?.status, .waiting)
        try await e.outbox.markOverdueAtLaunch()
        XCTAssertEqual(try await e.outbox.rows().map(\.status), [.overdue, .overdue], "After a restart it never goes unannounced")
    }

    @Test func testOnlyFailuresBeforeLeavingTheMacCountAsOffline() {
        XCTAssertTrue(Outbox.neverLeft(URLError(.notConnectedToInternet)))
        XCTAssertTrue(Outbox.neverLeft(URLError(.cannotFindHost)))
        XCTAssertFalse(Outbox.neverLeft(URLError(.networkConnectionLost)))
        XCTAssertFalse(Outbox.neverLeft(URLError(.timedOut)))
        XCTAssertFalse(Outbox.neverLeft(GoogleAPIError(status: 400, message: "Invalid To header")))
    }

    @Test func testScheduledListLeavesOutTheUndoWindow() async throws {
        let e = try makeEngine()
        _ = try await e.outbox.enqueue(mail)
        let later = try await e.outbox.enqueue(mail, sendAt: Date().addingTimeInterval(3600))
        let listed = try await e.db.pool.read { try OutboxRow.listed($0) }
        XCTAssertEqual(listed.map(\.id), [later.id])
    }
}

@Suite(.serialized) struct SnoozeTests {
    @Test func testSnoozeHidesThenWakesUnread() async throws {
        let e = try makeEngine()
        let dto = try JSONDecoder().decode(GmailThreadDTO.self, from: JSONSerialization.data(withJSONObject: ["id": "t", "messages": [gmailMessage(id: "m", thread: "t")]]))
        try await GmailSync.store(db: e.db, accountId: "a@example.com", dto: dto)
        MockServer.reset { c in
            if c.path.hasSuffix("/token") { return (200, ["access_token": "tok", "expires_in": 3600]) }
            if c.path.hasSuffix("/labels"), c.method == "POST" { return (200, ["id": "Label_S", "name": GmailLabel.snoozedName]) }
            if c.path.hasSuffix("/modify") { return (200, [:]) }
            return (404, [:])
        }
        try await e.mail.snooze(accountId: "a@example.com", threadId: "t", until: Date().addingTimeInterval(3600))
        var inbox = try await e.mail.threads(ThreadQuery(folder: .inbox))
        XCTAssertTrue(inbox.isEmpty)
        let snoozed = try await e.mail.threads(ThreadQuery(folder: .snoozed))
        XCTAssertEqual(snoozed.count, 1)
        let first = try JSONSerialization.jsonObject(with: MockServer.recorded("/modify")[0].body) as! [String: [String]]
        XCTAssertEqual(first["addLabelIds"], ["Label_S"])
        XCTAssertEqual(first["removeLabelIds"], ["INBOX"])

        let notYet = await e.mail.wakeDueSnoozes()
        XCTAssertEqual(notYet, 0)
        let woke = await e.mail.wakeDueSnoozes(now: Date().addingTimeInterval(7200))
        XCTAssertEqual(woke, 1)
        inbox = try await e.mail.threads(ThreadQuery(folder: .inbox))
        XCTAssertEqual(inbox.count, 1)
        XCTAssertTrue(inbox[0].isUnread)
    }

    @Test func testNewMailEndsSnooze() async throws {
        let e = try makeEngine()
        try await e.db.pool.write { try SnoozeRow(accountId: "a@example.com", threadId: "t", wakeAt: Date().addingTimeInterval(3600)).save($0) }
        let dto = try JSONDecoder().decode(GmailThreadDTO.self, from: JSONSerialization.data(withJSONObject: ["id": "t", "messages": [gmailMessage(id: "m", thread: "t", labels: ["INBOX"])]]))
        try await GmailSync.store(db: e.db, accountId: "a@example.com", dto: dto)
        let wake = try await e.mail.snoozeWake(accountId: "a@example.com", threadId: "t")
        XCTAssertNil(wake)
    }
}

@Suite(.serialized) struct ComposeTests {
    @Test func testSignatureAndReplyThreading() async throws {
        let e = try makeEngine()
        let dto = try JSONDecoder().decode(GmailThreadDTO.self, from: JSONSerialization.data(withJSONObject: ["id": "t", "messages": [gmailMessage(id: "m", thread: "t", subject: "Offerte")]]))
        try await GmailSync.store(db: e.db, accountId: "a@example.com", dto: dto)
        try e.db.setSetting("signature.a@example.com", "<b>Anna</b>")
        let addr = try await e.mail.replyAddressing(accountId: "a@example.com", messageId: "m", replyAll: false)
        XCTAssertEqual(addr.subject, "Re: Offerte")
        XCTAssertEqual(addr.to, ["Ann <ann@example.net>"])
        var i = ComposeInput(accountId: "a@example.com", to: addr.to, subject: addr.subject, text: "Dag An")
        i.replyTo = ("a@example.com", "m")
        let mail = try await e.mail.prepare(i)
        XCTAssertEqual(mail.threadId, "t")
        XCTAssertEqual(mail.inReplyTo, "<m@x>")
        XCTAssertTrue(mail.htmlBody!.contains("<b>Anna</b>"))
        XCTAssertTrue(mail.textBody.contains("Anna"))
    }

    @Test func testPerAccountSignatureIsSeparate() async throws {
        let e = try makeEngine(accounts: ["a@example.com", "b@example.com"])
        try e.db.setSetting("signature.a@example.com", "Sig A")
        try e.db.setSetting("signature.b@example.com", "Sig B")
        let a = try await e.mail.prepare(ComposeInput(accountId: "a@example.com", to: ["x@y.be"], subject: "s", text: "t"))
        let b = try await e.mail.prepare(ComposeInput(accountId: "b@example.com", to: ["x@y.be"], subject: "s", text: "t"))
        XCTAssertTrue(a.htmlBody!.contains("Sig A"))
        XCTAssertTrue(b.htmlBody!.contains("Sig B"))
    }

    @Test func testRecipientRequired() async throws {
        let e = try makeEngine()
        do {
            _ = try await e.mail.prepare(ComposeInput(accountId: "a@example.com", to: [], subject: "s", text: "t"))
            XCTFail("should throw")
        } catch {}
    }

    @Test func testSuggestionsIncludeCalendarGuestsOnceEach() async throws {
        let e = try makeEngine()
        let dto = try JSONDecoder().decode(GmailThreadDTO.self, from: JSONSerialization.data(withJSONObject: ["id": "t", "messages": [gmailMessage(id: "m", thread: "t", from: "An Peeters <An@example.net>")]]))
        try await GmailSync.store(db: e.db, accountId: "a@example.com", dto: dto)
        let guests = "[{\"email\":\"an@example.net\",\"response\":\"accepted\",\"isSelf\":false,\"isOrganizer\":false},"
            + "{\"email\":\"bert@example.org\",\"name\":\"Bert Peeters\",\"response\":\"accepted\",\"isSelf\":false,\"isOrganizer\":false},"
            + "{\"email\":\"me@peeters.be\",\"response\":\"accepted\",\"isSelf\":true,\"isOrganizer\":true}]"
        try await e.db.pool.write { db in
            try CalendarRecord(accountId: "a@example.com", calendarId: "c", summary: "c", colorHex: "#000", isPrimary: true, isSelected: true,
                               accessRole: "owner", syncToken: nil, lastFullSyncAt: nil).insert(db)
            for id in ["e1", "e2"] {
                try CalendarEvent(accountId: "a@example.com", calendarId: "c", eventId: id, summary: "Plaatsing", details: "", location: "",
                                  startAt: Date(), endAt: Date().addingTimeInterval(3600), isAllDay: false, status: "confirmed", transparency: "opaque",
                                  organizerEmail: "me@peeters.be", attendeesJSON: guests, selfResponse: "accepted", meetingLink: nil, htmlLink: nil,
                                  recurringEventId: nil).insert(db)
            }
        }
        let suggested = try await e.mail.contacts(matching: "peeters")
        // An's invites list only her address, yet count for her: three in all, so she comes first, once, with her name.
        // Bert is only in invites. You are left out.
        XCTAssertEqual(suggested, ["An Peeters <an@example.net>", "Bert Peeters <bert@example.org>"])
    }

    @Test func testSenderWithCommaInNameStaysOneRecipient() async throws {
        let e = try makeEngine()
        let dto = try JSONDecoder().decode(GmailThreadDTO.self, from: JSONSerialization.data(withJSONObject: ["id": "t", "messages": [gmailMessage(id: "m", thread: "t", from: "\"Peeters, An\" <an@example.net>")]]))
        try await GmailSync.store(db: e.db, accountId: "a@example.com", dto: dto)

        // The composer joins these into one line and splits it again when sending, so check that round trip.
        let addr = try await e.mail.replyAddressing(accountId: "a@example.com", messageId: "m", replyAll: false)
        let suggested = try await e.mail.contacts(matching: "peeters")
        XCTAssertEqual(suggested, ["\"Peeters, An\" <an@example.net>"])
        for line in [addr.to.joined(separator: ", "), suggested[0]] {
            let to = GmailParser.splitAddresses(line)
            XCTAssertEqual(to.count, 1)
            let mail = try await e.mail.prepare(ComposeInput(accountId: "a@example.com", to: to, subject: "s", text: "t"))
            let raw = String(decoding: try MIMEBuilder.build(mail), as: UTF8.self)
            XCTAssertTrue(raw.contains("To: \"Peeters, An\" <an@example.net>"))
        }
    }

    @Test func testEditingAQueuedReplyKeepsThreadAndDoesNotDoubleTheSignature() async throws {
        let e = try makeEngine()
        let dto = try JSONDecoder().decode(GmailThreadDTO.self, from: JSONSerialization.data(withJSONObject: ["id": "t", "messages": [gmailMessage(id: "m", thread: "t", from: "\"Peeters, An\" <an@example.net>", subject: "Offerte")]]))
        try await GmailSync.store(db: e.db, accountId: "a@example.com", dto: dto)
        try e.db.setSetting("signature.a@example.com", "<b>Anna</b>")
        let parent = try await e.mail.detail(accountId: "a@example.com", threadId: "t").messages[0]

        var i = ComposeInput(accountId: "a@example.com", to: ["\"Peeters, An\" <an@example.net>"], subject: "Re: Offerte", text: "Dag An")
        i.replyTo = ("a@example.com", "m")
        i.quotedHtml = e.mail.quotedBlock(message: parent)
        let original = try await e.mail.prepare(i)

        let edit = try await e.mail.editable(original)
        XCTAssertEqual(edit.text, "Dag An")
        XCTAssertEqual(edit.to, "\"Peeters, An\" <an@example.net>")
        XCTAssertEqual(edit.replyTo?.messageId, "m")
        XCTAssertEqual(edit.quotedHtml, i.quotedHtml)

        var again = ComposeInput(accountId: "a@example.com", to: GmailParser.splitAddresses(edit.to), subject: original.subject, text: edit.text)
        again.replyTo = edit.replyTo
        again.quotedHtml = edit.quotedHtml
        let resent = try await e.mail.prepare(again)
        XCTAssertEqual(resent.textBody, original.textBody)
        XCTAssertEqual(resent.htmlBody, original.htmlBody)
        XCTAssertEqual(resent.threadId, "t")
        XCTAssertEqual(resent.inReplyTo, original.inReplyTo)
    }

    @Test func testQueuedMailStaysQueuedWhileEditing() async throws {
        let e = try makeEngine()
        let mail = OutgoingMail(accountId: "a@example.com", to: ["b@example.com"], subject: "Hi", textBody: "text")
        let row = try await e.outbox.enqueue(mail, sendAt: Date().addingTimeInterval(-60))
        try await e.outbox.markOverdueAtLaunch()
        let read = try await e.outbox.queuedMail(id: row.id)
        XCTAssertEqual(read?.subject, "Hi")
        let rows = try await e.outbox.rows()
        XCTAssertEqual(rows.count, 1)
    }

    @Test func testRecipientWithoutAddressIsRefusedBeforeQueueing() async throws {
        let e = try makeEngine()
        let line = GmailParser.splitAddresses("Peeters, An <an@example.net>")
        do {
            _ = try await e.mail.prepare(ComposeInput(accountId: "a@example.com", to: line, subject: "s", text: "t"))
            XCTFail("should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("“Peeters”"))
        }
        XCTAssertTrue(GmailParser.isValidRecipient("\"Peeters, An\" <an@example.net>"))
        XCTAssertTrue(GmailParser.isValidRecipient("an@example.net"))
        XCTAssertFalse(GmailParser.isValidRecipient("an@"))
        XCTAssertFalse(GmailParser.isValidRecipient("An <>"))
    }

    @Test func testReplyAllSkipsSelf() async throws {
        let e = try makeEngine()
        let dto = try JSONDecoder().decode(GmailThreadDTO.self, from: JSONSerialization.data(withJSONObject: ["id": "t", "messages": [gmailMessage(id: "m", thread: "t", to: "a@example.com, Bob <bob@x.be>")]]))
        try await GmailSync.store(db: e.db, accountId: "a@example.com", dto: dto)
        let addr = try await e.mail.replyAddressing(accountId: "a@example.com", messageId: "m", replyAll: true)
        XCTAssertEqual(addr.cc, ["Bob <bob@x.be>"])
    }

    @Test func testManualSenderCorrectionAppliesToNewMail() async throws {
        let e = try makeEngine()
        let dto = try JSONDecoder().decode(GmailThreadDTO.self, from: JSONSerialization.data(withJSONObject: ["id": "t", "messages": [gmailMessage(id: "m", thread: "t", labels: ["INBOX", "CATEGORY_PERSONAL"])]]))
        try await GmailSync.store(db: e.db, accountId: "a@example.com", dto: dto)
        try await e.mail.setBucket(accountId: "a@example.com", threadId: "t", bucket: .newsletters)
        let next = try JSONDecoder().decode(GmailThreadDTO.self, from: JSONSerialization.data(withJSONObject: ["id": "t2", "messages": [gmailMessage(id: "m2", thread: "t2", labels: ["INBOX", "CATEGORY_PERSONAL"])]]))
        try await GmailSync.store(db: e.db, accountId: "a@example.com", dto: next)
        let t2 = try await e.db.pool.read { try MailThread.fetchOne($0, key: ["accountId": "a@example.com", "threadId": "t2"]) }
        XCTAssertEqual(t2?.bucket, "newsletters")
        XCTAssertEqual(t2?.needsAIClassification, false)
    }
}

@Suite(.serialized) struct RichTextTests {
    @Test @MainActor func testDarkModeTextNeverExportsAsWhite() {
        let saved = NSAppearance.currentDrawing()
        NSAppearance.current = NSAppearance(named: .darkAqua)
        defer { NSAppearance.current = saved }
        let s = NSAttributedString(string: "Dag An", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor])
        let html = RichTextHTML.html(from: s)
        XCTAssertTrue(html.contains("Dag An"))
        XCTAssertFalse(html.lowercased().contains("color:"), html)
    }

    @Test @MainActor func testFormattingAndEscaping() {
        let m = NSMutableAttributedString(string: "a<b>\n", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        m.append(NSAttributedString(string: "vet", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)]))
        m.append(NSAttributedString(string: " rood", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)]))
        m.append(NSAttributedString(string: " site", attributes: [.link: URL(string: "https://example.com")!]))
        m.append(NSAttributedString(string: " bad", attributes: [.link: "javascript:alert(1)"]))
        let html = RichTextHTML.html(from: m)
        XCTAssertTrue(html.contains("a&lt;b&gt;<br>"), html)
        XCTAssertTrue(html.contains("<b>vet</b>"), html)
        XCTAssertTrue(html.contains("color:#ff0000"), html)
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">"), html)
        XCTAssertFalse(html.contains("javascript:"), html)
    }

    @Test @MainActor func testListsBecomeHTMLLists() {
        let f: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14)]
        let m = NSMutableAttributedString(string: "Agenda:\n• Planning\n• ", attributes: f)
        m.append(NSAttributedString(string: "Prijs", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)]))
        m.append(NSAttributedString(string: "\n1. Eerst\n2. Dan\nGroet\n", attributes: f))
        let html = RichTextHTML.html(from: m)
        XCTAssertTrue(html.contains("Agenda:<ul style=\"margin:0;padding-left:1.4em\"><li>Planning</li><li><b>Prijs</b></li></ul>"), html)
        XCTAssertTrue(html.contains("<ol style=\"margin:0;padding-left:1.4em\"><li>Eerst</li><li>Dan</li></ol>Groet<br></div>"), html)
        XCTAssertEqual(RichTextHTML.plainText(from: m), m.string, "The plain-text version keeps the markers")
        // Without lists the line breaks come out as before.
        XCTAssertTrue(RichTextHTML.html(from: NSAttributedString(string: "a\n\nb\n", attributes: f)).contains(">a<br><br>b<br></div>"))
    }

    @Test func testListLinesToggleAndContinue() {
        let typing: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14)]
        func toggled(_ kind: RichTextList.Kind, _ s: String) -> String {
            RichTextList.toggled(kind, in: NSAttributedString(string: s, attributes: typing), typing: typing).string
        }
        XCTAssertEqual(toggled(.bullet, "Planning\n\nPrijs\n"), "• Planning\n\n• Prijs\n", "Blank lines stay blank")
        XCTAssertEqual(toggled(.bullet, "• Planning\n• Prijs"), "Planning\nPrijs", "Off again")
        XCTAssertEqual(toggled(.number, "• Planning\nPrijs"), "1. Planning\n2. Prijs", "Bullets become numbers")
        XCTAssertEqual(toggled(.number, ""), "1. ", "An empty line starts a list")
        XCTAssertEqual(RichTextList.continuation(of: "• Planning"), .next("• "))
        XCTAssertEqual(RichTextList.continuation(of: "9. Dan"), .next("10. "))
        XCTAssertEqual(RichTextList.continuation(of: "• "), .end, "Return on an empty item ends the list")
        XCTAssertEqual(RichTextList.continuation(of: "2026. Een jaartal"), .notList)
        XCTAssertEqual(RichTextList.continuation(of: "Gewoon"), .notList)
    }

    @Test @MainActor func testPastedPictureBecomesAnInlineImage() {
        let image = NSImage(size: NSSize(width: 1200, height: 600), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
        let att = NSTextAttachment()
        att.image = image
        att.bounds = CGRect(x: 0, y: 0, width: 560, height: 280)
        let m = NSMutableAttributedString(string: "Zie hier:\n", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        m.append(NSAttributedString(attachment: att))
        m.append(NSAttributedString(string: "\nGroet"))
        let c = RichTextHTML.content(from: m)
        XCTAssertEqual(c.images.count, 1)
        XCTAssertTrue(c.images.first?.mimeType == "image/png" || c.images.first?.mimeType == "image/jpeg")
        XCTAssertTrue(c.html.contains("<img src=\"cid:\(c.images.first!.contentId)\" width=\"560\""), c.html)
        XCTAssertEqual(RichTextHTML.plainText(from: m), "Zie hier:\n[image]\nGroet")
    }
}

@Suite(.serialized) struct FollowUpTests {
    let a = "a@example.com"

    func store(_ e: Engine, _ id: String, messages: [[String: Any]]) async throws {
        let dto = try JSONDecoder().decode(GmailThreadDTO.self, from: JSONSerialization.data(withJSONObject: ["id": id, "messages": messages]))
        try await GmailSync.store(db: e.db, accountId: a, dto: dto)
    }

    @Test func testWorkingDaysSkipTheWeekend() {
        let c = Calendar(identifier: .gregorian)
        let friday = c.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 10))!
        XCTAssertEqual(c.component(.weekday, from: FollowUps.workingDays(1, after: friday, calendar: c)), 2, "Friday + 1 is Monday")
        let thursday = c.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 10))!
        XCTAssertEqual(c.component(.day, from: FollowUps.workingDays(3, after: thursday, calendar: c)), 10, "Thursday + 3 is Tuesday")
    }

    @Test func testSendingWithAReminderStartsWatching() async throws {
        let e = try makeEngine()
        MockServer.reset { c in
            if let b = baseAnswer(c) { return b }
            if c.path.hasSuffix("/messages/send") { return (200, ["id": "sent1", "threadId": "t1"]) }
            if c.path.hasSuffix("/threads/t1") { return (200, ["id": "t1", "messages": [gmailMessage(id: "sent1", thread: "t1", from: "a@example.com", labels: ["SENT"])]]) }
            return (404, [:])
        }
        var m = OutgoingMail(accountId: a, to: ["b@example.com"], subject: "Offerte", textBody: "text")
        m.followUp = .workingDays(3)
        _ = try await e.outbox.enqueue(m)
        await e.outbox.tick(now: Date().addingTimeInterval(6))
        let f = try await e.db.pool.read { try FollowUpRecord.fetchOne($0, key: "sent1") }
        XCTAssertEqual(f?.threadId, "t1")
        XCTAssertEqual(f?.status, .waiting)
        XCTAssertTrue((f?.dueAt ?? .distantPast) > Date().addingTimeInterval(2 * 86400))
        // Without a reminder nothing is watched.
        _ = try await e.outbox.enqueue(OutgoingMail(accountId: a, to: ["b@example.com"], subject: "Gewoon", textBody: "t"))
        await e.outbox.tick(now: Date().addingTimeInterval(6))
        XCTAssertEqual(try await e.db.pool.read { try FollowUpRecord.fetchCount($0) }, 1)
    }

    @Test func testReplyEndsItAndSilenceBringsTheThreadBackOnTop() async throws {
        let e = try makeEngine()
        MockServer.reset { c in baseAnswer(c) ?? (200, ["id": "x"]) }
        // Two sent mails with reminders, and a newer unrelated thread in the inbox.
        try await store(e, "quiet", messages: [gmailMessage(id: "s1", thread: "quiet", from: "a@example.com", subject: "Offerte", labels: ["SENT"], hoursAgo: 100)])
        try await store(e, "answered", messages: [gmailMessage(id: "s2", thread: "answered", from: "a@example.com", subject: "Demo", labels: ["SENT"], hoursAgo: 100),
                                                   gmailMessage(id: "r2", thread: "answered", from: "Jan <jan@x.be>", subject: "Re: Demo", labels: ["INBOX"], hoursAgo: 50)])
        try await store(e, "newer", messages: [gmailMessage(id: "n1", thread: "newer", labels: ["INBOX"], hoursAgo: 1)])
        let sent = Date().addingTimeInterval(-100 * 3600)
        try await e.followUps.track(FollowUpRecord(id: "s1", accountId: a, threadId: "quiet", subject: "Offerte", recipients: "b@x.be", sentAt: sent, dueAt: Date().addingTimeInterval(-60)))
        try await e.followUps.track(FollowUpRecord(id: "s2", accountId: a, threadId: "answered", subject: "Demo", recipients: "jan@x.be", sentAt: sent, dueAt: Date().addingTimeInterval(-60)))

        let fell = await e.followUps.check()
        XCTAssertEqual(fell.map(\.id), ["s1"])
        let shown = try await e.db.pool.read { try FollowUps.open($0, accountId: "a@example.com", threadId: "quiet") }
        XCTAssertEqual(shown?.status, .due, "What the thread's bar and the list's badge read")
        XCTAssertEqual(try await e.db.pool.read { try FollowUpRecord.fetchOne($0, key: "s2") }?.status, .replied)
        XCTAssertTrue(MockServer.recorded("/threads/quiet/modify", method: "POST").count == 1, "Back in the inbox at Gmail too")
        let inbox = try await e.mail.threads(ThreadQuery(folder: .inbox))
        XCTAssertEqual(inbox.first?.threadId, "quiet", "On top, above newer mail")
        XCTAssertTrue(inbox.first?.isUnread == true)

        // Sending the nudge closes it, and the thread sorts by its own date again.
        try await store(e, "quiet", messages: [gmailMessage(id: "s1", thread: "quiet", from: "a@example.com", subject: "Offerte", labels: ["SENT", "INBOX"], hoursAgo: 100),
                                                gmailMessage(id: "s3", thread: "quiet", from: "a@example.com", subject: "Re: Offerte", labels: ["SENT"], hoursAgo: -0.01)])
        _ = await e.followUps.check()
        XCTAssertEqual(try await e.db.pool.read { try FollowUpRecord.fetchOne($0, key: "s1") }?.status, .done)
    }

    @Test func testNudgeSamplesLeaveOutQuotes() {
        XCTAssertEqual(FollowUpWriter.ownText("Dag Jan,\n\nHier is de offerte.\n\nGroeten,\nAnna\n\nOp 4 nov. 2026 schreef Jan:\n> Kan je iets sturen?"),
                       "Dag Jan,\n\nHier is de offerte.\n\nGroeten,\nAnna")
    }
}

/// Mail Postvak writes goes out from the address of its project, not from whichever account holds the thread.
@Suite(.serialized) struct SenderTests {
    static let personal = "anna@gmail.com", company = "anna@zonnehoek.be"

    func setUp() throws -> Engine {
        let e = try makeEngine(accounts: [Self.personal, Self.company])
        let config = ProjectConfig(projects: [ProjectRule(name: "Personal", accounts: [Self.personal]),
                                              ProjectRule(name: "Zonnehoek", accounts: [Self.company], addresses: ["info@zonnehoek.be"], domains: ["zonnehoek.be"])])
        try e.db.pool.write { db in
            try db.execute(sql: "INSERT INTO setting (key, value) VALUES (?, ?)",
                           arguments: [ProjectConfig.settingKey, String(data: try JSONEncoder().encode(config), encoding: .utf8)!])
            try db.execute(sql: """
                INSERT INTO deal (key, isDeal, venture, company, contacts, stage, risk, nextStep, owner, due, amount, amountEUR, size, sizeSource, activityKey, analyzedAt)
                VALUES ('panelwerk.be', 1, 'Zonnehoek', 'Panelwerk', '', 'demo', '', '', '', '', '', 0, '', '', '', ?)
                """, arguments: [Date()])
        }
        MockServer.reset { c in
            if let b = baseAnswer(c) { return b }
            if c.path.hasSuffix("/settings/sendAs") {
                return (200, ["sendAs": [["sendAsEmail": Self.personal, "displayName": "Anna", "isPrimary": true, "signature": "Anna"],
                                         ["sendAsEmail": Self.company, "displayName": "Anna - Zonnehoek", "signature": "<b>Zonnehoek</b>", "verificationStatus": "accepted"],
                                         ["sendAsEmail": "old@zonnehoek.be", "displayName": "Old", "verificationStatus": "pending"]]])
            }
            if c.path.hasSuffix("/drafts"), c.method == "POST" { return (200, ["id": "d9", "message": ["id": "m9", "threadId": "t9"]]) }
            return (404, ["error": ["message": "unhandled \(c.path)"]])
        }
        return e
    }

    @Test func testNewMailToAProjectDealMovesToTheProjectAccount() async throws {
        let e = try setUp()
        let c = await e.mail.chooseSender(accountId: Self.personal, recipients: ["Jo Maes <jo@panelwerk.be>"], isReply: false)
        XCTAssertEqual(c.accountId, Self.company)
        XCTAssertNil(c.fromEmail)
        XCTAssertEqual(c.project, "Zonnehoek")
    }

    @Test func testReplyKeptInGmailGoesAsTheProjectAddress() async throws {
        let e = try setUp()
        let c = await e.mail.chooseSender(accountId: Self.personal, recipients: ["jo@panelwerk.be"], isReply: true)
        XCTAssertEqual(c.accountId, Self.personal, "A reply stays in the account holding its thread")
        XCTAssertEqual(c.fromEmail, Self.company)
    }

    @Test func testPersonalMailIsLeftAlone() async throws {
        let e = try setUp()
        let c = await e.mail.chooseSender(accountId: Self.personal, recipients: ["friend@telenet.be"], isReply: false)
        XCTAssertEqual(c, SenderChoice(accountId: Self.personal, fromEmail: nil, project: nil, reason: nil))
        let already = await e.mail.chooseSender(accountId: Self.company, recipients: ["jo@panelwerk.be"], isReply: true)
        XCTAssertNil(already.fromEmail, "Already in the project's own account")
    }

    @Test func testSendingAsAnAliasUsesItsNameAndSignature() async throws {
        let e = try setUp()
        var i = ComposeInput(accountId: Self.personal, to: ["jo@panelwerk.be"], subject: "Offerte", text: "Dag Jo")
        i.fromEmail = Self.company
        let mail = try await e.mail.prepare(i)
        XCTAssertEqual(mail.fromEmail, Self.company)
        XCTAssertEqual(mail.fromName, "Anna - Zonnehoek")
        XCTAssertEqual(mail.htmlBody?.contains("<b>Zonnehoek</b>"), true)
        let raw = String(data: try MIMEBuilder.build(mail), encoding: .utf8)!
        XCTAssertTrue(raw.contains("<\(Self.company)>"), "The From header carries the alias")
        XCTAssertFalse(raw.contains("<\(Self.personal)>"))
    }

    @Test func testAnAddressGmailCannotSendAsIsRefused() async throws {
        let e = try setUp()
        for bad in ["old@zonnehoek.be", "someone@else.be"] {
            var i = ComposeInput(accountId: Self.personal, to: ["jo@panelwerk.be"], subject: "x", text: "y")
            i.fromEmail = bad
            do { _ = try await e.mail.prepare(i); XCTFail("\(bad) should be refused") } catch {}
        }
    }

    @Test func testClaudeCanSeeWhatIsAlreadyScheduled() async throws {
        let e = try setUp()
        var m = OutgoingMail(accountId: Self.personal, to: ["jo@panelwerk.be"], subject: "Opvolging demo", textBody: "Dag Jo")
        m.fromEmail = Self.company
        _ = try await e.outbox.enqueue(m, sendAt: Date().addingTimeInterval(3600))
        _ = try await e.outbox.enqueue(OutgoingMail(accountId: Self.personal, to: ["x@telenet.be"], subject: "Undo window", textBody: "t"))
        let s = MCPServer(tools: PostvakTools.all(engine: e, recorder: nil, ui: nil)) { "secret" }
        let r = await s.handle(MCPTests().req(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "list_scheduled", "arguments": [:]]]))
        let j = try JSONSerialization.jsonObject(with: r.body) as! [String: Any]
        let text = (((j["result"] as! [String: Any])["content"] as! [[String: Any]])[0]["text"] as! String)
        let rows = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [[String: Any]]
        XCTAssertEqual(rows.map { $0["subject"] as? String }, ["Opvolging demo"], "The undo window is left out")
        XCTAssertEqual(rows.first?["from"] as? String, Self.company)
    }

    @Test func testClaudeDraftForAProjectContactLandsInTheProjectAccount() async throws {
        let e = try setUp()
        let s = MCPServer(tools: PostvakTools.all(engine: e, recorder: nil, ui: nil)) { "secret" }
        let r = await s.handle(MCPTests().req(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": [
            "name": "create_draft", "arguments": ["account": Self.personal, "to": ["jo@panelwerk.be"], "subject": "Opvolging", "body": "Dag Jo"]]]))
        let j = try JSONSerialization.jsonObject(with: r.body) as! [String: Any]
        let text = (((j["result"] as! [String: Any])["content"] as! [[String: Any]])[0]["text"] as! String)
        let out = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        XCTAssertEqual(out["account"] as? String, Self.company)
        XCTAssertEqual(out["project"] as? String, "Zonnehoek")
        let raw = try JSONSerialization.jsonObject(with: MockServer.recorded("/drafts", method: "POST")[0].body) as! [String: Any]
        let mime = String(data: Data(base64URL: (raw["message"] as! [String: Any])["raw"] as! String)!, encoding: .utf8)!
        XCTAssertTrue(mime.contains("<\(Self.company)>"))
        let listed = try await e.autoDrafts.pending()
        XCTAssertEqual(listed.map(\.source), [.claude], "Claude's draft waits in Review Drafts")
        XCTAssertEqual(listed.first?.fromEmail, Self.company)
    }
}
