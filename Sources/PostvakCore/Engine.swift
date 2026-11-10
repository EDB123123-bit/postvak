import Foundation
import GRDB
import Network

/// Owns every core service and the background loops. The app, MCP server and dev tool all share one instance.
public final class Engine: @unchecked Sendable {
    public let paths: AppPaths
    public let db: AppDatabase
    public let secrets: SecretStore
    public let auth: GoogleAuth
    public let api: GoogleAPI
    public let gmail: GmailClient
    public let sync: GmailSync
    public let mail: MailService
    public let outbox: Outbox
    public let followUps: FollowUps
    /// Drafts Postvak wrote on its own, waiting for the user's review.
    public let autoDrafts: AutoDrafts
    /// Called with reminders that just fell due, so the app can draft a nudge.
    nonisolated(unsafe) public var onFollowUpsDue: (@Sendable ([FollowUpRecord]) async -> Void)?
    public let calendar: CalendarService
    public let meetings: MeetingStore
    public let session: URLSession

    /// Runs after each mail sync pass, used for smart inbox classification.
    public var afterMailSync: (@Sendable () async -> Void)?
    /// Runs on each error surfaced to the user.
    public var onError: (@Sendable (String) -> Void)?

    private var loops: [Task<Void, Never>] = []
    /// Tells the outbox when the network comes back, so mail that waited for a connection goes at once.
    private var networkMonitor: NWPathMonitor?
    private let afterSyncGate = SingleFlight()
    public static let accountColors = ["#3B82F6", "#10B981", "#F59E0B", "#EF4444", "#8B5CF6", "#EC4899"]

    public init(paths: AppPaths = AppPaths(), secrets: SecretStore = KeychainSecretStore(), session: URLSession = .shared) throws {
        try paths.createAll()
        self.paths = paths
        self.secrets = secrets
        self.session = session
        db = try AppDatabase(path: paths.database.path)
        auth = GoogleAuth(secrets: secrets, session: session)
        api = GoogleAPI(tokens: auth, session: session)
        gmail = GmailClient(api: api)
        sync = GmailSync(db: db, gmail: gmail)
        mail = MailService(db: db, gmail: gmail, sync: sync, paths: paths)
        outbox = Outbox(db: db, gmail: gmail, sync: sync, paths: paths)
        followUps = FollowUps(db: db, mail: mail)
        autoDrafts = AutoDrafts(db: db)
        calendar = CalendarService(db: db, api: api)
        meetings = MeetingStore(db: db)
    }

    public var syncSettings: SyncSettings {
        SyncSettings(initialWindowDays: Int(db.setting("sync.windowDays") ?? "") ?? 365)
    }

    // MARK: accounts

    public func addAccount(open: @Sendable (URL) -> Void) async throws -> Account {
        let (email, name) = try await auth.signIn(open: open)
        let id = email.lowercased()
        let existing = try await db.pool.read { try Account.fetchOne($0, key: id) }
        let count = try await db.pool.read { try Account.fetchCount($0) }
        var account = existing ?? Account(id: id, displayName: name, colorHex: Self.accountColors[count % Self.accountColors.count])
        account.needsReauth = false
        account.lastError = nil
        let saved = account
        try await db.pool.write { try saved.save($0) }
        if id != email { try secrets.set(SecretKey.refreshToken(id), secrets.get(SecretKey.refreshToken(email))) }
        triggerSync(accountId: id)
        return account
    }

    /// Removes the account, its local data and its saved sign-in. Nothing changes at Google.
    public func removeAccount(_ id: String) async throws {
        try await db.pool.write { db in
            _ = try Account.deleteOne(db, key: id)
            try db.execute(sql: "DELETE FROM snooze WHERE accountId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM outbox WHERE accountId = ?", arguments: [id])
        }
        try await auth.signOut(id)
    }

    /// Sets the letter inside an account's colour; nil goes back to the default.
    public func setAccountBadge(_ id: String, _ badge: String?) async throws {
        try await db.pool.write { db in
            try db.execute(sql: "UPDATE account SET badge = ? WHERE id = ?", arguments: [badge, id])
        }
    }

    // MARK: loops

    public func start() {
        guard loops.isEmpty else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [outbox] path in
            let up = path.status == .satisfied
            Task { await outbox.networkChanged(available: up) }
        }
        monitor.start(queue: DispatchQueue(label: "be.postvak.network"))
        networkMonitor = monitor
        loops.append(Task { [weak self] in
            try? await self?.outbox.markOverdueAtLaunch()
            var lastFollowUpCheck = Date.distantPast
            while !Task.isCancelled {
                await self?.outbox.tick()
                await self?.mail.wakeDueSnoozes()
                if Date().timeIntervalSince(lastFollowUpCheck) >= 60, let self {
                    lastFollowUpCheck = Date()
                    let fell = await self.followUps.check()
                    if !fell.isEmpty { await self.onFollowUpsDue?(fell) }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollMail()
                try? await Task.sleep(for: .seconds(45))
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncAllCalendars()
                try? await Task.sleep(for: .seconds(120))
            }
        })
    }

    public func stop() {
        loops.forEach { $0.cancel() }
        loops = []
        networkMonitor?.cancel()
        networkMonitor = nil
    }

    private func accountIds() async -> [String] {
        (try? await db.pool.read { try Account.filter(Column("needsReauth") == false).fetchAll($0).map(\.id) }) ?? []
    }

    /// One polling tick. It does not wait, so a first sync lasting hours leaves the other accounts polling on time.
    /// An account still busy from an earlier tick skips this one.
    public func pollMail() async {
        for id in await accountIds() {
            Task { [weak self] in
                await self?.syncMail(accountId: id)
                await self?.runAfterMailSync()
            }
        }
    }

    /// Every account calls this when it finishes. One run at a time, so two never pay to sort the same threads.
    private func runAfterMailSync() async {
        guard await afterSyncGate.enter() else { return }
        await afterMailSync?()
        await afterSyncGate.leave()
    }

    public func syncMail(accountId id: String) async {
        do {
            try await sync.sync(accountId: id, settings: syncSettings)
        } catch {
            await record(error, accountId: id)
        }
    }

    public func syncAllCalendars() async {
        for id in await accountIds() {
            do { try await calendar.syncAll(accountId: id) }
            catch { await record(error, accountId: id) }
        }
    }

    public func triggerSync(accountId: String) {
        Task { [weak self] in
            await self?.syncMail(accountId: accountId)
            await self?.runAfterMailSync()
        }
        Task { [weak self] in
            do { try await self?.calendar.syncAll(accountId: accountId) }
            catch { await self?.record(error, accountId: accountId) }
        }
    }

    private func record(_ error: Error, accountId: String) async {
        if error is CancellationError { return }
        let message = error.localizedDescription
        var reauth = false
        if case GoogleAuthError.revoked = error { reauth = true }
        if case GoogleAuthError.noRefreshToken = error { reauth = true }
        let needsReauth = reauth
        try? await db.pool.write { db in
            guard var a = try Account.fetchOne(db, key: accountId) else { return }
            a.lastError = message
            if needsReauth { a.needsReauth = true }
            try a.update(db)
        }
        onError?(message)
    }
}

private actor SingleFlight {
    private var busy = false
    func enter() -> Bool {
        if busy { return false }
        busy = true
        return true
    }
    func leave() { busy = false }
}
