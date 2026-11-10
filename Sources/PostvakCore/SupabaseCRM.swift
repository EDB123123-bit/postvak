import Foundation
import GRDB

/// A sales CRM kept in Supabase with `leads`, `activities` and `lost_reasons` tables, like one built with Lovable.
/// Postvak signs in as the user, so the CRM's own row-level rules decide what it may read and write.
/// Each deal is matched to a lead by company domain, or by address for someone at a personal mail provider.
public final class SupabaseCRM: @unchecked Sendable {
    let db: AppDatabase
    let secrets: SecretStore
    let session: URLSession
    let notes: DealNotes
    private let lock = NSLock()
    private var tokens: [String: (access: String, expires: Date)] = [:]

    public static let closedLost = "Closed Lost"
    public static let closedWon = "Closed Won"
    /// Notes Postvak writes carry this subject, so they are not read back as the CRM's own.
    public static let noteSubject = "Note from Postvak"

    public init(db: AppDatabase, secrets: SecretStore, session: URLSession = .shared) {
        self.db = db; self.secrets = secrets; self.session = session; notes = DealNotes(db: db)
    }

    // MARK: settings

    public struct Config: Sendable, Equatable {
        public var name: String
        public var url: String
        public var key: String
        public var isComplete: Bool { !url.isEmpty && !key.isEmpty }
        public init(name: String, url: String, key: String) { self.name = name; self.url = url; self.key = key }
    }

    public struct Login: Codable, Sendable, Hashable { public let email: String; public let userId: String }

    public var config: Config {
        Config(name: db.setting("crm.name").flatMap { $0.isEmpty ? nil : $0 } ?? "CRM",
               url: (db.setting("crm.url") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ ")),
               key: db.setting("crm.key") ?? "")
    }

    public func setConfig(_ c: Config) throws {
        try db.setSetting("crm.name", c.name.trimmingCharacters(in: .whitespaces))
        try db.setSetting("crm.url", c.url.trimmingCharacters(in: .whitespacesAndNewlines))
        try db.setSetting("crm.key", c.key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public var logins: [Login] {
        guard let s = db.setting("crm.logins"), let d = s.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Login].self, from: d)) ?? []
    }

    func setLogins(_ l: [Login]) throws {
        try db.setSetting("crm.logins", String(decoding: try JSONEncoder().encode(l), as: UTF8.self))
    }

    public var isConnected: Bool { config.isComplete && !logins.isEmpty }

    static func refreshKey(_ email: String) -> String { "crm.refresh.\(email.lowercased())" }

    // MARK: sign-in

    public struct CRMError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    struct TokenAnswer: Decodable {
        struct User: Decodable { let id: String; let email: String? }
        let access_token: String
        let refresh_token: String
        let expires_in: Double?
        let user: User?
    }

    /// Signs in with the CRM's own email and password. Only the refresh token is kept, in the Keychain.
    public func signIn(email: String, password: String) async throws {
        let answer = try await token(grant: "password", body: ["email": email, "password": password])
        guard let id = answer.user?.id else { throw CRMError(message: "The CRM did not say who signed in.") }
        let e = (answer.user?.email ?? email).lowercased()
        try store(answer, for: e)
        var l = logins.filter { $0.email != e }
        l.append(Login(email: e, userId: id))
        try setLogins(l)
    }

    public func signOut(_ email: String) throws {
        try secrets.set(Self.refreshKey(email), nil)
        lock.withLock { _ = tokens.removeValue(forKey: email) }
        try setLogins(logins.filter { $0.email != email })
    }

    private func store(_ a: TokenAnswer, for email: String) throws {
        try secrets.set(Self.refreshKey(email), a.refresh_token)
        lock.withLock { tokens[email] = (a.access_token, Date().addingTimeInterval((a.expires_in ?? 3600) - 120)) }
    }

    private func token(grant: String, body: [String: String]) async throws -> TokenAnswer {
        let c = config
        guard c.isComplete, let url = URL(string: "\(c.url)/auth/v1/token?grant_type=\(grant)") else {
            throw CRMError(message: "Fill in the CRM's address and publishable key first.")
        }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue(c.key, forHTTPHeaderField: "apikey")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw CRMError(message: Self.errorText(data, status: status, signIn: true)) }
        return try JSONDecoder().decode(TokenAnswer.self, from: data)
    }

    func accessToken(_ email: String) async throws -> String {
        if let t = lock.withLock({ tokens[email] }), t.expires > Date() { return t.access }
        guard let refresh = secrets.get(Self.refreshKey(email)) else {
            throw CRMError(message: "Sign in to the CRM again as \(email) in Settings → CRM.")
        }
        do {
            let a = try await token(grant: "refresh_token", body: ["refresh_token": refresh])
            try store(a, for: email)
            return a.access_token
        } catch {
            throw CRMError(message: "Sign in to the CRM again as \(email) in Settings → CRM. (\(error.localizedDescription))")
        }
    }

    static func errorText(_ data: Data, status: Int, signIn: Bool = false) -> String {
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let msg = (o?["error_description"] ?? o?["msg"] ?? o?["message"] ?? o?["error"]) as? String
        if signIn && status == 400 { return msg ?? "Wrong email or password." }
        return "The CRM answered \(status)" + (msg.map { ": \($0)" } ?? ".")
    }

    // MARK: REST

    func rest(_ method: String, _ path: String, as email: String, body: Any? = nil) async throws -> Data {
        let c = config
        guard let url = URL(string: "\(c.url)/rest/v1/\(path)") else { throw CRMError(message: "The CRM address is not valid.") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue(c.key, forHTTPHeaderField: "apikey")
        r.setValue("Bearer \(try await accessToken(email))", forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue("return=minimal", forHTTPHeaderField: "Prefer")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await session.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw CRMError(message: Self.errorText(data, status: status)) }
        return data
    }

    func get<T: Decodable>(_ path: String, as email: String) async throws -> [T] {
        try JSONDecoder().decode([T].self, from: try await rest("GET", path, as: email))
    }

    public struct Lead: Decodable, Sendable, Hashable {
        public let id: String
        public let user_id: String
        public let company_name: String?
        public let email: String?
        public let website: String?
        public let stage: String?
        public let project: String?
        public let last_activity_at: String?
    }

    struct Activity: Decodable { let lead_id: String; let date: String?; let subject: String?; let notes: String? }
    struct LostReason: Decodable { let lead_id: String; let reason: String?; let competitor_name: String?; let notes: String?; let lost_date: String? }

    // MARK: matching

    /// The deal keys a lead belongs to: the domain of its address and website, or the address itself at a personal provider.
    public static func keys(for lead: Lead) -> Set<String> {
        var out = Set<String>()
        for raw in (lead.email ?? "").split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }) {
            let e = String(raw).lowercased()
            if e.contains("@") { out.insert(Deals.key(for: e)) }
        }
        // Typed by hand, so also "https:www.acme.be" or "acme.be/contact".
        let w = (lead.website ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"^[a-z]+:/*"#, with: "", options: .regularExpression)
        if !w.isEmpty {
            if var host = URL(string: "https://" + w)?.host {
                if host.hasPrefix("www.") { host.removeFirst(4) }
                if host.contains("."), !Deals.personalDomains.contains(host) { out.insert(host) }
            }
        }
        return out
    }

    /// One lead per deal key; when several share a domain, the one with the latest activity.
    public static func match(_ leads: [Lead]) -> [String: Lead] {
        var out: [String: Lead] = [:]
        for l in leads {
            for k in keys(for: l) {
                if let o = out[k], (o.last_activity_at ?? "") >= (l.last_activity_at ?? "") { continue }
                out[k] = l
            }
        }
        return out
    }

    static func day(_ iso: String?) -> String {
        guard let iso, iso.count >= 10 else { return "" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        guard let d = f.date(from: String(iso.prefix(10))) else { return String(iso.prefix(10)) }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_GB")
        out.dateFormat = "EEE d MMM yyyy"
        return out.string(from: d)
    }

    // MARK: sync

    public struct SyncResult: Sendable {
        /// Deals whose CRM record changed since the last sync, so Claude should read them again.
        public var changed: Set<String> = []
        public var matched = 0
        public var pushed = 0
    }

    /// Reads every lead the signed-in users can see, records stage, lost reason and notes per matched deal,
    /// and sends notes that have not reached the CRM yet.
    @discardableResult
    public func sync(now: Date = Date()) async throws -> SyncResult {
        guard isConnected else { return SyncResult() }
        var leads: [Lead] = [], acts: [Activity] = [], lost: [LostReason] = []
        var firstError: Error?
        var loginFor: [String: String] = [:]
        for l in logins {
            do {
                let ls: [Lead] = try await get("leads?select=id,user_id,company_name,email,website,stage,project,last_activity_at", as: l.email)
                for x in ls { loginFor[x.user_id] = l.email }
                leads += ls
                acts += try await get("activities?select=lead_id,date,subject,notes&type=eq.note&order=date.desc&limit=1000", as: l.email)
                lost += try await get("lost_reasons?select=lead_id,reason,competitor_name,notes,lost_date", as: l.email)
            } catch { if firstError == nil { firstError = error } }
        }
        if leads.isEmpty, let firstError { throw firstError }
        let matched = Self.match(leads)
        let deals = try await db.pool.read { try String.fetchAll($0, sql: "SELECT key FROM deal WHERE isDeal = 1") }
        let notesByLead = Dictionary(grouping: acts.filter { $0.subject != Self.noteSubject }, by: \.lead_id)
        let lostByLead = Dictionary(grouping: lost, by: \.lead_id)
        var result = SyncResult()
        let name = config.name
        for key in deals {
            guard let lead = matched[key] else { continue }
            result.matched += 1
            var context: [String] = []
            if let stage = lead.stage { context.append("Stage in \(name): \(stage).") }
            for r in (lostByLead[lead.id] ?? []).prefix(1) {
                let parts = [r.reason, r.competitor_name.map { "chose \($0)" }, r.notes].compactMap { $0 }.filter { !$0.isEmpty }
                context.append("Lost \(Self.day(r.lost_date)): \(parts.joined(separator: "; ")).")
            }
            for a in (notesByLead[lead.id] ?? []).prefix(3) {
                let text = (a.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { context.append("Note \(Self.day(a.date)): \(String(text.prefix(400)))") }
            }
            let joined = context.joined(separator: "\n")
            let fingerprint = String(Self.stableHash(joined))
            // The first sight of a record counts as a change too: the CRM may know things the last reading did not.
            if try await notes.state(key).crmFingerprint != fingerprint { result.changed.insert(key) }
            try await notes.update(key) { s in
                s.crmLeadId = lead.id; s.crmUserId = lead.user_id; s.crmProject = lead.project; s.crmCompany = lead.company_name
                s.crmStage = lead.stage; s.crmContext = joined
                if s.crmFingerprint != fingerprint { s.crmChangedAt = now; s.crmFingerprint = fingerprint }
            }
        }
        result.pushed = try await pushPending(loginFor: loginFor)
        try db.setSetting("crm.lastSync", String(now.timeIntervalSince1970))
        try db.setSetting("crm.lastError", nil)
        if let firstError { try db.setSetting("crm.lastError", firstError.localizedDescription) }
        return result
    }

    /// A hash that stays the same between launches, unlike `hashValue`.
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    private func login(for state: DealState, loginFor: [String: String]) -> String? {
        if let u = state.crmUserId, let e = loginFor[u] ?? logins.first(where: { $0.userId == u })?.email { return e }
        return nil
    }

    /// Sends the user's notes that have not reached the CRM, to deals with a matched lead. Returns how many went.
    func pushPending(loginFor: [String: String] = [:]) async throws -> Int {
        let pending = try await db.pool.read { try DealNote.filter(Column("crmPushedAt") == nil).fetchAll($0) }
        var sent = 0
        for n in pending {
            let state = try await notes.state(n.dealKey)
            guard let lead = state.crmLeadId, let user = state.crmUserId, let email = login(for: state, loginFor: loginFor) else { continue }
            var row: [String: Any] = ["lead_id": lead, "user_id": user, "type": "note", "subject": Self.noteSubject, "notes": n.text,
                                      "date": ISO8601DateFormatter().string(from: n.createdAt)]
            if let p = state.crmProject { row["project"] = p }
            do {
                _ = try await rest("POST", "activities", as: email, body: row)
                let id = n.id
                try await db.pool.write { try $0.execute(sql: "UPDATE deal_note SET crmPushedAt = ?, crmError = NULL WHERE id = ?", arguments: [Date(), id]) }
                sent += 1
            } catch {
                let id = n.id, msg = error.localizedDescription
                try await db.pool.write { try $0.execute(sql: "UPDATE deal_note SET crmError = ? WHERE id = ?", arguments: [msg, id]) }
            }
        }
        return sent
    }

    /// Sends new notes now, to deals with a CRM record. A failure is kept on the note; the next sync tries again.
    public func pushNotes() async {
        guard isConnected else { return }
        _ = try? await pushPending()
    }

    /// The CRM stage a reading suggests, when it differs from the CRM's and the user did not wave it away.
    public static func proposedStage(for deal: DealRecord, state: DealState?) -> String? {
        guard let state, state.crmLeadId != nil, let current = state.crmStage else { return nil }
        let wanted: String? = switch deal.stage {
        case .lost: closedLost
        case .customer: closedWon
        default: nil
        }
        guard let wanted, wanted != current, state.crmProposalDismissed != wanted else { return nil }
        return wanted
    }

    /// Sets the lead's stage in the CRM. A lost deal also gets a lost reason, with the user's latest note as its explanation.
    public func setStage(_ stage: String, for key: String, reason: String?, now: Date = Date()) async throws {
        let state = try await notes.state(key)
        guard let lead = state.crmLeadId, let user = state.crmUserId, let email = login(for: state, loginFor: [:]) else {
            throw CRMError(message: "This deal has no record in the CRM, or nobody who can change it is signed in.")
        }
        let iso = ISO8601DateFormatter().string(from: now)
        _ = try await rest("PATCH", "leads?id=eq.\(lead)", as: email, body: ["stage": stage, "last_activity_at": iso])
        if stage == Self.closedLost {
            var row: [String: Any] = ["lead_id": lead, "user_id": user, "reason": "Other", "lost_date": iso]
            if let reason, !reason.isEmpty { row["notes"] = reason }
            if let p = state.crmProject { row["project"] = p }
            _ = try? await rest("POST", "lost_reasons", as: email, body: row)
        }
        try await notes.update(key) { $0.crmStage = stage }
    }

    public func dismissProposal(_ stage: String, for key: String) async throws {
        try await notes.update(key) { $0.crmProposalDismissed = stage }
    }
}
