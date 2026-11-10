import Foundation

public struct OutgoingAttachment: Codable, Hashable, Sendable {
    public var filename: String
    public var mimeType: String
    public var path: String
    /// Set for a picture shown inside the text, which the HTML refers to as `cid:<contentId>`.
    public var contentId: String?
    public init(filename: String, mimeType: String, path: String, contentId: String? = nil) {
        self.filename = filename; self.mimeType = mimeType; self.path = path; self.contentId = contentId
    }
}

public struct OutgoingMail: Codable, Hashable, Sendable {
    public var accountId: String
    public var fromName: String?
    /// A Gmail send-as address of the account (info@yourcompany.com kept in Gmail). Nil sends as the account itself.
    public var fromEmail: String?
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var subject: String
    public var textBody: String
    public var htmlBody: String?
    public var threadId: String?
    public var inReplyTo: String?
    public var references: String?
    public var attachments: [OutgoingAttachment]
    public var draftId: String?
    /// The thread the Gmail draft sits in. A new mail's draft has a thread of its own, separate from where the mail goes.
    public var draftThreadId: String?
    /// Bring the thread back if nobody answers. Watched from the moment it is actually sent.
    public var followUp: FollowUpRule?

    public init(accountId: String, fromName: String? = nil, to: [String], cc: [String] = [], bcc: [String] = [],
                subject: String, textBody: String, htmlBody: String? = nil, threadId: String? = nil,
                inReplyTo: String? = nil, references: String? = nil, attachments: [OutgoingAttachment] = [], draftId: String? = nil,
                draftThreadId: String? = nil) {
        self.accountId = accountId; self.fromName = fromName; self.to = to; self.cc = cc; self.bcc = bcc
        self.subject = subject; self.textBody = textBody; self.htmlBody = htmlBody; self.threadId = threadId
        self.inReplyTo = inReplyTo; self.references = references; self.attachments = attachments; self.draftId = draftId
        self.draftThreadId = draftThreadId
    }
}

extension OutgoingMail {
    func withFollowUp(_ rule: FollowUpRule?) -> OutgoingMail { var m = self; m.followUp = rule; return m }
}

/// Builds RFC 2822 / MIME for Gmail's `raw` send and drafts endpoints.
public enum MIMEBuilder {
    public static func build(_ mail: OutgoingMail, messageIdDomain: String? = nil, date: Date = Date()) throws -> Data {
        var head: [String] = []
        head.append("MIME-Version: 1.0")
        head.append("Date: \(rfc2822Date(date))")
        head.append("From: \(formatAddress(name: mail.fromName, email: mail.fromEmail ?? mail.accountId))")
        if !mail.to.isEmpty { head.append("To: \(formatAddressList(mail.to))") }
        if !mail.cc.isEmpty { head.append("Cc: \(formatAddressList(mail.cc))") }
        if !mail.bcc.isEmpty { head.append("Bcc: \(formatAddressList(mail.bcc))") }
        head.append("Subject: \(encodeHeader(mail.subject))")
        if let r = mail.inReplyTo, !r.isEmpty { head.append("In-Reply-To: \(r)") }
        if let r = mail.references, !r.isEmpty { head.append("References: \(r)") }

        let html = mail.htmlBody
        let alternative: Data
        var altHeaders: [String]
        if let html {
            let boundary = "alt_" + UUID().uuidString
            altHeaders = ["Content-Type: multipart/alternative; boundary=\"\(boundary)\""]
            var b = Data()
            b.append(line("--\(boundary)"))
            b.append(textPart(mail.textBody, subtype: "plain"))
            b.append(line("--\(boundary)"))
            b.append(textPart(html, subtype: "html"))
            b.append(line("--\(boundary)--"))
            alternative = b
        } else {
            altHeaders = ["Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64"]
            alternative = base64Lines(Data(mail.textBody.utf8))
        }

        // Pictures inside the text travel next to the HTML that shows them, in multipart/related.
        let inline = html == nil ? [] : mail.attachments.filter { $0.contentId != nil }
        let files = html == nil ? mail.attachments : mail.attachments.filter { $0.contentId == nil }
        var bodyHeaders = altHeaders
        var body = alternative
        if !inline.isEmpty {
            let related = "rel_" + UUID().uuidString
            var d = Data()
            d.append(line("--\(related)"))
            d.append(line(altHeaders.joined(separator: "\r\n")))
            d.append(line(""))
            d.append(alternative)
            for a in inline {
                let data = try Data(contentsOf: URL(fileURLWithPath: a.path))
                let fname = encodeFilename(a.filename)
                d.append(line("--\(related)"))
                d.append(line("Content-Type: \(a.mimeType); name=\(fname)"))
                d.append(line("Content-ID: <\(a.contentId!)>"))
                d.append(line("Content-Disposition: inline; filename=\(fname)"))
                d.append(line("Content-Transfer-Encoding: base64"))
                d.append(line(""))
                d.append(base64Lines(data))
            }
            d.append(line("--\(related)--"))
            bodyHeaders = ["Content-Type: multipart/related; boundary=\"\(related)\""]
            body = d
        }

        var out = Data()
        if files.isEmpty {
            out.append(line((head + bodyHeaders).joined(separator: "\r\n")))
            out.append(line(""))
            out.append(body)
            return out
        }

        let mixed = "mix_" + UUID().uuidString
        head.append("Content-Type: multipart/mixed; boundary=\"\(mixed)\"")
        out.append(line(head.joined(separator: "\r\n")))
        out.append(line(""))
        out.append(line("--\(mixed)"))
        out.append(line(bodyHeaders.joined(separator: "\r\n")))
        out.append(line(""))
        out.append(body)
        for a in files {
            let data = try Data(contentsOf: URL(fileURLWithPath: a.path))
            out.append(line("--\(mixed)"))
            let fname = encodeFilename(a.filename)
            out.append(line("Content-Type: \(a.mimeType); name=\(fname)"))
            out.append(line("Content-Disposition: attachment; filename=\(fname)"))
            out.append(line("Content-Transfer-Encoding: base64"))
            out.append(line(""))
            out.append(base64Lines(data))
        }
        out.append(line("--\(mixed)--"))
        return out
    }

    private static func line(_ s: String) -> Data { Data((s + "\r\n").utf8) }

    private static func textPart(_ s: String, subtype: String) -> Data {
        var d = line("Content-Type: text/\(subtype); charset=UTF-8")
        d.append(line("Content-Transfer-Encoding: base64"))
        d.append(line(""))
        d.append(base64Lines(Data(s.utf8)))
        return d
    }

    static func base64Lines(_ data: Data) -> Data {
        Data((data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]) + "\r\n").utf8)
    }

    /// RFC 2047 encoded-word, split so no single word exceeds 75 characters.
    public static func encodeHeader(_ s: String) -> String {
        // Header injection guard: a header value never carries line breaks.
        let clean = s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        if clean.allSatisfy({ $0.isASCII }) { return clean }
        var words: [String] = [], cur = ""
        for ch in clean {
            let next = cur + String(ch)
            if Data(next.utf8).count > 42 { words.append(cur); cur = String(ch) } else { cur = next }
        }
        if !cur.isEmpty { words.append(cur) }
        return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    private static func encodeFilename(_ s: String) -> String {
        let clean = s.replacingOccurrences(of: "\"", with: "'")
        return clean.allSatisfy({ $0.isASCII }) ? "\"\(encodeHeader(clean))\"" : encodeHeader(clean)
    }

    public static func formatAddress(name: String?, email: String) -> String {
        let cleanEmail = email.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        guard let name, !name.isEmpty else { return cleanEmail }
        let isPlain = name.allSatisfy { $0.isASCII }
        let n = isPlain ? "\"\(encodeHeader(name).replacingOccurrences(of: "\"", with: ""))\"" : encodeHeader(name)
        return "\(n) <\(cleanEmail)>"
    }

    static func formatAddressList(_ list: [String]) -> String {
        list.map { raw in
            let (n, e) = GmailParser.parseAddress(raw)
            return formatAddress(name: n, email: e)
        }.joined(separator: ", ")
    }

    static func rfc2822Date(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: d)
    }

    /// Escapes plain text for the HTML alternative part.
    public static func textToHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>")
    }
}
