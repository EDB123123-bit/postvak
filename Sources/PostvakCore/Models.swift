import Foundation
import GRDB

public typealias PersistableModel = Codable & FetchableRecord & PersistableRecord & Sendable

/// Label sets are stored as `|INBOX|UNREAD|` so a LIKE filter stays exact.
public enum LabelSet {
    public static func encode<S: Sequence>(_ labels: S) -> String where S.Element == String {
        let sorted = Set(labels).sorted()
        return sorted.isEmpty ? "|" : "|" + sorted.joined(separator: "|") + "|"
    }
    public static func decode(_ s: String) -> Set<String> {
        Set(s.split(separator: "|").map(String.init))
    }
}

public enum GmailLabel {
    public static let inbox = "INBOX", unread = "UNREAD", starred = "STARRED", sent = "SENT"
    public static let draft = "DRAFT", spam = "SPAM", trash = "TRASH", important = "IMPORTANT"
    public static let catPersonal = "CATEGORY_PERSONAL", catSocial = "CATEGORY_SOCIAL"
    public static let catPromotions = "CATEGORY_PROMOTIONS", catUpdates = "CATEGORY_UPDATES", catForums = "CATEGORY_FORUMS"
    public static let snoozedName = "Postvak/Snoozed"
}

public enum InboxBucket: String, Codable, CaseIterable, Sendable, Hashable {
    case people, notifications, newsletters
    public var title: String {
        switch self {
        case .people: "People"
        case .notifications: "Notifications"
        case .newsletters: "Newsletters"
        }
    }
}

public struct Account: PersistableModel, Identifiable, Hashable {
    public static let databaseTableName = "account"
    public var id: String
    public var displayName: String
    public var colorHex: String
    public var historyId: String?
    public var initialPageToken: String?
    public var initialSyncDone: Bool
    public var syncedThreadCount: Int
    public var lastSyncAt: Date?
    public var lastError: String?
    public var needsReauth: Bool
    /// The letter shown inside the account's colour, so the user can tell the inboxes apart. Nil means the default.
    public var badge: String?
    public var email: String { id }

    /// The letter in the account's colour: the one the user chose, or one taken from the address.
    public var badgeLetter: String {
        if let b = badge?.trimmingCharacters(in: .whitespaces), let c = b.first { return String(c).uppercased() }
        return Self.defaultBadge(for: id)
    }

    /// "P" for a personal address (Gmail and the like), else the first letter of the company's name,
    /// skipping a "get", "try", "use" or "hello" in front: anna@getbrightly.com is B, ann@zonnehoek.be is Z.
    public static func defaultBadge(for email: String) -> String {
        let domain = email.split(separator: "@").last.map { String($0).lowercased() } ?? ""
        if domain.isEmpty || Matching.genericDomains.contains(domain) { return "P" }
        var name = String(domain.split(separator: ".").first ?? "")
        for p in ["get", "try", "use", "hello"] where name.hasPrefix(p) && name.count > p.count + 2 {
            name = String(name.dropFirst(p.count)); break
        }
        return name.first.map { String($0).uppercased() } ?? "?"
    }

    public init(id: String, displayName: String, colorHex: String) {
        self.id = id; self.displayName = displayName; self.colorHex = colorHex
        initialSyncDone = false; syncedThreadCount = 0; needsReauth = false
    }
}

public struct MailLabelRecord: PersistableModel, Identifiable, Hashable {
    public static let databaseTableName = "label"
    public var accountId: String
    public var labelId: String
    public var name: String
    public var type: String
    public var id: String { "\(accountId)/\(labelId)" }
    public init(accountId: String, labelId: String, name: String, type: String) {
        self.accountId = accountId; self.labelId = labelId; self.name = name; self.type = type
    }
}

public struct MailThread: PersistableModel, Identifiable, Hashable {
    public static let databaseTableName = "thread"
    public var accountId: String
    public var threadId: String
    public var subject: String
    public var snippet: String
    public var participants: String
    public var lastSenderEmail: String
    public var lastMessageAt: Date
    public var messageCount: Int
    public var labelIds: String
    public var hasAttachments: Bool
    public var bucket: String?
    public var bucketSource: String?   // gmail | ai | override
    public var needsAIClassification: Bool

    public var id: String { "\(accountId)/\(threadId)" }
    public var labels: Set<String> { LabelSet.decode(labelIds) }
    public var isUnread: Bool { labels.contains(GmailLabel.unread) }
    public var isStarred: Bool { labels.contains(GmailLabel.starred) }
    public var isInInbox: Bool { labels.contains(GmailLabel.inbox) }
    public var isSpam: Bool { labels.contains(GmailLabel.spam) }
    public var isTrash: Bool { labels.contains(GmailLabel.trash) }
    public var inboxBucket: InboxBucket? { bucket.flatMap(InboxBucket.init(rawValue:)) }
}

public struct MailMessage: PersistableModel, Identifiable, Hashable {
    public static let databaseTableName = "message"
    public var accountId: String
    public var messageId: String
    public var threadId: String
    public var rfcMessageId: String?
    public var inReplyTo: String?
    public var referencesHeader: String?
    public var fromName: String
    public var fromEmail: String
    public var toLine: String
    public var ccLine: String
    public var subject: String
    public var date: Date
    public var snippet: String
    public var bodyText: String
    public var bodyHtml: String?
    public var labelIds: String
    public var hasListUnsubscribe: Bool

    public var id: String { "\(accountId)/\(messageId)" }
    public var labels: Set<String> { LabelSet.decode(labelIds) }
    public var isUnread: Bool { labels.contains(GmailLabel.unread) }
    public var isDraft: Bool { labels.contains(GmailLabel.draft) }
    public var senderDisplay: String { fromName.isEmpty ? fromEmail : fromName }
}

public struct AttachmentRecord: PersistableModel, Identifiable, Hashable {
    public static let databaseTableName = "attachment"
    public var accountId: String
    public var messageId: String
    public var partId: String
    public var attachmentId: String
    public var filename: String
    public var mimeType: String
    public var size: Int
    public var contentId: String?
    public var localPath: String?
    public var id: String { "\(accountId)/\(messageId)/\(partId)" }
}

public struct OutboxRow: PersistableModel, Identifiable, Hashable {
    public static let databaseTableName = "outbox"
    /// `held`: paused while a composer edits it, so the original can't go out under the edit.
    /// `waiting`: due while there was no connection. It goes by itself as soon as the network is back.
    public enum Status: String, Codable, Sendable { case pending, sending, overdue, failed, held, waiting }
    public var id: String
    public var accountId: String
    public var payload: Data
    public var sendAt: Date
    public var status: Status
    public var isUndoWindow: Bool
    public var lastError: String?
    public var createdAt: Date
    public var summary: String
}

public struct SnoozeRow: PersistableModel, Hashable {
    public static let databaseTableName = "snooze"
    public var accountId: String
    public var threadId: String
    public var wakeAt: Date
    public init(accountId: String, threadId: String, wakeAt: Date) {
        self.accountId = accountId; self.threadId = threadId; self.wakeAt = wakeAt
    }
}

public struct CalendarRecord: PersistableModel, Identifiable, Hashable {
    public static let databaseTableName = "calendar"
    public var accountId: String
    public var calendarId: String
    public var summary: String
    public var colorHex: String
    public var isPrimary: Bool
    public var isSelected: Bool
    public var accessRole: String
    public var syncToken: String?
    public var lastFullSyncAt: Date?
    public init(accountId: String, calendarId: String, summary: String, colorHex: String, isPrimary: Bool, isSelected: Bool, accessRole: String, syncToken: String?, lastFullSyncAt: Date?) {
        self.accountId = accountId; self.calendarId = calendarId; self.summary = summary; self.colorHex = colorHex; self.isPrimary = isPrimary
        self.isSelected = isSelected; self.accessRole = accessRole; self.syncToken = syncToken; self.lastFullSyncAt = lastFullSyncAt
    }
    public var id: String { "\(accountId)/\(calendarId)" }
    public var canWrite: Bool { accessRole == "owner" || accessRole == "writer" }
}

public struct EventAttendee: Codable, Hashable, Sendable {
    public var email: String
    public var name: String?
    public var response: String
    public var isSelf: Bool
    public var isOrganizer: Bool
    public init(email: String, name: String? = nil, response: String = "needsAction", isSelf: Bool = false, isOrganizer: Bool = false) {
        self.email = email; self.name = name; self.response = response; self.isSelf = isSelf; self.isOrganizer = isOrganizer
    }
}

public struct CalendarEvent: PersistableModel, Identifiable, Hashable {
    public static let databaseTableName = "event"
    public var accountId: String
    public var calendarId: String
    public var eventId: String
    public var summary: String
    public var details: String
    public var location: String
    public var startAt: Date
    public var endAt: Date
    public var isAllDay: Bool
    public var status: String
    public var transparency: String
    public var organizerEmail: String
    public var attendeesJSON: String
    public var selfResponse: String?
    public var meetingLink: String?
    public var htmlLink: String?
    public var recurringEventId: String?

    public init(accountId: String, calendarId: String, eventId: String, summary: String, details: String, location: String, startAt: Date, endAt: Date,
                isAllDay: Bool, status: String, transparency: String, organizerEmail: String, attendeesJSON: String, selfResponse: String?,
                meetingLink: String?, htmlLink: String?, recurringEventId: String?) {
        self.accountId = accountId; self.calendarId = calendarId; self.eventId = eventId; self.summary = summary; self.details = details
        self.location = location; self.startAt = startAt; self.endAt = endAt; self.isAllDay = isAllDay; self.status = status
        self.transparency = transparency; self.organizerEmail = organizerEmail; self.attendeesJSON = attendeesJSON
        self.selfResponse = selfResponse; self.meetingLink = meetingLink; self.htmlLink = htmlLink; self.recurringEventId = recurringEventId
    }

    public var id: String { "\(accountId)/\(calendarId)/\(eventId)" }
    public var attendees: [EventAttendee] {
        (try? JSONDecoder().decode([EventAttendee].self, from: Data(attendeesJSON.utf8))) ?? []
    }
    /// Blocks time on the agenda: not cancelled, not free, not declined.
    public var isBusy: Bool {
        status != "cancelled" && transparency != "transparent" && selfResponse != "declined"
    }
}

public struct MeetingRecord: PersistableModel, Identifiable, Hashable {
    public static let databaseTableName = "meeting"
    public enum Status: String, Codable, Sendable { case recording, processing, transcribing, summarizing, ready, failed }
    public var id: String
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var micAudioPath: String?
    public var systemAudioPath: String?
    public var language: String?
    public var status: Status
    public var statusDetail: String?
    public var eventAccountId: String?
    public var eventCalendarId: String?
    public var eventId: String?
    public var attendeesJSON: String
    public var source: String     // recorded | granola | anarlog
    public var sourceId: String?
    public var transcriptEngine: String?
    /// The project it is filed under, nil when unfiled.
    public var project: String?
    /// How: `manual` (the user chose; rules never change it), `rules` (attendees and invited address), `mail` (where the
    /// mail with these people lives), `none` (the rules found nothing). Nil means not filed yet.
    public var projectSource: String?
    /// The long summary, topic by topic, instead of one paragraph. Stays when the summary is written again.
    public var detailedSummary = false
    public var attendees: [EventAttendee] {
        (try? JSONDecoder().decode([EventAttendee].self, from: Data(attendeesJSON.utf8))) ?? []
    }

    public init(id: String = UUID().uuidString, title: String, startedAt: Date, endedAt: Date? = nil,
                status: Status = .recording, source: String = "recorded", sourceId: String? = nil) {
        self.id = id; self.title = title; self.startedAt = startedAt; self.endedAt = endedAt
        self.status = status; self.source = source; self.sourceId = sourceId; attendeesJSON = "[]"
    }
}

public struct TranscriptSegmentRecord: PersistableModel, Identifiable, Hashable {
    public static let databaseTableName = "transcript_segment"
    public var id: String
    public var meetingId: String
    public var position: Int
    public var startSeconds: Double
    public var endSeconds: Double
    public var speaker: String
    public var text: String
    public init(id: String = UUID().uuidString, meetingId: String, position: Int, startSeconds: Double, endSeconds: Double, speaker: String, text: String) {
        self.id = id; self.meetingId = meetingId; self.position = position
        self.startSeconds = startSeconds; self.endSeconds = endSeconds; self.speaker = speaker; self.text = text
    }
}

public struct ActionItem: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// The owner took it on, or the meeting agreed on it.
        case agreed
        /// Someone proposed it, and nobody committed.
        case suggested
    }
    public var task: String
    public var owner: String?
    public var due: String?
    /// Nil for summaries from before statuses, and for imported ones.
    public var status: Status?
    /// The transcript segment (its position) where it was agreed or proposed.
    public var segment: Int?
    public init(task: String, owner: String? = nil, due: String? = nil, status: Status? = nil, segment: Int? = nil) {
        self.task = task; self.owner = owner; self.due = due; self.status = status; self.segment = segment
    }
}

/// A decision, with the transcript segment (its position) where it was taken.
public struct DecisionItem: Codable, Hashable, Sendable {
    public var text: String
    public var segment: Int?
    public init(text: String, segment: Int? = nil) { self.text = text; self.segment = segment }

    enum CodingKeys: String, CodingKey { case text, segment }
    /// Older summaries keep decisions as plain strings.
    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) { self.init(text: s); return }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(text: try c.decode(String.self, forKey: .text), segment: try c.decodeIfPresent(Int.self, forKey: .segment))
    }
}

public struct MeetingSummaryRecord: PersistableModel, Hashable {
    public static let databaseTableName = "meeting_summary"
    public var meetingId: String
    public var summary: String
    public var decisionsJSON: String
    public var actionItemsJSON: String
    public var openQuestionsJSON: String
    public var model: String
    public var createdAt: Date
    public var editedAt: Date?
    public var decisions: [String] { decisionItems.map(\.text) }
    public var decisionItems: [DecisionItem] { (try? JSONDecoder().decode([DecisionItem].self, from: Data(decisionsJSON.utf8))) ?? [] }
    public var openQuestions: [String] { (try? JSONDecoder().decode([String].self, from: Data(openQuestionsJSON.utf8))) ?? [] }
    public var actionItems: [ActionItem] { (try? JSONDecoder().decode([ActionItem].self, from: Data(actionItemsJSON.utf8))) ?? [] }

    public init(meetingId: String, summary: String, decisions: [String], actionItems: [ActionItem], openQuestions: [String], model: String) {
        self.meetingId = meetingId; self.summary = summary; self.model = model; createdAt = Date()
        let enc = JSONEncoder()
        decisionsJSON = String(decoding: (try? enc.encode(decisions)) ?? Data("[]".utf8), as: UTF8.self)
        actionItemsJSON = String(decoding: (try? enc.encode(actionItems)) ?? Data("[]".utf8), as: UTF8.self)
        openQuestionsJSON = String(decoding: (try? enc.encode(openQuestions)) ?? Data("[]".utf8), as: UTF8.self)
    }

    public mutating func setDecisions(_ v: [DecisionItem]) { decisionsJSON = Self.json(v) }
    public mutating func setOpenQuestions(_ v: [String]) { openQuestionsJSON = Self.json(v) }
    public mutating func setActionItems(_ v: [ActionItem]) { actionItemsJSON = Self.json(v) }
    static func json<T: Encodable>(_ v: T) -> String { String(decoding: (try? JSONEncoder().encode(v)) ?? Data("[]".utf8), as: UTF8.self) }
}

public struct SenderOverride: PersistableModel, Hashable {
    public static let databaseTableName = "sender_override"
    public var email: String
    public var bucket: String
    public init(email: String, bucket: String) { self.email = email; self.bucket = bucket }
}

public struct SettingRow: PersistableModel {
    public static let databaseTableName = "setting"
    public var key: String
    public var value: String
    public init(key: String, value: String) { self.key = key; self.value = value }
}
