import Foundation
import Testing
import GRDB
@testable import PostvakCore

/// Answers Google API calls in-process and records them.
final class MockServer: URLProtocol, @unchecked Sendable {
    struct Call { let method: String; let path: String; let query: [String: String]; let body: Data; let headers: [String: String] }
    typealias Handler = (Call) -> (Int, Any)

    nonisolated(unsafe) static var handler: Handler = { _ in (404, ["error": ["message": "no handler"]]) }
    nonisolated(unsafe) static var calls: [Call] = []
    /// A handler returning this status leaves the request hanging, like a slow server.
    static let neverAnswer = -1
    /// A handler returning this status fails the request as if the Mac had no network.
    static let offline = -2
    /// A handler returning this status drops the connection mid-request.
    static let connectionLost = -3
    static let lock = NSLock()

    static func reset(_ h: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handler = h
        calls = []
    }
    static func recorded(_ pathContains: String, method: String? = nil) -> [Call] {
        lock.lock(); defer { lock.unlock() }
        return calls.filter { $0.path.contains(pathContains) && (method == nil || $0.method == method) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let s = request.httpBodyStream {
            s.open()
            var buf = [UInt8](repeating: 0, count: 65536)
            while s.hasBytesAvailable {
                let n = s.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            s.close()
        }
        let url = request.url!
        var q: [String: String] = [:]
        for i in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { q[i.name] = i.value ?? "" }
        let call = Call(method: request.httpMethod ?? "GET", path: url.path, query: q, body: body, headers: request.allHTTPHeaderFields ?? [:])
        Self.lock.lock()
        Self.calls.append(call)
        let h = Self.handler
        Self.lock.unlock()
        let (status, obj) = h(call)
        if status == Self.neverAnswer { return }
        if status == Self.offline || status == Self.connectionLost {
            client?.urlProtocol(self, didFailWithError: URLError(status == Self.offline ? .notConnectedToInternet : .networkConnectionLost))
            return
        }
        let data: Data
        if let d = obj as? Data { data = d } else { data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data() }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [MockServer.self]
        return URLSession(configuration: c)
    }
}

func makeEngine(accounts: [String] = ["a@example.com"]) throws -> Engine {
    setenv("POSTVAK_NO_BACKOFF", "1", 1)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("postvak-tests-\(UUID().uuidString)")
    var secretValues = [SecretKey.googleClientId: "cid", SecretKey.googleClientSecret: "sec"]
    for a in accounts { secretValues[SecretKey.refreshToken(a)] = "refresh-\(a)" }
    let engine = try Engine(paths: AppPaths(root: dir), secrets: MemorySecretStore(secretValues), session: MockServer.session)
    try engine.db.pool.write { db in
        for a in accounts { try Account(id: a, displayName: a, colorHex: "#000000").insert(db) }
    }
    return engine
}

func b64(_ s: String) -> String { Data(s.utf8).base64URL }

func gmailMessage(id: String, thread: String, from: String = "Ann <ann@example.net>", to: String = "a@example.com", subject: String = "Hello",
                  body: String = "Body text", labels: [String] = ["INBOX"], hoursAgo: Double = 1) -> [String: Any] {
    [
        "id": id, "threadId": thread, "labelIds": labels, "snippet": String(body.prefix(40)), "historyId": "10",
        "internalDate": String(Int((Date().timeIntervalSince1970 - hoursAgo * 3600) * 1000)),
        "payload": [
            "mimeType": "text/plain", "filename": "",
            "headers": [["name": "From", "value": from], ["name": "To", "value": to], ["name": "Subject", "value": subject], ["name": "Message-ID", "value": "<\(id)@x>"]],
            "body": ["size": body.count, "data": b64(body)],
        ] as [String: Any],
    ]
}

/// Default answers for token refresh and the calls every sync makes.
func baseAnswer(_ c: MockServer.Call) -> (Int, Any)? {
    if c.path.hasSuffix("/token") { return (200, ["access_token": "tok", "expires_in": 3600]) }
    if c.path.hasSuffix("/labels"), c.method == "GET" { return (200, ["labels": [["id": "INBOX", "name": "INBOX", "type": "system"], ["id": "Label_1", "name": "Work", "type": "user"]]]) }
    return nil
}


// Assertion names kept short and familiar; XCTest itself ships only with full Xcode.
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, _ m: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(a == b, Comment(rawValue: m), sourceLocation: sourceLocation)
}
func XCTAssertEqual(_ a: TimeInterval, _ b: TimeInterval, accuracy: TimeInterval, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(abs(a - b) <= accuracy, sourceLocation: sourceLocation)
}
func XCTAssertTrue(_ v: Bool, _ m: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(v, Comment(rawValue: m), sourceLocation: sourceLocation)
}
func XCTAssertFalse(_ v: Bool, _ m: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!v, Comment(rawValue: m), sourceLocation: sourceLocation)
}
func XCTAssertNil<T>(_ v: T?, _ m: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(v == nil, Comment(rawValue: m), sourceLocation: sourceLocation)
}
func XCTAssertNotNil<T>(_ v: T?, _ m: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(v != nil, Comment(rawValue: m), sourceLocation: sourceLocation)
}
func XCTAssertLessThanOrEqual<T: Comparable>(_ a: T, _ b: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(a <= b, sourceLocation: sourceLocation)
}
func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: T, _ b: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(a >= b, sourceLocation: sourceLocation)
}
func XCTFail(_ m: String = "failed", sourceLocation: SourceLocation = #_sourceLocation) {
    Issue.record(Comment(rawValue: m), sourceLocation: sourceLocation)
}
