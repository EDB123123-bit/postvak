import Foundation

/// Tagging people in a mail's text by typing "@": the part being typed, who it matches, and what
/// picking someone does to the address fields.
public enum Mentions {
    /// The "@" and what follows it up to the cursor. `range` covers both, in UTF-16 units.
    public struct Query: Equatable, Sendable {
        public let range: NSRange
        public let text: String
    }

    /// The tag being typed just before the cursor, if any. The "@" must start a word, so an email
    /// address typed out ("anna@zonnehoek.be") is left alone. A first and last name may be typed,
    /// so one space is allowed; a second one, or a new line, ends it.
    public static func query(in text: String, cursor: Int) -> Query? {
        let ns = text as NSString
        guard cursor > 0, cursor <= ns.length else { return nil }
        let start = max(0, cursor - 40)
        let before = ns.substring(with: NSRange(location: start, length: cursor - start)) as NSString
        let at = before.range(of: "@", options: .backwards)
        guard at.location != NSNotFound else { return nil }
        let atIndex = start + at.location
        if atIndex > 0 {
            let prev = ns.substring(with: NSRange(location: atIndex - 1, length: 1))
            guard prev.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || "([\"'«“".contains(prev) else { return nil }
        }
        let typed = ns.substring(with: NSRange(location: atIndex + 1, length: cursor - atIndex - 1))
        guard typed.rangeOfCharacter(from: .newlines) == nil, !typed.hasPrefix(" "),
              typed.filter({ $0 == " " }).count <= 1 else { return nil }
        // "@Anna " can still become "@Anna Vermeulen", but "@Anna Vermeulen " is finished.
        if typed.hasSuffix(" "), typed.dropLast().contains(" ") { return nil }
        return Query(range: NSRange(location: atIndex, length: cursor - atIndex), text: typed)
    }

    /// Whether a recipient ("Name <address>" or an address) fits what was typed. Nothing typed fits everyone.
    public static func matches(_ recipient: String, _ typed: String) -> Bool {
        let t = typed.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return true }
        let p = GmailParser.parseAddress(recipient)
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return p.name.range(of: t, options: opts) != nil || p.email.range(of: t, options: opts) != nil
    }

    /// The suggestions in order: people already on the mail, then others, each person once, without the sender's own addresses.
    public static func suggestions(typed: String, onMail: [String], others: [String], own: Set<String>, limit: Int = 8) -> [String] {
        var seen = own
        var out: [String] = []
        for r in onMail.filter({ matches($0, typed) }) + others {
            let e = GmailParser.parseAddress(r).email.lowercased()
            guard !e.isEmpty, seen.insert(e).inserted else { continue }
            out.append(r)
            if out.count == limit { break }
        }
        return out
    }

    /// What the tag shows in the text: the person's name, or their address when there is no name.
    public static func label(for recipient: String) -> String {
        let p = GmailParser.parseAddress(recipient)
        return "@" + (p.name.isEmpty ? p.email : p.name)
    }

    /// The To line with the tagged person added, or nil when they are already in To, Cc or Bcc.
    public static func to(adding recipient: String, to: String, cc: String, bcc: String) -> String? {
        let e = GmailParser.parseAddress(recipient).email.lowercased()
        let present = Set(GmailParser.splitAddresses([to, cc, bcc].joined(separator: ",")).map { GmailParser.parseAddress($0).email.lowercased() })
        guard !e.isEmpty, !present.contains(e) else { return nil }
        let kept = GmailParser.splitAddresses(to)
        return (kept + [recipient]).joined(separator: ", ")
    }
}
