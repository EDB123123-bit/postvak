import Foundation
import UniformTypeIdentifiers
import PostvakCore

/// Controls recording from Claude. Implemented in the app, which owns the recorder.
public protocol RecorderControl: Sendable {
    func startRecording(title: String?) async throws -> String
    func stopRecording() async throws -> String
}

/// Lets the app show its undo toast for a send that came in through MCP.
public protocol MCPUIHooks: Sendable {
    func didQueueSend(_ row: OutboxRow, mail: OutgoingMail) async
}

public struct ArgError: Error, LocalizedError {
    let message: String
    public var errorDescription: String? { message }
}

struct Args {
    let raw: [String: Any]
    func string(_ k: String) -> String? { (raw[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    func need(_ k: String) throws -> String {
        guard let s = string(k) else { throw ArgError(message: "Missing argument: \(k)") }
        return s
    }
    func int(_ k: String) -> Int? { (raw[k] as? NSNumber)?.intValue }
    func bool(_ k: String) -> Bool? { (raw[k] as? NSNumber)?.boolValue }
    func strings(_ k: String) -> [String] {
        if let a = raw[k] as? [String] { return a }
        if let s = raw[k] as? String, !s.isEmpty { return GmailParser.splitAddresses(s) }
        return []
    }
    func date(_ k: String) throws -> Date? {
        guard let s = string(k) else { return nil }
        guard let d = Fmt.parse(s) else { throw ArgError(message: "\(k) must be ISO 8601, for example 2026-11-05T14:00:00+01:00") }
        return d
    }
    func needDate(_ k: String) throws -> Date {
        guard let d = try date(k) else { throw ArgError(message: "Missing argument: \(k)") }
        return d
    }
}

enum Fmt {
    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; f.timeZone = .current; return f
    }()
    nonisolated(unsafe) static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static func day() -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current; return f
    }
    static func parse(_ s: String) -> Date? { iso.date(from: s) ?? isoFrac.date(from: s) ?? day().date(from: s) }
    static func string(_ d: Date) -> String { iso.string(from: d) }
}

private func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
private func int(_ d: String) -> [String: Any] { ["type": "integer", "description": d] }
private func bool(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }
private func strs(_ d: String) -> [String: Any] { ["type": "array", "items": ["type": "string"], "description": d] }

private func threadJSON(_ t: MailThread) -> [String: Any] {
    [
        "account": t.accountId, "thread_id": t.threadId, "subject": t.subject, "snippet": t.snippet,
        "participants": t.participants, "last_message_at": Fmt.string(t.lastMessageAt), "message_count": t.messageCount,
        "unread": t.isUnread, "starred": t.isStarred, "in_inbox": t.isInInbox, "spam": t.isSpam, "trash": t.isTrash,
        "bucket": t.bucket ?? NSNull(), "has_attachments": t.hasAttachments,
        "labels": t.labels.sorted(),
    ]
}

private func eventJSON(_ e: CalendarEvent) -> [String: Any] {
    [
        "account": e.accountId, "calendar_id": e.calendarId, "event_id": e.eventId, "summary": e.summary,
        "start": Fmt.string(e.startAt), "end": Fmt.string(e.endAt), "all_day": e.isAllDay, "location": e.location,
        "description": e.details, "status": e.status, "organizer": e.organizerEmail,
        "my_response": e.selfResponse ?? NSNull(), "meeting_link": e.meetingLink ?? NSNull(),
        "attendees": e.attendees.map { ["email": $0.email, "name": $0.name ?? NSNull(), "response": $0.response] as [String: Any] },
    ]
}

private func meetingJSON(_ m: MeetingRecord) -> [String: Any] {
    [
        "meeting_id": m.id, "title": m.title, "started_at": Fmt.string(m.startedAt),
        "ended_at": m.endedAt.map(Fmt.string) ?? NSNull(), "status": m.status.rawValue, "source": m.source,
        "language": m.language ?? NSNull(), "linked_event_id": m.eventId ?? NSNull(),
        "attendees": m.attendees.map { $0.name ?? $0.email },
        "project": m.project ?? NSNull(),
    ]
}

public enum PostvakTools {
    public static func all(engine: Engine, recorder: RecorderControl?, ui: MCPUIHooks?) -> [MCPTool] {
        mail(engine, ui) + calendar(engine) + meetings(engine, recorder)
    }

    /// The account a mail is kept in and the address it goes out as: the `from` asked for, or else the address of the
    /// mail's project, so company mail never leaves from a personal Gmail.
    private static func sender(_ e: Engine, _ a: Args, account: String?, recipients: [String], replyTo: String?) async throws -> SenderChoice {
        let isReply = replyTo != nil
        var acct = account
        if let r = replyTo { acct = try await e.mail.account(ofMessage: r, preferred: account) }
        if acct == nil { acct = try await e.mail.accounts().first?.id }
        guard let acct else { throw ArgError(message: "No Gmail account is connected.") }
        if let from = a.string("from") { return try await e.mail.namedSender(from, accountId: acct, isReply: isReply) }
        return await e.mail.chooseSender(accountId: acct, recipients: recipients, isReply: isReply)
    }

    static let fromDescription = "Address to send as: an account, or a Gmail send-as address of the account. Leave out to use the address of the mail's project (company mail from the company address); the result says which was used."

    private static func describe(_ c: SenderChoice) -> [String: Any] {
        ["account": c.accountId, "from": c.address, "project": c.project ?? NSNull(), "from_reason": c.reason ?? NSNull()]
    }

    private static func queue(_ e: Engine, ui: MCPUIHooks?, _ input: ComposeInput, sendAt: Date?) async throws -> [String: Any] {
        let mail = try await e.mail.prepare(input)
        let row = try await e.outbox.enqueue(mail, sendAt: sendAt)
        await ui?.didQueueSend(row, mail: mail)
        return [
            "queued": true, "outbox_id": row.id, "account": mail.accountId, "from": mail.fromEmail ?? mail.accountId, "to": mail.to, "cc": mail.cc, "bcc": mail.bcc,
            "subject": mail.subject, "send_at": Fmt.string(row.sendAt),
            "note": sendAt == nil ? "Goes out after the 5 second undo window while the app is running." : "Scheduled. Goes out at send_at while the app is running.",
        ]
    }

    static func mail(_ e: Engine, _ ui: MCPUIHooks?) -> [MCPTool] {
        [
            MCPTool(name: "list_accounts", description: "List the connected Gmail accounts with sync state and their user labels.", properties: [:]) { _ in
                var out: [[String: Any]] = []
                for a in try await e.mail.accounts() {
                    let labels = try await e.mail.labels(accountId: a.id)
                    out.append(["email": a.email, "name": a.displayName, "initial_sync_done": a.initialSyncDone,
                                "last_sync_at": a.lastSyncAt.map(Fmt.string) ?? NSNull(), "last_error": a.lastError ?? NSNull(),
                                "needs_sign_in": a.needsReauth, "labels": labels.map(\.name)])
                }
                return out
            },
            MCPTool(name: "search_mail", description: "Search or list threads across all accounts. Leave query empty to list a folder. Searches local mail; set search_gmail true to also pull matches from Gmail for mail older than the local window.",
                    properties: [
                        "query": str("Words to find in subject, people and body."),
                        "account": str("Limit to this address."),
                        "folder": str("inbox, snoozed, starred, drafts, sent, spam, trash or all. Default: all, or inbox when query is empty."),
                        "label": str("Limit to a user label by name. Needs account."),
                        "bucket": str("people, notifications or newsletters."),
                        "unread_only": bool("Only unread threads."),
                        "after": str("ISO 8601 date."), "before": str("ISO 8601 date."),
                        "limit": int("Default 25, maximum 100."), "offset": int("For paging."),
                        "search_gmail": bool("Also query Gmail's servers first."),
                    ]) { raw in
                let a = Args(raw: raw)
                let text = a.string("query")
                if a.bool("search_gmail") == true, let text { _ = try await e.mail.serverSearch(text, accountId: a.string("account")) }
                var q = ThreadQuery(folder: MailFolder(name: a.string("folder") ?? (text == nil ? "inbox" : "all")) ?? .all,
                                    accountId: a.string("account"), bucket: a.string("bucket").flatMap(InboxBucket.init(rawValue:)),
                                    text: text, unreadOnly: a.bool("unread_only") ?? false, after: try a.date("after"), before: try a.date("before"),
                                    limit: min(a.int("limit") ?? 25, 100), offset: a.int("offset") ?? 0)
                if let l = a.string("label") {
                    guard let acct = a.string("account") else { throw ArgError(message: "label needs account.") }
                    q.folder = .label(try await e.mail.resolveLabel(accountId: acct, name: l, create: false))
                }
                return try await e.mail.threads(q).map(threadJSON)
            },
            MCPTool(name: "get_thread", description: "Read a whole thread: every message with its body and attachment names.",
                    properties: ["account": str("Account address."), "thread_id": str("Thread id.")], required: ["account", "thread_id"]) { raw in
                let a = Args(raw: raw)
                let d = try await e.mail.detail(accountId: try a.need("account"), threadId: try a.need("thread_id"))
                var out = threadJSON(d.thread)
                out["messages"] = d.messages.map { m -> [String: Any] in
                    [
                        "message_id": m.messageId, "from": GmailParser.recipient(name: m.fromName, email: m.fromEmail),
                        "to": m.toLine, "cc": m.ccLine, "date": Fmt.string(m.date), "subject": m.subject, "body": m.bodyText, "unread": m.isUnread,
                        "attachments": (d.attachments[m.messageId] ?? []).map { ["filename": $0.filename, "mime_type": $0.mimeType, "size": $0.size] as [String: Any] },
                    ]
                }
                return out
            },
            MCPTool(name: "get_attachment", description: "Download an attachment to the local cache and return its file path.",
                    properties: ["account": str("Account address."), "message_id": str("Message id."), "filename": str("Attachment filename.")],
                    required: ["account", "message_id", "filename"]) { raw in
                let a = Args(raw: raw)
                let rec = try await e.mail.attachment(accountId: try a.need("account"), messageId: try a.need("message_id"), filename: try a.need("filename"))
                let url = try await e.mail.attachmentFile(rec)
                return ["path": url.path, "mime_type": rec.mimeType, "size": rec.size] as [String: Any]
            },
            MCPTool(name: "create_draft", description: "Save a Gmail draft. Nothing is sent: the user approves, edits or deletes it in Postvak's Review Drafts. Pass reply_to_message_id to thread it, and draft_id to replace an earlier draft. The sender is picked from the mail's project unless `from` says otherwise; the result tells which account holds the draft and which address it is from.",
                    properties: [
                        "account": str("Account to keep the draft in. A reply is always kept in the account that holds the message it answers."),
                        "from": str(fromDescription),
                        "to": strs("Recipients."), "cc": strs("Cc."), "bcc": strs("Bcc."),
                        "subject": str("Subject."), "body": str("Plain text body. The sending address's signature is added."),
                        "reply_to_message_id": str("Message this replies to."), "draft_id": str("Draft to replace; keeps its account and sender."),
                        "reason": str("One line on why this draft: who waits for what, since when. Shown to the user when they review it in Postvak."),
                        "attachments": strs("Files to attach, as absolute paths on this Mac (get_attachment gives one for a file from a mail). Postvak reads them itself, so pass the path, never the content. Up to 25 MB together. With draft_id, leave out to keep the draft's files; [] removes them."),
                    ], required: ["subject", "body"]) { raw in
                let a = Args(raw: raw)
                let to = a.strings("to"), cc = a.strings("cc"), bcc = a.strings("bcc")
                let draftId = a.string("draft_id"), replyTo = a.string("reply_to_message_id")
                let choice: SenderChoice
                if draftId != nil, a.string("from") == nil {
                    // Replacing a draft keeps it where it is.
                    choice = SenderChoice(accountId: try a.need("account"), fromEmail: nil, project: nil, reason: "replacing a draft")
                } else {
                    choice = try await sender(e, a, account: a.string("account"), recipients: to + cc, replyTo: replyTo)
                }
                var i = ComposeInput(accountId: choice.accountId, to: to, cc: cc, bcc: bcc, subject: try a.need("subject"), text: try a.need("body"))
                i.fromEmail = choice.fromEmail
                i.draftId = draftId
                if let r = replyTo { i.replyTo = (choice.accountId, r) }
                if raw["attachments"] != nil {
                    i.attachments = try DraftFiles.resolve(a.strings("attachments"), paths: e.paths)
                } else if let draftId {
                    // A rewrite keeps what the draft had, files the user added included.
                    i.attachments = try await e.mail.draftAttachments(accountId: choice.accountId, draftId: draftId)
                }
                let d = try await e.mail.saveDraft(i)
                // Listed in Postvak's Review Drafts, so it doesn't sit unseen. A replaced draft is already listed.
                if draftId == nil {
                    try await e.autoDrafts.record(AutoDraftRecord(accountId: choice.accountId, draftId: d.draftId, threadId: d.threadId,
                                                                  fromEmail: choice.address, recipients: (to + cc).joined(separator: ", "), subject: i.subject,
                                                                  source: .claude, reason: a.string("reason") ?? "Drafted by Claude"))
                }
                return (["draft_id": d.draftId, "thread_id": d.threadId ?? NSNull(), "subject": i.subject, "to": i.to,
                         "attachments": i.attachments.map(\.filename), "review": "Waits in Postvak's Review Drafts."] as [String: Any])
                    .merging(describe(choice)) { a, _ in a }
            },
            MCPTool(name: "send_mail", description: "Send a new mail. Requires confirm_send true, only after the user approved the exact text. Goes through the app's 5 second undo window, or waits until send_at.",
                    properties: [
                        "account": str("Account to send from. Leave out to use the account of the mail's project."),
                        "from": str(fromDescription),
                        "to": strs("Recipients."), "cc": strs("Cc."), "bcc": strs("Bcc."),
                        "subject": str("Subject."), "body": str("Plain text body. The sending address's signature is added."),
                        "send_at": str("ISO 8601 time for send later."), "confirm_send": bool("Must be true."),
                    ], required: ["to", "subject", "body", "confirm_send"]) { raw in
                let a = Args(raw: raw)
                guard a.bool("confirm_send") == true else { throw ArgError(message: "Not sent: confirm_send must be true.") }
                let to = a.strings("to"), cc = a.strings("cc")
                let choice = try await sender(e, a, account: a.string("account"), recipients: to + cc, replyTo: nil)
                var i = ComposeInput(accountId: choice.accountId, to: to, cc: cc, bcc: a.strings("bcc"),
                                     subject: try a.need("subject"), text: try a.need("body"))
                i.fromEmail = choice.fromEmail
                return try await queue(e, ui: ui, i, sendAt: try a.date("send_at")).merging(describe(choice)) { a, _ in a }
            },
            MCPTool(name: "reply", description: "Reply to a message in its thread. Requires confirm_send true, only after the user approved the exact text. Goes through the 5 second undo window, or waits until send_at.",
                    properties: [
                        "account": str("Account address."), "message_id": str("Message being answered."), "body": str("Plain text reply."),
                        "from": str(fromDescription),
                        "reply_all": bool("Also address the other recipients."), "send_at": str("ISO 8601 time for send later."), "confirm_send": bool("Must be true."),
                    ], required: ["account", "message_id", "body", "confirm_send"]) { raw in
                let a = Args(raw: raw)
                guard a.bool("confirm_send") == true else { throw ArgError(message: "Not sent: confirm_send must be true.") }
                let msg = try a.need("message_id")
                let acct = try await e.mail.account(ofMessage: msg, preferred: try a.need("account")) ?? (try a.need("account"))
                let addr = try await e.mail.replyAddressing(accountId: acct, messageId: msg, replyAll: a.bool("reply_all") ?? false)
                let choice = try await sender(e, a, account: acct, recipients: addr.to + addr.cc, replyTo: msg)
                var i = ComposeInput(accountId: acct, to: addr.to, cc: addr.cc, subject: addr.subject, text: try a.need("body"))
                i.fromEmail = choice.fromEmail
                i.replyTo = (acct, msg)
                return try await queue(e, ui: ui, i, sendAt: try a.date("send_at")).merging(describe(choice)) { a, _ in a }
            },
            MCPTool(name: "list_scheduled", description: "List mail waiting in Postvak's outbox: scheduled for later, waiting for a connection, or needing a decision because its time passed while Postvak was closed or it failed. Check it before writing a follow-up, since a mail queued here has not reached Sent yet.",
                    properties: [:]) { _ in
                let rows = try await e.db.pool.read { try OutboxRow.listed($0) }
                return rows.map { r -> [String: Any] in
                    let m = try? JSONDecoder().decode(OutgoingMail.self, from: r.payload)
                    return ["outbox_id": r.id, "status": r.status.rawValue, "send_at": Fmt.string(r.sendAt), "account": r.accountId,
                            "from": m?.fromEmail ?? r.accountId, "to": m?.to ?? [], "cc": m?.cc ?? [], "subject": m?.subject ?? r.summary,
                            "last_error": r.lastError ?? NSNull()]
                }
            },
            MCPTool(name: "cancel_send", description: "Cancel a queued mail by outbox_id while it is still in its undo window or scheduled.",
                    properties: ["outbox_id": str("Id from send_mail or reply.")], required: ["outbox_id"]) { raw in
                let id = try Args(raw: raw).need("outbox_id")
                let m = try await e.outbox.cancel(id: id)
                await e.outbox.removeFiles(id: id)
                return ["cancelled": m != nil] as [String: Any]
            },
            MCPTool(name: "archive", description: "Archive a thread: it leaves the inbox and stays in All Mail.",
                    properties: ["account": str("Account address."), "thread_id": str("Thread id.")], required: ["account", "thread_id"]) { raw in
                let a = Args(raw: raw)
                try await e.mail.archive(accountId: try a.need("account"), threadId: try a.need("thread_id"))
                return ["archived": try a.need("thread_id")]
            },
            MCPTool(name: "label", description: "Add or remove labels on a thread, by name. Missing labels in add are created.",
                    properties: ["account": str("Account address."), "thread_id": str("Thread id."), "add": strs("Label names to add."), "remove": strs("Label names to remove.")],
                    required: ["account", "thread_id"]) { raw in
                let a = Args(raw: raw)
                let acct = try a.need("account"), t = try a.need("thread_id")
                var add: [String] = [], remove: [String] = []
                for n in a.strings("add") { add.append(try await e.mail.resolveLabel(accountId: acct, name: n, create: true)) }
                for n in a.strings("remove") { remove.append(try await e.mail.resolveLabel(accountId: acct, name: n, create: false)) }
                try await e.mail.modify(accountId: acct, threadId: t, add: add, remove: remove)
                return ["thread_id": t, "added": a.strings("add"), "removed": a.strings("remove")] as [String: Any]
            },
            MCPTool(name: "mark_read", description: "Mark a thread read, or unread with read false.",
                    properties: ["account": str("Account address."), "thread_id": str("Thread id."), "read": bool("Default true.")], required: ["account", "thread_id"]) { raw in
                let a = Args(raw: raw)
                let read = a.bool("read") ?? true
                try await e.mail.markRead(accountId: try a.need("account"), threadId: try a.need("thread_id"), read: read)
                return ["thread_id": try a.need("thread_id"), "read": read] as [String: Any]
            },
            MCPTool(name: "snooze", description: "Hide a thread from the inbox until a time. It returns unread.",
                    properties: ["account": str("Account address."), "thread_id": str("Thread id."), "until": str("ISO 8601 time.")], required: ["account", "thread_id", "until"]) { raw in
                let a = Args(raw: raw)
                let until = try a.needDate("until")
                try await e.mail.snooze(accountId: try a.need("account"), threadId: try a.need("thread_id"), until: until)
                return ["thread_id": try a.need("thread_id"), "until": Fmt.string(until)]
            },
            MCPTool(name: "get_signature", description: "Read an account's Gmail signature (HTML).",
                    properties: ["account": str("Account address.")], required: ["account"]) { raw in
                let s = try await e.mail.signature(accountId: try Args(raw: raw).need("account"))
                return ["email": s.email, "name": s.name ?? NSNull(), "signature_html": s.html] as [String: Any]
            },
            MCPTool(name: "set_signature", description: "Replace an account's Gmail signature. Gmail web shows the same one. Pass the old text back in the reply so the user can compare.",
                    properties: ["account": str("Account address."), "signature_html": str("New signature as HTML.")], required: ["account", "signature_html"]) { raw in
                let a = Args(raw: raw)
                let acct = try a.need("account"), html = try a.need("signature_html")
                let old = (try? await e.mail.signature(accountId: acct).html) ?? ""
                try await e.mail.setSignature(accountId: acct, html: html)
                return ["account": acct, "previous_signature_html": old, "signature_html": html]
            },
        ]
    }

    static func calendar(_ e: Engine) -> [MCPTool] {
        [
            MCPTool(name: "list_calendars", description: "List calendars across all accounts.", properties: ["account": str("Limit to this address.")]) { raw in
                try await e.calendar.calendars(accountId: Args(raw: raw).string("account")).map {
                    ["account": $0.accountId, "calendar_id": $0.calendarId, "name": $0.summary, "primary": $0.isPrimary, "selected": $0.isSelected, "can_write": $0.canWrite] as [String: Any]
                }
            },
            MCPTool(name: "list_events", description: "List events in a time range, merged across accounts.",
                    properties: ["from": str("ISO 8601 start."), "to": str("ISO 8601 end."), "account": str("Limit to this address."), "include_hidden_calendars": bool("Also include calendars switched off in the app.")],
                    required: ["from", "to"]) { raw in
                let a = Args(raw: raw)
                return try await e.calendar.events(from: try a.needDate("from"), to: try a.needDate("to"), accountId: a.string("account"),
                                                   onlySelected: !(a.bool("include_hidden_calendars") ?? false)).map(eventJSON)
            },
            MCPTool(name: "get_availability", description: "Free time across every account's selected calendars. Free, declined and all-day events don't block time.",
                    properties: ["from": str("ISO 8601 start."), "to": str("ISO 8601 end."), "min_minutes": int("Shortest useful slot. Default 30."),
                                 "work_start_hour": int("Clip to weekdays from this hour, for example 9."), "work_end_hour": int("Clip to weekdays until this hour, for example 18.")],
                    required: ["from", "to"]) { raw in
                let a = Args(raw: raw)
                var hours: ClosedRange<Int>?
                if let s = a.int("work_start_hour"), let t = a.int("work_end_hour") {
                    guard s < t, s >= 0, t <= 23 else { throw ArgError(message: "Working hours must be 0 to 23, start before end.") }
                    hours = s...t
                }
                return try await e.calendar.availability(from: try a.needDate("from"), to: try a.needDate("to"), minMinutes: a.int("min_minutes") ?? 30, workingHours: hours).map {
                    ["start": Fmt.string($0.start), "end": Fmt.string($0.end), "minutes": Int($0.end.timeIntervalSince($0.start) / 60)] as [String: Any]
                }
            },
            MCPTool(name: "create_event", description: "Create an event. Attendees get an invitation from Google straight away.",
                    properties: [
                        "account": str("Owning address."), "calendar_id": str("Default: that account's primary calendar."), "summary": str("Title."),
                        "start": str("ISO 8601, or yyyy-MM-dd when all_day."), "end": str("ISO 8601. For all_day, the day after the last day."), "all_day": bool("All-day event."),
                        "description": str("Details."), "location": str("Place."), "attendees": strs("Addresses to invite."),
                        "recurrence": strs("RRULE lines, for example RRULE:FREQ=WEEKLY."), "add_meet_link": bool("Create a Google Meet link. Default: true, except for all-day events. Pass false for an event without a link."),
                    ], required: ["account", "summary", "start", "end"]) { raw in
                let a = Args(raw: raw)
                let acct = try a.need("account")
                var calendarId = a.string("calendar_id")
                if calendarId == nil { calendarId = try await e.calendar.calendars(accountId: acct).first(where: \.isPrimary)?.calendarId ?? acct }
                let allDay = a.bool("all_day") ?? false
                let input = EventInput(accountId: acct, calendarId: calendarId!, summary: try a.need("summary"), details: a.string("description"), location: a.string("location"),
                                       start: try a.needDate("start"), end: try a.needDate("end"), isAllDay: allDay, attendees: a.strings("attendees"),
                                       recurrence: a.strings("recurrence"), addMeetLink: a.bool("add_meet_link") ?? !allDay)
                return eventJSON(try await e.calendar.create(input))
            },
            MCPTool(name: "update_event", description: "Change an event. Only the fields you pass change. Attendees are told by Google. Recurring events change one instance.",
                    properties: [
                        "account": str("Owning address."), "calendar_id": str("Calendar id."), "event_id": str("Event id."),
                        "summary": str("Title."), "description": str("Details."), "location": str("Place."),
                        "start": str("ISO 8601."), "end": str("ISO 8601."), "all_day": bool("All-day."), "attendees": strs("Replaces the attendee list."),
                    ], required: ["account", "calendar_id", "event_id"]) { raw in
                let a = Args(raw: raw)
                let patch = EventPatch(summary: a.string("summary"), details: a.string("description"), location: a.string("location"),
                                       start: try a.date("start"), end: try a.date("end"), isAllDay: a.bool("all_day"),
                                       attendees: raw["attendees"] == nil ? nil : a.strings("attendees"))
                return eventJSON(try await e.calendar.update(accountId: try a.need("account"), calendarId: try a.need("calendar_id"), eventId: try a.need("event_id"), patch: patch))
            },
            MCPTool(name: "delete_event", description: "Delete an event. Attendees are told by Google. Requires confirm_delete true.",
                    properties: ["account": str("Owning address."), "calendar_id": str("Calendar id."), "event_id": str("Event id."), "confirm_delete": bool("Must be true.")],
                    required: ["account", "calendar_id", "event_id", "confirm_delete"]) { raw in
                let a = Args(raw: raw)
                guard a.bool("confirm_delete") == true else { throw ArgError(message: "Not deleted: confirm_delete must be true.") }
                try await e.calendar.delete(accountId: try a.need("account"), calendarId: try a.need("calendar_id"), eventId: try a.need("event_id"))
                return ["deleted": try a.need("event_id")]
            },
            MCPTool(name: "respond_to_invite", description: "Accept, decline or tentatively accept an invitation. The organiser is told.",
                    properties: ["account": str("Invited address."), "calendar_id": str("Calendar id."), "event_id": str("Event id."), "response": str("accepted, declined or tentative.")],
                    required: ["account", "calendar_id", "event_id", "response"]) { raw in
                let a = Args(raw: raw)
                return eventJSON(try await e.calendar.respond(accountId: try a.need("account"), calendarId: try a.need("calendar_id"), eventId: try a.need("event_id"), response: try a.need("response")))
            },
        ]
    }

    static func meetings(_ e: Engine, _ rec: RecorderControl?) -> [MCPTool] {
        [
            MCPTool(name: "list_meetings", description: "List recorded and imported meetings, newest first. Each has the project it is filed under, or null when unfiled.",
                    properties: ["from": str("ISO 8601."), "to": str("ISO 8601."), "text": str("Match title or attendee."), "limit": int("Default 25."),
                                 "project": str("Only meetings filed under this project, or \"unfiled\".")]) { raw in
                let a = Args(raw: raw)
                return try await e.meetings.list(from: try a.date("from"), to: try a.date("to"), text: a.string("text"), project: a.string("project"),
                                                 limit: a.int("limit") ?? 25).map(meetingJSON)
            },
            MCPTool(name: "get_meeting", description: "Read a meeting: summary, decisions, action items with their transcript source, open questions, attendees, speakers, linked event, and email threads with the guests around its date.",
                    properties: ["meeting_id": str("Meeting id.")], required: ["meeting_id"]) { raw in
                let id = try Args(raw: raw).need("meeting_id")
                guard let (m, s) = try await e.meetings.get(id) else { throw MailError.notFound("meeting \(id)") }
                var out = meetingJSON(m)
                out["segment_count"] = try await e.meetings.segmentCount(meetingId: id)
                out["related_threads"] = try await e.meetings.relatedThreads(meetingId: id).map {
                    ["account": $0.accountId, "thread_id": $0.threadId, "subject": $0.subject, "last_at": Fmt.string($0.lastAt),
                     "sent": $0.sent, "received": $0.received, "with_guests": $0.guestsInThread > 0] as [String: Any]
                }
                out["speakers"] = try await e.meetings.speakers(meetingId: id).map {
                    ["label": $0.label, "name": $0.isApplied ? $0.name : NSNull(), "suggested_name": $0.isApplied ? NSNull() : $0.name,
                     "email": $0.email ?? NSNull(), "source": $0.source.rawValue] as [String: Any]
                }
                if let s {
                    // Each point carries the transcript moment it came from, so it can be checked.
                    var segs: [Int: TranscriptSegmentRecord] = [:]
                    if s.actionItems.contains(where: { $0.segment != nil }) || s.decisionItems.contains(where: { $0.segment != nil }) {
                        for seg in try await e.meetings.segments(meetingId: id) { segs[seg.position] = seg }
                    }
                    func source(_ p: Int?) -> Any {
                        guard let p, let seg = segs[p] else { return NSNull() }
                        return ["segment": p, "at_seconds": seg.startSeconds, "quote": String(seg.text.prefix(300))] as [String: Any]
                    }
                    out["summary"] = s.summary
                    out["decisions"] = s.decisionItems.map { ["text": $0.text, "source": source($0.segment)] as [String: Any] }
                    if s.decisionItems.isEmpty, s.model.hasPrefix("claude") { out["decisions_note"] = "No decision taken." }
                    out["open_questions"] = s.openQuestions
                    out["action_items"] = s.actionItems.map {
                        ["task": $0.task, "owner": $0.owner ?? NSNull(), "due": $0.due ?? NSNull(), "status": $0.status?.rawValue ?? NSNull(),
                         "source": source($0.segment)] as [String: Any]
                    }
                }
                return out
            },
            MCPTool(name: "get_transcript", description: "Read a meeting's transcript in pages, with speakers and timestamps in seconds. speaker is the person's name when known, speaker_label the raw label.",
                    properties: ["meeting_id": str("Meeting id."), "offset": int("First segment. Default 0."), "limit": int("Default 200, maximum 1000.")], required: ["meeting_id"]) { raw in
                let a = Args(raw: raw)
                let id = try a.need("meeting_id"), offset = a.int("offset") ?? 0, limit = min(a.int("limit") ?? 200, 1000)
                let segs = try await e.meetings.segments(meetingId: id, offset: offset, limit: limit)
                let total = try await e.meetings.segmentCount(meetingId: id)
                let names = try await e.meetings.speakerNames(meetingId: id)
                return [
                    "total": total, "offset": offset,
                    "next_offset": offset + segs.count < total ? offset + segs.count : NSNull(),
                    "segments": segs.map {
                        ["start": $0.startSeconds, "end": $0.endSeconds, "speaker": names[$0.speaker] ?? $0.speaker, "speaker_label": $0.speaker, "text": $0.text] as [String: Any]
                    },
                ] as [String: Any]
            },
            MCPTool(name: "search_transcripts", description: "Find what was said across all meetings.",
                    properties: ["query": str("Words to find."), "limit": int("Default 30.")], required: ["query"]) { raw in
                let a = Args(raw: raw)
                return try await e.meetings.search(try a.need("query"), limit: a.int("limit") ?? 30).map {
                    ["meeting_id": $0.meetingId, "meeting": $0.meetingTitle, "date": Fmt.string($0.startedAt), "speaker": $0.speaker, "at_seconds": $0.startSeconds, "text": $0.text] as [String: Any]
                }
            },
            MCPTool(name: "import_meeting", description: "Add a past meeting from another tool. Importing the same source and source_id again updates it.",
                    properties: [
                        "source": str("granola, anarlog or another name."), "source_id": str("Id in that tool."), "title": str("Title."),
                        "started_at": str("ISO 8601."), "ended_at": str("ISO 8601."), "attendees": strs("Names or addresses."), "language": str("nl, en or fr."),
                        "summary": str("Summary text."),
                        "transcript": ["type": "array", "description": "Segments.", "items": [
                            "type": "object",
                            "properties": ["start": ["type": "number"], "end": ["type": "number"], "speaker": ["type": "string"], "text": ["type": "string"]],
                            "required": ["text"],
                        ]],
                    ], required: ["source", "source_id", "title", "started_at"]) { raw in
                let a = Args(raw: raw)
                let segs = (raw["transcript"] as? [[String: Any]])?.compactMap { s -> ImportedSegment? in
                    guard let t = s["text"] as? String else { return nil }
                    return ImportedSegment(start: (s["start"] as? NSNumber)?.doubleValue, end: (s["end"] as? NSNumber)?.doubleValue, speaker: s["speaker"] as? String, text: t)
                }
                let new = try await e.meetings.importMeeting(ImportedMeeting(
                    source: try a.need("source"), sourceId: try a.need("source_id"), title: try a.need("title"),
                    startedAt: try a.needDate("started_at"), endedAt: try a.date("ended_at"), attendees: a.strings("attendees"),
                    language: a.string("language"), summary: a.string("summary"), segments: segs))
                return ["imported": new ? "new" : "updated", "segments": segs?.count ?? 0] as [String: Any]
            },
            MCPTool(name: "start_recording", description: "Start recording a meeting on this Mac: system audio and microphone. Only when the user asks, and everyone present should know.",
                    properties: ["title": str("Meeting title. Default: the current calendar event.")]) { raw in
                guard let rec else { throw ArgError(message: "Recording is not available.") }
                return ["recording": true, "meeting_id": try await rec.startRecording(title: Args(raw: raw).string("title"))] as [String: Any]
            },
            MCPTool(name: "stop_recording", description: "Stop the current recording. Transcription and the summary then run in the background.", properties: [:]) { _ in
                guard let rec else { throw ArgError(message: "Recording is not available.") }
                return ["recording": false, "meeting_id": try await rec.stopRecording()] as [String: Any]
            },
        ]
    }
}

/// Checks the files Claude asks to attach. A mail Claude reads could ask it to attach something private, so keys,
/// credentials and app data stay out, whatever the path says; the user still sees every file in Review Drafts.
enum DraftFiles {
    static let maxTotal = 25 * 1024 * 1024

    static func resolve(_ list: [String], paths: AppPaths, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> [OutgoingAttachment] {
        let fm = FileManager.default
        let cache = paths.attachments.resolvingSymlinksInPath().path + "/"
        let homePath = home.resolvingSymlinksInPath().path + "/"
        var total = 0
        return try list.map { given in
            let expanded = (given as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { throw ArgError(message: "Attachment \(given): give an absolute path.") }
            let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
            let p = url.path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue else { throw ArgError(message: "Attachment \(given): no such file.") }
            if !p.hasPrefix(cache) {
                // Hidden folders and files (~/.ssh, ~/.aws, .env…), ~/Library (keychains, app data, Postvak's own
                // database) and system folders are refused; files from mail come from Postvak's cache above.
                let parts = url.pathComponents
                let hidden = parts.contains { $0.hasPrefix(".") }
                let inLibrary = p.hasPrefix(homePath + "Library/")
                let outsideHome = !p.hasPrefix(homePath) && !p.hasPrefix("/Volumes/") && !p.hasPrefix(NSTemporaryDirectory().resolvingPath)
                if hidden || inLibrary || outsideHome {
                    throw ArgError(message: "Attachment \(given): Postvak does not attach files from hidden folders, Library or system folders. Copy it to Documents or Downloads first.")
                }
            }
            guard fm.isReadableFile(atPath: p) else { throw ArgError(message: "Attachment \(given): Postvak may not read it.") }
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard total <= maxTotal else { throw ArgError(message: "Attachments come to more than 25 MB, Gmail's limit. Share a link instead.") }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            return OutgoingAttachment(filename: url.lastPathComponent, mimeType: type, path: p)
        }
    }
}

private extension String {
    var resolvingPath: String { URL(fileURLWithPath: self).resolvingSymlinksInPath().path }
}
