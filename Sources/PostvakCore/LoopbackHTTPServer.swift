import Foundation
import Network

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]   // lower-cased names
    public var body: Data
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }
    public static func text(_ status: Int, _ s: String, type: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": type], body: Data(s.utf8))
    }
}

/// Minimal HTTP/1.1 server bound to 127.0.0.1 only. Used by the OAuth redirect
/// and the MCP endpoint. One request per connection.
public final class LoopbackHTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "postvak.http")
    private let maxBody = 25 * 1024 * 1024
    public private(set) var port: UInt16 = 0

    public init(port: UInt16 = 0, handler: @escaping Handler) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        listener = try NWListener(using: params)
        self.handler = handler
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = self?.listener.port?.rawValue ?? 0
                    once.run { c.resume() }
                case .failed(let e):
                    once.run { c.resume(throwing: e) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.start(queue: queue)
        }
    }

    public func stop() { listener.cancel() }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if error != nil { conn.cancel(); return }
            switch Self.parse(buf, maxBody: self.maxBody) {
            case .needMore:
                if done { conn.cancel() } else { self.receive(conn, buffer: buf) }
            case .invalid(let status):
                self.send(.text(status, "bad request"), on: conn)
            case .complete(let req):
                let handler = self.handler
                Task {
                    let resp = await handler(req)
                    self.send(resp, on: conn)
                }
            }
        }
    }

    private func send(_ resp: HTTPResponse, on conn: NWConnection) {
        var head = "HTTP/1.1 \(resp.status) \(Self.reason(resp.status))\r\n"
        var headers = resp.headers
        headers["Content-Length"] = String(resp.body.count)
        headers["Connection"] = "close"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(resp.body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    enum ParseResult { case needMore, invalid(Int), complete(HTTPRequest) }

    static func parse(_ data: Data, maxBody: Int) -> ParseResult {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 64 * 1024 ? .invalid(431) : .needMore
        }
        guard let head = String(data: data[data.startIndex..<sep.lowerBound], encoding: .utf8) else { return .invalid(400) }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return .invalid(400) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        if length > maxBody { return .invalid(413) }
        let body = data[sep.upperBound...]
        if body.count < length { return .needMore }
        let comps = URLComponents(string: String(parts[1]))
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .complete(HTTPRequest(method: String(parts[0]), path: comps?.path ?? String(parts[1]),
                                     query: query, headers: headers, body: Data(body.prefix(length))))
    }

    static func reason(_ s: Int) -> String {
        switch s {
        case 200: "OK"; case 202: "Accepted"; case 204: "No Content"; case 400: "Bad Request"
        case 401: "Unauthorized"; case 403: "Forbidden"; case 404: "Not Found"; case 405: "Method Not Allowed"
        case 413: "Payload Too Large"; case 431: "Request Header Fields Too Large"
        default: "Status"
        }
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ f: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        if !done { done = true; f() }
    }
}
