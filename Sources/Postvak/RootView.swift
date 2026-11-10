import SwiftUI
import PostvakCore
import GRDB

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var showSettingsHint = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            // Banners sit above the page and push it down, so they never cover the sidebar, the list or its search.
            // A plain stack, because the mail page's split view ignores a safe-area inset.
            VStack(spacing: 0) {
            BannerStack()
            Group {
                switch model.destination {
                case .mail: MailContainerView()
                case .scheduled: ScheduledView()
                case .review: DraftReviewView(review: model.draftReview)
                case .calendar: CalendarContainerView()
                case .meetings: MeetingsContainerView()
                case .ask: AskView(ask: model.ask)
                case .deals: DealsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottom) { ToastStack().padding(.bottom, 20) }
        .onAppear {
            model.mainWindowVisible = true
            model.reopenMainWindow = { [openWindow] in openWindow(id: mainWindowId) }
        }
        .onDisappear { model.mainWindowVisible = false }
        .sheet(isPresented: $model.showMorningOverview) { MorningOverview().environmentObject(model) }
        .sheet(item: $model.namingRecording) { n in NameRecordingSheet(naming: n).environmentObject(model) }
        .sheet(isPresented: $model.showOnboarding) { OnboardingView().environmentObject(model).interactiveDismissDisabled() }
        .task {
            await model.maybeShowOnboarding()
            await model.maybeShowMorningOverview()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.maybeShowMorningOverview() }
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @State private var labels: [String: [MailLabelRecord]] = [:]
    @State private var counts: [String: Int] = [:]

    private var selection: Binding<Destination?> {
        Binding(get: { model.destination }, set: { if let v = $0 { model.destination = v } })
    }

    var body: some View {
        List(selection: selection) {
            Section("Inbox") {
                row("All Inboxes", icon: "tray.2", dest: .mail(folder: .inbox, accountId: nil, bucket: nil), count: nil)
                ForEach(InboxBucket.allCases, id: \.self) { b in
                    row(b.title, icon: icon(b), dest: .mail(folder: .inbox, accountId: nil, bucket: b), count: counts["bucket.\(b.rawValue)"])
                }
            }
            Section("Mail") {
                row("Scheduled", icon: "calendar.badge.clock", dest: .scheduled, count: counts["scheduled"])
                ReviewDraftsRow(review: model.draftReview) { row("Review Drafts", icon: "checkmark.bubble", dest: .review, count: $0) }
                row("Snoozed", icon: "clock", dest: .mail(folder: .snoozed, accountId: nil, bucket: nil), count: nil)
                row("Starred", icon: "star", dest: .mail(folder: .starred, accountId: nil, bucket: nil), count: nil)
                row("Drafts", icon: "doc", dest: .mail(folder: .drafts, accountId: nil, bucket: nil), count: nil)
                row("Sent", icon: "paperplane", dest: .mail(folder: .sent, accountId: nil, bucket: nil), count: nil)
                row("Spam", icon: "xmark.octagon", dest: .mail(folder: .spam, accountId: nil, bucket: nil), count: counts["spam"])
                row("Trash", icon: "trash", dest: .mail(folder: .trash, accountId: nil, bucket: nil), count: nil)
                row("All Mail", icon: "archivebox", dest: .mail(folder: .all, accountId: nil, bucket: nil), count: nil)
            }
            Section("Agenda") {
                row("Calendar", icon: "calendar", dest: .calendar, count: nil)
                row("Meetings", icon: "waveform", dest: .meetings, count: nil)
                row("Ask Meetings", icon: "bubble.left.and.text.bubble.right", dest: .ask, count: nil)
            }
            Section("Sales") {
                row("Deals", icon: "briefcase", dest: .deals, count: nil)
            }
            ForEach(model.accounts) { a in
                Section {
                    row("Inbox", icon: "tray", dest: .mail(folder: .inbox, accountId: a.id, bucket: nil), count: counts["account.\(a.id)"])
                    row("Sent", icon: "paperplane", dest: .mail(folder: .sent, accountId: a.id, bucket: nil), count: nil)
                    row("Spam", icon: "xmark.octagon", dest: .mail(folder: .spam, accountId: a.id, bucket: nil), count: nil)
                    ForEach(labels[a.id] ?? []) { l in
                        row(l.name, icon: "tag", dest: .mail(folder: .label(l.labelId), accountId: a.id, bucket: nil), count: nil)
                    }
                } header: {
                    HStack(spacing: 6) {
                        AccountBadge(account: a, size: 15)
                        Text(a.email).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SidebarFooter(composers: model.composers) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.compose() } label: { Label("New Mail", systemImage: "square.and.pencil") }
            }
        }
        .task {
            let pool = model.engine.db.pool
            let o = ValueObservation.tracking { db -> ([String: [MailLabelRecord]], [String: Int]) in
                let all = try MailLabelRecord.filter(Column("type") == "user").order(Column("name")).fetchAll(db)
                var c: [String: Int] = [:]
                let unreadInbox = "labelIds LIKE '%|INBOX|%' AND labelIds LIKE '%|UNREAD|%' AND labelIds NOT LIKE '%|SPAM|%' AND labelIds NOT LIKE '%|TRASH|%'"
                for r in try Row.fetchAll(db, sql: "SELECT bucket, COUNT(*) n FROM thread WHERE \(unreadInbox) GROUP BY bucket") {
                    if let b: String = r["bucket"] { c["bucket.\(b)"] = r["n"] }
                }
                for r in try Row.fetchAll(db, sql: "SELECT accountId, COUNT(*) n FROM thread WHERE \(unreadInbox) GROUP BY accountId") {
                    let a: String = r["accountId"]
                    c["account.\(a)"] = r["n"]
                }
                c["spam"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM thread WHERE labelIds LIKE '%|SPAM|%' AND labelIds LIKE '%|UNREAD|%'") ?? 0
                c["scheduled"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox WHERE \(OutboxRow.listedSQL)") ?? 0
                return (Dictionary(grouping: all, by: \.accountId), c)
            }
            do {
                for try await (l, c) in o.values(in: pool) {
                    labels = l.mapValues { $0.filter { $0.name != GmailLabel.snoozedName } }
                    counts = c
                }
            } catch {}
        }
    }

    private func icon(_ b: InboxBucket) -> String {
        switch b { case .people: "person.2"; case .notifications: "bell"; case .newsletters: "newspaper" }
    }

    private func row(_ title: String, icon: String, dest: Destination, count: Int?) -> some View {
        NavigationLink(value: dest) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                if let count, count > 0 { Text("\(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
        }
    }
}

struct SyncStatusBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.isRecording, let start = model.recordingStartedAt {
                RecordingPill(start: start) { model.stopRecording() }
            } else {
                RecordButton()
            }
            if let a = model.accounts.first(where: { !$0.initialSyncDone }) {
                Label("Syncing \(a.email): \(a.syncedThreadCount) threads", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if let a = model.accounts.first(where: { $0.needsReauth }) {
                Label("\(a.email) needs a new sign-in", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
            } else if let a = model.accounts.first(where: { $0.lastError != nil }) {
                Label(a.lastError ?? "", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
            } else if model.accounts.isEmpty {
                SettingsLink { Label("Add a Google account", systemImage: "person.badge.plus") }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

/// Records any time, as a glass capsule at the bottom of the sidebar. Right-click for an in-person recording.
struct RecordButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button { model.recordNow() } label: {
            HStack(spacing: 8) {
                Image(systemName: "record.circle").foregroundStyle(.red).font(.body.weight(.semibold))
                Text("Record").font(.callout.weight(.medium))
                Spacer(minLength: 0)
                Text("⇧⌘R").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassCapsule()
        .help("Record now, with the call's sound. Right-click to record an in-person meeting with the microphone only.")
        .contextMenu {
            Button("Record a Call") { model.recordNow() }
            Button("Record In-Person Meeting") { model.recordNow(captureSystem: false) }
        }
    }
}

/// A stopped recording's title and guests, as the sheet asking for them starts out.
struct NamingRecording: Identifiable, Equatable {
    var id: String { meetingId }
    let meetingId: String
    let title: String
    let guests: String
}

/// Asked once a recording stops: what it was, and with whom, so the summary, speakers and follow-up know.
struct NameRecordingSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let naming: NamingRecording
    @State private var title = ""
    @State private var guests = ""
    @State private var suggesting = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Name this recording").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("Title").font(.caption).foregroundStyle(.secondary)
                TextField("For example: Demo Zonnehoek", text: $title).focused($titleFocused)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Attendees").font(.caption).foregroundStyle(.secondary)
                AddressCompletionField(title: "Email addresses, separated by commas", text: $guests, suggesting: $suggesting)
                Text("Used to name the speakers, file the meeting under its project and write the follow-up.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Skip") { dismiss() }.keyboardShortcut(suggesting ? nil : .cancelAction)
                Button("Save") { save() }.keyboardShortcut(suggesting ? nil : .defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            title = naming.title
            guests = naming.guests
            titleFocused = true
        }
    }

    private func save() {
        let id = naming.meetingId, t = title
        let list = GmailParser.splitAddresses(guests)
        model.perform("Saving the recording's details") {
            try await model.engine.meetings.setDetails(meetingId: id, title: t, guests: list)
        }
        dismiss()
    }
}

/// The recording in progress, as a glass capsule over the sidebar: a pulsing red dot, the time running, and Stop.
struct RecordingPill: View {
    let start: Date
    let stop: () -> Void
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 8, height: 8)
                .shadow(color: .red.opacity(0.6), radius: pulse ? 4 : 1)
                .opacity(pulse ? 0.45 : 1)
                .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)
            VStack(alignment: .leading, spacing: 0) {
                Text("Recording").font(.caption.weight(.semibold))
                Text(start, style: .timer).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            stopButton
        }
        .padding(.leading, 12).padding(.trailing, 5).padding(.vertical, 5)
        .glassCapsule(tint: .red.opacity(0.10))
        .onAppear { pulse = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording")
    }

    @ViewBuilder private var stopButton: some View {
        let label = Label("Stop", systemImage: "stop.fill").font(.caption.weight(.semibold))
        if #available(macOS 26, *) {
            Button(action: stop) { label }.buttonStyle(.glassProminent).tint(.red).controlSize(.small)
        } else {
            Button(action: stop) { label }.buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
        }
    }
}

extension View {
    /// Liquid Glass on macOS 26, a frosted capsule before that.
    @ViewBuilder func glassCapsule(tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint), in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        }
    }
}

struct ToastStack: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.toasts) { t in
                HStack(spacing: 12) {
                    if t.kind == .error { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    Text(t.text).lineLimit(3)
                    if case .undoSend(let id, let deadline) = t.kind {
                        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                            Text("\(max(0, Int(deadline.timeIntervalSince(ctx.date).rounded(.up))))s")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        Button("Undo") { model.undoSend(outboxId: id) }.keyboardShortcut("z")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .shadow(radius: 6, y: 2)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toasts)
    }
}

/// Mail whose send time passed while the app was closed and failed sends, which wait for a decision,
/// and mail waiting for a connection, which goes by itself once back online.
struct BannerStack: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            if let err = model.mcpError {
                banner(err, color: .orange) { EmptyView() }
            }
            DraftsBanner(review: model.draftReview)
            // The Scheduled page lists these itself, with the same choices.
            ForEach(model.destination == .scheduled ? [] : model.overdueOutbox) { row in
                banner(Self.text(row), color: .orange) {
                    Button("Edit") { model.editQueued(row) }
                    Button("Send now") { model.perform { try await model.engine.outbox.sendNow(id: row.id) } }
                    Button("Discard", role: .destructive) {
                        model.perform {
                            _ = try await model.engine.outbox.cancel(id: row.id)
                            await model.engine.outbox.removeFiles(id: row.id)
                        }
                    }
                }
            }
        }
    }
    static func text(_ row: OutboxRow) -> String {
        switch row.status {
        case .failed: "Not sent: \(row.summary). \(row.lastError ?? "")"
        case .waiting: "No connection: \(row.summary). It goes as soon as you're back online."
        default: "Waiting to send: \(row.summary). Its send time has passed."
        }
    }
    private func banner<A: View>(_ text: String, color: Color, @ViewBuilder actions: () -> A) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(color)
            Text(text).lineLimit(2)
            Spacer()
            actions()
        }
        .bannerStyle()
    }
}

/// The sidebar row for the review, counting drafts that wait. Watches the review itself, which the sidebar doesn't.
private struct ReviewDraftsRow<Content: View>: View {
    @ObservedObject var review: DraftReview
    let content: (Int?) -> Content
    init(review: DraftReview, @ViewBuilder content: @escaping (Int?) -> Content) { self.review = review; self.content = content }
    var body: some View { content(review.pending.count) }
}

/// Drafts Postvak wrote stay in view until reviewed: a banner with a Review button, which Later hides until more arrive.
private struct DraftsBanner: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var review: DraftReview
    @AppStorage("drafts.bannerHiddenAt") private var hiddenAt = 0

    var body: some View {
        let n = review.pending.count
        if n > 0, n > hiddenAt, model.destination != .review {
            HStack {
                Image(systemName: "checkmark.bubble.fill").foregroundStyle(Color.accentColor)
                Text(n == 1 ? "Postvak wrote a draft for you. It waits for your review." : "Postvak wrote \(n) drafts for you. They wait for your review.")
                    .lineLimit(2)
                Spacer()
                Button("Later") { hiddenAt = n }
                Button("Review") { hiddenAt = 0; model.destination = .review }.buttonStyle(.borderedProminent)
            }
            .bannerStyle()
            .onChange(of: n) { _, new in if new < hiddenAt { hiddenAt = new } }
        }
    }
}

extension View {
    /// A banner above the page: a rounded card with a hairline edge, clear of the content beside it.
    func bannerStyle() -> some View {
        padding(.horizontal, 12).padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            .padding(.horizontal, 12).padding(.top, 8)
    }
}
