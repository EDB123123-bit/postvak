import Foundation
import Testing
import GRDB
@testable import PostvakCore

/// Google's words, as they reached a real account on first sync.
private let quotaError: [String: Any] = ["error": [
    "code": 403, "status": "PERMISSION_DENIED",
    "message": "Quota exceeded for quota metric 'Total Query Cost' and limit 'Units per minute per user' of service 'gmail.googleapis.com' for consumer 'project_number:1'.",
] as [String: Any]]

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite(.serialized) struct RateLimitTests {
    func threadAnswer(_ c: MockServer.Call) -> (Int, Any)? {
        if c.path.hasSuffix("/profile") { return (200, ["emailAddress": "a@example.com", "historyId": "10"]) }
        if c.path.hasSuffix("/history") { return (200, ["history": [], "historyId": "11"]) }
        if c.path.hasSuffix("/threads") { return (200, ["threads": [["id": "t"]]]) }
        if c.path.hasSuffix("/threads/t") { return (200, ["id": "t", "messages": [gmailMessage(id: "m", thread: "t")]]) }
        return nil
    }

    @Test func testQuotaErrorIsRetriedAndSyncFinishes() async throws {
        let e = try makeEngine()
        let failed = Flag()
        MockServer.reset { [self] c in
            if let b = baseAnswer(c) { return b }
            if c.path.hasSuffix("/threads/t"), !failed.isSet { failed.set(); return (403, quotaError) }
            return threadAnswer(c) ?? (404, [:])
        }
        try await e.sync.sync(accountId: "a@example.com")
        let a = try await e.db.pool.read { try Account.fetchOne($0, key: "a@example.com") }
        XCTAssertEqual(a?.initialSyncDone, true)
        XCTAssertEqual(MockServer.recorded("/threads/t").count, 2, "Waits and asks again instead of giving up")
    }

    @Test func testOtherForbiddenErrorsAreNotRetried() async throws {
        let e = try makeEngine()
        MockServer.reset { c in
            if let b = baseAnswer(c) { return b }
            return (403, ["error": ["message": "Not allowed to operate on this mailbox"]])
        }
        do { _ = try await e.gmail.profile("a@example.com"); XCTFail("should throw") } catch {}
        XCTAssertEqual(MockServer.recorded("/profile").count, 1, "A word that merely contains 'rate' is not a rate limit")
    }

    @Test func testRateLimitWaitsLongEnoughForAPerMinuteQuota() {
        let total = (1...4).reduce(0.0) { $0 + GoogleAPI.rateLimitDelay(attempt: $1, retryAfter: nil) }
        XCTAssertGreaterThanOrEqual(total, 60)
        XCTAssertGreaterThanOrEqual(GoogleAPI.rateLimitDelay(attempt: 1, retryAfter: "90"), 90)
        XCTAssertLessThanOrEqual(GoogleAPI.rateLimitDelay(attempt: 1, retryAfter: "99999"), 125)
    }

    @Test func testPaceBacksOffOnRefusalAndRecoversSlowly() {
        var pace = SyncPace()
        let start = pace.seconds
        pace.record(refused: true)
        XCTAssertEqual(pace.seconds, start * 2, accuracy: 0.001)
        for _ in 0..<9 { pace.record(refused: false) }
        XCTAssertEqual(pace.seconds, start * 2, accuracy: 0.001)
        pace.record(refused: false)
        XCTAssertTrue(pace.seconds < start * 2, "Ten clean batches speed it up a little")
        for _ in 0..<20 { pace.record(refused: true) }
        XCTAssertEqual(pace.seconds, SyncPace.slowest, accuracy: 0.001)
        for _ in 0..<5000 { pace.record(refused: false) }
        XCTAssertEqual(pace.seconds, SyncPace.fastest, accuracy: 0.001)
    }

    @Test func testRefusalsAreCountedPerAccount() async throws {
        let e = try makeEngine(accounts: ["a@example.com", "b@example.com"])
        let failed = Flag()
        MockServer.reset { [self] c in
            if let b = baseAnswer(c) { return b }
            if c.path.hasSuffix("/profile"), !failed.isSet { failed.set(); return (403, quotaError) }
            return threadAnswer(c) ?? (404, [:])
        }
        _ = try await e.gmail.profile("a@example.com")
        XCTAssertEqual(e.api.rateLimits.count("a@example.com"), 1)
        XCTAssertEqual(e.api.rateLimits.count("b@example.com"), 0)
    }

    @Test func testOverlappingSyncsOfOneAccountListOnce() async throws {
        let e = try makeEngine()
        MockServer.reset { [self] c in
            if let b = baseAnswer(c) { Thread.sleep(forTimeInterval: 0.05); return b }
            return threadAnswer(c) ?? (404, [:])
        }
        async let first: Void = e.sync.sync(accountId: "a@example.com")
        async let second: Void = e.sync.sync(accountId: "a@example.com")
        _ = try await (first, second)
        XCTAssertEqual(MockServer.recorded("/threads", method: "GET").filter { $0.path.hasSuffix("/threads") }.count, 1)
    }

    @Test func testAStuckAccountDoesNotStopOthersPolling() async throws {
        let e = try makeEngine(accounts: ["a@example.com", "b@example.com"])
        MockServer.reset { [self] c in
            if c.path.hasSuffix("/token") {
                let who = String(decoding: c.body, as: UTF8.self).contains("refresh-a") ? "a" : "b"
                return (200, ["access_token": "tok-\(who)", "expires_in": 3600])
            }
            if c.path.hasSuffix("/labels") {
                if c.headers["Authorization"] == "Bearer tok-a" { return (MockServer.neverAnswer, [:]) }
                return (200, ["labels": []])
            }
            return threadAnswer(c) ?? (404, [:])
        }
        func labelCalls(_ who: String) -> Int {
            MockServer.recorded("/labels").filter { $0.headers["Authorization"] == "Bearer tok-\(who)" }.count
        }
        func wait(until done: () -> Bool) async throws {
            for _ in 0..<100 where !done() { try await Task.sleep(for: .milliseconds(20)) }
        }
        await e.pollMail()
        try await wait { labelCalls("b") == 1 && labelCalls("a") == 1 }
        // The first account is still hanging, and each poll must still reach the second.
        try await Task.sleep(for: .milliseconds(100))
        await e.pollMail()
        try await wait { labelCalls("b") == 2 }
        XCTAssertEqual(labelCalls("b"), 2, "The second account polls again")
        XCTAssertEqual(labelCalls("a"), 1, "The stuck account does not start a second pass")
    }
}
