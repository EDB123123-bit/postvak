import Foundation
import GRDB

extension OutboxRow {
    /// What the Scheduled list shows: everything queued except mail in its few seconds of undo.
    public static let listedSQL = "NOT (isUndoWindow = 1 AND status IN ('pending', 'sending'))"

    public static func listed(_ db: Database) throws -> [OutboxRow] {
        try OutboxRow.filter(sql: listedSQL).order(Column("sendAt")).fetchAll(db)
    }
}

public struct OutboxEvent: Sendable {
    public enum Kind: Sendable { case sent, failed(String) }
    public let id: String
    public let kind: Kind
}

/// Every send goes through this durable queue. A short `sendAt` is the undo window;
/// a future one is send later. Only runs while the app runs.
public actor Outbox {
    public static let undoSeconds: TimeInterval = 5
    /// Mail waiting for a connection is tried again this often, besides at once when the network comes back.
    public static let offlineRetrySeconds: TimeInterval = 30

    let db: AppDatabase
    let gmail: GmailClient
    let sync: GmailSync
    let paths: AppPaths
    private var onEvent: (@Sendable (OutboxEvent) -> Void)?
    /// What macOS last said about the network. Unknown counts as up, so a wrong guess costs one quick failed try.
    private var networkUp = true
    private var retryWaitingAt = Date.distantPast

    public init(db: AppDatabase, gmail: GmailClient, sync: GmailSync, paths: AppPaths) {
        self.db = db; self.gmail = gmail; self.sync = sync; self.paths = paths
    }

    public func setHandler(_ h: @escaping @Sendable (OutboxEvent) -> Void) { onEvent = h }

    /// The network came or went. Back online, mail waiting for a connection goes on the next tick.
    public func networkChanged(available: Bool, now: Date = Date()) {
        networkUp = available
        if available { retryWaitingAt = now }
    }

    /// Failures that prove the mail never left this Mac: no network, no name lookup, no server reachable.
    /// A dropped or timed-out connection is not one of them, because the mail may have gone out before it dropped.
    static func neverLeft(_ error: Error) -> Bool {
        guard let u = error as? URLError else { return false }
        let codes: Set<URLError.Code> = [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                                         .dataNotAllowed, .internationalRoamingOff, .callIsActive]
        return codes.contains(u.code)
    }

    private struct NoConnection: Error { let message: String }

    /// Queues a mail. `sendAt == nil` starts the 5 second undo window.
    @discardableResult
    public func enqueue(_ mail: OutgoingMail, sendAt: Date? = nil) async throws -> OutboxRow {
        let id = UUID().uuidString
        var stored = mail
        // Copy attachments so the file survives until the send, whatever happens to the original.
        if !mail.attachments.isEmpty {
            let dir = paths.outbox.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            stored.attachments = try mail.attachments.enumerated().map { i, a in
                let dest = dir.appendingPathComponent("\(i)-\(URL(fileURLWithPath: a.filename).lastPathComponent)")
                try FileManager.default.copyItem(at: URL(fileURLWithPath: a.path), to: dest)
                var copy = a
                copy.path = dest.path
                return copy
            }
        }
        let row = OutboxRow(id: id, accountId: mail.accountId, payload: try JSONEncoder().encode(stored),
                            sendAt: sendAt ?? Date().addingTimeInterval(Self.undoSeconds), status: .pending,
                            isUndoWindow: sendAt == nil, lastError: nil, createdAt: Date(),
                            summary: "\(mail.subject) → \((mail.to + mail.cc + mail.bcc).first ?? "")")
        try await db.pool.write { try row.insert($0) }
        return row
    }

    /// Removes a queued mail and returns it so the UI can reopen the composer.
    /// Returns nil when the send has already started.
    public func cancel(id: String) async throws -> OutgoingMail? {
        let row: OutboxRow? = try await db.pool.write { db in
            guard let r = try OutboxRow.fetchOne(db, key: id), r.status != .sending else { return nil }
            try r.delete(db)
            return r
        }
        guard let row else { return nil }
        return try JSONDecoder().decode(OutgoingMail.self, from: row.payload)
    }

    /// A queued mail for editing. It stays in the queue, so it survives until its replacement exists.
    /// Returns nil when it is gone or the send has already started.
    public func queuedMail(id: String) async throws -> OutgoingMail? {
        let row = try await db.pool.read { try OutboxRow.fetchOne($0, key: id) }
        guard let row, row.status != .sending else { return nil }
        return try JSONDecoder().decode(OutgoingMail.self, from: row.payload)
    }

    /// Discards the queue's copied attachments once the caller no longer needs them.
    public func removeFiles(id: String) {
        try? FileManager.default.removeItem(at: paths.outbox.appendingPathComponent(id, isDirectory: true))
    }

    /// A queued mail opened in a composer. A scheduled one is paused (`held`) so it can't go out
    /// while it is being edited; `release` puts it back if the composer closes without sending, saving or discarding.
    /// Returns the row as it was before the pause, or nil when it is gone or already on its way.
    public func takeForEdit(id: String) async throws -> (row: OutboxRow, mail: OutgoingMail)? {
        let row: OutboxRow? = try await db.pool.write { db in
            guard var r = try OutboxRow.fetchOne(db, key: id), r.status != .sending else { return nil }
            let before = r
            if r.status == .pending || r.status == .waiting {
                r.status = .held
                try r.update(db)
            }
            return before
        }
        guard let row else { return nil }
        return (row, try JSONDecoder().decode(OutgoingMail.self, from: row.payload))
    }

    /// Ends a pause from `takeForEdit`. Still ahead, it is scheduled again; past its time, it waits for a decision.
    public func release(id: String, now: Date = Date()) async throws {
        try await db.pool.write { db in
            try db.execute(sql: "UPDATE outbox SET status = CASE WHEN sendAt > ? THEN 'pending' ELSE 'overdue' END WHERE id = ? AND status = 'held'",
                           arguments: [now, id])
        }
    }

    /// Moves a scheduled, overdue or failed mail to a new time. False when it is gone, being edited or already on its way.
    @discardableResult
    public func reschedule(id: String, to date: Date) async throws -> Bool {
        try await db.pool.write { db in
            guard var r = try OutboxRow.fetchOne(db, key: id), [.pending, .overdue, .failed, .waiting].contains(r.status) else { return false }
            r.status = .pending
            r.sendAt = date
            r.isUndoWindow = false
            r.lastError = nil
            try r.update(db)
            return true
        }
    }

    public func rows() async throws -> [OutboxRow] {
        try await db.pool.read { try OutboxRow.order(Column("sendAt")).fetchAll($0) }
    }

    /// At launch, anything whose time passed while the app was closed waits for a decision instead of going out unannounced,
    /// and so does mail that was still waiting for a connection when it quit.
    /// No composer survives a restart, so a mail paused for editing goes back to its schedule first.
    public func markOverdueAtLaunch(now: Date = Date()) async throws {
        try await db.pool.write { db in
            try db.execute(sql: "UPDATE outbox SET status = 'pending' WHERE status = 'held'")
            try db.execute(sql: "UPDATE outbox SET status = 'overdue' WHERE (status = 'pending' AND sendAt <= ?) OR status IN ('sending', 'waiting')",
                           arguments: [now])
        }
    }

    /// Releases a scheduled, overdue, failed or waiting row to go out on the next tick.
    /// Leaves a row alone while it is being edited or already on its way, so it never goes twice.
    @discardableResult
    public func sendNow(id: String) async throws -> Bool {
        try await db.pool.write { db in
            guard var r = try OutboxRow.fetchOne(db, key: id), [.pending, .overdue, .failed, .waiting].contains(r.status) else { return false }
            r.status = .pending
            r.sendAt = Date()
            r.isUndoWindow = false
            r.lastError = nil
            try r.update(db)
            return true
        }
    }

    /// Sends everything due, and mail waiting for a connection once the network is back (or every 30 seconds while
    /// macOS thinks it is up). Claims each row first, so a row is never picked up twice.
    public func tick(now: Date = Date()) async {
        let retryWaiting = networkUp && now >= retryWaitingAt
        let due: [OutboxRow] = (try? await db.pool.write { db in
            var rows = try OutboxRow.filter(Column("status") == OutboxRow.Status.pending.rawValue && Column("sendAt") <= now).fetchAll(db)
            if retryWaiting {
                rows += try OutboxRow.filter(Column("status") == OutboxRow.Status.waiting.rawValue).order(Column("sendAt")).fetchAll(db)
            }
            for var r in rows { r.status = .sending; try r.update(db) }
            return rows
        }) ?? []
        for row in due { await send(row, now: now) }
    }

    private func send(_ row: OutboxRow, now: Date) async {
        do {
            let mail = try JSONDecoder().decode(OutgoingMail.self, from: row.payload)
            let raw = try MIMEBuilder.build(mail)
            // The sign-in token runs out after an hour, so after a night asleep it is fetched first.
            // Any network failure there, or one proving the send never left this Mac, means: wait for a connection.
            do { try await gmail.prepareAccess(mail.accountId) } catch let e as URLError { throw NoConnection(message: e.localizedDescription) }
            let result: (messageId: String, threadId: String)
            do {
                result = try await gmail.send(mail.accountId, raw: raw, threadId: mail.threadId)
            } catch let e where Self.neverLeft(e) {
                throw NoConnection(message: e.localizedDescription)
            } catch let e as URLError {
                throw MailError.invalid("\(e.localizedDescription) It may have gone out before the connection dropped: check Sent before sending it again.")
            }
            _ = try await db.pool.write { try OutboxRow.deleteOne($0, key: row.id) }
            removeFiles(id: row.id)
            if let d = mail.draftId {
                try? await gmail.deleteDraft(mail.accountId, draftId: d)
                // A new mail's draft sat in a thread of its own. Refreshing it takes the draft out of Drafts at once.
                if let t = mail.draftThreadId, t != result.threadId { try? await sync.refresh(accountId: mail.accountId, threadId: t) }
            }
            try? await sync.refresh(accountId: mail.accountId, threadId: result.threadId)
            if let rule = mail.followUp {
                let now = Date()
                let f = FollowUpRecord(id: result.messageId, accountId: mail.accountId, threadId: result.threadId, subject: mail.subject,
                                       recipients: (mail.to + mail.cc).joined(separator: ", "), sentAt: now, dueAt: rule.due(after: now))
                try? await db.pool.write { try f.save($0) }
            }
            onEvent?(OutboxEvent(id: row.id, kind: .sent))
        } catch let offline as NoConnection {
            retryWaitingAt = max(now, Date()).addingTimeInterval(Self.offlineRetrySeconds)
            try? await db.pool.write { db in
                guard var r = try OutboxRow.fetchOne(db, key: row.id) else { return }
                r.status = .waiting
                r.lastError = offline.message
                try r.update(db)
            }
        } catch {
            let message = error.localizedDescription
            try? await db.pool.write { db in
                guard var r = try OutboxRow.fetchOne(db, key: row.id) else { return }
                r.status = .failed
                r.lastError = message
                try r.update(db)
            }
            onEvent?(OutboxEvent(id: row.id, kind: .failed(message)))
        }
    }
}
