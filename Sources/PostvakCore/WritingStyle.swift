import Foundation
import GRDB
import NaturalLanguage

/// The user's writing style: a short description of how they write, which every drafting prompt carries, so drafts sound
/// like them. It lives in the user's own data folder (`writing-style.md`, readable by this user only), is never synced
/// anywhere, and can be edited or deleted from Settings → AI. Empty means no profile: drafts then learn the tone from
/// past emails alone.
public struct WritingStyle: Sendable {
    public let file: URL

    public init(paths: AppPaths) { file = paths.root.appendingPathComponent("writing-style.md") }

    /// The profile, or empty when there is none.
    public func load() -> String {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Saves the profile. Saving an empty text deletes it.
    public func save(_ text: String) throws {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return try delete() }
        try Data((t + "\n").utf8).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public func delete() throws {
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    public var exists: Bool { !load().isEmpty }

    /// When the profile was last saved, or nil without one.
    public var savedAt: Date? {
        guard exists else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }
}

/// Text helpers for mail bodies.
public enum MailText {
    /// Text before the quoted earlier mail, so a sample shows only what its sender wrote.
    public static func ownText(_ body: String) -> String {
        var lines: [String] = []
        for line in body.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            // Gmail's quote lines: "On … wrote:", "Op … schreef Jan:", "Le … a écrit :".
            let quoteLine = (l.hasPrefix("On ") && l.contains(" wrote")) || (l.hasPrefix("Op ") && l.contains(" schreef "))
                || (l.hasPrefix("Le ") && l.contains(" a écrit")) || l.hasSuffix("wrote:")
            if l.hasPrefix(">") || quoteLine || line == "-- " { break }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "nl", "fr", "en" or "de" when the text is clearly one of them, else nil.
    public static func language(_ text: String) -> String? {
        let t = text.prefix(1500)
        guard t.count >= 20 else { return nil }
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.dutch, .french, .english, .german]
        r.processString(String(t))
        guard let top = r.languageHypotheses(withMaximum: 2).max(by: { $0.value < $1.value }), top.value >= 0.5 else { return nil }
        return top.key.rawValue
    }
}

/// Picks the user's own past emails that a new draft should sound like: to the same people first, then to the same
/// company, then in the same language, the newest first among equals.
public enum StyleExamples {
    /// How many examples a prompt carries.
    public static let count = 5
    /// How many recent sent mails are considered.
    static let window = 500

    /// Domains many unrelated people share: matching one says nothing about the recipient.
    static let sharedDomains: Set<String> = ["gmail.com", "googlemail.com", "hotmail.com", "outlook.com", "live.com", "icloud.com",
                                             "me.com", "yahoo.com", "skynet.be", "telenet.be", "proximus.be", "msn.com", "hotmail.be"]

    /// - Parameters:
    ///   - recipients: who the draft goes to (To and CC), as address lines.
    ///   - about: text in the language the draft will be in (the thread's last mail), used to prefer that language.
    ///   - language: the draft's language when already known ("nl", "fr", "en"); wins over `about`.
    ///   - excludingThread: the thread being answered, whose own mails are already in the prompt.
    public static func pick(_ db: Database, accountId: String, recipients: [String], about: String = "", language: String? = nil,
                            excludingThread: String? = nil, limit: Int = count) throws -> [String] {
        var q = MailMessage.filter(Column("accountId") == accountId && Column("labelIds").like("%|SENT|%") && !Column("labelIds").like("%|DRAFT|%"))
        if let excludingThread { q = q.filter(Column("threadId") != excludingThread) }
        let sent = try q.order(Column("date").desc).limit(window).fetchAll(db)
        return rank(sent, recipients: recipients, language: language ?? MailText.language(about), limit: limit)
    }

    /// The ranking behind `pick`, on mails already read.
    static func rank(_ sent: [MailMessage], recipients: [String], language: String?, limit: Int) -> [String] {
        let emails = Set(recipients.map { GmailParser.parseAddress($0).email.lowercased() }.filter { !$0.isEmpty })
        let domains = Set(emails.compactMap(domain).filter { !sharedDomains.contains($0) })
        var seen = Set<String>()
        var scored: [(score: Int, order: Int, text: String)] = []
        for (i, m) in sent.enumerated() {
            let text = MailText.ownText(m.bodyText)
            // Too short says nothing about style ("Ok, merci!"); very long is a document, not a mail.
            guard text.count >= 40, text.count <= 4000, seen.insert(text).inserted else { continue }
            let to = Set(GmailParser.splitAddresses(m.toLine + "," + m.ccLine).map { GmailParser.parseAddress($0).email.lowercased() })
            var score = 0
            if !emails.isDisjoint(with: to) { score += 100 }
            else if !domains.isDisjoint(with: Set(to.compactMap(domain))) { score += 40 }
            if let language { score += MailText.language(text) == language ? 30 : 0 }
            scored.append((score, i, text))
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }.prefix(limit).map(\.text)
    }

    /// Samples to build a profile from: the newest substantial sent mails, at most `limit`.
    public static func forProfile(_ db: Database, accountIds: [String], limit: Int = 80) throws -> [String] {
        guard !accountIds.isEmpty else { return [] }
        let sent = try MailMessage.filter(accountIds.contains(Column("accountId")) && Column("labelIds").like("%|SENT|%") && !Column("labelIds").like("%|DRAFT|%"))
            .order(Column("date").desc).limit(window).fetchAll(db)
        var seen = Set<String>(), out: [String] = []
        for m in sent {
            let text = MailText.ownText(m.bodyText)
            guard text.count >= 60, text.count <= 4000, seen.insert(text).inserted else { continue }
            out.append(text)
            if out.count == limit { break }
        }
        return out
    }

    static func domain(_ email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        let d = email[email.index(after: at)...]
        return d.isEmpty ? nil : String(d)
    }
}
