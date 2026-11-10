import Foundation
import GRDB

/// Where the follow-up mail after a meeting goes: a reply in the thread with its guests, or a new mail. Decided in plain code.
public enum MeetingFollowUp {
    public enum Target: Sendable, Equatable {
        /// One thread has the most guests in it: reply there.
        case reply(RelatedThread)
        /// Several threads are equally good: the user picks one, best first, or a new mail.
        case choose([RelatedThread])
        /// No thread with the guests around the meeting: a new mail.
        case new
    }

    /// Only threads with the guests themselves count, not those with colleagues only. The thread holding the most guests
    /// wins; a tie is the user's to settle.
    public static func target(_ related: [RelatedThread]) -> Target {
        let withGuests = related.filter { $0.guestsInThread > 0 }
            .sorted { ($0.guestsInThread, $0.lastAt) > ($1.guestsInThread, $1.lastAt) }
        guard let top = withGuests.first else { return .new }
        let tied = withGuests.filter { $0.guestsInThread == top.guestsInThread }
        return tied.count == 1 ? .reply(top) : .choose(withGuests)
    }

    /// The guests the mail goes to, as "Name <address>": everyone invited but the user and those who declined.
    public static func recipients(_ m: MeetingRecord, _ db: Database) throws -> [String] {
        let own = try Matching.ownAddresses(db)
        var seen = Set<String>()
        return try m.attendees.filter { !$0.isSelf && $0.response != "declined" }.compactMap { a in
            let e = a.email.lowercased()
            guard e.contains("@"), !own.contains(e), seen.insert(e).inserted else { return nil }
            let name = try Matching.name(for: e, given: a.name, db)
            return name == e ? e : GmailParser.recipient(name: name, email: e)
        }
    }

    /// The guests split in two: those at another company go in To, the user's own colleagues (an address at one of the
    /// user's company domains) go in Cc. A meeting with colleagues only writes to them.
    public static func addressees(_ m: MeetingRecord, _ db: Database) throws -> (to: [String], cc: [String]) {
        let ours = Set(try Matching.ownAddresses(db).compactMap(Matching.companyDomain))
        var to: [String] = [], cc: [String] = []
        for r in try recipients(m, db) {
            let e = GmailParser.parseAddress(r).email
            if Matching.companyDomain(e).map(ours.contains) == true { cc.append(r) } else { to.append(r) }
        }
        return to.isEmpty ? (cc, []) : (to, cc)
    }

    /// The account a new mail goes out from: the first account of the meeting's project, else the account of its calendar event.
    public static func account(_ m: MeetingRecord, _ db: Database) throws -> String? {
        let accounts = Set(try Account.fetchAll(db).map { $0.id.lowercased() })
        if let p = m.project, let rule = try ProjectConfig.load(db).projects.first(where: { $0.name == p }),
           let a = rule.accounts.map({ $0.lowercased() }).first(where: accounts.contains) { return a }
        return m.eventAccountId.flatMap { accounts.contains($0.lowercased()) ? $0 : nil }
    }
}
