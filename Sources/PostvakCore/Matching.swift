import Foundation
import GRDB

/// Matching people and companies in plain code: by exact address, or by company domain. Never by name.
public enum Matching {
    /// Mail providers anyone can sign up at: an address there says nothing about someone's company.
    public static let genericDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "outlook.be", "hotmail.com", "hotmail.be", "live.com", "live.be", "msn.com",
        "icloud.com", "me.com", "mac.com", "yahoo.com", "yahoo.fr", "skynet.be", "telenet.be", "proximus.be", "scarlet.be",
        "gmx.de", "gmx.net", "protonmail.com", "proton.me", "bluewin.ch", "orange.fr", "free.fr", "aol.com",
    ]

    /// The domain of an address, lowercased.
    public static func domain(_ email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        let d = String(email[email.index(after: at)...]).lowercased().trimmingCharacters(in: .whitespaces)
        return d.isEmpty ? nil : d
    }

    /// The company domain of an address, or nil for a generic provider.
    public static func companyDomain(_ email: String) -> String? {
        guard let d = domain(email), !genericDomains.contains(d) else { return nil }
        return d
    }

    /// The addresses in a To or Cc line, lowercased.
    public static func addresses(in line: String) -> Set<String> {
        Set(GmailParser.splitAddresses(line).map { GmailParser.parseAddress($0).email.lowercased() }.filter { $0.contains("@") })
    }

    /// `pv_has_address(line, email)` in SQL: whether a To or Cc line holds exactly that address. Pair it with a LIKE
    /// on the same line first, which is fast and lets this one weed out "dejan@x.be" when looking for "jan@x.be".
    static let hasAddressFunction = DatabaseFunction("pv_has_address", argumentCount: 2, pure: true) { values in
        guard let line = String.fromDatabaseValue(values[0]), let email = String.fromDatabaseValue(values[1]) else { return false }
        return addresses(in: line).contains(email.lowercased())
    }

    /// The user's own addresses: the connected accounts and every address they sent mail from.
    public static func ownAddresses(_ db: Database) throws -> Set<String> {
        var out = Set(try Account.fetchAll(db).map { $0.id.lowercased() })
        out.formUnion(try String.fetchAll(db, sql: "SELECT DISTINCT lower(fromEmail) FROM message WHERE labelIds LIKE '%|SENT|%'"))
        return out
    }

    /// The name people know an address by: the one in the invitation, or else the latest one it sent mail under.
    public static func name(for email: String, given: String?, _ db: Database) throws -> String {
        if let g = given?.trimmingCharacters(in: .whitespaces), !g.isEmpty { return g }
        let n = try String.fetchOne(db, sql: """
            SELECT fromName FROM message WHERE lower(fromEmail) = ? AND fromName != '' ORDER BY date DESC LIMIT 1
            """, arguments: [email.lowercased()])
        return n?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) ?? email
    }

    /// Replaces `old` with `new` where it stands as a whole word, matching case exactly.
    public static func replaceWhole(_ old: String, with new: String, in text: String) -> String {
        guard !old.isEmpty, old != new else { return text }
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: old) + "(?![\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                           withTemplate: NSRegularExpression.escapedTemplate(for: new))
    }
}
