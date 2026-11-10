import Foundation
import Testing
@testable import PostvakCore
@testable import PostvakMCP

/// Files on drafts Claude writes through MCP: passed as paths, checked, and big ones uploaded the way Gmail wants.
@Suite(.serialized) struct DraftAttachmentTests {
    static let account = "a@example.com"

    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("postvak-att-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func file(_ dir: URL, _ name: String, bytes: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: UInt64(bytes))
        try h.close()
        return url
    }

    func call(_ e: Engine, _ args: [String: Any]) async throws -> (out: [String: Any]?, error: String?) {
        let s = MCPServer(tools: PostvakTools.all(engine: e, recorder: nil, ui: nil)) { "secret" }
        let r = await s.handle(MCPTests().req(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "create_draft", "arguments": args]]))
        let j = try JSONSerialization.jsonObject(with: r.body) as! [String: Any]
        let result = j["result"] as! [String: Any]
        let text = (result["content"] as! [[String: Any]])[0]["text"] as! String
        if result["isError"] as? Bool == true { return (nil, text) }
        return (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], nil)
    }

    func engine() throws -> Engine {
        let e = try makeEngine(accounts: [Self.account])
        MockServer.reset { c in
            if let b = baseAnswer(c) { return b }
            if c.path.hasSuffix("/settings/sendAs") { return (200, ["sendAs": [["sendAsEmail": Self.account, "isPrimary": true]]]) }
            if c.path.hasSuffix("/drafts"), c.method == "POST" { return (200, ["id": "d9", "message": ["id": "m9", "threadId": "t9"]]) }
            if c.path.hasSuffix("/drafts/d1"), c.method == "GET" { return (200, ["id": "d1", "message": ["id": "m1", "threadId": "t1"]]) }
            if c.path.hasSuffix("/drafts/d1"), c.method == "PUT" { return (200, ["id": "d1", "message": ["id": "m2", "threadId": "t1"]]) }
            if c.path.hasSuffix("/threads/t1") {
                var m = gmailMessage(id: "m1", thread: "t1", from: Self.account, to: "jo@example.net", subject: "Offerte", labels: ["DRAFT"])
                m["payload"] = ["mimeType": "multipart/mixed", "filename": "",
                                "headers": [["name": "From", "value": Self.account], ["name": "To", "value": "jo@example.net"], ["name": "Subject", "value": "Offerte"]],
                                "parts": [["partId": "0", "mimeType": "text/plain", "filename": "", "body": ["size": 3, "data": b64("Dag")]],
                                          ["partId": "1", "mimeType": "application/pdf", "filename": "offerte.pdf", "body": ["size": 7, "attachmentId": "att1"]]]] as [String: Any]
                return (200, ["id": "t1", "historyId": "10", "messages": [m]])
            }
            if c.path.hasSuffix("/attachments/att1") { return (200, ["data": b64("PDFDATA")]) }
            return (404, ["error": ["message": "unhandled \(c.path)"]])
        }
        return e
    }

    @Test func testFiveMegabyteFileGoesUpAsAMultipartUpload() async throws {
        let e = try engine()
        let pdf = try file(try tempDir(), "Offerte 2026.pdf", bytes: 5 * 1024 * 1024)
        let (out, err) = try await call(e, ["to": ["jo@example.net"], "subject": "Offerte", "body": "Dag Jo", "attachments": [pdf.path]])
        XCTAssertNil(err)
        XCTAssertEqual(out?["attachments"] as? [String], ["Offerte 2026.pdf"], "The result names the file, nothing of its content")
        let posts = MockServer.recorded("/drafts", method: "POST")
        XCTAssertEqual(posts.count, 1)
        let c = posts[0]
        XCTAssertTrue(c.path.hasPrefix("/upload/gmail/v1/users/me/drafts"), "Big mail uses Gmail's upload endpoint")
        XCTAssertEqual(c.query["uploadType"], "multipart")
        XCTAssertTrue(c.headers["Content-Type"]?.hasPrefix("multipart/related; boundary=") == true)
        let body = String(decoding: c.body, as: UTF8.self)
        XCTAssertTrue(body.contains("Content-Type: message/rfc822"))
        XCTAssertTrue(body.contains("Offerte 2026.pdf"))
        XCTAssertTrue(body.contains("{\"message\":{}}"), "Metadata travels as JSON next to the message")
        XCTAssertLessThanOrEqual(c.body.count, 7_500_000)   // base64 once, not twice
        XCTAssertEqual(try await e.autoDrafts.pending().count, 1, "Still waits in Review Drafts")
    }

    @Test func testSmallDraftStaysPlainJSON() async throws {
        let e = try engine()
        let txt = try file(try tempDir(), "notes.txt", bytes: 2000)
        let (_, err) = try await call(e, ["to": ["jo@example.net"], "subject": "Notes", "body": "Hier", "attachments": [txt.path]])
        XCTAssertNil(err)
        let c = MockServer.recorded("/drafts", method: "POST")[0]
        XCTAssertEqual(c.path, "/gmail/v1/users/me/drafts")
        let json = try JSONSerialization.jsonObject(with: c.body) as! [String: Any]
        let mime = String(data: Data(base64URL: (json["message"] as! [String: Any])["raw"] as! String)!, encoding: .utf8)!
        XCTAssertTrue(mime.contains("filename=notes.txt") || mime.contains("filename=\"notes.txt\""))
    }

    @Test func testPrivateFilesAreRefused() throws {
        let home = try tempDir()
        let paths = AppPaths(root: home.appendingPathComponent("Library/Application Support/Postvak"))
        try paths.createAll()
        let ok = try file(home, "Documents/plan.pdf", bytes: 10)
        for bad in [".ssh/id_ed25519", ".aws/credentials", "Projects/app/.env", "Library/Keychains/login.keychain-db",
                    "Library/Application Support/Postvak/postvak.sqlite"] {
            let u = try file(home, bad, bytes: 10)
            #expect(throws: ArgError.self, "\(bad) is refused") { try DraftFiles.resolve([u.path], paths: paths, home: home) }
        }
        #expect(throws: ArgError.self) { try DraftFiles.resolve(["/etc/hosts"], paths: paths, home: home) }
        #expect(throws: ArgError.self) { try DraftFiles.resolve(["Documents/plan.pdf"], paths: paths, home: home) }
        #expect(throws: ArgError.self) { try DraftFiles.resolve([home.appendingPathComponent("Documents/none.pdf").path], paths: paths, home: home) }
        // A link to a private file is judged by where it points.
        let link = home.appendingPathComponent("Documents/innocent.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent(".ssh/id_ed25519"))
        #expect(throws: ArgError.self) { try DraftFiles.resolve([link.path], paths: paths, home: home) }
        // Allowed: ordinary files, and files Postvak saved from mail (get_attachment) even though they sit in Library.
        let fromMail = try file(paths.attachments, "m1/invoice.pdf", bytes: 10)
        let got = try DraftFiles.resolve([ok.path, fromMail.path], paths: paths, home: home)
        XCTAssertEqual(got.map(\.filename), ["plan.pdf", "invoice.pdf"])
        XCTAssertEqual(got.first?.mimeType, "application/pdf")
    }

    @Test func testMoreThanGmailsLimitIsRefused() throws {
        let home = try tempDir()
        let paths = AppPaths(root: home.appendingPathComponent("Library/Application Support/Postvak"))
        let a = try file(home, "Documents/a.mov", bytes: 15 * 1024 * 1024)
        let b = try file(home, "Documents/b.mov", bytes: 15 * 1024 * 1024)
        #expect(throws: ArgError.self) { try DraftFiles.resolve([a.path, b.path], paths: paths, home: home) }
        XCTAssertEqual(try DraftFiles.resolve([a.path], paths: paths, home: home).count, 1)
    }

    @Test func testRewritingADraftKeepsItsFiles() async throws {
        let e = try engine()
        let (out, err) = try await call(e, ["account": Self.account, "draft_id": "d1", "to": ["jo@example.net"], "subject": "Offerte", "body": "Dag Jo, nieuwe tekst"])
        XCTAssertNil(err)
        XCTAssertEqual(out?["attachments"] as? [String], ["offerte.pdf"])
        let put = MockServer.recorded("/drafts/d1", method: "PUT")
        XCTAssertEqual(put.count, 1)
        let json = try JSONSerialization.jsonObject(with: put[0].body) as! [String: Any]
        let mime = String(data: Data(base64URL: (json["message"] as! [String: Any])["raw"] as! String)!, encoding: .utf8)!
        XCTAssertTrue(mime.contains("offerte.pdf"))
        XCTAssertTrue(mime.contains(Data("PDFDATA".utf8).base64EncodedString()))
    }

    @Test func testReviewDraftsFollowsARewrittenDraftToItsNewThread() async throws {
        let e = try engine()
        try await e.autoDrafts.record(AutoDraftRecord(accountId: Self.account, draftId: "d1", threadId: "t0", fromEmail: Self.account,
                                                      recipients: "jo@example.net", subject: "Offerte", source: .claude, reason: "test"))
        MockServer.reset { [h = MockServer.handler] c in
            if c.path.hasSuffix("/drafts/d1"), c.method == "PUT" { return (200, ["id": "d1", "message": ["id": "m2", "threadId": "t5"]]) }
            return h(c)
        }
        _ = try await call(e, ["account": Self.account, "draft_id": "d1", "to": ["jo@example.net"], "subject": "Offerte", "body": "Nieuw", "attachments": [String]()])
        XCTAssertEqual(try await e.autoDrafts.pending().map(\.threadId), ["t5"])
    }

    @Test func testEmptyListRemovesTheFiles() async throws {
        let e = try engine()
        let (out, err) = try await call(e, ["account": Self.account, "draft_id": "d1", "to": ["jo@example.net"], "subject": "Offerte", "body": "Zonder bijlage", "attachments": [String]()])
        XCTAssertNil(err)
        XCTAssertEqual(out?["attachments"] as? [String], [])
        XCTAssertEqual(MockServer.recorded("/drafts/d1", method: "GET").count, 0, "Nothing fetched when the files are replaced")
    }
}
