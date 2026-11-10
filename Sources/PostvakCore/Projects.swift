import Foundation
import GRDB

/// One project meetings are filed under, and what marks a meeting as belonging to it.
public struct ProjectRule: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    /// The user's own Gmail accounts for this project: an invite to one of them, or mail kept in it, counts for the project.
    public var accounts: [String]
    /// Exact addresses: the user's own aliases (info@yourcompany.com) or contacts at a generic provider such as gmail.com.
    public var addresses: [String]
    /// Company domains. Generic providers are ignored here, because they say nothing about a company.
    public var domains: [String]
    public var id: String { name }
    public init(name: String, accounts: [String] = [], addresses: [String] = [], domains: [String] = []) {
        self.name = name; self.accounts = accounts; self.addresses = addresses; self.domains = domains
    }

    /// Lowercased and trimmed, empty entries and generic domains removed.
    public var cleaned: ProjectRule {
        func list(_ l: [String]) -> [String] {
            var seen = Set<String>()
            return l.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        return ProjectRule(name: name.trimmingCharacters(in: .whitespacesAndNewlines), accounts: list(accounts), addresses: list(addresses),
                           domains: list(domains.map { $0.hasPrefix("@") ? String($0.dropFirst()) : $0 }).filter { !Matching.genericDomains.contains($0) })
    }
}

/// The editable mapping rules, kept as JSON in the settings table under `projects.rules`.
public struct ProjectConfig: Codable, Hashable, Sendable {
    public var projects: [ProjectRule]
    public init(projects: [ProjectRule]) { self.projects = projects }

    public static let settingKey = "projects.rules"

    /// The starting rules: one project per connected account. A company account is named after its domain and gets
    /// that domain; an account at a generic provider is Personal. Only a first suggestion: everything can be edited in
    /// Settings, where aliases such as an info@ address are added.
    public static func defaults(accounts: [String]) -> ProjectConfig {
        var out: [ProjectRule] = []
        for a in accounts.map({ $0.lowercased() }).sorted() {
            if let d = Matching.companyDomain(a) {
                let name = d.split(separator: ".").first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? d
                out.append(ProjectRule(name: name, accounts: [a], domains: [d]))
            } else if let i = out.firstIndex(where: { $0.name == "Personal" }) {
                out[i].accounts.append(a)
            } else {
                out.append(ProjectRule(name: "Personal", accounts: [a]))
            }
        }
        return ProjectConfig(projects: out)
    }

    public static func load(_ db: Database) throws -> ProjectConfig {
        if let raw = try SettingRow.fetchOne(db, key: settingKey)?.value,
           let c = try? JSONDecoder().decode(ProjectConfig.self, from: Data(raw.utf8)) { return c }
        return defaults(accounts: try Account.fetchAll(db).map(\.id))
    }

    public var names: [String] { projects.map(\.name) }
}

/// Files meetings under projects by plain rules. A choice the user made is never overwritten.
public enum Projects {
    public struct Filing: Equatable, Sendable {
        public var project: String?
        public var source: String
    }

    /// The share of mail with someone that has to sit in one project before the meeting follows it.
    static let mailShare = 0.8
    static let mailMinimum = 3

    /// Works out the project of a meeting:
    /// 0. An imported meeting whose title starts with a folder tag that is exactly a project's name, like "[Acme] Demo".
    /// 1. A guest's exact address or company domain listed under a project.
    /// 2. The user's own company address the invitation went to. An invite to a generic address such as gmail.com says
    ///    nothing, because that calendar receives everything.
    /// 3. The mail with these guests: at least 80% of the mail that shows a company address (sent from or to a project's
    ///    address, or kept in a company account) belongs to one project. Mail in a generic account such as Gmail only
    ///    counts when none of it shows a company address, since that account receives everything.
    /// Signals pointing at two projects count as no answer, so the meeting stays unfiled rather than guess.
    public static func classify(_ db: Database, config: ProjectConfig, emails: [String], tag: String? = nil, context: Context? = nil) throws -> Filing {
        let rules = config.projects.map(\.cleaned)
        if let tag, let r = rules.first(where: { $0.name.caseInsensitiveCompare(tag) == .orderedSame }) {
            return Filing(project: r.name, source: "import")
        }
        let ctx = context ?? Context()
        let own = try ctx.own(db).union(rules.flatMap { $0.accounts })
        let people = Set(emails.map { $0.lowercased() }.filter { $0.contains("@") })
        let guests = people.subtracting(own)
        let mine = people.intersection(own)

        // 1. Guests named in the rules.
        var byRules = Set<String>()
        for g in guests {
            for r in rules where r.addresses.contains(g) || Matching.companyDomain(g).map(r.domains.contains) == true { byRules.insert(r.name) }
        }
        if byRules.count == 1 { return Filing(project: byRules.first, source: "rules") }
        if byRules.count > 1 { return Filing(project: nil, source: "none") }

        // 2. The user's own company address the invitation went to.
        var invited = Set<String>()
        for a in mine where Matching.companyDomain(a) != nil {
            for r in rules where r.accounts.contains(a) || r.addresses.contains(a) { invited.insert(r.name) }
        }
        if invited.count == 1 { return Filing(project: invited.first, source: "rules") }

        // 3. The mail with the guests.
        var company: [String: Int] = [:], hub: [String: Int] = [:]
        for g in guests {
            let c = try ctx.projects(of: g, db, rules: rules)
            company.merge(c.company, uniquingKeysWith: +)
            hub.merge(c.hub, uniquingKeysWith: +)
        }
        func winner(_ votes: [String: Int], minimum: Int) -> String? {
            let total = votes.values.reduce(0, +)
            guard total >= minimum, let (best, n) = votes.max(by: { $0.value < $1.value }), Double(n) / Double(total) >= mailShare else { return nil }
            return best
        }
        if !company.isEmpty {
            if let p = winner(company, minimum: 2) { return Filing(project: p, source: "mail") }
        } else if let p = winner(hub, minimum: mailMinimum) {
            return Filing(project: p, source: "mail")
        }
        return Filing(project: nil, source: "none")
    }

    /// The project of a mail about to go out. A recipient's company that is a deal of one venture decides first, since
    /// the deals list knows prospects whose mail all arrives in a personal Gmail. Then the same rules as for meetings:
    /// addresses and domains in the rules, then the mail with these people.
    public static func forOutgoing(_ db: Database, config: ProjectConfig, recipients: [String]) throws -> Filing {
        let rules = config.projects.map(\.cleaned)
        let own = try Matching.ownAddresses(db).union(rules.flatMap { $0.accounts + $0.addresses })
        let people = recipients.map { GmailParser.parseAddress($0).email }.filter { $0.contains("@") && !own.contains($0) }
        guard !people.isEmpty else { return Filing(project: nil, source: "none") }
        var ventures = Set<String>()
        for p in people {
            let key = Matching.companyDomain(p) ?? p
            guard let v = try String.fetchOne(db, sql: "SELECT venture FROM deal WHERE key = ? AND isDeal = 1", arguments: [key]),
                  let r = rules.first(where: { $0.name.caseInsensitiveCompare(v) == .orderedSame }) else { continue }
            ventures.insert(r.name)
        }
        if ventures.count == 1 { return Filing(project: ventures.first, source: "deal") }
        return try classify(db, config: config, emails: people)
    }

    /// The folder tag an imported meeting's title starts with: "Kickoff" has none, "[Acme] Kickoff" has "Acme".
    static func importTag(of m: MeetingRecord) -> String? {
        guard m.source != "recorded", m.title.hasPrefix("["), let end = m.title.firstIndex(of: "]") else { return nil }
        let tag = m.title[m.title.index(after: m.title.startIndex)..<end].trimmingCharacters(in: .whitespaces)
        return tag.isEmpty ? nil : tag
    }

    /// The people of a meeting the rules look at: its guests, with the organiser of its calendar event.
    static func emails(of m: MeetingRecord, _ db: Database) throws -> [String] {
        var out = m.attendees.map(\.email)
        if let c = m.eventCalendarId, let id = m.eventId {
            for e in try CalendarEvent.filter(Column("calendarId") == c && Column("eventId") == id).fetchAll(db) {
                out.append(e.organizerEmail)
                out += e.attendees.map(\.email)
            }
        }
        return out
    }

    public static func emails(of e: CalendarEvent) -> [String] { e.attendees.map(\.email) + [e.organizerEmail] }

    /// What one filing run looks up once: the user's own addresses, and how much mail with each person or company
    /// sits in each project.
    public final class Context: @unchecked Sendable {
        private var ownAddresses: Set<String>?
        private var counts: [String: (company: [String: Int], hub: [String: Int])] = [:]
        public init() {}

        func own(_ db: Database) throws -> Set<String> {
            if let o = ownAddresses { return o }
            let o = try Matching.ownAddresses(db)
            ownAddresses = o
            return o
        }

        /// For a company address, all mail with its domain; for an address at a generic provider, mail with that address.
        /// A message counts for the project of the own alias it was sent from, else of the project address it was sent to
        /// (info@yourcompany.com read in Gmail is still company mail), else of the account it is kept in.
        func projects(of email: String, _ db: Database, rules: [ProjectRule]) throws -> (company: [String: Int], hub: [String: Int]) {
            let domain = Matching.companyDomain(email)
            let key = domain ?? email
            if let c = counts[key] { return c }
            let rows: [Row]
            if let domain {
                rows = try Row.fetchAll(db, sql: """
                    SELECT accountId, lower(fromEmail) AS f, toLine, ccLine FROM message
                    WHERE labelIds NOT LIKE '%|DRAFT|%' AND labelIds NOT LIKE '%|SPAM|%' AND labelIds NOT LIKE '%|TRASH|%'
                    AND (lower(fromEmail) LIKE ? OR lower(toLine) LIKE ? OR lower(ccLine) LIKE ?)
                    """, arguments: ["%@\(domain)", "%@\(domain)%", "%@\(domain)%"])
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT accountId, lower(fromEmail) AS f, toLine, ccLine FROM message
                    WHERE labelIds NOT LIKE '%|DRAFT|%' AND labelIds NOT LIKE '%|SPAM|%' AND labelIds NOT LIKE '%|TRASH|%'
                    AND (lower(fromEmail) = ? OR (lower(toLine) LIKE ? AND pv_has_address(toLine, ?)) OR (lower(ccLine) LIKE ? AND pv_has_address(ccLine, ?)))
                    """, arguments: [key, "%\(key)%", key, "%\(key)%", key])
            }
            var company: [String: Int] = [:], hub: [String: Int] = [:]
            // A project's own addresses: its listed addresses, and its accounts at a company domain.
            func marks(_ r: ProjectRule, _ a: String) -> Bool { r.addresses.contains(a) || (r.accounts.contains(a) && Matching.companyDomain(a) != nil) }
            for row in rows {
                let account = (row["accountId"] as String).lowercased(), from: String = row["f"]
                let recipients = Matching.addresses(in: (row["toLine"] as String? ?? "") + ", " + (row["ccLine"] as String? ?? ""))
                if let r = rules.first(where: { marks($0, from) }) ?? rules.first(where: { r in recipients.contains { marks(r, $0) } }) {
                    company[r.name, default: 0] += 1
                } else if let r = rules.first(where: { $0.accounts.contains(account) }) {
                    if Matching.companyDomain(account) != nil { company[r.name, default: 0] += 1 } else { hub[r.name, default: 0] += 1 }
                }
            }
            counts[key] = (company, hub)
            return (company, hub)
        }
    }
}

public extension MeetingStore {
    func projectConfig() async throws -> ProjectConfig {
        try await db.pool.read { try ProjectConfig.load($0) }
    }

    func saveProjectConfig(_ c: ProjectConfig) async throws {
        let cleaned = ProjectConfig(projects: c.projects.map(\.cleaned).filter { !$0.name.isEmpty })
        let json = String(decoding: try JSONEncoder().encode(cleaned), as: UTF8.self)
        try await db.pool.write { try SettingRow(key: ProjectConfig.settingKey, value: json).save($0) }
        try await fileMeetings(onlyNew: false)
    }

    /// Files meetings by the rules. `onlyNew` touches only meetings never filed; otherwise every meeting the user did
    /// not file by hand is filed again, as after a change to the rules. `ids` limits it to those meetings.
    func fileMeetings(onlyNew: Bool, ids: [String]? = nil) async throws {
        // Worked out in a read, which never holds up mail sync; written in one short write after.
        let filings = try await db.pool.read { db -> [String: Projects.Filing] in
            let config = try ProjectConfig.load(db)
            var sql = "SELECT * FROM meeting WHERE (projectSource IS NULL OR projectSource != 'manual')"
            if onlyNew { sql += " AND projectSource IS NULL" }
            var meetings = try MeetingRecord.fetchAll(db, sql: sql)
            if let ids { meetings = meetings.filter { ids.contains($0.id) } }
            let ctx = Projects.Context()
            var out: [String: Projects.Filing] = [:]
            for m in meetings {
                let f = try Projects.classify(db, config: config, emails: try Projects.emails(of: m, db), tag: Projects.importTag(of: m), context: ctx)
                if m.project != f.project || m.projectSource != f.source { out[m.id] = f }
            }
            return out
        }
        guard !filings.isEmpty else { return }
        try await db.pool.write { db in
            for (id, f) in filings {
                // The user may have filed it by hand meanwhile.
                guard var m = try MeetingRecord.fetchOne(db, key: id), m.projectSource != "manual" else { continue }
                m.project = f.project
                m.projectSource = f.source
                try m.update(db)
            }
        }
    }

    /// The user's choice for one meeting. Nil files it by the rules again.
    func setProject(meetingId: String, project: String?, manual: Bool) async throws {
        if manual {
            try await db.pool.write { db in
                guard var m = try MeetingRecord.fetchOne(db, key: meetingId) else { return }
                m.project = project
                m.projectSource = "manual"
                try m.update(db)
            }
        } else {
            try await db.pool.write { db in
                guard var m = try MeetingRecord.fetchOne(db, key: meetingId) else { return }
                m.projectSource = nil
                try m.update(db)
            }
            try await fileMeetings(onlyNew: true, ids: [meetingId])
        }
    }

    /// The project an upcoming calendar meeting would be filed under.
    func project(for e: CalendarEvent) async throws -> Projects.Filing {
        try await db.pool.read { db in
            try Projects.classify(db, config: try ProjectConfig.load(db), emails: Projects.emails(of: e))
        }
    }
}
