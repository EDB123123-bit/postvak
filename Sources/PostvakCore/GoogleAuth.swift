import Foundation
import CryptoKit
#if canImport(AppKit)
import AppKit
#endif

public enum GoogleScopes {
    public static let all = [
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.settings.basic",
        "https://www.googleapis.com/auth/calendar",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "openid",
    ]
}

public enum GoogleAuthError: Error, LocalizedError {
    case missingClientConfig
    case noRefreshToken(String)
    case revoked(String)
    case stateMismatch
    case denied(String)
    case tokenExchange(String)
    public var errorDescription: String? {
        switch self {
        case .missingClientConfig: "Add your Google OAuth client ID and secret in Settings first."
        case .noRefreshToken(let a): "No saved sign-in for \(a). Sign in again."
        case .revoked(let a): "Google revoked the sign-in for \(a). Sign in again."
        case .stateMismatch: "The sign-in response did not match this request."
        case .denied(let r): "Google sign-in was cancelled: \(r)"
        case .tokenExchange(let m): "Google sign-in failed: \(m)"
        }
    }
}

public actor GoogleAuth {
    struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double
        let refresh_token: String?
    }
    struct Cached { let token: String; let expires: Date }

    private let secrets: SecretStore
    private let session: URLSession
    private var cache: [String: Cached] = [:]
    var tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    var userInfoURL = URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!

    public init(secrets: SecretStore, session: URLSession = .shared) {
        self.secrets = secrets
        self.session = session
    }

    private func clientConfig() throws -> (id: String, secret: String) {
        guard let id = secrets.get(SecretKey.googleClientId), !id.isEmpty else { throw GoogleAuthError.missingClientConfig }
        return (id, secrets.get(SecretKey.googleClientSecret) ?? "")
    }

    // MARK: PKCE helpers

    public nonisolated static func pkcePair() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URL
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        return (verifier, challenge)
    }

    /// Runs the browser sign-in and returns the signed-in address and display name.
    /// The refresh token is stored in the secret store under the address.
    public func signIn(open: @Sendable (URL) -> Void) async throws -> (email: String, name: String) {
        let cfg = try clientConfig()
        let (verifier, challenge) = Self.pkcePair()
        let state = UUID().uuidString

        let received = CodeBox()
        let server = try LoopbackHTTPServer { req in
            guard req.path == "/oauth2callback" else { return .text(404, "not found") }
            received.resolve(req.query)
            let page = "<html><body style='font:16px -apple-system;padding:40px'><h2>Postvak is signed in.</h2><p>You can close this tab.</p></body></html>"
            return .text(200, page, type: "text/html; charset=utf-8")
        }
        try await server.start()
        defer { server.stop() }
        let redirect = "http://127.0.0.1:\(server.port)/oauth2callback"

        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: cfg.id),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: GoogleScopes.all.joined(separator: " ")),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent select_account"),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        open(c.url!)

        let query = try await received.wait(timeout: 300)
        if let err = query["error"] { throw GoogleAuthError.denied(err) }
        guard query["state"] == state, let code = query["code"] else { throw GoogleAuthError.stateMismatch }

        let token = try await post(form: [
            "code": code, "client_id": cfg.id, "client_secret": cfg.secret,
            "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier,
        ], accountForRevocation: nil)
        guard let refresh = token.refresh_token else {
            throw GoogleAuthError.tokenExchange("Google did not return a refresh token.")
        }

        var req = URLRequest(url: userInfoURL)
        req.setValue("Bearer \(token.access_token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: req)
        struct Info: Decodable { let email: String; let name: String? }
        let info = try JSONDecoder().decode(Info.self, from: data)
        try secrets.set(SecretKey.refreshToken(info.email), refresh)
        cache[info.email] = Cached(token: token.access_token, expires: Date().addingTimeInterval(token.expires_in - 60))
        return (info.email, info.name ?? info.email)
    }

    public func accessToken(for account: String) async throws -> String {
        if let c = cache[account], c.expires > Date() { return c.token }
        let cfg = try clientConfig()
        guard let refresh = secrets.get(SecretKey.refreshToken(account)) else { throw GoogleAuthError.noRefreshToken(account) }
        let t = try await post(form: [
            "client_id": cfg.id, "client_secret": cfg.secret,
            "refresh_token": refresh, "grant_type": "refresh_token",
        ], accountForRevocation: account)
        cache[account] = Cached(token: t.access_token, expires: Date().addingTimeInterval(t.expires_in - 60))
        return t.access_token
    }

    public func invalidate(_ account: String) { cache[account] = nil }

    public func signOut(_ account: String) throws {
        cache[account] = nil
        try secrets.set(SecretKey.refreshToken(account), nil)
    }

    private func post(form: [String: String], accountForRevocation: String?) async throws -> TokenResponse {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = form.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            if status == 400 || status == 401, message.contains("invalid_grant"), let a = accountForRevocation {
                throw GoogleAuthError.revoked(a)
            }
            throw GoogleAuthError.tokenExchange(message)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }
}

final class CodeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String: String]?
    private var cont: CheckedContinuation<[String: String], Error>?

    func resolve(_ q: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        if let cont { cont.resume(returning: q); self.cont = nil } else if value == nil { value = q }
    }

    func wait(timeout: TimeInterval) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: [String: String].self) { g in
            g.addTask {
                try await withCheckedThrowingContinuation { c in
                    self.lock.lock(); defer { self.lock.unlock() }
                    if let v = self.value { c.resume(returning: v) } else { self.cont = c }
                }
            }
            g.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw GoogleAuthError.denied("timed out waiting for the browser")
            }
            let r = try await g.next()!
            g.cancelAll()
            self.lock.lock(); self.cont?.resume(throwing: CancellationError()); self.cont = nil; self.lock.unlock()
            return r
        }
    }
}

public extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}
