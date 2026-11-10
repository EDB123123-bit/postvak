import Foundation

/// Turns Gmail API payloads into local rows. Pure, so it is covered by unit tests.
public enum GmailParser {
    public static func header(_ part: GmailPart?, _ name: String) -> String? {
        part?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Splits `"Name" <a@b>` into its parts.
    public static func parseAddress(_ raw: String) -> (name: String, email: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lt = s.lastIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {
            let name = s[..<lt].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
            return (name, String(s[s.index(after: lt)..<gt]).lowercased())
        }
        return ("", s.lowercased())
    }

    /// One recipient as it appears in an address list. A name such as `Peeters, An` gets quotes,
    /// because a bare comma separates recipients.
    public static func recipient(name: String, email: String) -> String {
        guard !name.isEmpty else { return email }
        let clean = name.replacingOccurrences(of: "\"", with: "")
        return clean.contains(where: { ",;<>@".contains($0) }) ? "\"\(clean)\" <\(email)>" : "\(clean) <\(email)>"
    }

    /// Whether a recipient holds one usable address. Google refuses the whole mail otherwise.
    public static func isValidRecipient(_ raw: String) -> Bool {
        parseAddress(raw).email.range(of: #"^[^\s@,;<>"]+@[^\s@,;<>"]+$"#, options: .regularExpression) != nil
    }

    /// Splits an address list on commas outside quotes.
    /// Splits on commas, and on the semicolons, tabs and line breaks of lists pasted from Outlook, Teams or a spreadsheet.
    public static func splitAddresses(_ line: String) -> [String] {
        var out: [String] = [], cur = "", quoted = false, angle = false
        for ch in line {
            if ch == "\"" { quoted.toggle() }
            if ch == "<" { angle = true }
            if ch == ">" { angle = false }
            if [",", ";", "\t"].contains(ch) || ch.isNewline, !quoted, !angle {
                let t = cur.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(t) }
                cur = ""
            } else { cur.append(ch) }
        }
        let t = cur.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { out.append(t) }
        return out
    }

    struct Walked {
        var text: [String] = []
        var html: [String] = []
        var attachments: [(partId: String, attachmentId: String, filename: String, mime: String, size: Int, cid: String?)] = []
    }

    static func walk(_ part: GmailPart, into w: inout Walked) {
        let mime = part.mimeType?.lowercased() ?? ""
        let filename = part.filename ?? ""
        let cid = header(part, "Content-ID")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        if let id = part.body?.attachmentId, !id.isEmpty {
            w.attachments.append((part.partId ?? UUID().uuidString, id,
                                  filename.isEmpty ? (cid ?? "attachment") : filename, mime, part.body?.size ?? 0, cid))
        } else if filename.isEmpty, let d = part.body?.data, let data = Data(base64URL: d) {
            let s = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            if mime == "text/plain" { w.text.append(s) }
            else if mime == "text/html" { w.html.append(s) }
        }
        for p in part.parts ?? [] { walk(p, into: &w) }
    }

    public static func htmlToText(_ html: String) -> String {
        var s = html
        for (pattern, rep) in [("(?is)<(script|style|head)[^>]*>.*?</\\1>", " "), ("(?i)<br\\s*/?>", "\n"),
                               ("(?i)</(p|div|tr|li|h[1-6])>", "\n"), ("(?s)<[^>]+>", " ")] {
            s = s.replacingOccurrences(of: pattern, with: rep, options: .regularExpression)
        }
        for (e, r) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            s = s.replacingOccurrences(of: e, with: r)
        }
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func decodeEntities(_ s: String) -> String {
        var out = s
        for (e, r) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: e, with: r)
        }
        return out
    }

    public static func parse(_ m: GmailMessage, accountId: String, threadId: String) -> (MailMessage, [AttachmentRecord]) {
        var w = Walked()
        if let p = m.payload { walk(p, into: &w) }
        let html = w.html.isEmpty ? nil : w.html.joined(separator: "<hr>")
        let text = w.text.isEmpty ? (html.map(htmlToText) ?? "") : w.text.joined(separator: "\n")
        let (name, email) = parseAddress(header(m.payload, "From") ?? "")
        let date = m.internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        let msg = MailMessage(
            accountId: accountId, messageId: m.id, threadId: threadId,
            rfcMessageId: header(m.payload, "Message-ID") ?? header(m.payload, "Message-Id"),
            inReplyTo: header(m.payload, "In-Reply-To"), referencesHeader: header(m.payload, "References"),
            fromName: name, fromEmail: email,
            toLine: header(m.payload, "To") ?? "", ccLine: header(m.payload, "Cc") ?? "",
            subject: header(m.payload, "Subject") ?? "", date: date,
            snippet: decodeEntities(m.snippet ?? ""), bodyText: text, bodyHtml: html,
            labelIds: LabelSet.encode(m.labelIds ?? []),
            hasListUnsubscribe: header(m.payload, "List-Unsubscribe") != nil)
        let atts = w.attachments.map {
            AttachmentRecord(accountId: accountId, messageId: m.id, partId: $0.partId, attachmentId: $0.attachmentId,
                             filename: $0.filename, mimeType: $0.mime, size: $0.size, contentId: $0.cid, localPath: nil)
        }
        return (msg, atts)
    }

    /// First-pass bucket from Gmail's own categories. No API cost.
    public static func firstPassBucket(labels: Set<String>, senderIsAutomated: Bool) -> (bucket: InboxBucket, askAI: Bool) {
        if labels.contains(GmailLabel.catPromotions) { return (.newsletters, !senderIsAutomated) }
        if labels.contains(GmailLabel.catUpdates) || labels.contains(GmailLabel.catSocial) || labels.contains(GmailLabel.catForums) {
            return (.notifications, false)
        }
        if labels.contains(GmailLabel.catPersonal) { return (.people, senderIsAutomated) }
        return (senderIsAutomated ? .notifications : .people, true)
    }

    public static func looksAutomated(email: String, hasListUnsubscribe: Bool) -> Bool {
        if hasListUnsubscribe { return true }
        let local = email.split(separator: "@").first.map { $0.lowercased() } ?? email.lowercased()
        let markers = ["noreply", "no-reply", "donotreply", "do-not-reply", "notification", "notifications", "mailer",
                       "newsletter", "news", "info", "support", "billing", "invoice", "updates", "alerts", "automated", "bounce", "hello"]
        return markers.contains { local == $0 || local.contains($0 + "-") || local.contains("-" + $0) || local.contains($0 + ".") || local.hasPrefix($0) }
    }

    /// Builds the thread row from its messages.
    public static func buildThread(accountId: String, threadId: String, messages: [MailMessage], attachments: [AttachmentRecord],
                                   existing: MailThread?, override: InboxBucket?, selfAddresses: Set<String>) -> MailThread {
        let sorted = messages.sorted { $0.date < $1.date }
        let last = sorted.last
        // The list snippet follows the newest non-draft message where possible.
        let visible = sorted.last(where: { !$0.isDraft }) ?? last
        var labels = Set<String>()
        sorted.forEach { labels.formUnion($0.labels) }
        let incoming = sorted.last(where: { !selfAddresses.contains($0.fromEmail) }) ?? last
        var names: [String] = []
        for m in sorted {
            let n = selfAddresses.contains(m.fromEmail) ? "me" : m.senderDisplay
            if !n.isEmpty && !names.contains(n) { names.append(n) }
        }
        let automated = looksAutomated(email: incoming?.fromEmail ?? "", hasListUnsubscribe: incoming?.hasListUnsubscribe ?? false)
        let first = firstPassBucket(labels: labels, senderIsAutomated: automated)

        var bucket = first.bucket.rawValue
        var source = "gmail"
        var needsAI = first.askAI
        if let override {
            bucket = override.rawValue; source = "override"; needsAI = false
        } else if let e = existing, e.bucketSource == "ai", let b = e.bucket {
            bucket = b; source = "ai"; needsAI = false
        }
        if !labels.contains(GmailLabel.inbox) { needsAI = false }

        return MailThread(
            accountId: accountId, threadId: threadId,
            subject: sorted.first(where: { !$0.subject.isEmpty })?.subject ?? "(no subject)",
            snippet: visible?.snippet ?? "", participants: names.joined(separator: ", "),
            lastSenderEmail: incoming?.fromEmail ?? "", lastMessageAt: last?.date ?? Date(),
            messageCount: sorted.count, labelIds: LabelSet.encode(labels),
            hasAttachments: attachments.contains { $0.contentId == nil || !$0.filename.isEmpty && !$0.mimeType.hasPrefix("image/") },
            bucket: bucket, bucketSource: source, needsAIClassification: needsAI)
    }
}
