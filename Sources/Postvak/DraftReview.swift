import SwiftUI
import AppKit
import GRDB
import UserNotifications
import PostvakCore
import PostvakAI

/// Drafts Postvak wrote on its own, waiting for the user: send, edit, keep or delete each one. Also runs the follow-up
/// review that writes most of them, on the schedule set in Settings → AI.
@MainActor
final class DraftReview: ObservableObject {
    @Published private(set) var pending: [AutoDraftRecord] = []
    @Published private(set) var running = false
    @Published private(set) var lastRun: Date?
    private unowned let model: AppModel
    private var observer: Task<Void, Never>?
    lazy var writer = FollowUpReviewWriter(claude: model.claude)

    /// The most follow-ups one review writes, so a busy fortnight doesn't bury the user.
    static let maxDrafts = 10

    init(model: AppModel) { self.model = model }

    var store: AutoDrafts { model.engine.autoDrafts }

    var frequency: FollowUpReview.Frequency {
        FollowUpReview.Frequency(rawValue: model.engine.db.setting(FollowUpReview.settingKey) ?? "") ?? .weekly
    }

    func start() {
        lastRun = model.engine.db.setting(FollowUpReview.lastRunKey).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        let pool = model.engine.db.pool
        observer = Task { [weak self] in
            let o = ValueObservation.tracking { try AutoDraftRecord.filter(Column("status") == "pending").order(Column("createdAt")).fetchAll($0) }
            do { for try await v in o.values(in: pool) { self?.pending = v } } catch {}
        }
    }

    /// After each mail sync: drafts handled elsewhere leave the list, and the review runs when its morning has come.
    /// Running after a sync means mail sent from any account, today's included, is known before anything is written.
    func afterSync() async {
        _ = try? await store.reconcile()
        guard model.claude.hasKey, !model.demoMode,
              FollowUpReview.isDue(frequency, lastRun: lastRun, now: Date()) else { return }
        await run(manual: false)
    }

    /// Finds threads and meetings waiting on a follow-up and drafts one for each that Claude thinks is worth it.
    func run(manual: Bool) async {
        guard !running else { return }
        guard model.claude.hasKey else {
            if manual { model.toast("Add your Claude API key in Settings first.", kind: .error) }
            return
        }
        running = true
        defer { running = false }
        let now = Date()
        // Marked first, so a failing run waits for the next slot instead of retrying after every sync.
        try? model.engine.db.setSetting(FollowUpReview.lastRunKey, String(now.timeIntervalSince1970))
        lastRun = now
        _ = try? await store.reconcile(now: now)
        let found = try? await model.engine.db.pool.read { db in
            (try FollowUpReview.candidates(db, now: now), try FollowUpReview.meetingCandidates(db, now: now))
        }
        var made = 0
        for c in found?.0 ?? [] where made < Self.maxDrafts {
            do { if try await draft(c, now: now) { made += 1 } }
            catch { model.logFailure("Follow-up review of “\(c.last.subject)”", error) }
        }
        for m in found?.1 ?? [] where made < Self.maxDrafts {
            do { if try await model.writeMeetingFollowUpForReview(m) { made += 1 } }
            catch { model.logFailure("Meeting follow-up for “\(m.title)”", error) }
        }
        if made > 0 {
            notify(count: made)
        }
        if manual {
            model.toast(made == 0 ? "Nothing needs a follow-up right now." : "\(made) follow-up draft\(made == 1 ? "" : "s") to review.")
        }
    }

    /// One thread: Claude decides and writes; the draft goes in the thread, from the address of the thread's project.
    private func draft(_ c: FollowUpCandidate, now: Date) async throws -> Bool {
        let mail = model.engine.mail, last = c.last
        let detail = try await mail.detail(accountId: last.accountId, threadId: last.threadId)
        let samples = try await model.engine.db.pool.read { db in
            try MailMessage.filter(Column("accountId") == last.accountId && Column("labelIds").like("%|SENT|%") && !Column("labelIds").like("%|DRAFT|%"))
                .order(Column("date").desc).limit(5).fetchAll(db)
        }.map { FollowUpWriter.ownText($0.bodyText) }.filter { !$0.isEmpty }
        let out = try await writer.review(c, thread: detail.messages, samples: samples, now: now)
        guard out.needed, !out.text.isEmpty else { return false }
        let addr = try await mail.replyAddressing(accountId: last.accountId, messageId: last.messageId, replyAll: true)
        let sender = await mail.chooseSender(accountId: last.accountId, recipients: addr.to + addr.cc, isReply: true)
        var input = ComposeInput(accountId: last.accountId, to: addr.to, cc: addr.cc, subject: addr.subject, text: out.text)
        input.fromEmail = sender.fromEmail
        input.replyTo = (last.accountId, last.messageId)
        input.quotedHtml = mail.quotedBlock(message: last)
        let saved = try await mail.saveDraft(input)
        try await store.record(AutoDraftRecord(accountId: last.accountId, draftId: saved.draftId, threadId: saved.threadId ?? last.threadId,
                                               fromEmail: sender.address, recipients: (addr.to + addr.cc).joined(separator: ", "),
                                               subject: addr.subject, source: .review, reason: out.reason))
        return true
    }

    private func notify(count: Int) {
        guard Bundle.main.bundleIdentifier != nil, ProcessInfo.processInfo.environment["POSTVAK_NO_NOTIFY"] == nil else { return }
        let c = UNMutableNotificationContent()
        c.title = count == 1 ? "A follow-up draft to review" : "\(count) follow-up drafts to review"
        c.body = "Postvak wrote them for threads waiting on you or on an answer. Nothing is sent until you approve."
        c.categoryIdentifier = "drafts"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "drafts-\(UUID().uuidString)", content: c, trigger: nil))
    }

    // MARK: actions

    /// The draft as it is in Gmail now, with the message it answers.
    func load(_ r: AutoDraftRecord) async -> (draft: MailMessage, answering: MailMessage?)? {
        // Straight from the local copy: no network needed to show it.
        guard let t = r.threadId, let messages = try? await model.engine.db.pool.read({ db in
            try MailMessage.filter(Column("accountId") == r.accountId && Column("threadId") == t).order(Column("date")).fetchAll(db)
        }), let draft = messages.last(where: \.isDraft) else { return nil }
        return (draft, messages.last { !$0.isDraft && $0.date <= draft.date })
    }

    func send(_ r: AutoDraftRecord, draft: MailMessage, skipCheck: Bool = false) async -> [String] {
        do {
            let state = try await model.draftState(draft)
            if !skipCheck {
                let findings = await model.checkBeforeSending(state)
                if !findings.isEmpty { return findings }
            }
            try await model.send(state, sendAt: nil)
            try await store.setStatus(r.id, .sent)
        } catch {
            model.toast(error.localizedDescription, kind: .error)
        }
        return []
    }

    func edit(_ draft: MailMessage) {
        model.perform { [model] in model.composers.open(try await model.draftState(draft)) }
    }

    func keep(_ r: AutoDraftRecord) {
        model.perform { [store] in try await store.setStatus(r.id, .kept) }
    }

    func delete(_ r: AutoDraftRecord) {
        model.perform("Deleting the draft") { [model, store] in
            try await model.engine.mail.deleteDraft(accountId: r.accountId, draftId: r.draftId, threadId: r.threadId)
            try await store.setStatus(r.id, .deleted)
        }
    }

    func forget(_ r: AutoDraftRecord) {
        model.perform { [store] in try await store.setStatus(r.id, .gone) }
    }
}

extension AppModel {
    /// A meeting's follow-up from its agreed next steps, saved as a draft for review rather than opened: in the thread
    /// with the most guests, or a new mail, from the address of the meeting's project.
    func writeMeetingFollowUpForReview(_ m: MeetingRecord) async throws -> Bool {
        let mail = engine.mail
        guard let (_, summary) = try await engine.meetings.get(m.id), let summary else { return false }
        let thread: RelatedThread? = switch try await followUpTarget(meetingId: m.id) {
        case .reply(let t): t
        case .choose(let list): list.first
        case .new: nil
        }
        guard let (input, sender) = try await meetingFollowUp(m, summary: summary, invite: nil, thread: thread) else { return false }
        let accountId = input.accountId, subject = input.subject
        let recipients = input.to + input.cc
        let saved = try await mail.saveDraft(input)
        let when = (m.endedAt ?? m.startedAt).formatted(date: .abbreviated, time: .omitted)
        try await engine.autoDrafts.record(AutoDraftRecord(accountId: accountId, draftId: saved.draftId, threadId: saved.threadId,
                                                           fromEmail: sender.address, recipients: recipients.joined(separator: ", "), subject: subject,
                                                           source: .meeting, reason: "“\(m.title)” on \(when): no mail to the guests since", meetingId: m.id))
        return true
    }
}

/// The review page: every draft Postvak wrote, one at a time, with why it was written.
struct DraftReviewView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var review: DraftReview
    @State private var selected: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if review.pending.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to review", systemImage: "checkmark.circle")
                } description: {
                    Text("Drafts Postvak writes for you wait here: follow-ups for threads waiting on you or on an answer, reminders, meeting follow-ups and drafts from Claude. Nothing is sent until you approve.")
                }
            } else {
                HSplitView {
                    List(review.pending, selection: $selected) { r in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(r.recipients.isEmpty ? "(no recipient)" : r.recipients).fontWeight(.semibold).lineLimit(1)
                                Spacer()
                                Text(r.source.title).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                            Text(r.subject).lineLimit(1)
                            Text(r.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .padding(.vertical, 3)
                        .tag(r.id)
                    }
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
                    Group {
                        if let r = review.pending.first(where: { $0.id == selected }) ?? review.pending.first {
                            DraftReviewDetail(review: review, record: r).id(r.id)
                        }
                    }
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { model.perform { [review] in _ = try await review.store.reconcile() } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Review Drafts").font(.title2.weight(.semibold))
            if !review.pending.isEmpty { Text("\(review.pending.count)").foregroundStyle(.secondary).monospacedDigit() }
            Spacer()
            Text(scheduleText).font(.caption).foregroundStyle(.secondary)
            Button {
                Task { await review.run(manual: true) }
            } label: {
                if review.running { ProgressView().controlSize(.small) } else { Text("Find Follow-ups Now") }
            }
            .disabled(review.running)
            .help("Look through the last two weeks for threads waiting on a follow-up, and draft one where it is worth it")
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
    }

    private var scheduleText: String {
        let last = review.lastRun.map { " · last \($0.formatted(.relative(presentation: .named)))" } ?? ""
        switch review.frequency {
        case .off: return "Automatic review off (Settings → AI)\(last)"
        case .daily: return "Reviews every weekday at 8:15\(last)"
        case .weekly: return "Reviews Monday mornings at 8:15\(last)"
        }
    }
}

private struct DraftReviewDetail: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var review: DraftReview
    let record: AutoDraftRecord
    @State private var loaded: (draft: MailMessage, answering: MailMessage?)?
    @State private var missing = false
    @State private var files: [AttachmentRecord] = []
    @State private var findings: [String] = []
    @State private var sending = false

    private var blanks: [String] { loaded.map { FollowUpReviewWriter.placeholders(in: FollowUpWriter.ownText($0.draft.bodyText)) } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Label(record.reason, systemImage: "lightbulb").font(.callout)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    if let d = loaded?.draft {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                            GridRow { Text("From").foregroundStyle(.secondary); Text(d.fromEmail.isEmpty ? record.fromEmail : d.fromEmail) }
                            GridRow { Text("To").foregroundStyle(.secondary); Text(d.toLine).textSelection(.enabled) }
                            if !d.ccLine.isEmpty { GridRow { Text("Cc").foregroundStyle(.secondary); Text(d.ccLine).textSelection(.enabled) } }
                            GridRow { Text("Subject").foregroundStyle(.secondary); Text(d.subject).fontWeight(.semibold) }
                        }
                        .font(.callout)
                        Divider()
                        Text(FollowUpWriter.ownText(d.bodyText)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        if !files.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(files) { f in
                                    Label {
                                        Text(f.filename) + Text("  \(ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file))").foregroundStyle(.secondary)
                                    } icon: { Image(systemName: "paperclip") }
                                    .font(.callout)
                                }
                            }
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                        }
                        if let a = loaded?.answering {
                            DisclosureGroup("In reply to \(a.senderDisplay), \(a.date.formatted(date: .abbreviated, time: .shortened))") {
                                Text(FollowUpWriter.ownText(a.bodyText).prefix(2000)).font(.callout).foregroundStyle(.secondary)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                            }
                            .font(.callout)
                        }
                    } else if missing {
                        Text("This draft is no longer in Gmail's Drafts: it was sent or deleted elsewhere.").foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(20)
            }
            if !findings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Before this goes", systemImage: "exclamationmark.bubble").font(.callout.weight(.semibold))
                    ForEach(findings, id: \.self) { Text("• \($0)").font(.callout) }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
            }
            Divider()
            HStack {
                if missing {
                    Spacer()
                    Button("Remove from List") { review.forget(record) }
                } else {
                    Button(role: .destructive) { review.delete(record) } label: { Label("Delete", systemImage: "trash") }
                        .disabled(loaded == nil).help("Delete the draft from Gmail. Nothing is sent.")
                    Button("Keep in Drafts") { review.keep(record) }
                        .help("Take it off this list and leave it in Gmail's Drafts")
                    Spacer()
                    if !blanks.isEmpty {
                        Text("Fill in \(blanks.prefix(2).joined(separator: ", ")) first").font(.caption).foregroundStyle(.orange)
                    }
                    Button("Edit…") { if let d = loaded?.draft { review.edit(d) } }
                        .disabled(loaded == nil).help("Open it in the composer to change it, then send it from there")
                    Button(sending ? "Checking…" : (findings.isEmpty ? "Send" : "Send Anyway")) { send() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(loaded == nil || sending || !blanks.isEmpty)
                        .help("Send it now, with the usual 5 seconds to undo")
                }
            }
            .padding(12)
        }
        .task {
            if let l = await review.load(record) {
                loaded = l
                files = (try? await model.engine.db.pool.read { db in
                    try AttachmentRecord.filter(Column("accountId") == l.draft.accountId && Column("messageId") == l.draft.messageId).fetchAll(db)
                }) ?? []
            } else { missing = true }
        }
    }

    private func send() {
        guard let d = loaded?.draft else { return }
        let skip = !findings.isEmpty
        sending = true
        Task {
            findings = await review.send(record, draft: d, skipCheck: skip)
            sending = false
        }
    }
}
