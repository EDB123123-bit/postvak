import SwiftUI
import AppKit
import GRDB
import UserNotifications
import PostvakCore
import PostvakAI
import PostvakAudio
import PostvakMCP

enum Destination: Hashable {
    case mail(folder: MailFolder, accountId: String?, bucket: InboxBucket?)
    case scheduled
    case review
    case calendar
    case meetings
    case ask
    case deals
}

struct Toast: Identifiable, Equatable {
    enum Kind: Equatable { case info, error, undoSend(outboxId: String, deadline: Date) }
    let id = UUID()
    var text: String
    var kind: Kind
}

/// Everything needed to reopen a composer, including after Undo.
struct ComposerState: Identifiable {
    let id = UUID()
    var accountId: String
    /// A Gmail send-as address of the account to send as; nil sends as the account itself.
    var fromEmail: String?
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body = NSAttributedString(string: "")
    var attachments: [OutgoingAttachment] = []
    var replyTo: (accountId: String, messageId: String)?
    var quotedHtml: String?
    var booking: BookingInsert?
    /// The meeting type behind `booking`, so the card's times can be refreshed.
    var bookingEvent: CalEventType?
    var draftId: String?
    var draftThreadId: String?
    /// The queued mail this composer is editing. It leaves the queue only once the edit is sent, saved or discarded.
    var replacesOutboxId: String?
    /// When the queued mail being edited was scheduled to go. The composer keeps that time unless it is changed.
    var scheduledAt: Date?
    /// Bring the thread back if nobody replies. Off unless chosen in the composer.
    var followUp: FollowUpRule?

    /// What the mail service sends or saves. Pictures in the text are written to files and go along inline.
    func composeInput() -> ComposeInput {
        let content = RichTextHTML.content(from: body)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("postvak-inline", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let inline = content.images.compactMap { img -> OutgoingAttachment? in
            let url = dir.appendingPathComponent(img.filename)
            guard (try? img.data.write(to: url)) != nil else { return nil }
            return OutgoingAttachment(filename: img.filename, mimeType: img.mimeType, path: url.path, contentId: img.contentId)
        }
        var i = ComposeInput(accountId: accountId, to: GmailParser.splitAddresses(to), cc: GmailParser.splitAddresses(cc),
                             bcc: GmailParser.splitAddresses(bcc), subject: subject, text: RichTextHTML.plainText(from: body),
                             html: content.html, attachments: attachments + inline)
        i.fromEmail = fromEmail
        i.replyTo = replyTo
        i.quotedHtml = quotedHtml
        i.booking = booking
        i.draftId = draftId
        i.draftThreadId = draftThreadId
        i.followUp = followUp
        return i
    }

    /// Plain text in the composer's font.
    static func body(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor])
    }
}

@MainActor
final class AppModel: NSObject, ObservableObject {
    let engine: Engine
    let claude: ClaudeClient
    let classifier: InboxClassifier
    let deals: Deals
    let dealAnalyzer: DealAnalyzer
    /// The user's notes and done steps per deal.
    let dealNotes: DealNotes
    /// The user's CRM, matched to deals by company domain.
    let crm: SupabaseCRM
    @Published var dealsRunning = false
    @Published var dealsError: String?
    /// Meetings whose follow-up is being written now. A second click waits for the first instead of making another draft.
    @Published var draftingFollowUps = Set<String>()
    let summarizer: MeetingSummarizer
    let ask: AskModel
    let pipeline: MeetingPipeline
    let recording: RecordingCoordinator
    private(set) var mcpServer: MCPServer?
    let demoMode: Bool

    @Published var destination: Destination = .mail(folder: .inbox, accountId: nil, bucket: nil)
    @Published var accounts: [Account] = []
    @Published var toasts: [Toast] = []
    /// Every mail being written, each in a window of its own.
    lazy var composers = ComposerWindows(model: self)
    lazy var sendCheck = SendCheck(claude: claude)
    lazy var followUpWriter = FollowUpWriter(claude: claude)
    lazy var draftReview = DraftReview(model: self)
    lazy var meetingFollowUpWriter = MeetingFollowUpWriter(claude: claude)
    lazy var prepBriefs = PrepBriefs(db: engine.db)
    lazy var prepWriter = PrepBriefWriter(claude: claude)
    /// Today's meetings with their briefs, over the main window.
    @Published var showMorningOverview = false
    /// The welcome guide, over the main window: on a fresh install, or from Help → Postvak Guide.
    @Published var showOnboarding = false
    var openThreadWindows = Set<ThreadWindowRef>()
    /// The main window shows the Undo Send button, so a send from a composer brings it back when it was closed.
    var mainWindowVisible = false
    var reopenMainWindow: (() -> Void)?
    @Published var isRecording = false
    @Published var recordingStartedAt: Date?
    /// The recording just stopped that needs a title and guests: the sheet asking for them shows while it is set.
    @Published var namingRecording: NamingRecording?
    /// Started with the Record button: always asks for the title and guests when it stops.
    private var recordingAsksDetails = false
    @Published var recordingMeetingId: String?
    @Published var overdueOutbox: [OutboxRow] = []
    @Published var unreadCount = 0
    @Published var mcpError: String?
    @Published var newEventRequest: Date?
    /// The calendar's search, kept while you look at mail and come back.
    @Published var calendarSearch = ""
    @Published var selectedMeetingId: String?
    /// The public meeting types on the configured cal.com profile, loaded on first use.
    @Published var calEventTypes: [CalEventType] = []
    @Published var calEventTypesError: String?

    private var observers: [Task<Void, Never>] = []
    private var notifiedEvents = Set<String>()
    private var lastCallApp: String?
    /// For stopping a call recording once the call ends.
    private var recordingIsCall = false
    private var callSeenWhileRecording = false
    private var callGoneSince: Date?
    /// Meetings in a room that already started recording by themselves, so stopping one by hand keeps it stopped.
    private var autoRecordedEvents = Set<String>()
    /// When a room recording that started by itself stops: a little after its meeting's scheduled end.
    private var roomRecordingStopsAt: Date?

    override init() {
        demoMode = ProcessInfo.processInfo.environment["POSTVAK_DEMO"] == "1"
        do {
            if demoMode {
                // Demo mode never touches the real data folder or Keychain.
                let env = ProcessInfo.processInfo.environment["POSTVAK_DATA_DIR"]
                let root = env.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("postvak-demo")
                engine = try Engine(paths: AppPaths(root: root), secrets: MemorySecretStore([SecretKey.mcpToken: "dev-token", SecretKey.googleClientId: "demo"]))
            } else {
                let service = ProcessInfo.processInfo.environment["POSTVAK_KEYCHAIN_SERVICE"] ?? "be.postvak.app"
                engine = try Engine(secrets: KeychainSecretStore(service: service))
            }
        } catch {
            fatalError("Cannot open the Postvak database: \(error)")
        }
        let secrets = engine.secrets
        // Every answered request is added to the usage shown in Settings → AI.
        let usage = ApiUsage(db: engine.db)
        claude = ClaudeClient(key: { secrets.get(SecretKey.anthropicKey) }, onUsage: { feature, model, u in
            Task { try? await usage.record(feature: feature, model: model, usage: u) }
        })
        classifier = InboxClassifier(db: engine.db, claude: claude)
        deals = Deals(db: engine.db)
        dealNotes = DealNotes(db: engine.db)
        crm = SupabaseCRM(db: engine.db, secrets: engine.secrets, session: engine.session)
        dealAnalyzer = DealAnalyzer(deals: deals, claude: claude, db: engine.db, crm: crm)
        summarizer = MeetingSummarizer(claude: claude, store: engine.meetings)
        ask = AskModel(chat: MeetingChat(claude: claude, store: engine.meetings, mail: engine.mail), history: AskHistory(db: engine.db), db: engine.db)
        pipeline = MeetingPipeline(engine: engine, summarizer: summarizer)
        recording = RecordingCoordinator(engine: engine, pipeline: pipeline)
        super.init()

        let classifier = classifier
        let dealAnalyzer = dealAnalyzer
        engine.afterMailSync = { [weak self] in
            _ = try? await classifier.run()
            // Drafts handled elsewhere leave the review list, and the follow-up review runs when its morning came.
            await self?.draftReview.afterSync()
            // Deals are read again at most every six hours, and then only the companies with new mail or meetings.
            if dealAnalyzer.isDue() { _ = try? await dealAnalyzer.run() }
        }
        engine.onFollowUpsDue = { [weak self] fell in await self?.draftNudges(fell) }
        engine.onError = { [weak self] message in
            Task { @MainActor in self?.log(message) }
        }
        observe()
        draftReview.start()
        if !demoMode {
            engine.start()
            Task {
                await pipeline.resumeUnfinished()
                let meetings = engine.meetings
                let fixedAudio = await CallAudioRepair.run(store: meetings)
                if !fixedAudio.isEmpty { log("Call audio repaired for: \(fixedAudio.joined(separator: ", "))") }
                let repaired = ((try? await meetings.repairEventAttendees()) ?? []) + ((try? await meetings.linkImportedMeetings()) ?? [])
                try? await meetings.assignSpeakersEverywhere()
                if !repaired.isEmpty { try? await meetings.fileMeetings(onlyNew: false, ids: repaired) }
                try? await meetings.fileMeetings(onlyNew: true)
                try? await meetings.anchorUnsourcedPoints()
            }
            setupNotifications()
            startMeetingWatchers()
        }
        Task { await startMCP() }
        DemoSnapshots.runIfRequested(self)
    }

    private func log(_ message: String) { NSLog("Postvak: %@", message) }

    // MARK: observation

    private func observe() {
        let pool = engine.db.pool
        observers.append(Task { [weak self] in
            let o = ValueObservation.tracking { try Account.order(Column("id")).fetchAll($0) }
            do { for try await v in o.values(in: pool) { self?.accounts = v } } catch {}
        })
        observers.append(Task { [weak self] in
            let o = ValueObservation.tracking { try OutboxRow.filter(["overdue", "failed", "waiting"].contains(Column("status"))).fetchAll($0) }
            do { for try await v in o.values(in: pool) { self?.overdueOutbox = v } } catch {}
        })
        observers.append(Task { [weak self] in
            let o = ValueObservation.tracking { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM thread WHERE labelIds LIKE '%|INBOX|%' AND labelIds LIKE '%|UNREAD|%' AND labelIds NOT LIKE '%|SPAM|%' AND labelIds NOT LIKE '%|TRASH|%'") ?? 0
            }
            do { for try await v in o.values(in: pool) { self?.unreadCount = v } } catch {}
        })
    }

    func color(for accountId: String) -> Color {
        Color(hex: accounts.first { $0.id == accountId }?.colorHex ?? "#888888")
    }

    func account(_ id: String) -> Account? { accounts.first { $0.id == id } }

    // MARK: toasts

    func toast(_ text: String, kind: Toast.Kind = .info, seconds: Double = 4) {
        let t = Toast(text: text, kind: kind)
        toasts.append(t)
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            toasts.removeAll { $0.id == t.id }
        }
    }

    /// Runs an action in the background. A failure shows as a toast and is written to the system log,
    /// so a change that never reached Google leaves a trace.
    func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action() }
            catch {
                logFailure("Action", error)
                toast(error.localizedDescription, kind: .error, seconds: 10)
            }
        }
    }

    /// Same, with what was being done in the toast, for actions that change something at Google.
    func perform(_ what: String, _ action: @escaping () async throws -> Void) {
        Task {
            do { try await action() }
            catch {
                logFailure(what, error)
                toast("\(what) failed: \(error.localizedDescription)", kind: .error, seconds: 10)
            }
        }
    }

    func logFailure(_ what: String, _ error: Error) { log("\(what) failed: \(error)") }

    // MARK: sending

    func send(_ state: ComposerState, sendAt: Date?) async throws {
        let mail = try await engine.mail.prepare(state.composeInput())
        let row = try await engine.outbox.enqueue(mail, sendAt: sendAt)
        pendingUndo[row.id] = state
        await retireReplaced(state)
        if sendAt == nil {
            showUndo(outboxId: row.id, subject: mail.subject, deadline: row.sendAt)
        } else {
            toast("Scheduled for \(sendAt!.formatted(date: .abbreviated, time: .shortened)). Postvak needs to be running then.")
        }
    }

    private var pendingUndo: [String: ComposerState] = [:]

    /// The longest Send waits for Claude's check. Past it the mail goes with only the checks made on this Mac.
    static let sendCheckTimeout: Duration = .seconds(15)

    /// What is worth a second look before this mail goes: a forgotten attachment, a wrong name, date or amount.
    func checkBeforeSending(_ s: ComposerState) async -> [String] {
        var thread: [MailMessage] = []
        if let r = s.replyTo,
           let m = try? await engine.db.pool.read({ try MailMessage.fetchOne($0, key: ["accountId": r.accountId, "messageId": r.messageId]) }),
           let d = try? await engine.mail.detail(accountId: m.accountId, threadId: m.threadId) {
            thread = d.messages.filter { !$0.isDraft }
        }
        let draft = SendCheck.Draft(to: GmailParser.splitAddresses(s.to), cc: GmailParser.splitAddresses(s.cc), subject: s.subject,
                                    text: RichTextHTML.plainText(from: s.body),
                                    hasFiles: !s.attachments.isEmpty || s.body.string.contains("\u{FFFC}"), thread: thread)
        let local = SendCheck.localFindings(draft)
        let check = sendCheck
        let reviewed = await withTaskGroup(of: [String]?.self) { g in
            g.addTask { await check.review(draft) }
            g.addTask { try? await Task.sleep(for: Self.sendCheckTimeout); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first ?? []
        }
        return local + reviewed
    }

    /// Undo Send shows in the main window and in popped-out threads. With none of them open, the main window comes back.
    func keepUndoInReach() {
        if !mainWindowVisible && openThreadWindows.isEmpty { reopenMainWindow?() }
    }

    func showUndo(outboxId: String, subject: String, deadline: Date) {
        toast("Sending “\(subject)”", kind: .undoSend(outboxId: outboxId, deadline: deadline), seconds: max(1, deadline.timeIntervalSinceNow) + 0.5)
    }

    func undoSend(outboxId: String) {
        toasts.removeAll {
            if case .undoSend(let id, _) = $0.kind { return id == outboxId }
            return false
        }
        perform { [self] in
            guard let mail = try await engine.outbox.cancel(id: outboxId) else {
                toast("Too late to undo: the mail already went out.", kind: .error)
                return
            }
            if var state = pendingUndo.removeValue(forKey: outboxId) {
                // The queue's copies, because the edited mail's earlier copies are gone by now.
                // Pictures in the text are still in the text, so only the attached files come back.
                state.attachments = mail.attachments.filter { $0.contentId == nil }
                composers.open(state)
            } else {
                // Queued through MCP, so the composer is rebuilt from the mail itself.
                composers.open(try await composerState(from: mail))
            }
            toast("Send cancelled.")
        }
    }

    /// Opens a queued mail in the composer. It stays queued until the edit is sent, saved or discarded;
    /// a scheduled one is paused meanwhile, so it can't go out under the edit.
    func editQueued(_ row: OutboxRow) {
        // Already open: bring that composer forward instead of pausing it a second time.
        if composers.bringForward(outboxId: row.id) { return }
        perform { [self] in
            guard let (queued, mail) = try await engine.outbox.takeForEdit(id: row.id) else {
                toast("This mail is already on its way.", kind: .error)
                return
            }
            do {
                // Sent earlier in this session, the composer's own state still has the formatting.
                var s = if let saved = pendingUndo[row.id] { saved } else { try await composerState(from: mail) }
                s.attachments = pendingUndo[row.id] != nil ? mail.attachments.filter { $0.contentId == nil } : Self.asFiles(mail.attachments)
                s.replacesOutboxId = row.id
                s.scheduledAt = queued.status == .pending && !queued.isUndoWindow ? queued.sendAt : nil
                composers.open(s)
            } catch {
                try? await engine.outbox.release(id: row.id)
                throw error
            }
        }
    }

    /// The composer editing a queued mail closed without sending, saving or discarding it: it goes back to how it was.
    func releaseQueued(_ state: ComposerState) {
        guard let id = state.replacesOutboxId else { return }
        perform { [self] in try await engine.outbox.release(id: id) }
    }

    /// Takes the original out of the queue once its edited version has been sent, saved or discarded.
    func retireReplaced(_ state: ComposerState) async {
        guard let id = state.replacesOutboxId else { return }
        _ = try? await engine.outbox.cancel(id: id)
        await engine.outbox.removeFiles(id: id)
    }

    /// Rebuilt from plain text, the pictures that were inside it come back as attached files, so none is lost.
    static func asFiles(_ list: [OutgoingAttachment]) -> [OutgoingAttachment] {
        list.map { var a = $0; a.contentId = nil; return a }
    }

    private func composerState(from mail: OutgoingMail) async throws -> ComposerState {
        let e = try await engine.mail.editable(mail)
        var s = ComposerState(accountId: mail.accountId)
        s.fromEmail = mail.fromEmail
        s.to = e.to
        s.cc = e.cc
        s.bcc = e.bcc
        s.subject = mail.subject
        s.body = ComposerState.body(e.text)
        s.attachments = Self.asFiles(mail.attachments)
        s.replyTo = e.replyTo
        s.quotedHtml = e.quotedHtml
        s.booking = e.booking
        s.draftId = mail.draftId
        s.draftThreadId = mail.draftThreadId ?? mail.threadId
        return s
    }

    // MARK: follow-up reminders

    /// For each reminder that fell due, a short follow-up drafted in your tone, waiting in the thread as a Gmail draft.
    /// Without an API key the thread still comes back, only without the draft.
    func draftNudges(_ fell: [FollowUpRecord]) async {
        guard claude.hasKey else { return }
        let mail = engine.mail, pool = engine.db.pool
        for f in fell where f.nudgeDraftId == nil {
            do {
                let d = try await mail.detail(accountId: f.accountId, threadId: f.threadId)
                guard let sent = d.messages.first(where: { $0.messageId == f.id }) ?? d.messages.last(where: { !$0.isDraft }) else { continue }
                let samples = try await pool.read { db in
                    try MailMessage.filter(Column("accountId") == f.accountId && Column("threadId") != f.threadId
                                           && Column("labelIds").like("%|SENT|%") && !Column("labelIds").like("%|DRAFT|%"))
                        .order(Column("date").desc).limit(5).fetchAll(db)
                }.map { FollowUpWriter.ownText($0.bodyText) }.filter { !$0.isEmpty }
                let text = try await followUpWriter.nudge(sent: sent, thread: d.messages.filter { !$0.isDraft }, samples: samples)
                let lower = sent.subject.lowercased()
                var input = ComposeInput(accountId: f.accountId, to: GmailParser.splitAddresses(sent.toLine), cc: GmailParser.splitAddresses(sent.ccLine),
                                         subject: lower.hasPrefix("re:") ? sent.subject : "Re: \(sent.subject)", text: text)
                input.replyTo = (f.accountId, sent.messageId)
                // A nudge goes out as the address the first mail went out as.
                if sent.fromEmail.lowercased() != f.accountId.lowercased() { input.fromEmail = sent.fromEmail.lowercased() }
                input.quotedHtml = mail.quotedBlock(message: sent)
                let saved = try await mail.saveDraft(input)
                try await engine.followUps.setNudgeDraft(id: f.id, draftId: saved.draftId)
                try await engine.autoDrafts.record(AutoDraftRecord(accountId: f.accountId, draftId: saved.draftId, threadId: saved.threadId ?? f.threadId,
                                                                   fromEmail: input.fromEmail ?? f.accountId, recipients: input.to.joined(separator: ", "),
                                                                   subject: input.subject, source: .reminder,
                                                                   reason: "No reply to “\(f.subject)” since \(f.sentAt.formatted(date: .abbreviated, time: .omitted))"))
            } catch {
                logFailure("Drafting the follow-up for “\(f.subject)”", error)
            }
        }
    }

    // MARK: meeting follow-up

    /// Where a meeting's follow-up would go: a reply in the thread with its guests, a choice between threads, or a new mail.
    func followUpTarget(meetingId: String) async throws -> MeetingFollowUp.Target {
        MeetingFollowUp.target(try await engine.meetings.relatedThreads(meetingId: meetingId))
    }

    /// Writes the follow-up from the meeting's agreed next steps and saves it as a Gmail draft, in `thread` when given,
    /// then opens it for review. Nothing is sent.
    func draftMeetingFollowUp(meetingId: String, thread: RelatedThread?) {
        draftFollowUp(key: meetingId, thread: thread) { [self] in
            guard let (m, summary) = try await engine.meetings.get(meetingId), let summary else {
                throw MailError.invalid("The meeting needs a summary first.")
            }
            return (m, summary, nil)
        }
    }

    /// The key `draftingFollowUps` holds while a calendar event's follow-up is being written.
    static func followUpKey(_ e: CalendarEvent) -> String { "event:\(e.id)" }

    /// The meeting behind a past calendar event: its recording when that has a summary, else one made from the event alone.
    private func followUpMeeting(for e: CalendarEvent) async throws -> (MeetingRecord, MeetingSummaryRecord?) {
        if let r = try await engine.meetings.meeting(for: e),
           let s = try await engine.db.pool.read({ try MeetingSummaryRecord.fetchOne($0, key: r.id) }), !s.summary.isEmpty {
            return (r, s)
        }
        var m = MeetingRecord(title: e.summary, startedAt: e.startAt, endedAt: e.endAt, status: .ready, source: "calendar")
        m.eventAccountId = e.accountId; m.eventCalendarId = e.calendarId; m.eventId = e.eventId
        m.attendeesJSON = e.attendeesJSON
        m.project = try? await engine.meetings.project(for: e).project
        return (m, nil)
    }

    /// Where a past calendar event's follow-up would go, as for a recorded meeting.
    func followUpTarget(event e: CalendarEvent) async throws -> MeetingFollowUp.Target {
        let (m, _) = try await followUpMeeting(for: e)
        let guests = m.attendees.filter { !$0.isSelf && $0.response != "declined" }.map(\.email)
        return MeetingFollowUp.target(try await engine.db.pool.read { try RelatedMail.threads($0, guests: guests, around: m.startedAt) })
    }

    /// The follow-up for a past calendar event: from its summary when it was recorded, else a short thank-you.
    func draftEventFollowUp(_ e: CalendarEvent, thread: RelatedThread?) {
        draftFollowUp(key: Self.followUpKey(e), thread: thread) { [self] in
            let (m, s) = try await followUpMeeting(for: e)
            return (m, s, GmailParser.htmlToText(e.details))
        }
    }

    private func draftFollowUp(key: String, thread: RelatedThread?,
                               load: @escaping () async throws -> (MeetingRecord, MeetingSummaryRecord?, String?)) {
        guard claude.hasKey else { toast("Add your Claude API key in Settings first.", kind: .error); return }
        guard draftingFollowUps.insert(key).inserted else { return }
        toast("Writing the follow-up…")
        perform("Drafting the follow-up") { [self] in
            defer { draftingFollowUps.remove(key) }
            let mail = engine.mail
            let (m, summary, invite) = try await load()
            guard let (input, sender) = try await meetingFollowUp(m, summary: summary, invite: invite, thread: thread) else {
                throw MailError.invalid("This meeting has no guests to write to.")
            }
            let accountId = input.accountId, subject = input.subject
            let saved = try await mail.saveDraft(input)
            toast("Follow-up saved in the drafts of \(accountId)\(sender.fromEmail.map { ", from \($0)" } ?? "")\(thread == nil ? "" : ", in “\(subject)”"). Nothing was sent.")
            // Opened for review: sending stays the user's own click.
            if let t = saved.threadId, let draft = try await mail.detail(accountId: accountId, threadId: t).messages.last(where: \.isDraft) {
                composers.open(try await draftState(draft, attachments: []))
            }
        }
    }

    /// The follow-up mail for a meeting, written from its transcript when it has one: to the guests, the user's colleagues
    /// in Cc, from the address of the meeting's project, in `thread` when given. Nil when there is nobody to write to.
    func meetingFollowUp(_ m: MeetingRecord, summary: MeetingSummaryRecord?, invite: String?,
                         thread: RelatedThread?) async throws -> (ComposeInput, SenderChoice)? {
        let mail = engine.mail, store = engine.meetings
        let (people, projectAccount) = try await engine.db.pool.read { db in
            (try MeetingFollowUp.addressees(m, db), try MeetingFollowUp.account(m, db))
        }
        guard !people.to.isEmpty else { return nil }
        guard let start = thread?.accountId ?? projectAccount ?? defaultAccount() else {
            throw MailError.invalid("Add a Google account in Settings first.")
        }
        // From the meeting's project: its own account for a new mail, its send-as address in a thread kept elsewhere.
        let sender = await mail.chooseSender(accountId: start, recipients: people.to, isReply: thread != nil, project: m.project)
        let accountId = sender.accountId
        var last: MailMessage?
        if let thread {
            let d = try await mail.detail(accountId: thread.accountId, threadId: thread.threadId)
            last = d.messages.first { $0.messageId == thread.lastMessageId } ?? d.messages.last { !$0.isDraft }
        }
        let samples = try await engine.db.pool.read { db in
            try MailMessage.filter(Column("accountId") == accountId && Column("labelIds").like("%|SENT|%") && !Column("labelIds").like("%|DRAFT|%"))
                .order(Column("date").desc).limit(5).fetchAll(db)
        }.map { FollowUpWriter.ownText($0.bodyText) }.filter { !$0.isEmpty }
        let me = try await store.speakerCandidates(meetingId: m.id).first?.name
        // A meeting made from a calendar event alone has no transcript; these come back empty.
        let segments = try await store.segments(meetingId: m.id)
        let speakers = try await store.speakers(meetingId: m.id)
        let names = SpeakerNames.displayNames(speakers)
        // Names Postvak suggested but nobody confirmed still help tell the voices apart.
        let hints = speakers.filter { $0.source == .suggested }.reduce(into: [String: String]()) { $0[$1.label] = $1.name }
        let out = try await meetingFollowUpWriter.write(meeting: m, summary: summary, invite: invite, segments: segments, names: names, hints: hints,
                                                        me: me, recipients: people.to, cc: people.cc, lastInThread: last, samples: samples)
        var subject = out.subject
        if let last { subject = last.subject.lowercased().hasPrefix("re:") ? last.subject : "Re: \(last.subject)" }
        var input = ComposeInput(accountId: accountId, to: people.to, cc: people.cc, subject: subject, text: out.text)
        input.fromEmail = sender.fromEmail
        if let last {
            input.replyTo = (accountId, last.messageId)
            input.quotedHtml = mail.quotedBlock(message: last)
        }
        return (input, sender)
    }

    // MARK: composer entry points

    func compose() {
        guard let a = defaultAccount() else {
            toast("Add a Google account in Settings first.", kind: .error)
            return
        }
        composers.open(ComposerState(accountId: a))
    }

    /// A new mail to an address someone clicked, sent from `accountId` when given (the account the address was seen in).
    func compose(to address: String, subject: String = "", accountId: String? = nil) {
        guard let a = accountId.flatMap({ id in accounts.contains { $0.id == id } ? id : nil }) ?? defaultAccount() else {
            toast("Add a Google account in Settings first.", kind: .error)
            return
        }
        var s = ComposerState(accountId: a)
        s.to = address
        s.subject = subject
        composers.open(s)
    }

    /// Brings the main window forward on the review of drafts Postvak wrote.
    func showDraftReview() {
        destination = .review
        reopenMainWindow?()
        NSApp.activate()
    }

    func defaultAccount() -> String? {
        if case .mail(_, let id?, _) = destination { return id }
        return accounts.first?.id
    }

    func reply(to m: MailMessage, replyAll: Bool) {
        perform { [self] in
            let addr = try await engine.mail.replyAddressing(accountId: m.accountId, messageId: m.messageId, replyAll: replyAll)
            var s = ComposerState(accountId: m.accountId)
            s.to = addr.to.joined(separator: ", ")
            s.cc = addr.cc.joined(separator: ", ")
            s.subject = addr.subject
            s.replyTo = (m.accountId, m.messageId)
            s.quotedHtml = engine.mail.quotedBlock(message: m)
            // Company mail kept in a personal Gmail is answered as the company address, when Gmail can send as it.
            s.fromEmail = await engine.mail.chooseSender(accountId: m.accountId, recipients: addr.to + addr.cc, isReply: true).fromEmail
            composers.open(s)
        }
    }

    func forward(_ m: MailMessage, attachments: [AttachmentRecord]) {
        perform { [self] in
            var s = ComposerState(accountId: m.accountId)
            let lower = m.subject.lowercased()
            s.subject = (lower.hasPrefix("fwd:") || lower.hasPrefix("fw:")) ? m.subject : "Fwd: \(m.subject)"
            s.quotedHtml = engine.mail.quotedBlock(message: m)
            for a in attachments where a.contentId == nil || !a.mimeType.hasPrefix("image/") {
                let url = try await engine.mail.attachmentFile(a)
                s.attachments.append(OutgoingAttachment(filename: a.filename, mimeType: a.mimeType, path: url.path))
            }
            composers.open(s)
        }
    }

    func openDraft(_ m: MailMessage) {
        perform { [self] in composers.open(try await draftState(m)) }
    }

    /// Double-clicking a draft: the newest draft in the thread opens straight in the composer.
    func editDraft(in t: MailThread) {
        perform { [self] in
            let d = try await engine.mail.detail(accountId: t.accountId, threadId: t.threadId)
            guard let m = d.messages.last(where: \.isDraft) else { return }
            composers.open(try await draftState(m, attachments: d.attachments[m.messageId] ?? []))
        }
    }

    /// A Gmail draft as a composer: still a reply when it was one, without a second signature, with its files.
    /// Sending it deletes the draft, so it leaves Drafts.
    func draftState(_ m: MailMessage, attachments: [AttachmentRecord]? = nil) async throws -> ComposerState {
        let mail = engine.mail
        let e = try await mail.editableDraft(m)
        var s = ComposerState(accountId: m.accountId)
        // Written as a send-as address (company mail kept in Gmail), it stays so.
        if !m.fromEmail.isEmpty, m.fromEmail.lowercased() != m.accountId.lowercased() { s.fromEmail = m.fromEmail.lowercased() }
        s.to = e.to
        s.cc = e.cc
        s.bcc = e.bcc
        s.subject = m.subject
        s.body = ComposerState.body(e.text)
        s.replyTo = e.replyTo
        s.quotedHtml = e.quotedHtml
        s.booking = e.booking
        s.draftId = try await mail.draftId(accountId: m.accountId, messageId: m.messageId)
        s.draftThreadId = m.threadId
        let files = if let attachments { attachments } else { try await mail.detail(accountId: m.accountId, threadId: m.threadId).attachments[m.messageId] ?? [] }
        // A reopened draft is plain text, so pictures that were inside it come back as attached files.
        for a in files {
            let url = try await mail.attachmentFile(a)
            s.attachments.append(OutgoingAttachment(filename: a.filename, mimeType: a.mimeType, path: url.path))
        }
        return s
    }

    // MARK: MCP

    func mcpToken() -> String {
        if let t = engine.secrets.get(SecretKey.mcpToken), !t.isEmpty { return t }
        let t = UUID().uuidString + UUID().uuidString
        let token = t.replacingOccurrences(of: "-", with: "")
        try? engine.secrets.set(SecretKey.mcpToken, token)
        return token
    }

    var mcpPort: UInt16 { UInt16(engine.db.setting("mcp.port") ?? "") ?? MCPServer.defaultPort }

    /// The script Claude Desktop and Claude Code run to reach Postvak. It reads the token from the Keychain as it
    /// starts, so no configuration file ever holds it. Rewritten at each start, so it always has the current port.
    var mcpBridgePath: String { engine.paths.root.appendingPathComponent("postvak-mcp-bridge").path }

    private func writeMCPBridge() {
        let service = ProcessInfo.processInfo.environment["POSTVAK_KEYCHAIN_SERVICE"] ?? "be.postvak.app"
        let script = """
        #!/bin/zsh
        # Connects Claude to Postvak over MCP. Postvak writes this file at each start; edits are overwritten.
        # The token comes from the Keychain here and is never stored in a configuration file.
        for d in /opt/homebrew/bin /usr/local/bin "$HOME/.volta/bin" "$HOME"/.nvm/versions/node/*/bin(N/On) "$HOME/.local/bin"; do
          [[ -x "$d/npx" ]] && { export PATH="$d:$PATH"; break; }
        done
        command -v npx >/dev/null || { echo "postvak-mcp-bridge: Node.js (npx) was not found. Install Node, then connect again." >&2; exit 1; }
        TOKEN=$(security find-generic-password -s "\(service)" -a mcp.token -w 2>/dev/null) || {
          echo "postvak-mcp-bridge: no Postvak token in the Keychain. Start Postvak once, and click Always Allow when macOS asks." >&2; exit 1; }
        exec npx -y mcp-remote "http://127.0.0.1:\(mcpPort)/mcp" --allow-http --header "Authorization:Bearer $TOKEN"

        """
        let url = URL(fileURLWithPath: mcpBridgePath)
        if (try? String(contentsOf: url, encoding: .utf8)) != script {
            try? script.write(to: url, atomically: true, encoding: .utf8)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mcpBridgePath)
    }

    func startMCP() async {
        mcpServer?.stop()
        let token = mcpToken()
        let server = MCPServer(tools: PostvakTools.all(engine: engine, recorder: self, ui: self)) { token }
        do {
            try await server.start(port: mcpPort)
            mcpServer = server
            mcpError = nil
            if !demoMode { writeMCPBridge() }
        } catch {
            mcpError = "The MCP server could not start on port \(mcpPort): \(error.localizedDescription)"
        }
    }

    func rotateMCPToken() {
        try? engine.secrets.set(SecretKey.mcpToken, nil)
        Task { await startMCP() }
    }

    // MARK: recording

    func startRecording(title: String? = nil, captureSystem: Bool = true) {
        perform { [self] in
            _ = try await startRecordingNow(title: title, captureSystem: captureSystem)
        }
    }

    @discardableResult
    func startRecordingNow(title: String?, captureSystem: Bool) async throws -> String {
        let id = try await recording.start(title: title, captureSystem: captureSystem)
        recordingIsCall = captureSystem
        callSeenWhileRecording = false
        callGoneSince = nil
        roomRecordingStopsAt = nil
        isRecording = true
        recordingStartedAt = Date()
        recordingMeetingId = id
        return id
    }

    func stopRecording() {
        perform { [self] in _ = try await stopRecordingNow() }
    }

    /// The Record button: records any time, with the call's sound unless `captureSystem` is off, and asks for a title
    /// and the guests once it stops.
    func recordNow(captureSystem: Bool = true) {
        perform { [self] in
            _ = try await startRecordingNow(title: nil, captureSystem: captureSystem)
            recordingAsksDetails = true
        }
    }

    @discardableResult
    func stopRecordingNow() async throws -> String {
        let id = try await recording.stop()
        let asks = recordingAsksDetails
        recordingAsksDetails = false
        isRecording = false
        recordingIsCall = false
        callGoneSince = nil
        roomRecordingStopsAt = nil
        recordingStartedAt = nil
        recordingMeetingId = nil
        selectedMeetingId = id
        toast("Recording saved. Transcribing in the background.")
        // A recording with no calendar meeting behind it, or one made with the Record button, asks who it was with.
        if let m = try? await engine.meetings.get(id)?.0,
           asks || m.title == MeetingRecord.untitled || !m.attendees.contains(where: { !$0.isSelf }) {
            namingRecording = NamingRecording(meetingId: id, title: m.title == MeetingRecord.untitled ? "" : m.title,
                                              guests: m.attendees.filter { !$0.isSelf }.map { a in
                                                  a.name.map { GmailParser.recipient(name: $0, email: a.email) } ?? a.email
                                              }.joined(separator: ", "))
            reopenMainWindow?()
        }
        return id
    }

    // MARK: notifications and meeting watchers

    private func setupNotifications() {
        guard Bundle.main.bundleIdentifier != nil, ProcessInfo.processInfo.environment["POSTVAK_NO_NOTIFY"] == nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let record = UNNotificationAction(identifier: "record", title: "Record", options: [.foreground])
        let stop = UNNotificationAction(identifier: "stop", title: "Stop Recording", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "meeting", actions: [record], intentIdentifiers: []),
            UNNotificationCategory(identifier: "recording", actions: [stop], intentIdentifiers: []),
            UNNotificationCategory(identifier: "drafts", actions: [UNNotificationAction(identifier: "review", title: "Review", options: [.foreground])],
                                   intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `online` decides whether the Record button also captures the call's sound.
    private func notify(id: String, title: String, body: String, meetingTitle: String?, online: Bool = true, category: String = "meeting") {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.categoryIdentifier = category
        c.userInfo = ["title": meetingTitle ?? "", "online": online ? "1" : "0"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    private func startMeetingWatchers() {
        observers.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkUpcomingEvents()
                try? await Task.sleep(for: .seconds(30))
            }
        })
        observers.append(Task { [weak self] in
            while !Task.isCancelled {
                self?.checkCallApps()
                try? await Task.sleep(for: .seconds(5))
            }
        })
    }

    /// Calls (Meet, Zoom, Teams…) record by themselves, with the call's sound, as soon as you join.
    /// Off until the user switches it on: recording other people is their decision to take knowingly.
    var autoRecord: Bool { engine.db.settingBool("meetings.autoRecord", default: false) }
    /// Meetings in a room record the microphone from their start time. Its own switch since 10 Nov 2026; before that
    /// it came with `autoRecord`, so it follows that switch until set.
    var autoRecordRooms: Bool { engine.db.settingBool("meetings.autoRecordRooms", default: autoRecord) }

    private func checkUpcomingEvents() async {
        if autoRecordRooms { await autoRecordRoomMeeting() }
        guard engine.db.settingBool("meetings.notifyEvents", default: true), !isRecording else { return }
        let now = Date()
        guard let events = try? await engine.calendar.events(from: now, to: now.addingTimeInterval(90)) else { return }
        for e in events where !e.isAllDay && e.startAt > now && e.selfResponse != "declined" {
            guard e.attendees.count >= 2 || e.meetingLink != nil else { continue }
            // No offer for what records by itself: a call when calls do, a room meeting when those do.
            if e.meetingLink != nil ? autoRecord : autoRecordRooms { continue }
            guard notifiedEvents.insert(e.id).inserted else { continue }
            notify(id: "event-\(e.id)", title: "Record “\(e.summary)”?", body: "Starts in about a minute. Tell everyone present before recording.",
                   meetingTitle: e.summary, online: e.meetingLink != nil)
        }
    }

    private func checkCallApps() {
        let app = MeetingAppDetector.activeCallApp()
        // Remembered while recording too, so stopping by hand during a call doesn't start or offer it again.
        defer { lastCallApp = app }
        if isRecording { checkCallEnded(); checkRoomMeetingOver(); return }
        guard let app, app != lastCallApp else { return }
        if autoRecord {
            Task { await autoRecordCall(app) }
        } else if engine.db.settingBool("meetings.detectCalls", default: false) {
            notify(id: "call-\(UUID().uuidString)", title: "Record this call?", body: "\(app) is using the microphone. Tell everyone present before recording.", meetingTitle: nil)
        }
    }

    /// A call app just took the microphone: you joined a call. It records with the call's sound, and stops when the call ends.
    private func autoRecordCall(_ app: String) async {
        let now = Date()
        let events = (try? await engine.calendar.events(from: now, to: now.addingTimeInterval(15 * 60))) ?? []
        let (record, meeting) = AutoRecord.call(app: app, events: events, now: now)
        guard record, !isRecording, MeetingAppDetector.activeCallApp() != nil else { return }
        do {
            try await startRecordingNow(title: meeting?.summary, captureSystem: true)
            let who = app == "a browser call" ? "Your browser" : app
            notifyRecording(title: meeting.map { "Recording “\($0.summary)”" } ?? "Recording this call",
                            body: "\(who) joined a call, so Postvak is recording it with the call's sound. It stops when the call ends. Tell everyone present.")
        } catch {
            logFailure("Starting the call recording", error)
            toast("The call could not be recorded: \(error.localizedDescription)", kind: .error, seconds: 10)
        }
    }

    /// A meeting in a room has just begun: it records the microphone, and stops a little after its scheduled end.
    private func autoRecordRoomMeeting() async {
        let now = Date()
        guard !isRecording, MeetingAppDetector.activeCallApp() == nil,
              let events = try? await engine.calendar.events(from: now.addingTimeInterval(-AutoRecord.roomStartWindow), to: now.addingTimeInterval(1)),
              let e = AutoRecord.roomMeeting(events: events, now: now, alreadyStarted: autoRecordedEvents), !isRecording else { return }
        autoRecordedEvents.insert(e.id)
        do {
            try await startRecordingNow(title: e.summary, captureSystem: false)
            roomRecordingStopsAt = e.endAt.addingTimeInterval(AutoRecord.roomStopGrace)
            notifyRecording(title: "Recording “\(e.summary)”",
                            body: "The meeting began, so Postvak is recording the microphone. It stops 10 minutes after the scheduled end. Tell everyone present.")
        } catch {
            logFailure("Starting the meeting recording", error)
            toast("“\(e.summary)” could not be recorded: \(error.localizedDescription)", kind: .error, seconds: 10)
        }
    }

    private func checkRoomMeetingOver() {
        guard let stopAt = roomRecordingStopsAt, Date() >= stopAt else { return }
        roomRecordingStopsAt = nil
        Task {
            do {
                _ = try await stopRecordingNow()
                notify(id: "autostop-\(UUID().uuidString)", title: "Recording stopped", body: "The meeting has ended, so Postvak stopped recording. Transcribing in the background.", meetingTitle: nil)
            } catch {
                logFailure("Stopping the recording after the meeting", error)
                toast("The meeting ended but the recording could not be stopped: \(error.localizedDescription)", kind: .error, seconds: 10)
            }
        }
    }

    private func notifyRecording(title: String, body: String) {
        notify(id: "recording-\(UUID().uuidString)", title: title, body: body, meetingTitle: nil, category: "recording")
    }
}

extension AppModel {
    /// How long the microphone must stay free of call apps before a call recording stops.
    static let callEndGrace: TimeInterval = 20

    /// Stops a call recording once the call app that was using the microphone lets go of it,
    /// for example when the Meet tab or Zoom closes. Recordings where no call app was ever seen,
    /// and in-person recordings, are left alone.
    fileprivate func checkCallEnded() {
        guard recordingIsCall, engine.db.settingBool("meetings.autoStop", default: true) else { return }
        if MeetingAppDetector.activeCallApp() != nil {
            callSeenWhileRecording = true
            callGoneSince = nil
            return
        }
        guard callSeenWhileRecording else { return }
        let since = callGoneSince ?? Date()
        callGoneSince = since
        guard Date().timeIntervalSince(since) >= Self.callEndGrace else { return }
        callSeenWhileRecording = false
        callGoneSince = nil
        recordingIsCall = false
        Task {
            do {
                _ = try await stopRecordingNow()
                notify(id: "autostop-\(UUID().uuidString)", title: "Recording stopped", body: "The call ended, so Postvak stopped recording. Transcribing in the background.", meetingTitle: nil)
            } catch {
                logFailure("Stopping the recording after the call ended", error)
                toast("The call ended but the recording could not be stopped: \(error.localizedDescription)", kind: .error, seconds: 10)
            }
        }
    }
}

extension AppModel: RecorderControl {
    nonisolated func startRecording(title: String?) async throws -> String {
        try await startRecordingNow(title: title, captureSystem: true)
    }
    nonisolated func stopRecording() async throws -> String {
        try await stopRecordingNow()
    }
}

extension AppModel: MCPUIHooks {
    nonisolated func didQueueSend(_ row: OutboxRow, mail: OutgoingMail) async {
        guard row.isUndoWindow else { return }
        await MainActor.run { self.showUndo(outboxId: row.id, subject: mail.subject, deadline: row.sendAt) }
    }
}

extension AppModel: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        // Drafts to review: a click on the notification or its Review button opens the review.
        if response.notification.request.content.categoryIdentifier == "drafts" {
            await MainActor.run { self.showDraftReview() }
            return
        }
        switch response.actionIdentifier {
        case "record":
            let title = info["title"] as? String
            let online = (info["online"] as? String) != "0"
            await MainActor.run { self.startRecording(title: title?.isEmpty == false ? title : nil, captureSystem: online) }
        case "stop":
            await MainActor.run { if self.isRecording { self.stopRecording() } }
        default:
            break
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt64(s, radix: 16) ?? 0x888888
        self.init(.sRGB, red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
}
