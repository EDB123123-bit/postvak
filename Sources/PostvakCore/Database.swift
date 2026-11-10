import Foundation
import GRDB

public final class AppDatabase: @unchecked Sendable {
    public let pool: DatabasePool

    public init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in db.add(function: Matching.hasAddressFunction) }
        pool = try DatabasePool(path: path, configuration: config)
        try Self.migrator.migrate(pool)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "account") { t in
                t.primaryKey("id", .text)
                t.column("displayName", .text).notNull()
                t.column("colorHex", .text).notNull()
                t.column("historyId", .text)
                t.column("initialPageToken", .text)
                t.column("initialSyncDone", .boolean).notNull().defaults(to: false)
                t.column("syncedThreadCount", .integer).notNull().defaults(to: 0)
                t.column("lastSyncAt", .datetime)
                t.column("lastError", .text)
                t.column("needsReauth", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "label") { t in
                t.column("accountId", .text).notNull().references("account", onDelete: .cascade)
                t.column("labelId", .text).notNull()
                t.column("name", .text).notNull()
                t.column("type", .text).notNull()
                t.primaryKey(["accountId", "labelId"])
            }
            try db.create(table: "thread") { t in
                t.column("accountId", .text).notNull().references("account", onDelete: .cascade)
                t.column("threadId", .text).notNull()
                t.column("subject", .text).notNull()
                t.column("snippet", .text).notNull()
                t.column("participants", .text).notNull()
                t.column("lastSenderEmail", .text).notNull()
                t.column("lastMessageAt", .datetime).notNull().indexed()
                t.column("messageCount", .integer).notNull()
                t.column("labelIds", .text).notNull()
                t.column("hasAttachments", .boolean).notNull()
                t.column("bucket", .text)
                t.column("bucketSource", .text)
                t.column("needsAIClassification", .boolean).notNull().defaults(to: false)
                t.primaryKey(["accountId", "threadId"])
            }
            try db.create(table: "message") { t in
                t.column("accountId", .text).notNull().references("account", onDelete: .cascade)
                t.column("messageId", .text).notNull()
                t.column("threadId", .text).notNull()
                t.column("rfcMessageId", .text)
                t.column("inReplyTo", .text)
                t.column("referencesHeader", .text)
                t.column("fromName", .text).notNull()
                t.column("fromEmail", .text).notNull().indexed()
                t.column("toLine", .text).notNull()
                t.column("ccLine", .text).notNull()
                t.column("subject", .text).notNull()
                t.column("date", .datetime).notNull()
                t.column("snippet", .text).notNull()
                t.column("bodyText", .text).notNull()
                t.column("bodyHtml", .text)
                t.column("labelIds", .text).notNull()
                t.column("hasListUnsubscribe", .boolean).notNull()
                t.primaryKey(["accountId", "messageId"])
            }
            try db.create(index: "message_thread", on: "message", columns: ["accountId", "threadId", "date"])
            try db.create(table: "attachment") { t in
                t.column("accountId", .text).notNull()
                t.column("messageId", .text).notNull()
                t.column("partId", .text).notNull()
                t.column("attachmentId", .text).notNull()
                t.column("filename", .text).notNull()
                t.column("mimeType", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("contentId", .text)
                t.column("localPath", .text)
                t.primaryKey(["accountId", "messageId", "partId"])
                t.foreignKey(["accountId", "messageId"], references: "message", onDelete: .cascade)
            }
            try db.create(table: "outbox") { t in
                t.primaryKey("id", .text)
                t.column("accountId", .text).notNull()
                t.column("payload", .blob).notNull()
                t.column("sendAt", .datetime).notNull().indexed()
                t.column("status", .text).notNull()
                t.column("isUndoWindow", .boolean).notNull()
                t.column("lastError", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("summary", .text).notNull()
            }
            try db.create(table: "snooze") { t in
                t.column("accountId", .text).notNull()
                t.column("threadId", .text).notNull()
                t.column("wakeAt", .datetime).notNull().indexed()
                t.primaryKey(["accountId", "threadId"])
            }
            try db.create(table: "calendar") { t in
                t.column("accountId", .text).notNull().references("account", onDelete: .cascade)
                t.column("calendarId", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("colorHex", .text).notNull()
                t.column("isPrimary", .boolean).notNull()
                t.column("isSelected", .boolean).notNull()
                t.column("accessRole", .text).notNull()
                t.column("syncToken", .text)
                t.column("lastFullSyncAt", .datetime)
                t.primaryKey(["accountId", "calendarId"])
            }
            try db.create(table: "event") { t in
                t.column("accountId", .text).notNull()
                t.column("calendarId", .text).notNull()
                t.column("eventId", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("details", .text).notNull()
                t.column("location", .text).notNull()
                t.column("startAt", .datetime).notNull().indexed()
                t.column("endAt", .datetime).notNull().indexed()
                t.column("isAllDay", .boolean).notNull()
                t.column("status", .text).notNull()
                t.column("transparency", .text).notNull()
                t.column("organizerEmail", .text).notNull()
                t.column("attendeesJSON", .text).notNull()
                t.column("selfResponse", .text)
                t.column("meetingLink", .text)
                t.column("htmlLink", .text)
                t.column("recurringEventId", .text)
                t.primaryKey(["accountId", "calendarId", "eventId"])
                t.foreignKey(["accountId", "calendarId"], references: "calendar", onDelete: .cascade)
            }
            try db.create(table: "meeting") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("endedAt", .datetime)
                t.column("micAudioPath", .text)
                t.column("systemAudioPath", .text)
                t.column("language", .text)
                t.column("status", .text).notNull()
                t.column("statusDetail", .text)
                t.column("eventAccountId", .text)
                t.column("eventCalendarId", .text)
                t.column("eventId", .text)
                t.column("attendeesJSON", .text).notNull()
                t.column("source", .text).notNull()
                t.column("sourceId", .text)
                t.column("transcriptEngine", .text)
            }
            try db.create(index: "meeting_source", on: "meeting", columns: ["source", "sourceId"], unique: true)
            try db.create(table: "transcript_segment") { t in
                t.primaryKey("id", .text)
                t.column("meetingId", .text).notNull().references("meeting", onDelete: .cascade).indexed()
                t.column("position", .integer).notNull()
                t.column("startSeconds", .double).notNull()
                t.column("endSeconds", .double).notNull()
                t.column("speaker", .text).notNull()
                t.column("text", .text).notNull()
            }
            try db.create(table: "meeting_summary") { t in
                t.primaryKey("meetingId", .text).references("meeting", onDelete: .cascade)
                t.column("summary", .text).notNull()
                t.column("decisionsJSON", .text).notNull()
                t.column("actionItemsJSON", .text).notNull()
                t.column("openQuestionsJSON", .text).notNull()
                t.column("model", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("editedAt", .datetime)
            }
            try db.create(table: "sender_override") { t in
                t.primaryKey("email", .text)
                t.column("bucket", .text).notNull()
            }
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            try db.create(virtualTable: "message_ft", using: FTS5()) { t in
                t.synchronize(withTable: "message")
                t.tokenizer = .unicode61()
                t.column("subject")
                t.column("fromName")
                t.column("fromEmail")
                t.column("toLine")
                t.column("bodyText")
            }
            try db.create(virtualTable: "transcript_ft", using: FTS5()) { t in
                t.synchronize(withTable: "transcript_segment")
                t.tokenizer = .unicode61()
                t.column("speaker")
                t.column("text")
            }
        }
        // Ask Meetings questions and answers, kept so earlier chats can be read and continued.
        m.registerMigration("v2-ask-history") { db in
            try db.create(table: "ask_turn") { t in
                t.primaryKey("id", .text)
                t.column("chatId", .text).notNull().indexed()
                t.column("question", .text).notNull()
                t.column("answer", .text)
                t.column("error", .text)
                t.column("stepsJSON", .text).notNull()
                t.column("askedAt", .datetime).notNull()
            }
        }
        m.registerMigration("v3-follow-up") { db in
            try db.create(table: "follow_up") { t in
                t.primaryKey("id", .text)
                t.column("accountId", .text).notNull()
                t.column("threadId", .text).notNull()
                t.column("subject", .text).notNull()
                t.column("recipients", .text).notNull()
                t.column("sentAt", .datetime).notNull()
                t.column("dueAt", .datetime).notNull()
                t.column("status", .text).notNull().indexed()
                t.column("firedAt", .datetime)
                t.column("nudgeDraftId", .text)
            }
            try db.create(index: "follow_up_thread", on: "follow_up", columns: ["accountId", "threadId"])
        }
        m.registerMigration("v4-prep-brief") { db in
            try db.create(table: "prep_brief") { t in
                t.primaryKey("eventKey", .text)
                t.column("text", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }
        m.registerMigration("v5-api-usage") { db in
            try db.create(table: "api_usage") { t in
                t.column("day", .text).notNull()
                t.column("feature", .text).notNull()
                t.column("model", .text).notNull()
                t.column("requests", .integer).notNull()
                t.column("inputTokens", .integer).notNull()
                t.column("outputTokens", .integer).notNull()
                t.column("cacheReadTokens", .integer).notNull()
                t.column("cacheWriteTokens", .integer).notNull()
                t.column("costMicros", .integer).notNull()
                t.primaryKey(["day", "feature", "model"])
            }
        }
        // Deals across the user's ventures, as Claude last read them from mail and meetings.
        m.registerMigration("v6-deals") { db in
            try db.create(table: "deal") { t in
                t.primaryKey("key", .text)
                t.column("isDeal", .boolean).notNull()
                t.column("venture", .text).notNull()
                t.column("company", .text).notNull()
                t.column("contacts", .text).notNull()
                t.column("stage", .text).notNull()
                t.column("risk", .text).notNull()
                t.column("nextStep", .text).notNull()
                t.column("owner", .text).notNull()
                t.column("due", .text).notNull()
                t.column("amount", .text).notNull()
                t.column("amountEUR", .double).notNull()
                t.column("size", .text).notNull()
                t.column("sizeSource", .text).notNull()
                t.column("latestThread", .text)
                t.column("activityKey", .text).notNull()
                t.column("analyzedAt", .datetime).notNull()
            }
        }
        // Who each transcript speaker is: named by rule, suggested by Claude, or chosen by the user.
        m.registerMigration("v7-meeting-speakers") { db in
            try db.create(table: "meeting_speaker") { t in
                t.column("meetingId", .text).notNull().references("meeting", onDelete: .cascade)
                t.column("label", .text).notNull()
                t.column("name", .text).notNull()
                t.column("email", .text)
                t.column("source", .text).notNull()
                t.primaryKey(["meetingId", "label"])
            }
        }
        // The project a meeting is filed under, and whether the rules or the user chose it.
        m.registerMigration("v8-meeting-project") { db in
            try db.alter(table: "meeting") { t in
                t.add(column: "project", .text)
                t.add(column: "projectSource", .text)
            }
        }
        // Drafts Postvak wrote without being asked at that moment, waiting for the user to send, edit or delete them.
        m.registerMigration("v9-auto-drafts") { db in
            try db.create(table: "auto_draft") { t in
                t.primaryKey("id", .text)
                t.column("accountId", .text).notNull()
                t.column("draftId", .text).notNull()
                t.column("threadId", .text)
                t.column("fromEmail", .text).notNull()
                t.column("recipients", .text).notNull()
                t.column("subject", .text).notNull()
                t.column("source", .text).notNull()
                t.column("reason", .text).notNull()
                t.column("meetingId", .text).indexed()
                t.column("createdAt", .datetime).notNull()
                t.column("status", .text).notNull().indexed()
                t.column("reviewedAt", .datetime)
            }
        }
        // What the user says about a deal (notes, steps done) and what the CRM says, kept apart from Claude's reading.
        m.registerMigration("v10-deal-notes") { db in
            try db.create(table: "deal_note") { t in
                t.primaryKey("id", .text)
                t.column("dealKey", .text).notNull().indexed()
                t.column("text", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("crmPushedAt", .datetime)
                t.column("crmError", .text)
            }
            try db.create(table: "deal_state") { t in
                t.primaryKey("key", .text)
                t.column("doneStep", .text)
                t.column("doneAt", .datetime)
                t.column("doneActivityKey", .text)
                t.column("crmLeadId", .text)
                t.column("crmUserId", .text)
                t.column("crmProject", .text)
                t.column("crmCompany", .text)
                t.column("crmStage", .text)
                t.column("crmContext", .text)
                t.column("crmFingerprint", .text)
                t.column("crmChangedAt", .datetime)
                t.column("crmProposalDismissed", .text)
            }
        }
        // The letter shown inside each account's colour.
        m.registerMigration("v11-account-badge") { db in
            try db.alter(table: "account") { t in t.add(column: "badge", .text) }
        }
        // Meetings whose summary should be the long one, kept when the summary is written again.
        m.registerMigration("v12-detailed-summary") { db in
            try db.alter(table: "meeting") { t in t.add(column: "detailedSummary", .boolean).notNull().defaults(to: false) }
        }
        return m
    }

    // MARK: settings

    public func setting(_ key: String) -> String? {
        try? pool.read { try SettingRow.fetchOne($0, key: key)?.value }
    }

    public func setSetting(_ key: String, _ value: String?) throws {
        try pool.write { db in
            if let value { try SettingRow(key: key, value: value).save(db) }
            else { _ = try SettingRow.deleteOne(db, key: key) }
        }
    }

    public func settingBool(_ key: String, default def: Bool) -> Bool {
        setting(key).map { $0 == "1" } ?? def
    }
}

/// Turns free text into a safe FTS5 prefix query: every word must match.
public func ftsQuery(_ text: String) -> String? {
    let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    guard !tokens.isEmpty else { return nil }
    return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
}
