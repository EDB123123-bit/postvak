import Foundation
import GRDB

public enum MailFolder: Hashable, Sendable {
    case inbox, snoozed, starred, drafts, sent, spam, trash, all
    case label(String)

    public var title: String {
        switch self {
        case .inbox: "Inbox"; case .snoozed: "Snoozed"; case .starred: "Starred"; case .drafts: "Drafts"
        case .sent: "Sent"; case .spam: "Spam"; case .trash: "Trash"; case .all: "All Mail"
        case .label(let l): l
        }
    }
    public init?(name: String) {
        switch name.lowercased() {
        case "inbox": self = .inbox; case "snoozed": self = .snoozed; case "starred": self = .starred
        case "drafts": self = .drafts; case "sent": self = .sent; case "spam": self = .spam
        case "trash": self = .trash; case "all": self = .all
        default: return nil
        }
    }
}

public struct ThreadQuery: Sendable, Hashable {
    public var folder: MailFolder = .inbox
    public var accountId: String?
    public var bucket: InboxBucket?
    public var text: String?
    public var unreadOnly = false
    public var after: Date?
    public var before: Date?
    public var fromEmail: String?
    public var limit = 200
    public var offset = 0
    public init(folder: MailFolder = .inbox, accountId: String? = nil, bucket: InboxBucket? = nil, text: String? = nil,
                unreadOnly: Bool = false, after: Date? = nil, before: Date? = nil, limit: Int = 200, offset: Int = 0) {
        self.folder = folder; self.accountId = accountId; self.bucket = bucket; self.text = text
        self.unreadOnly = unreadOnly; self.after = after; self.before = before; self.limit = limit; self.offset = offset
    }
}

public struct ThreadDetail: Sendable {
    public var thread: MailThread
    public var messages: [MailMessage]
    public var attachments: [String: [AttachmentRecord]]   // by messageId
}

public struct ComposeInput: Sendable {
    public var accountId: String
    /// Send as this Gmail send-as address of the account instead of the account itself.
    public var fromEmail: String?
    public var to: [String]
    public var cc: [String] = []
    public var bcc: [String] = []
    public var subject: String
    public var text: String
    public var html: String?
    public var attachments: [OutgoingAttachment] = []
    public var replyTo: (accountId: String, messageId: String)?
    public var includeSignature = true
    public var draftId: String?
    public var draftThreadId: String?
    public var followUp: FollowUpRule?
    public var quotedHtml: String?
    /// A booking card, placed after the text and before the signature.
    public var booking: BookingInsert?
    public init(accountId: String, to: [String], cc: [String] = [], bcc: [String] = [], subject: String, text: String, html: String? = nil,
                attachments: [OutgoingAttachment] = [], includeSignature: Bool = true) {
        self.accountId = accountId; self.to = to; self.cc = cc; self.bcc = bcc; self.subject = subject
        self.text = text; self.html = html; self.attachments = attachments; self.includeSignature = includeSignature
    }
}

/// A queued mail taken apart again for the composer. `prepare` adds the signature and quote back on sending.
public struct EditableMail: Sendable {
    public var to: String
    public var cc: String
    public var bcc: String
    public var text: String
    public var quotedHtml: String?
    public var replyTo: (accountId: String, messageId: String)?
    public var booking: BookingInsert?
}

public enum MailError: Error, LocalizedError {
    case notFound(String), invalid(String)
    public var errorDescription: String? {
        switch self { case .notFound(let s): "Not found: \(s)"; case .invalid(let s): s }
    }
}

/// The account a mail is kept in and the address it goes out as, with why.
public struct SenderChoice: Sendable, Equatable {
    public var accountId: String
    /// A send-as address of `accountId`; nil sends as the account itself.
    public var fromEmail: String?
    public var project: String?
    public var reason: String?
    public var address: String { fromEmail ?? accountId }
    public init(accountId: String, fromEmail: String?, project: String?, reason: String?) {
        self.accountId = accountId; self.fromEmail = fromEmail; self.project = project; self.reason = reason
    }
}

/// Send-as lists change rarely; one read an hour is plenty.
actor SendAsCache {
    private var lists: [String: (at: Date, list: [SendAsDTO])] = [:]
    func get(_ account: String) -> [SendAsDTO]? {
        guard let c = lists[account.lowercased()], Date().timeIntervalSince(c.at) < 3600 else { return nil }
        return c.list
    }
    func set(_ account: String, _ list: [SendAsDTO]) { lists[account.lowercased()] = (Date(), list) }
}

public final class MailService: Sendable {
    public let db: AppDatabase
    public let gmail: GmailClient
    public let sync: GmailSync
    let paths: AppPaths
    let sendAsCache = SendAsCache()

    public init(db: AppDatabase, gmail: GmailClient, sync: GmailSync, paths: AppPaths) {
        self.db = db; self.gmail = gmail; self.sync = sync; self.paths = paths
    }

    // MARK: reads

    public static func threadRequest(_ q: ThreadQuery) -> SQLRequest<MailThread> {
        var clauses: [String] = []
        var args: [DatabaseValueConvertible] = []
        func has(_ l: String) { clauses.append("labelIds LIKE ?"); args.append("%|\(l)|%") }
        func hasNot(_ l: String) { clauses.append("labelIds NOT LIKE ?"); args.append("%|\(l)|%") }
        switch q.folder {
        case .inbox: has(GmailLabel.inbox); hasNot(GmailLabel.spam); hasNot(GmailLabel.trash)
        case .snoozed: clauses.append("EXISTS (SELECT 1 FROM snooze s WHERE s.accountId = thread.accountId AND s.threadId = thread.threadId)")
        case .starred: has(GmailLabel.starred); hasNot(GmailLabel.trash)
        case .drafts: has(GmailLabel.draft)
        case .sent: has(GmailLabel.sent); hasNot(GmailLabel.trash)
        case .spam: has(GmailLabel.spam)
        case .trash: has(GmailLabel.trash)
        case .all: hasNot(GmailLabel.spam); hasNot(GmailLabel.trash)
        case .label(let l): has(l); hasNot(GmailLabel.trash); hasNot(GmailLabel.spam)
        }
        if let a = q.accountId { clauses.append("thread.accountId = ?"); args.append(a) }
        if let b = q.bucket { clauses.append("bucket = ?"); args.append(b.rawValue) }
        if q.unreadOnly { has(GmailLabel.unread) }
        if let d = q.after { clauses.append("lastMessageAt >= ?"); args.append(d) }
        if let d = q.before { clauses.append("lastMessageAt < ?"); args.append(d) }
        if let t = q.text, let match = ftsQuery(t) {
            clauses.append("""
            (thread.accountId || '/' || thread.threadId) IN (
              SELECT m.accountId || '/' || m.threadId FROM message m
              JOIN message_ft ON message_ft.rowid = m.rowid WHERE message_ft MATCH ?)
            """)
            args.append(match)
        }
        // A follow-up reminder that fell due puts its thread back on top, as if it had just arrived.
        let order = """
            MAX(lastMessageAt, IFNULL((SELECT MAX(f.firedAt) FROM follow_up f WHERE f.accountId = thread.accountId
              AND f.threadId = thread.threadId AND f.status = 'due'), ''))
            """
        let sql = "SELECT thread.* FROM thread WHERE \(clauses.joined(separator: " AND ")) ORDER BY \(order) DESC LIMIT \(q.limit) OFFSET \(q.offset)"
        return SQLRequest<MailThread>(sql: sql, arguments: StatementArguments(args))
    }

    public func threads(_ q: ThreadQuery) async throws -> [MailThread] {
        try await db.pool.read { try Self.threadRequest(q).fetchAll($0) }
    }

    public func detail(accountId: String, threadId: String) async throws -> ThreadDetail {
        try await db.pool.read { db in
            guard let t = try MailThread.fetchOne(db, key: ["accountId": accountId, "threadId": threadId]) else {
                throw MailError.notFound("thread \(threadId)")
            }
            let msgs = try MailMessage.filter(Column("accountId") == accountId && Column("threadId") == threadId)
                .order(Column("date")).fetchAll(db)
            let atts = try AttachmentRecord.filter(Column("accountId") == accountId && msgs.map(\.messageId).contains(Column("messageId"))).fetchAll(db)
            return ThreadDetail(thread: t, messages: msgs, attachments: Dictionary(grouping: atts, by: \.messageId))
        }
    }

    public func accounts() async throws -> [Account] {
        try await db.pool.read { try Account.order(Column("id")).fetchAll($0) }
    }

    /// People to suggest for an address being typed: those you had mail from and those in your calendar invites,
    /// the most frequent first.
    public func contacts(matching text: String, limit: Int = 8) async throws -> [String] {
        guard !text.isEmpty else { return [] }
        let like = "%\(text.lowercased())%"
        return try await db.pool.read { db in
            // An invite often has only the address, so it also counts for someone the mail already matched by name.
            let rows = try Row.fetchAll(db, sql: """
                WITH mail AS (
                    SELECT fromName AS name, lower(fromEmail) AS email, COUNT(*) AS c FROM message
                    WHERE lower(fromEmail) LIKE ?1 OR lower(fromName) LIKE ?1 GROUP BY lower(fromEmail)
                ), guests AS (
                    SELECT COALESCE(json_extract(g.value, '$.name'), '') AS name, lower(json_extract(g.value, '$.email')) AS email
                    FROM event, json_each(event.attendeesJSON) g WHERE json_extract(g.value, '$.isSelf') = 0
                )
                SELECT MAX(name) AS name, email, SUM(c) AS c FROM (
                    SELECT name, email, c FROM mail
                    UNION ALL
                    SELECT name, email, 1 FROM guests WHERE email LIKE ?1 OR lower(name) LIKE ?1 OR email IN (SELECT email FROM mail)
                ) GROUP BY email ORDER BY SUM(c) DESC LIMIT ?2
                """, arguments: [like, limit])
            return rows.map { r in
                let n: String = r["name"] ?? "", e: String = r["email"]
                return GmailParser.recipient(name: n, email: e)
            }
        }
    }

    public func unreadInboxCount() async throws -> Int {
        try await db.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM thread WHERE labelIds LIKE '%|INBOX|%' AND labelIds LIKE '%|UNREAD|%' AND labelIds NOT LIKE '%|SPAM|%' AND labelIds NOT LIKE '%|TRASH|%'") ?? 0
        }
    }

    /// Searches Gmail itself and pulls matches into the local store, for mail older than the sync window.
    public func serverSearch(_ text: String, accountId: String?) async throws -> Int {
        let targets = try await accounts().filter { accountId == nil || $0.id == accountId }
        var total = 0
        for a in targets {
            let page = try await gmail.listThreads(a.id, q: text, pageToken: nil, includeSpamTrash: false, maxResults: 50)
            total += try await sync.fetchAndStore(a.id, threadIds: (page.threads ?? []).map(\.id))
        }
        return total
    }

    // MARK: thread actions (optimistic: local first, real state restored from Gmail on failure)

    private func applyLocal(_ accountId: String, _ threadId: String, add: [String], remove: [String]) async throws {
        try await db.pool.write { db in
            guard var t = try MailThread.fetchOne(db, key: ["accountId": accountId, "threadId": threadId]) else { return }
            var labels = t.labels
            labels.formUnion(add)
            labels.subtract(remove)
            t.labelIds = LabelSet.encode(labels)
            try t.update(db)
            let msgs = try MailMessage.filter(Column("accountId") == accountId && Column("threadId") == threadId).fetchAll(db)
            for var m in msgs {
                var ml = m.labels
                ml.formUnion(add)
                ml.subtract(remove)
                m.labelIds = LabelSet.encode(ml)
                try m.update(db)
            }
        }
    }

    public func modify(accountId: String, threadId: String, add: [String] = [], remove: [String] = []) async throws {
        try await applyLocal(accountId, threadId, add: add, remove: remove)
        do {
            try await gmail.modifyThread(accountId, id: threadId, add: add, remove: remove)
        } catch {
            try? await sync.refresh(accountId: accountId, threadId: threadId)
            throw error
        }
    }

    public func archive(accountId: String, threadId: String) async throws {
        try await modify(accountId: accountId, threadId: threadId, remove: [GmailLabel.inbox])
    }
    public func moveToInbox(accountId: String, threadId: String) async throws {
        try await modify(accountId: accountId, threadId: threadId, add: [GmailLabel.inbox], remove: [GmailLabel.spam, GmailLabel.trash])
    }
    public func markRead(accountId: String, threadId: String, read: Bool) async throws {
        if read { try await modify(accountId: accountId, threadId: threadId, remove: [GmailLabel.unread]) }
        else { try await modify(accountId: accountId, threadId: threadId, add: [GmailLabel.unread]) }
    }
    public func star(accountId: String, threadId: String, starred: Bool) async throws {
        if starred { try await modify(accountId: accountId, threadId: threadId, add: [GmailLabel.starred]) }
        else { try await modify(accountId: accountId, threadId: threadId, remove: [GmailLabel.starred]) }
    }
    public func markSpam(accountId: String, threadId: String) async throws {
        try await modify(accountId: accountId, threadId: threadId, add: [GmailLabel.spam], remove: [GmailLabel.inbox])
    }
    public func notSpam(accountId: String, threadId: String) async throws {
        try await modify(accountId: accountId, threadId: threadId, add: [GmailLabel.inbox], remove: [GmailLabel.spam])
    }
    public func trash(accountId: String, threadId: String) async throws {
        try await applyLocal(accountId, threadId, add: [GmailLabel.trash], remove: [GmailLabel.inbox])
        do { try await gmail.trashThread(accountId, id: threadId) }
        catch { try? await sync.refresh(accountId: accountId, threadId: threadId); throw error }
    }
    public func untrash(accountId: String, threadId: String) async throws {
        try await applyLocal(accountId, threadId, add: [], remove: [GmailLabel.trash])
        do { try await gmail.untrashThread(accountId, id: threadId) }
        catch { try? await sync.refresh(accountId: accountId, threadId: threadId); throw error }
        try await sync.refresh(accountId: accountId, threadId: threadId)
    }

    /// Finds a label by name, creating it when asked.
    public func resolveLabel(accountId: String, name: String, create: Bool) async throws -> String {
        let existing = try await db.pool.read { db in
            try MailLabelRecord.filter(Column("accountId") == accountId && Column("name") == name).fetchOne(db)
        }
        if let existing { return existing.labelId }
        guard create else { throw MailError.notFound("label \(name)") }
        let l = try await gmail.createLabel(accountId, name: name)
        let rec = MailLabelRecord(accountId: accountId, labelId: l.id, name: l.name, type: "user")
        try await db.pool.write { try rec.save($0) }
        return l.id
    }

    public func labels(accountId: String) async throws -> [MailLabelRecord] {
        try await db.pool.read { db in
            try MailLabelRecord.filter(Column("accountId") == accountId && Column("type") == "user").order(Column("name")).fetchAll(db)
        }
    }

    // MARK: snooze

    public func snooze(accountId: String, threadId: String, until: Date) async throws {
        guard until > Date() else { throw MailError.invalid("Snooze time must be in the future.") }
        let label = try await resolveLabel(accountId: accountId, name: GmailLabel.snoozedName, create: true)
        try await modify(accountId: accountId, threadId: threadId, add: [label], remove: [GmailLabel.inbox])
        try await db.pool.write { try SnoozeRow(accountId: accountId, threadId: threadId, wakeAt: until).save($0) }
    }

    public func unsnooze(accountId: String, threadId: String, markUnread: Bool) async throws {
        let label = try await resolveLabel(accountId: accountId, name: GmailLabel.snoozedName, create: true)
        try await db.pool.write { _ = try SnoozeRow.deleteOne($0, key: ["accountId": accountId, "threadId": threadId]) }
        var add = [GmailLabel.inbox]
        if markUnread { add.append(GmailLabel.unread) }
        try await modify(accountId: accountId, threadId: threadId, add: add, remove: [label])
    }

    public func snoozeWake(accountId: String, threadId: String) async throws -> Date? {
        try await db.pool.read { try SnoozeRow.fetchOne($0, key: ["accountId": accountId, "threadId": threadId])?.wakeAt }
    }

    /// Returns threads whose snooze ended. Called by the engine's timer, and once at launch.
    @discardableResult
    public func wakeDueSnoozes(now: Date = Date()) async -> Int {
        let due = (try? await db.pool.read { try SnoozeRow.filter(Column("wakeAt") <= now).fetchAll($0) }) ?? []
        var woke = 0
        for s in due {
            if (try? await unsnooze(accountId: s.accountId, threadId: s.threadId, markUnread: true)) != nil { woke += 1 }
        }
        return woke
    }

    // MARK: sender

    /// The addresses Gmail lets an account send as, its own included. Read once an hour at most; empty when Gmail can't be reached.
    public func sendAsList(accountId: String) async -> [SendAsDTO] {
        if let cached = await sendAsCache.get(accountId) { return cached }
        guard let list = try? await gmail.sendAs(accountId) else { return [] }
        await sendAsCache.set(accountId, list)
        return list
    }

    /// Which address a mail written for the user goes out from: the one of its project (company mail from the
    /// company address, not from a personal Gmail that happens to receive it too).
    /// A new mail moves to the project's own account. A reply stays in its thread's account, which Gmail requires,
    /// and goes out as the project's send-as address when that account has one. Otherwise nothing changes.
    public func chooseSender(accountId: String, recipients: [String], isReply: Bool, project known: String? = nil) async -> SenderChoice {
        let unchanged = SenderChoice(accountId: accountId, fromEmail: nil, project: nil, reason: nil)
        guard let (rules, connected, filing) = try? await db.pool.read({ db -> ([ProjectRule], Set<String>, String?) in
            let config = try ProjectConfig.load(db)
            let project = try known ?? Projects.forOutgoing(db, config: config, recipients: recipients).project
            return (config.projects.map(\.cleaned), Set(try Account.fetchAll(db).map { $0.id.lowercased() }), project)
        }), let name = filing, let rule = rules.first(where: { $0.name == name }) else { return unchanged }
        let account = accountId.lowercased()
        let own = rule.accounts + rule.addresses.filter { !rule.accounts.contains($0) }
        if own.contains(account) { return SenderChoice(accountId: accountId, fromEmail: nil, project: name, reason: "already the \(name) account") }
        if !isReply, let a = rule.accounts.first(where: connected.contains) {
            return SenderChoice(accountId: a, fromEmail: nil, project: name, reason: "\(name) mail goes from the \(name) account")
        }
        let aliases = Set(await sendAsList(accountId: accountId).filter(\.usable).map { $0.sendAsEmail.lowercased() })
        if let alias = own.first(where: aliases.contains) {
            return SenderChoice(accountId: accountId, fromEmail: alias, project: name,
                                reason: "\(name) mail in a thread kept in \(accountId), sent as \(alias)")
        }
        return SenderChoice(accountId: accountId, fromEmail: nil, project: name, reason: nil)
    }

    /// A sender someone named: an account (a new mail moves there), or a send-as address of the mail's account.
    public func namedSender(_ address: String, accountId: String, isReply: Bool) async throws -> SenderChoice {
        let a = address.lowercased()
        if a == accountId.lowercased() { return SenderChoice(accountId: accountId, fromEmail: nil, project: nil, reason: "as asked") }
        let connected = try await db.pool.read { try Account.fetchAll($0).map(\.id) }
        if !isReply, let other = connected.first(where: { $0.lowercased() == a }) {
            return SenderChoice(accountId: other, fromEmail: nil, project: nil, reason: "as asked")
        }
        if await sendAsList(accountId: accountId).contains(where: { $0.sendAsEmail.lowercased() == a && $0.usable }) {
            return SenderChoice(accountId: accountId, fromEmail: a, project: nil, reason: "as asked")
        }
        throw MailError.invalid(isReply
            ? "A reply stays in the account that holds its thread (\(accountId)), and that account can't send as \(address)."
            : "\(address) is neither a connected account nor a send-as address of \(accountId).")
    }

    /// The account that holds a message, preferring `preferred`. Message ids are per mailbox, so a reply has to be drafted there.
    public func account(ofMessage messageId: String, preferred: String?) async throws -> String? {
        let holders = try await db.pool.read { try String.fetchAll($0, sql: "SELECT accountId FROM message WHERE messageId = ?", arguments: [messageId]) }
        if let p = preferred, holders.contains(where: { $0.lowercased() == p.lowercased() }) { return p }
        return holders.first ?? preferred
    }

    // MARK: signatures

    public func signature(accountId: String) async throws -> (email: String, name: String?, html: String) {
        let list = try await gmail.sendAs(accountId)
        let s = list.first { $0.sendAsEmail.lowercased() == accountId.lowercased() } ?? list.first { $0.isDefault == true } ?? list.first
        guard let s else { throw MailError.notFound("send-as settings for \(accountId)") }
        try? await db.setSetting("signature.\(accountId)", s.signature ?? "")
        try? await db.setSetting("sendAsName.\(accountId)", s.displayName ?? "")
        return (s.sendAsEmail, s.displayName, s.signature ?? "")
    }

    public func setSignature(accountId: String, html: String) async throws {
        try await gmail.updateSignature(accountId, sendAsEmail: accountId, signature: html)
        try await db.setSetting("signature.\(accountId)", html)
    }

    public func cachedSignature(accountId: String) -> String { db.setting("signature.\(accountId)") ?? "" }

    // MARK: compose

    /// Assembles the final mail: threading headers, signature, HTML alternative, Gmail display name.
    public func prepare(_ input: ComposeInput, checkRecipients: Bool = true) async throws -> OutgoingMail {
        guard !input.to.isEmpty || !input.cc.isEmpty || !input.bcc.isEmpty else { throw MailError.invalid("Add at least one recipient.") }
        // Refused here, while the composer is open, rather than by Google after the undo window.
        if checkRecipients, let bad = (input.to + input.cc + input.bcc).first(where: { !GmailParser.isValidRecipient($0) }) {
            throw MailError.invalid("“\(bad)” is not an email address. A name with a comma needs quotes, as in \"Peeters, An\" <an@example.net>.")
        }
        var threadId: String?
        var inReplyTo: String?
        var references: String?
        if let r = input.replyTo {
            guard let m = try await db.pool.read({ try MailMessage.fetchOne($0, key: ["accountId": r.accountId, "messageId": r.messageId]) }) else {
                throw MailError.notFound("message \(r.messageId)")
            }
            threadId = m.threadId
            inReplyTo = m.rfcMessageId
            references = [m.referencesHeader, m.rfcMessageId].compactMap { $0 }.joined(separator: " ")
        }
        var sig = db.setting("signature.\(input.accountId)")
        var name = db.setting("sendAsName.\(input.accountId)")
        let alias = input.fromEmail.flatMap { $0.lowercased() == input.accountId.lowercased() ? nil : $0.lowercased() }
        if let alias {
            // Sent as another address of the account: that address's own name and signature, as Gmail would.
            guard let s = await sendAsList(accountId: input.accountId).first(where: { $0.sendAsEmail.lowercased() == alias && $0.usable }) else {
                throw MailError.invalid("\(input.accountId) can't send as \(alias): add it under Gmail's “Send mail as” first.")
            }
            sig = s.signature ?? ""; name = s.displayName
        } else if sig == nil, input.includeSignature, let s = try? await signature(accountId: input.accountId) {
            sig = s.html; name = s.name
        }
        var bodyHtml = input.html ?? MIMEBuilder.textToHTML(input.text)
        var text = input.text
        if let b = input.booking {
            bodyHtml += b.html
            text += "\n\n" + b.text
        }
        if input.includeSignature, let sig, !sig.isEmpty {
            bodyHtml += "<br><br><div class=\"gmail_signature\">\(sig)</div>"
            text += "\n\n-- \n" + GmailParser.htmlToText(sig)
        }
        if let q = input.quotedHtml, !q.isEmpty { bodyHtml += q }
        var out = OutgoingMail(accountId: input.accountId, fromName: (name?.isEmpty == false) ? name : nil,
                               to: input.to, cc: input.cc, bcc: input.bcc, subject: input.subject,
                               textBody: text, htmlBody: bodyHtml, threadId: threadId, inReplyTo: inReplyTo,
                               references: references, attachments: input.attachments, draftId: input.draftId,
                               draftThreadId: input.draftThreadId)
            .withFollowUp(input.followUp)
        out.fromEmail = alias
        return out
    }

    public func replyAddressing(accountId: String, messageId: String, replyAll: Bool) async throws -> (to: [String], cc: [String], subject: String) {
        guard let m = try await db.pool.read({ try MailMessage.fetchOne($0, key: ["accountId": accountId, "messageId": messageId]) }) else {
            throw MailError.notFound("message \(messageId)")
        }
        let me = accountId.lowercased()
        // Mail the user sent as one of their other addresses (a company alias in Gmail) is theirs too.
        let own = (try? await db.pool.read { try Matching.ownAddresses($0) }) ?? [me]
        let sentByMe = own.contains(m.fromEmail.lowercased())
        var to = sentByMe ? GmailParser.splitAddresses(m.toLine) : [GmailParser.recipient(name: m.fromName, email: m.fromEmail)]
        var cc: [String] = []
        if replyAll {
            let others = (sentByMe ? [] : GmailParser.splitAddresses(m.toLine)) + GmailParser.splitAddresses(m.ccLine)
            var seen = Set(to.map { GmailParser.parseAddress($0).email })
            seen.formUnion(own)
            seen.insert(me)
            for o in others where seen.insert(GmailParser.parseAddress(o).email).inserted { cc.append(o) }
        }
        if to.isEmpty { to = [m.fromEmail] }
        let lower = m.subject.lowercased()
        let subject = (lower.hasPrefix("re:") || lower.hasPrefix("antw:")) ? m.subject : "Re: \(m.subject)"
        return (to, cc, subject)
    }

    public func quotedBlock(message m: MailMessage) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short
        let body = m.bodyHtml ?? MIMEBuilder.textToHTML(m.bodyText)
        let who = MIMEBuilder.textToHTML(m.fromName.isEmpty ? m.fromEmail : "\(m.fromName) <\(m.fromEmail)>")
        return "<br><br><div class=\"gmail_quote\"><div>On \(f.string(from: m.date)), \(who) wrote:</div><blockquote style=\"margin:0 0 0 .8ex;border-left:1px solid #ccc;padding-left:1ex\">\(body)</blockquote></div>"
    }

    /// Undoes what `prepare` added to a mail, so sending it again does not double the signature or lose the thread.
    public func editable(_ mail: OutgoingMail) async throws -> EditableMail {
        func line(_ list: [String]) -> String {
            list.map { let p = GmailParser.parseAddress($0); return GmailParser.recipient(name: p.name, email: p.email) }.joined(separator: ", ")
        }
        var text = mail.textBody
        if mail.htmlBody?.contains("<div class=\"gmail_signature\">") == true, let sig = text.range(of: "\n\n-- \n", options: .backwards) {
            text = String(text[..<sig.lowerBound])
        }
        var quoted: String?
        if let html = mail.htmlBody, let q = html.range(of: "<br><br><div class=\"gmail_quote\">") {
            quoted = String(html[q.lowerBound...])
        }
        let booking = mail.htmlBody.flatMap(BookingBlock.extract)
        if let b = booking, text.hasSuffix("\n\n" + b.text) { text.removeLast(b.text.count + 2) }
        var replyTo: (accountId: String, messageId: String)?
        if let parent = mail.inReplyTo {
            let found = try await db.pool.read { db in
                try MailMessage.filter(Column("accountId") == mail.accountId && Column("rfcMessageId") == parent).fetchOne(db)
            }
            if let found { replyTo = (mail.accountId, found.messageId) }
        }
        return EditableMail(to: line(mail.to), cc: line(mail.cc), bcc: line(mail.bcc), text: text, quotedHtml: quoted, replyTo: replyTo, booking: booking)
    }

    /// A Gmail draft, ready to edit: the signature and the quoted mail come off the text, as `prepare` adds
    /// them again on sending, and a reply keeps its place in the conversation.
    public func editableDraft(_ m: MailMessage) async throws -> EditableMail {
        let mail = OutgoingMail(accountId: m.accountId, to: GmailParser.splitAddresses(m.toLine), cc: GmailParser.splitAddresses(m.ccLine),
                                subject: m.subject, textBody: m.bodyText, htmlBody: m.bodyHtml, inReplyTo: m.inReplyTo)
        return try await editable(mail)
    }

    /// Saves a Gmail draft. Passing `draftId` replaces the earlier version.
    public func saveDraft(_ input: ComposeInput) async throws -> (draftId: String, threadId: String?) {
        var relaxed = input
        if relaxed.to.isEmpty && relaxed.cc.isEmpty && relaxed.bcc.isEmpty { relaxed.to = [] }
        let mail: OutgoingMail
        if relaxed.to.isEmpty && relaxed.cc.isEmpty && relaxed.bcc.isEmpty {
            // Drafts may have no recipients yet; `prepare` requires one for sending only.
            var withPlaceholder = relaxed
            withPlaceholder.to = ["placeholder@invalid"]
            var prepared = try await prepare(withPlaceholder, checkRecipients: false)
            prepared.to = []
            mail = prepared
        } else {
            // A draft may still hold a half-typed address.
            mail = try await prepare(relaxed, checkRecipients: false)
        }
        let raw = try MIMEBuilder.build(mail)
        let dto = input.draftId != nil
            ? try await gmail.updateDraft(input.accountId, draftId: input.draftId!, raw: raw, threadId: mail.threadId)
            : try await gmail.createDraft(input.accountId, raw: raw, threadId: mail.threadId)
        if let t = dto.message?.threadId {
            if input.draftId != nil {
                // Gmail moves a rewritten draft of a new mail to a new thread; Review Drafts follows it there.
                try? await db.pool.write { db in
                    try db.execute(sql: "UPDATE auto_draft SET threadId = ? WHERE accountId = ? AND draftId = ?", arguments: [t, input.accountId, dto.id])
                }
            }
            try? await sync.refresh(accountId: input.accountId, threadId: t)
        }
        return (dto.id, dto.message?.threadId)
    }

    public func deleteDraft(accountId: String, draftId: String, threadId: String?) async throws {
        try await gmail.deleteDraft(accountId, draftId: draftId)
        if let threadId { try? await sync.refresh(accountId: accountId, threadId: threadId) }
    }

    /// The files a Gmail draft carries now, downloaded to the cache, so a rewrite of the draft can keep them.
    public func draftAttachments(accountId: String, draftId: String) async throws -> [OutgoingAttachment] {
        guard let (messageId, threadId) = try await gmail.draftMessage(accountId, draftId: draftId) else { return [] }
        var records = try await db.pool.read { db in
            try AttachmentRecord.filter(Column("accountId") == accountId && Column("messageId") == messageId).fetchAll(db)
        }
        if records.isEmpty, let threadId {
            // Not synced yet: fetch its thread first.
            try? await sync.refresh(accountId: accountId, threadId: threadId)
            records = try await db.pool.read { db in
                try AttachmentRecord.filter(Column("accountId") == accountId && Column("messageId") == messageId).fetchAll(db)
            }
        }
        var out: [OutgoingAttachment] = []
        for r in records {
            out.append(OutgoingAttachment(filename: r.filename, mimeType: r.mimeType, path: try await attachmentFile(r).path))
        }
        return out
    }

    public func draftId(accountId: String, messageId: String) async throws -> String? {
        try await gmail.draftId(accountId, forMessage: messageId)
    }

    // MARK: attachments

    /// Downloads an attachment on demand and caches it. Returns the local file.
    public func attachmentFile(_ a: AttachmentRecord) async throws -> URL {
        if let p = a.localPath, FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        let data = try await gmail.attachment(a.accountId, messageId: a.messageId, attachmentId: a.attachmentId)
        let dir = paths.attachments.appendingPathComponent(a.messageId, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Filenames come from senders, so strip any path components.
        let safe = URL(fileURLWithPath: a.filename).lastPathComponent.replacingOccurrences(of: "/", with: "_")
        let url = dir.appendingPathComponent(safe.isEmpty ? "attachment" : safe)
        try data.write(to: url, options: .atomic)
        var updated = a
        updated.localPath = url.path
        let row = updated
        try await db.pool.write { try row.update($0) }
        return url
    }

    public func attachment(accountId: String, messageId: String, filename: String) async throws -> AttachmentRecord {
        guard let a = try await db.pool.read({ db in
            try AttachmentRecord.filter(Column("accountId") == accountId && Column("messageId") == messageId && Column("filename") == filename).fetchOne(db)
        }) else { throw MailError.notFound("attachment \(filename)") }
        return a
    }

    // MARK: sender bucket override

    public func setBucket(accountId: String, threadId: String, bucket: InboxBucket) async throws {
        try await db.pool.write { db in
            guard var t = try MailThread.fetchOne(db, key: ["accountId": accountId, "threadId": threadId]) else { return }
            t.bucket = bucket.rawValue
            t.bucketSource = "override"
            t.needsAIClassification = false
            try t.update(db)
            guard !t.lastSenderEmail.isEmpty else { return }
            try SenderOverride(email: t.lastSenderEmail, bucket: bucket.rawValue).save(db)
            // Everything already synced from this sender follows the correction.
            try db.execute(sql: "UPDATE thread SET bucket = ?, bucketSource = 'override', needsAIClassification = 0 WHERE lastSenderEmail = ?",
                           arguments: [bucket.rawValue, t.lastSenderEmail])
        }
    }
}
