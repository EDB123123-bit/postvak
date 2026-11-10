import Foundation
import GRDB

public struct SyncSettings: Sendable {
    public var initialWindowDays: Int
    public init(initialWindowDays: Int = 365) { self.initialWindowDays = initialWindowDays }
}

/// How long a batch of thread reads must take. Gmail's per-user quota varies by project and was 6,000 units a minute
/// when first measured, so the pace halves on a refusal and creeps back up while Google keeps saying yes.
struct SyncPace {
    static let fastest = 0.6, slowest = 8.0, cleanBatchesToSpeedUp = 10
    var seconds = 1.5
    private var clean = 0

    mutating func record(refused: Bool) {
        if refused {
            seconds = min(Self.slowest, seconds * 2)
            clean = 0
        } else {
            clean += 1
            if clean >= Self.cleanBatchesToSpeedUp {
                seconds = max(Self.fastest, seconds * 0.9)
                clean = 0
            }
        }
    }
}

/// Initial and incremental mail sync for one or more accounts. History polling needs no public endpoint.
public actor GmailSync {
    let db: AppDatabase
    let gmail: GmailClient
    private let concurrency = 3
    private var paces: [String: SyncPace] = [:]
    private var syncing = Set<String>()

    public init(db: AppDatabase, gmail: GmailClient) {
        self.db = db
        self.gmail = gmail
    }

    public func sync(accountId: String, settings: SyncSettings = .init()) async throws {
        // This actor is reentrant across awaits. A second pass would double the quota use and overwrite the page position.
        guard syncing.insert(accountId).inserted else { return }
        defer { syncing.remove(accountId) }
        guard var account = try await db.pool.read({ try Account.fetchOne($0, key: accountId) }) else { return }
        try await syncLabels(accountId)
        do {
            if !account.initialSyncDone {
                try await initialSync(&account, settings: settings)
            } else if let h = account.historyId {
                try await incremental(&account, from: h)
            }
        } catch let e as GoogleAPIError where e.status == 404 {
            // History expired: Gmail keeps about a week. Start the initial pass again.
            account.initialSyncDone = false
            account.initialPageToken = nil
            account.historyId = nil
            try await save(account)
            try await initialSync(&account, settings: settings)
        }
        account.lastSyncAt = Date()
        account.lastError = nil
        account.needsReauth = false
        try await save(account)
    }

    private func save(_ account: Account) async throws {
        try await db.pool.write { try account.update($0) }
    }

    func syncLabels(_ accountId: String) async throws {
        let labels = try await gmail.labels(accountId)
        try await db.pool.write { db in
            try MailLabelRecord.filter(Column("accountId") == accountId).deleteAll(db)
            for l in labels {
                try MailLabelRecord(accountId: accountId, labelId: l.id, name: l.name, type: l.type ?? "user").insert(db)
            }
        }
    }

    private func initialSync(_ account: inout Account, settings: SyncSettings) async throws {
        // Take the history id first, so anything arriving during the long initial pass can be replayed.
        if account.historyId == nil {
            account.historyId = try await gmail.profile(account.id).historyId
            try await save(account)
        }
        let q = "newer_than:\(settings.initialWindowDays)d"
        var token = account.initialPageToken
        repeat {
            // The pass can take hours and pages backwards in time, so new mail must not wait for it to finish.
            // Without a token the pass is only starting and the history id is seconds old: nothing to replay yet.
            if token != nil, let h = account.historyId {
                try await incremental(&account, from: h)
                account.lastSyncAt = Date()
                try await save(account)
            }
            let page = try await gmail.listThreads(account.id, q: q, pageToken: token, includeSpamTrash: true)
            let ids = (page.threads ?? []).map(\.id)
            let done = try await fetchAndStore(account.id, threadIds: ids)
            account.syncedThreadCount += done
            token = page.nextPageToken
            account.initialPageToken = token
            account.lastError = nil // A finished page means the last failure has passed.
            try await save(account)
        } while token != nil
        account.initialSyncDone = true
        account.initialPageToken = nil
        try await save(account)
        if let h = account.historyId { try await incremental(&account, from: h) }
    }

    private func incremental(_ account: inout Account, from start: String) async throws {
        var token: String?
        var changed = Set<String>()
        var latest = start
        repeat {
            let page = try await gmail.history(account.id, startHistoryId: start, pageToken: token)
            for h in page.history ?? [] {
                for list in [h.messagesAdded, h.messagesDeleted, h.labelsAdded, h.labelsRemoved] {
                    for m in list ?? [] { if let t = m.message.threadId { changed.insert(t) } }
                }
            }
            if let id = page.historyId { latest = id }
            token = page.nextPageToken
        } while token != nil
        if !changed.isEmpty { _ = try await fetchAndStore(account.id, threadIds: Array(changed)) }
        account.historyId = latest
    }

    /// Fetches threads with bounded concurrency. A 404 removes the thread locally.
    @discardableResult
    public func fetchAndStore(_ accountId: String, threadIds: [String]) async throws -> Int {
        var count = 0
        var index = 0
        while index < threadIds.count {
            let started = ContinuousClock.now
            let refusalsBefore = gmail.api.rateLimits.count(accountId)
            let slice = Array(threadIds[index..<min(index + concurrency, threadIds.count)])
            index += slice.count
            try await withThrowingTaskGroup(of: (String, GmailThreadDTO?).self) { g in
                for id in slice {
                    g.addTask { [gmail] in
                        do { return (id, try await gmail.thread(accountId, id: id)) }
                        catch let e as GoogleAPIError where e.status == 404 { return (id, nil) }
                    }
                }
                for try await (id, dto) in g {
                    if let dto { try await store(accountId, dto); count += 1 }
                    else { try await deleteThread(accountId, id) }
                }
            }
            var pace = paces[accountId] ?? SyncPace()
            pace.record(refused: gmail.api.rateLimits.count(accountId) > refusalsBefore)
            paces[accountId] = pace
            if index < threadIds.count, !GoogleAPI.backoffDisabled {
                try await Task.sleep(until: started + .seconds(pace.seconds))
            }
        }
        return count
    }

    public func refresh(accountId: String, threadId: String) async throws {
        try await fetchAndStore(accountId, threadIds: [threadId])
    }

    private func deleteThread(_ accountId: String, _ threadId: String) async throws {
        try await db.pool.write { db in
            _ = try MailMessage.filter(Column("accountId") == accountId && Column("threadId") == threadId).deleteAll(db)
            _ = try MailThread.deleteOne(db, key: ["accountId": accountId, "threadId": threadId])
            _ = try SnoozeRow.deleteOne(db, key: ["accountId": accountId, "threadId": threadId])
        }
    }

    func store(_ accountId: String, _ dto: GmailThreadDTO) async throws {
        try await Self.store(db: db, accountId: accountId, dto: dto)
    }

    /// Shared with tests and the seed tool.
    public static func store(db: AppDatabase, accountId: String, dto: GmailThreadDTO) async throws {
        let parsed = (dto.messages ?? []).map { GmailParser.parse($0, accountId: accountId, threadId: dto.id) }
        try await db.pool.write { database in
            guard !parsed.isEmpty else {
                _ = try MailThread.deleteOne(database, key: ["accountId": accountId, "threadId": dto.id])
                return
            }
            let keep = parsed.map { $0.0.messageId }
            try MailMessage.filter(Column("accountId") == accountId && Column("threadId") == dto.id && !keep.contains(Column("messageId"))).deleteAll(database)

            var allAttachments: [AttachmentRecord] = []
            for (msg, atts) in parsed {
                try msg.save(database)
                let existing = try AttachmentRecord.filter(Column("accountId") == accountId && Column("messageId") == msg.messageId).fetchAll(database)
                let known = Dictionary(uniqueKeysWithValues: existing.map { ($0.partId, $0.localPath) })
                try AttachmentRecord.filter(Column("accountId") == accountId && Column("messageId") == msg.messageId).deleteAll(database)
                for var a in atts {
                    a.localPath = known[a.partId] ?? nil
                    try a.insert(database)
                    allAttachments.append(a)
                }
            }

            let selfAddresses = Set(try Account.fetchAll(database).map { $0.id.lowercased() })
            let existing = try MailThread.fetchOne(database, key: ["accountId": accountId, "threadId": dto.id])
            let lastIncoming = parsed.map { $0.0 }.sorted { $0.date < $1.date }.last { !selfAddresses.contains($0.fromEmail) }
            let override = try lastIncoming.flatMap { try SenderOverride.fetchOne(database, key: $0.fromEmail) }
                .flatMap { InboxBucket(rawValue: $0.bucket) }
            let thread = GmailParser.buildThread(accountId: accountId, threadId: dto.id, messages: parsed.map { $0.0 },
                                                 attachments: allAttachments, existing: existing, override: override,
                                                 selfAddresses: selfAddresses)
            try thread.save(database)

            // A new message landing in the inbox ends a snooze, as in Gmail.
            if thread.isInInbox {
                _ = try SnoozeRow.deleteOne(database, key: ["accountId": accountId, "threadId": dto.id])
            }
        }
    }
}
