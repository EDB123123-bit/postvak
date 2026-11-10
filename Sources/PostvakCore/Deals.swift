import Foundation
import GRDB

/// A company or person one of the user's ventures is selling to, with the stage and next step Claude read from
/// mail and meetings. Keyed by the company's domain, or by the address of someone at a personal mail provider.
public struct DealRecord: PersistableModel, Identifiable, Hashable {
    public static let databaseTableName = "deal"
    public enum Stage: String, Codable, CaseIterable, Sendable {
        case contacted, talking, demo, proposal, closing, customer, parked, lost
        /// The open stages, in pipeline order.
        public static let pipeline: [Stage] = [.contacted, .talking, .demo, .proposal, .closing, .customer]
        public var title: String {
            switch self {
            case .contacted: "Contacted"
            case .talking: "In talks"
            case .demo: "Demo held"
            case .proposal: "Proposal sent"
            case .closing: "Onboarding"
            case .customer: "Customer"
            case .parked: "Parked until later"
            case .lost: "Declined"
            }
        }
        public var isOpen: Bool { self != .parked && self != .lost }
    }
    public enum Owner: String, Codable, Sendable { case you, them, meeting, none }

    public var key: String
    /// False for suppliers, banks, events, friends and the like: kept so they are not read again until something changes.
    public var isDeal: Bool
    public var venture: String
    public var company: String
    public var contacts: String
    public var stage: Stage
    /// A short warning such as "Cancelling", or empty.
    public var risk: String
    public var nextStep: String
    public var owner: Owner
    public var due: String
    public var amount: String
    /// The quoted amount in euro, for ranking. Zero when none was quoted.
    public var amountEUR: Double
    /// large, mid, small or unknown.
    public var size: String
    public var sizeSource: String
    /// ACCOUNT/THREAD of the newest mail with them.
    public var latestThread: String?
    /// Changes whenever new mail or a meeting arrives, which is when the deal is read again.
    public var activityKey: String
    public var analyzedAt: Date

    public var id: String { key }

    public init(key: String, isDeal: Bool, venture: String, company: String, contacts: String, stage: Stage, risk: String,
                nextStep: String, owner: Owner, due: String, amount: String, amountEUR: Double, size: String, sizeSource: String,
                latestThread: String?, activityKey: String, analyzedAt: Date) {
        self.key = key; self.isDeal = isDeal; self.venture = venture; self.company = company; self.contacts = contacts
        self.stage = stage; self.risk = risk; self.nextStep = nextStep; self.owner = owner; self.due = due; self.amount = amount
        self.amountEUR = amountEUR; self.size = size; self.sizeSource = sizeSource; self.latestThread = latestThread
        self.activityKey = activityKey; self.analyzedAt = analyzedAt
    }

    /// How much this deal matters: how far along it is, how big the company is and how much was quoted.
    public var importance: Double {
        let stageWeight: [Stage: Double] = [.closing: 6, .customer: 4, .proposal: 4, .demo: 3, .talking: 2, .contacted: 1, .parked: 0, .lost: -2]
        var x = stageWeight[stage] ?? 0
        x += ["large": 3, "mid": 2, "small": 1][size] ?? 1
        x += amountEUR >= 2000 ? 2 : amountEUR >= 1000 ? 1.5 : amountEUR >= 300 ? 1 : 0
        if risk.lowercased().contains("cancel") { x += 2 }
        return x
    }
}

/// Finds the companies worth tracking as deals and gathers what Postvak knows about them.
public final class Deals: Sendable {
    let db: AppDatabase

    public init(db: AppDatabase) { self.db = db }

    /// Who the user is: every address they write from, the companies behind those addresses, and colleagues there.
    public struct Identity: Sendable {
        public var addresses: Set<String>
        public var domains: Set<String>
        /// Names seen on colleagues' addresses, so the same person writing from elsewhere still counts as a colleague.
        public var teamNames: Set<String>
        var nameOf: [String: String]

        public func isMe(_ email: String) -> Bool { addresses.contains(email.lowercased()) }
        public func isInternal(_ email: String) -> Bool {
            let e = email.lowercased()
            if isMe(e) { return false }
            if let d = Deals.domain(e), domains.contains(d) { return true }
            return nameOf[e].map { teamNames.contains($0) } ?? false
        }
    }

    public struct Candidate: Sendable, Hashable {
        public let key: String
        public let mailsIn: Int
        public let mailsOut: Int
        public let meetingsHeld: Int
        public let meetingsBooked: Int
        public let latest: Date?
        public let latestThread: String?
        public var score: Int { mailsIn + mailsOut + 4 * meetingsHeld + 5 * meetingsBooked }
        public var activityKey: String {
            "\(mailsIn)-\(mailsOut)-\(meetingsHeld)-\(meetingsBooked)-\(Int(latest?.timeIntervalSince1970 ?? 0))"
        }
    }

    public struct Evidence: Sendable {
        public struct Mail: Sendable { public let fromUser: Bool; public let from: String; public let date: Date; public let subject: String; public let text: String }
        public struct Meeting: Sendable {
            public let title: String; public let date: Date; public let summary: String
            public let actionItems: [ActionItem]; public let decisions: [String]
        }
        public struct Event: Sendable { public let title: String; public let date: Date }
        public let candidate: Candidate
        public let userAddresses: [String]
        /// The people at the company seen in mail headers and on invites, like "Stig Verhoeven <stig.v@dealflow.be>".
        public let people: [String]
        /// What people at the company wrote, signatures included, plus the names the user greets them with. Used to check contacts.
        public let companyText: String
        public let mails: [Mail]
        public let meetings: [Meeting]
        public let pastEvents: [Event]
        public let upcoming: [Event]
    }

    public enum MarkKind: String, Sendable { case mailIn, mailOut, meeting, booked }
    public struct Mark: Sendable, Hashable { public let date: Date; public let kind: MarkKind }

    // MARK: identity

    /// Personal mail providers: an address there says nothing about a company.
    public static let personalDomains: Set<String> = Matching.genericDomains

    static func domain(_ email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        return String(email[email.index(after: at)...]).lowercased()
    }

    /// The company domain, or the whole address for someone at a personal provider.
    public static func key(for email: String) -> String {
        let e = email.lowercased()
        guard let d = domain(e) else { return e }
        return personalDomains.contains(d) ? e : d
    }

    static func normalizedName(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// "Ann Smith" also appears as "Smith, Ann" or "Smith Ann" on company systems.
    static func nameForms(_ display: String) -> Set<String> {
        let n = normalizedName(display)
        let parts = n.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return [n] }
        let first = parts[0], rest = parts.dropFirst().joined(separator: " ")
        return [n, "\(rest), \(first)", "\(rest) \(first)"]
    }

    public static func identity(_ db: Database) throws -> Identity {
        let accounts = try Account.fetchAll(db)
        var addresses = Set(accounts.map { $0.id.lowercased() })
        addresses.formUnion(try String.fetchAll(db, sql: "SELECT DISTINCT lower(fromEmail) FROM message WHERE labelIds LIKE '%|SENT|%'"))
        let ownNames = accounts.reduce(into: Set<String>()) { $0.formUnion(nameForms($1.displayName)) }
        var nameOf: [String: String] = [:]
        for r in try Row.fetchAll(db, sql: "SELECT lower(fromEmail) AS e, fromName AS n FROM message WHERE fromName != '' GROUP BY lower(fromEmail)") {
            let e: String = r["e"], n: String = r["n"]
            let name = normalizedName(n)
            nameOf[e] = name
            // Any address writing under the user's own name is theirs too: an old address, an employer, a side venture.
            if ownNames.contains(name) { addresses.insert(e) }
        }
        let domains = Set(addresses.compactMap(domain)).subtracting(personalDomains)
        var team = Set<String>()
        for (e, n) in nameOf where !addresses.contains(e) {
            if let d = domain(e), domains.contains(d) { team.insert(n) }
        }
        return Identity(addresses: addresses, domains: domains, teamNames: team, nameOf: nameOf)
    }

    /// Calendar replies and automatic answers: they look like mail from a person but ask nothing.
    static let automaticSubject = try! NSRegularExpression(pattern: #"^(accepted|declined|tentative|geaccepteerd|geweigerd|voorlopig|accepté|refusé|invitation|uitnodiging|updated invitation|bijgewerkte uitnodiging|automatic reply|automatisch antwoord|réponse automatique|out of office|afwezig)\b"#, options: [.caseInsensitive])

    /// Machine senders. Small companies often write from info@ or hello@, so those stay people.
    static func isRobot(_ email: String) -> Bool {
        let local = email.split(separator: "@").first.map { $0.lowercased() } ?? email.lowercased()
        return ["noreply", "no-reply", "donotreply", "do-not-reply", "notification", "mailer-daemon", "bounce", "calendar-"].contains { local.contains($0) }
    }

    static func isAutomaticSubject(_ s: String) -> Bool {
        automaticSubject.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func recipients(_ m: Row) -> [String] {
        let line = [m["toLine"] as String? ?? "", m["ccLine"] as String? ?? ""].joined(separator: ", ")
        return GmailParser.splitAddresses(line).map { GmailParser.parseAddress($0).email.lowercased() }.filter { $0.contains("@") }
    }

    /// Meetings with other people, each counted once however many calendars show it.
    static func meetingsWithOthers(_ db: Database, from: Date, to: Date, identity: Identity) throws -> [(event: CalendarEvent, keys: Set<String>)] {
        var seen = Set<String>()
        var out: [(CalendarEvent, Set<String>)] = []
        for e in try CalendarService.eventsRequest(from: from, to: to, onlySelected: false).fetchAll(db) {
            guard !e.isAllDay, e.status != "cancelled", e.selfResponse != "declined", e.transparency != "transparent", seen.insert(e.eventId).inserted else { continue }
            let keys = Set(e.attendees.filter { !$0.isSelf && !identity.isMe($0.email) && !identity.isInternal($0.email) }.map { key(for: $0.email) })
            if !keys.isEmpty { out.append((e, keys)) }
        }
        return out
    }

    // MARK: candidates

    /// Companies with two-way mail or a meeting in the last 75 days, or one booked in the next 90, busiest first.
    public func candidates(now: Date = Date()) async throws -> (identity: Identity, list: [Candidate]) {
        try await db.pool.read { db in
            let identity = try Self.identity(db)
            let since = now.addingTimeInterval(-75 * 86400)
            struct Tally { var mailsIn = 0, mailsOut = 0, held = 0, booked = 0; var latest: Date?; var latestThread: String? }
            var tally: [String: Tally] = [:]
            func touch(_ key: String, _ date: Date, thread: String?) {
                var t = tally[key, default: Tally()]
                if t.latest == nil || date > t.latest! { t.latest = date; if let thread { t.latestThread = thread } }
                tally[key] = t
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.accountId, m.threadId, m.fromEmail, m.toLine, m.ccLine, m.subject, m.date, m.labelIds, m.hasListUnsubscribe, t.bucket
                FROM message m LEFT JOIN thread t ON t.accountId = m.accountId AND t.threadId = m.threadId
                WHERE m.date >= ? AND m.date <= ? AND m.labelIds NOT LIKE '%|DRAFT|%' AND m.labelIds NOT LIKE '%|SPAM|%' AND m.labelIds NOT LIKE '%|TRASH|%'
                """, arguments: [since, now])
            for r in rows {
                let from = (r["fromEmail"] as String).lowercased(), labels: String = r["labelIds"], date: Date = r["date"]
                let thread = "\(r["accountId"] as String)/\(r["threadId"] as String)"
                if labels.contains("|SENT|") || identity.isMe(from) {
                    let keys = Set(Self.recipients(r).filter { !identity.isMe($0) && !identity.isInternal($0) }.map(Self.key(for:)))
                    for k in keys { tally[k, default: Tally()].mailsOut += 1; touch(k, date, thread: thread) }
                } else {
                    let bucket: String? = r["bucket"], unsubscribe: Bool = r["hasListUnsubscribe"], subject: String = r["subject"]
                    guard bucket == InboxBucket.people.rawValue, !unsubscribe, !identity.isInternal(from), !Self.isRobot(from),
                          !Self.isAutomaticSubject(subject) else { continue }
                    let k = Self.key(for: from)
                    tally[k, default: Tally()].mailsIn += 1
                    touch(k, date, thread: thread)
                }
            }
            for (e, keys) in try Self.meetingsWithOthers(db, from: since, to: now.addingTimeInterval(90 * 86400), identity: identity) {
                for k in keys {
                    if e.startAt <= now { tally[k, default: Tally()].held += 1; touch(k, e.startAt, thread: nil) }
                    else { tally[k, default: Tally()].booked += 1 }
                }
            }
            let list = tally.compactMap { k, t -> Candidate? in
                guard (t.mailsIn > 0 && t.mailsOut > 0) || t.held > 0 || t.booked > 0 else { return nil }
                return Candidate(key: k, mailsIn: t.mailsIn, mailsOut: t.mailsOut, meetingsHeld: t.held, meetingsBooked: t.booked,
                                 latest: t.latest, latestThread: t.latestThread)
            }.sorted { $0.score != $1.score ? $0.score > $1.score : $0.key < $1.key }
            return (identity, list)
        }
    }

    // MARK: evidence

    static func matchSQL(_ key: String) -> (String, [DatabaseValueConvertible]) {
        if key.contains("@") {
            return ("(lower(fromEmail) = ? OR lower(toLine) LIKE ? OR lower(ccLine) LIKE ?)", [key, "%\(key)%", "%\(key)%"])
        }
        return ("(lower(fromEmail) LIKE ? OR lower(toLine) LIKE ? OR lower(ccLine) LIKE ?)", ["%@\(key)", "%@\(key)%", "%@\(key)%"])
    }

    /// The latest mails, meetings and calendar events with one company, trimmed for Claude.
    public func evidence(for c: Candidate, identity: Identity, now: Date = Date()) async throws -> Evidence {
        try await db.pool.read { db in
            let (clause, args) = Self.matchSQL(c.key)
            let msgs = try MailMessage.fetchAll(db, sql: """
                SELECT * FROM message WHERE \(clause) AND date >= ? AND date <= ? AND labelIds NOT LIKE '%|DRAFT|%' AND labelIds NOT LIKE '%|SPAM|%'
                ORDER BY date DESC LIMIT 8
                """, arguments: StatementArguments(args + [now.addingTimeInterval(-120 * 86400), now])).reversed()
            var used = Set<String>()
            let mails = msgs.compactMap { m -> Evidence.Mail? in
                let fromUser = m.labels.contains(GmailLabel.sent) || identity.isMe(m.fromEmail)
                if fromUser { used.insert(m.fromEmail.lowercased()) }
                else {
                    if Self.isAutomaticSubject(m.subject) { return nil }
                    for e in Self.recipientsOf(m) where identity.isMe(e) { used.insert(e) }
                }
                let who = fromUser ? "USER" : (m.fromName.isEmpty ? m.fromEmail : "\(m.fromName) <\(m.fromEmail)>")
                return Evidence.Mail(fromUser: fromUser, from: who, date: m.date, subject: m.subject, text: String(Self.newText(m.bodyText).prefix(700)))
            }
            let pattern = c.key.contains("@") ? "%\(c.key)%" : "%@\(c.key)%"
            let meetingRows = try MeetingRecord.fetchAll(db, sql: "SELECT * FROM meeting WHERE lower(attendeesJSON) LIKE ? AND startedAt >= ? ORDER BY startedAt DESC LIMIT 4",
                                                         arguments: [pattern, now.addingTimeInterval(-120 * 86400)])
            var meetingIds = Set(meetingRows.map(\.id))
            var meetings = meetingRows
            // Recordings linked to a calendar event carry the guests on the event, not on the recording.
            for (e, keys) in try Self.meetingsWithOthers(db, from: now.addingTimeInterval(-120 * 86400), to: now, identity: identity) where keys.contains(c.key) {
                if let m = try MeetingRecord.filter(Column("eventId") == e.eventId).fetchOne(db), meetingIds.insert(m.id).inserted { meetings.append(m) }
            }
            let withSummaries = try meetings.sorted { $0.startedAt < $1.startedAt }.suffix(4).map { m in
                let s = try MeetingSummaryRecord.fetchOne(db, key: m.id)
                return Evidence.Meeting(title: m.title, date: m.startedAt, summary: String((s?.summary ?? "").prefix(900)),
                                        actionItems: s?.actionItems ?? [], decisions: s?.decisions ?? [])
            }
            let events = try Self.meetingsWithOthers(db, from: now.addingTimeInterval(-120 * 86400), to: now.addingTimeInterval(120 * 86400), identity: identity)
                .filter { $0.keys.contains(c.key) }.map(\.event)
            // Who actually works there: a mail can name people at other companies, and Claude then credits them to this one.
            var people: [String: String] = [:]
            func addPerson(_ name: String, _ email: String) {
                let e = email.lowercased()
                guard Self.key(for: e) == c.key, !identity.isMe(e), !Self.isRobot(e) else { return }
                if (people[e] ?? "").isEmpty { people[e] = name }
            }
            // People who write from a shared address like info@ sign their mails, and the user greets them by name.
            var companyText: [String] = []
            for r in try Row.fetchAll(db, sql: """
                SELECT fromName, fromEmail, toLine, ccLine, bodyText, labelIds FROM message WHERE \(clause) AND date >= ? AND date <= ? ORDER BY date DESC
                """, arguments: StatementArguments(args + [now.addingTimeInterval(-120 * 86400), now])) {
                let from: String = r["fromEmail"]
                addPerson(r["fromName"], from)
                for raw in GmailParser.splitAddresses((r["toLine"] as String) + ", " + (r["ccLine"] as String)) {
                    let a = GmailParser.parseAddress(raw)
                    addPerson(a.name, a.email)
                }
                guard companyText.count < 30 else { continue }
                let own = Self.newText(r["bodyText"], keepSignature: true)
                if Self.key(for: from) == c.key { companyText.append(String(own.prefix(3000))) }
                else if identity.isMe(from) || (r["labelIds"] as String).contains("|SENT|"), let name = Self.greetedName(own) { companyText.append(name) }
            }
            for e in events { for a in e.attendees { addPerson(a.name ?? "", a.email) } }
            let peopleList = people.map { $0.value.isEmpty ? $0.key : "\($0.value) <\($0.key)>" }.sorted().prefix(12)
            return Evidence(candidate: c, userAddresses: used.sorted(), people: Array(peopleList), companyText: companyText.joined(separator: "\n"), mails: Array(mails),
                            meetings: withSummaries,
                            pastEvents: events.filter { $0.startAt <= now }.suffix(4).map { Evidence.Event(title: $0.summary, date: $0.startAt) },
                            upcoming: events.filter { $0.startAt > now }.prefix(3).map { Evidence.Event(title: $0.summary, date: $0.startAt) })
        }
    }

    /// Keeps the contacts whose name matches someone seen at the company and drops people a mail only mentions.
    /// With no people known it keeps everything.
    /// A name counts when it is in the company's mail headers, inside one of its addresses (bramvandenberg@), or in what
    /// its people wrote, like a signature under a mail from info@.
    public static func groundedContacts(_ contacts: String, people: [String], companyText: String = "") -> String {
        guard !people.isEmpty || !companyText.isEmpty else { return contacts }
        let locals = people.compactMap { p -> String? in
            guard let r = p.range(of: "[A-Za-z0-9._%+-]+(?=@)", options: .regularExpression) else { return nil }
            return p[r].lowercased()
        }
        let known = Set(people.flatMap { nameTokens($0.replacingOccurrences(of: "@[^>\\s]+", with: "", options: .regularExpression)) } + nameTokens(companyText))
        return contacts.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { entry in
                let name = entry.components(separatedBy: ",").first ?? entry
                return nameTokens(name).contains { t in known.contains(t) || (t.count >= 4 && locals.contains { $0.contains(t) }) }
            }
            .joined(separator: "; ")
    }

    static let greetings: Set<String> = ["dag", "hi", "hey", "hoi", "hallo", "hello", "beste", "dear", "geachte", "goedemorgen", "goedemiddag",
                                         "bonjour", "cher", "chère", "salut"]

    /// The name after a greeting on the first line, like "Sven" in "Dag Sven,".
    static func greetedName(_ text: String) -> String? {
        guard let first = text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        let words = first.split(whereSeparator: { !$0.isLetter })
        guard let w = words.first, greetings.contains(w.lowercased()), words.count > 1 else { return nil }
        return words.dropFirst().prefix(4).joined(separator: " ")
    }

    static func nameTokens(_ s: String) -> [String] {
        let particles: Set<String> = ["de", "van", "der", "den", "het", "le", "la", "du", "von", "di", "da", "des", "ten", "ter"]
        return s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 3 && !particles.contains($0) }
    }

    static func recipientsOf(_ m: MailMessage) -> [String] {
        GmailParser.splitAddresses(m.toLine + ", " + m.ccLine).map { GmailParser.parseAddress($0).email.lowercased() }
    }

    /// The part of a mail its sender wrote, without the quoted thread below it.
    /// `keepSignature` reads on past a "-- " line, so the sender's name and role stay in.
    public static func newText(_ body: String, keepSignature: Bool = false) -> String {
        var lines: [String] = []
        for line in body.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            let quoteStart = l.hasPrefix(">") || (line == "-- " && !keepSignature) || l.hasPrefix("-----Original") || l.hasPrefix("________")
                || (l.hasPrefix("On ") && l.contains(" wrote")) || (l.hasPrefix("Op ") && l.contains(" schreef "))
                || (l.hasPrefix("Le ") && l.contains(" a écrit")) || l.hasSuffix("wrote:")
                || ((l.hasPrefix("From:") || l.hasPrefix("Van:") || l.hasPrefix("De :") || l.hasPrefix("Envoyé :") || l.hasPrefix("Verzonden:")) && !lines.isEmpty)
            if quoteStart { break }
            lines.append(line)
        }
        return lines.joined(separator: "\n").replacingOccurrences(of: "\n\n\n", with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: stored deals

    public func all() async throws -> [DealRecord] {
        try await db.pool.read { try DealRecord.fetchAll($0) }
    }

    public func save(_ records: [DealRecord]) async throws {
        try await db.pool.write { db in for r in records { try r.save(db) } }
    }

    /// One name per venture. Batches read side by side can call the same venture "Acme" and "acme.be",
    /// or "Getacme" and "Acme". A personal mail provider is no venture at all.
    public static func canonicalVentures(_ counts: [String: Int]) -> [String: String] {
        func core(_ n: String) -> String {
            var s = n.lowercased()
            if s.contains("."), let dot = s.lastIndex(of: ".") { s = String(s[..<dot]) }
            return s.filter { $0.isLetter || $0.isNumber }
        }
        func unclear(_ n: String) -> Bool { n.isEmpty || n.contains("@") || personalDomains.contains(n.lowercased()) || n == "Unclear" }
        let names = counts.keys.filter { !unclear($0) }
        var groups: [[String]] = []
        for n in names {
            let c = core(n)
            if let i = groups.firstIndex(where: { g in g.contains { o in
                let oc = core(o)
                return oc == c || (min(oc.count, c.count) >= 4 && (oc.contains(c) || c.contains(oc)))
            } }) { groups[i].append(n) } else { groups.append([n]) }
        }
        var map: [String: String] = [:]
        for n in counts.keys where unclear(n) { map[n] = "Unclear" }
        for g in groups {
            // A name without a dot is a brand rather than a domain; the shortest is the brand inside a domain like getacme.com.
            let best = g.sorted { a, b in
                if a.contains(".") != b.contains(".") { return !a.contains(".") }
                if a.count != b.count { return a.count < b.count }
                return (counts[a] ?? 0) > (counts[b] ?? 0)
            }[0]
            for n in g { map[n] = best }
        }
        return map
    }

    public func normalizeVentures() async throws {
        try await db.pool.write { db in
            var counts: [String: Int] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT venture, COUNT(*) AS n FROM deal GROUP BY venture") { counts[r["venture"]] = r["n"] }
            for (from, to) in Self.canonicalVentures(counts) where from != to {
                try db.execute(sql: "UPDATE deal SET venture = ? WHERE venture = ?", arguments: [to, from])
            }
        }
    }

    /// Drops deals that no longer have any recent activity.
    public func prune(keeping keys: Set<String>) async throws {
        try await db.pool.write { db in
            for k in try String.fetchAll(db, sql: "SELECT key FROM deal") where !keys.contains(k) { _ = try DealRecord.deleteOne(db, key: k) }
        }
    }

    // MARK: timelines

    /// Mail each way, meetings held and meetings booked with each company, between two dates.
    public func marks(for keys: Set<String>, from: Date, to: Date, now: Date = Date()) async throws -> [String: [Mark]] {
        guard !keys.isEmpty else { return [:] }
        return try await db.pool.read { db in
            let identity = try Self.identity(db)
            var out: [String: [Mark]] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT fromEmail, toLine, ccLine, subject, date, labelIds FROM message
                WHERE date >= ? AND date <= ? AND labelIds NOT LIKE '%|DRAFT|%' AND labelIds NOT LIKE '%|SPAM|%' AND labelIds NOT LIKE '%|TRASH|%'
                """, arguments: [from, min(to, now)])
            for r in rows {
                let fromEmail = (r["fromEmail"] as String).lowercased(), labels: String = r["labelIds"], date: Date = r["date"]
                if labels.contains("|SENT|") || identity.isMe(fromEmail) {
                    for k in Set(Self.recipients(r).map(Self.key(for:))) where keys.contains(k) { out[k, default: []].append(Mark(date: date, kind: .mailOut)) }
                } else if keys.contains(Self.key(for: fromEmail)), !Self.isAutomaticSubject(r["subject"]) {
                    out[Self.key(for: fromEmail), default: []].append(Mark(date: date, kind: .mailIn))
                }
            }
            for (e, ks) in try Self.meetingsWithOthers(db, from: from, to: to, identity: identity) {
                for k in ks where keys.contains(k) { out[k, default: []].append(Mark(date: e.startAt, kind: e.startAt <= now ? .meeting : .booked)) }
            }
            return out.mapValues { $0.sorted { $0.date < $1.date } }
        }
    }

    // MARK: secondary measures

    public struct FirstMailGroup: Sendable, Hashable { public let subject: String; public let sent: Int; public let replied: Int }

    /// First mails to new addresses in the last 12 weeks that had 7 days to get an answer, grouped by subject
    /// when 3 or more people got the same one.
    public func firstMailReplies(now: Date = Date()) async throws -> (groups: [FirstMailGroup], total: FirstMailGroup) {
        try await db.pool.read { db in
            let identity = try Self.identity(db)
            let start = now.addingTimeInterval(-84 * 86400), settled = now.addingTimeInterval(-7 * 86400)
            let rows = try Row.fetchAll(db, sql: """
                SELECT fromEmail, toLine, ccLine, subject, date, labelIds FROM message
                WHERE labelIds NOT LIKE '%|DRAFT|%' AND labelIds NOT LIKE '%|SPAM|%' ORDER BY date
                """)
            var seen = Set<String>()
            var inbound: [String: [Date]] = [:]
            for r in rows where !((r["labelIds"] as String).contains("|SENT|")) {
                inbound[(r["fromEmail"] as String).lowercased(), default: []].append(r["date"])
            }
            var firsts: [(subject: String, replied: Bool)] = []
            for r in rows {
                let from = (r["fromEmail"] as String).lowercased(), date: Date = r["date"]
                guard (r["labelIds"] as String).contains("|SENT|") || identity.isMe(from) else { seen.insert(from); continue }
                for e in Self.recipients(r) where !identity.isMe(e) && !identity.isInternal(e) && !seen.contains(e) {
                    seen.insert(e)
                    guard date >= start, date <= settled, !Self.isRobot(e) else { continue }
                    let replied = (inbound[e] ?? []).contains { $0 > date && $0 <= date.addingTimeInterval(7 * 86400) }
                    firsts.append((Self.baseSubject(r["subject"]), replied))
                }
            }
            let bySubject = Dictionary(grouping: firsts, by: \.subject)
            var groups: [FirstMailGroup] = []
            var oneOff = (sent: 0, replied: 0)
            for (s, xs) in bySubject {
                if xs.count >= 3 { groups.append(FirstMailGroup(subject: s, sent: xs.count, replied: xs.filter(\.replied).count)) }
                else { oneOff.sent += xs.count; oneOff.replied += xs.filter(\.replied).count }
            }
            groups.sort { $0.sent > $1.sent }
            if oneOff.sent > 0 { groups.append(FirstMailGroup(subject: "One-to-one first mails", sent: oneOff.sent, replied: oneOff.replied)) }
            return (groups, FirstMailGroup(subject: "All", sent: firsts.count, replied: firsts.filter(\.replied).count))
        }
    }

    static func baseSubject(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        while let r = t.range(of: #"^(re|fwd?|tr|aw|antw)\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) { t.removeSubrange(r) }
        return t.isEmpty ? "(no subject)" : t
    }

    public struct MeetingFollowUp: Sendable, Hashable {
        public let title: String
        public let date: Date
        /// Hours from the end of the meeting to the user's first mail to that company, or nil when none went out yet.
        public let lagHours: Double?
        /// A later meeting with the same company is booked, so an invite went out.
        public let invited: Bool
    }

    /// The most recent meetings with outside companies, and how soon a mail followed each.
    public func meetingFollowUps(now: Date = Date(), limit: Int = 8) async throws -> (recent: [MeetingFollowUp], medianHours: Double?, measured: Int) {
        try await db.pool.read { db in
            let identity = try Self.identity(db)
            let since = now.addingTimeInterval(-60 * 86400)
            let all = try Self.meetingsWithOthers(db, from: since, to: now.addingTimeInterval(120 * 86400), identity: identity)
            let held = all.filter { $0.event.endAt <= now }
            let sent = try Row.fetchAll(db, sql: "SELECT toLine, ccLine, date FROM message WHERE date >= ? AND labelIds LIKE '%|SENT|%' ORDER BY date", arguments: [since])
                .map { r in (date: r["date"] as Date, keys: Set(Self.recipients(r).map(Self.key(for:)))) }
            let results = held.map { item -> MeetingFollowUp in
                let e = item.event, keys = item.keys
                let first = sent.first { $0.date > e.endAt && !$0.keys.isDisjoint(with: keys) }
                let invited = all.contains { $0.event.startAt > e.endAt && $0.event.eventId != e.eventId && !$0.keys.isDisjoint(with: keys) }
                return MeetingFollowUp(title: e.summary, date: e.startAt, lagHours: first.map { $0.date.timeIntervalSince(e.endAt) / 3600 }, invited: invited)
            }
            let lags = results.compactMap(\.lagHours).sorted()
            return (Array(results.suffix(limit).reversed()), lags.isEmpty ? nil : lags[lags.count / 2], lags.count)
        }
    }
}
