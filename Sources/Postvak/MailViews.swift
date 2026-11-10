import SwiftUI
import GRDB
import PostvakCore

struct MailContainerView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var selected: String?
    @State private var threads: [MailThread] = []
    @State private var search = ""
    @State private var expanded = Set<String>()
    @State private var focusedMessage: String?
    @State private var snoozeTarget: MailThread?
    @State private var unreadOnly = false
    @State private var serverSearching = false
    @FocusState private var searchFocused: Bool
    /// Reminders still waiting or due, by thread.
    @State private var followUps: [String: FollowUpRecord] = [:]

    private var query: ThreadQuery {
        guard case .mail(let folder, let account, let bucket) = model.destination else { return ThreadQuery() }
        let text = search.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            // Search covers everything except when a specific account or Spam/Trash view is open.
            let f: MailFolder = (folder == .spam || folder == .trash) ? folder : .all
            return ThreadQuery(folder: f, accountId: account, text: text, unreadOnly: unreadOnly, limit: 300)
        }
        return ThreadQuery(folder: folder, accountId: account, bucket: bucket, unreadOnly: unreadOnly, limit: 500)
    }

    private var title: String {
        guard case .mail(let folder, _, let bucket) = model.destination else { return "Mail" }
        return bucket?.title ?? folder.title
    }

    private var selectedThread: MailThread? { threads.first { $0.id == selected } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                listHeader
                Divider()
                threadList
            }
            .frame(minWidth: 340, idealWidth: 430, maxWidth: 620)

            Group {
                if let t = selectedThread {
                    ReadingPane(thread: t, focusedMessage: $focusedMessage, onSnooze: { snoozeTarget = t }).id(t.id)
                } else {
                    ContentUnavailableView("No thread selected", systemImage: "envelope.open")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(title)
        // The title, filter and search sit above the mail list instead, so they stay on the left
        // and never cover the calendar panel at the right.
        .toolbar(removing: .title)
        .task(id: query) {
            let q = query
            let pool = model.engine.db.pool
            let o = ValueObservation.tracking { try MailService.threadRequest(q).fetchAll($0) }
            do {
                for try await v in o.values(in: pool) {
                    threads = v
                    if model.demoMode, selected == nil || !v.contains(where: { $0.id == selected }) { selected = v.first?.id }
                }
            } catch {}
        }
        .task {
            let pool = model.engine.db.pool
            let o = ValueObservation.tracking { db in
                try FollowUpRecord.filter([FollowUpRecord.Status.waiting.rawValue, FollowUpRecord.Status.due.rawValue].contains(Column("status"))).fetchAll(db)
            }
            do {
                for try await v in o.values(in: pool) {
                    followUps = Dictionary(v.map { ("\($0.accountId)/\($0.threadId)", $0) }, uniquingKeysWith: { a, b in a.status == .due ? a : b })
                }
            } catch {}
        }
        .sheet(item: $snoozeTarget) { t in
            SnoozeSheet(thread: t).environmentObject(model)
        }
        .background { KeyMonitor(handler: handleKey) }
    }

    /// The folder name with the unread filter beside it, and the search field below.
    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.title3.weight(.semibold)).lineLimit(1)
                Toggle(isOn: $unreadOnly) {
                    Image(systemName: unreadOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .toggleStyle(.button).buttonStyle(.borderless)
                .foregroundStyle(unreadOnly ? Color.accentColor : .secondary)
                .help(unreadOnly ? "Showing unread only. Click to show all." : "Show unread threads only")
                Spacer()
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search all mail", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onExitCommand { search = ""; searchFocused = false }
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Clear search")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))
            // ⌘F jumps to search, as it did when search sat in the toolbar.
            .background { Button("") { searchFocused = true }.keyboardShortcut("f").hidden() }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
    }

    private var threadList: some View {
        List(selection: $selected) {
            if !search.isEmpty {
                HStack {
                    Text("\(threads.count) local results").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(serverSearching ? "Searching Gmail…" : "Also search Gmail") {
                        serverSearching = true
                        let text = search, account = query.accountId
                        Task {
                            defer { serverSearching = false }
                            do {
                                let n = try await model.engine.mail.serverSearch(text, accountId: account)
                                model.toast("Gmail returned \(n) threads.")
                            } catch { model.toast(error.localizedDescription, kind: .error) }
                        }
                    }
                    .buttonStyle(.link).font(.caption).disabled(serverSearching)
                }
                .selectionDisabled()
            }
            ForEach(threads) { t in
                ThreadRow(thread: t, isExpanded: expanded.contains(t.id), toggle: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        if expanded.contains(t.id) { expanded.remove(t.id) } else { expanded.insert(t.id) }
                    }
                }, onSelectMessage: { id in
                    selected = t.id
                    focusedMessage = id
                }, onSnooze: { snoozeTarget = t }, followUp: followUps[t.id])
                .tag(t.id)
                .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 8))
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in
            if let t = threads.first(where: { ids.contains($0.id) }) {
                Button("Open in New Window") { popOut(t) }
                Divider()
                ThreadMenu(thread: t, onSnooze: { snoozeTarget = t })
            }
        } primaryAction: { ids in
            // Double-click or Return: a draft opens to edit, anything else in its own window.
            guard let t = threads.first(where: { ids.contains($0.id) }) else { return }
            if isDraft(t) { model.editDraft(in: t) } else { popOut(t) }
        }
        .overlay {
            if threads.isEmpty {
                ContentUnavailableView(search.isEmpty ? "Nothing here" : "No results", systemImage: search.isEmpty ? "tray" : "magnifyingglass")
            }
        }
    }

    /// Gmail-style single-key commands. Returns true when the key was used.
    private func handleKey(_ key: String) -> Bool {
        switch key {
        case "j": move(1)
        case "k": move(-1)
        case "o": if let t = selectedThread { popOut(t) }
        default:
            return model.handleThreadKey(key, thread: selectedThread, onSnooze: { snoozeTarget = $0 }, onLeave: advance)
        }
        return true
    }

    private func popOut(_ t: MailThread) { openWindow(value: ThreadWindowRef(t)) }

    /// Everything listed under Drafts, and a draft that is a thread of its own wherever it shows.
    private func isDraft(_ t: MailThread) -> Bool {
        if case .mail(.drafts, _, _) = model.destination { return true }
        return t.labels.contains(GmailLabel.draft) && t.messageCount == 1
    }

    private func move(_ d: Int) {
        guard !threads.isEmpty else { return }
        let i = threads.firstIndex { $0.id == selected } ?? -d
        selected = threads[max(0, min(threads.count - 1, i + d))].id
    }
    private func advance() {
        guard let i = threads.firstIndex(where: { $0.id == selected }) else { return }
        selected = (i + 1 < threads.count) ? threads[i + 1].id : (i > 0 ? threads[i - 1].id : nil)
    }
}

/// One line per thread with a disclosure arrow. Expanding lists each message, as in Outlook.
struct ThreadRow: View {
    @EnvironmentObject var model: AppModel
    let thread: MailThread
    let isExpanded: Bool
    let toggle: () -> Void
    let onSelectMessage: (String) -> Void
    let onSnooze: () -> Void
    var followUp: FollowUpRecord?
    @State private var hovering = false
    @State private var messages: [MailMessage] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(thread.messageCount > 1 ? .secondary : .tertiary)
                        .frame(width: 14, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(thread.messageCount <= 1)
                .help(isExpanded ? "Collapse thread" : "Show the messages in this thread")

                // Clicking the dot flips read and unread straight from the list.
                Button {
                    model.perform { try await model.engine.mail.markRead(accountId: thread.accountId, threadId: thread.threadId, read: thread.isUnread) }
                } label: {
                    Circle()
                        .strokeBorder(thread.isUnread ? Color.accentColor : Color.secondary.opacity(hovering ? 0.6 : 0), lineWidth: 1.5)
                        .background(Circle().fill(thread.isUnread ? Color.accentColor : .clear))
                        .frame(width: 10, height: 10)
                        .padding(.top, 4)
                        .contentShape(Rectangle().inset(by: -5))
                }
                .buttonStyle(.plain)
                .help(thread.isUnread ? "Mark as read" : "Mark as unread")

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(thread.participants.isEmpty ? thread.lastSenderEmail : thread.participants)
                            .fontWeight(thread.isUnread ? .semibold : .regular)
                            .lineLimit(1)
                        if thread.messageCount > 1 {
                            Text("\(thread.messageCount)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                        // A thread holding an unsent draft says so, wherever it is listed (Sent included).
                        if thread.labels.contains(GmailLabel.draft) {
                            Text("Draft").font(.caption.weight(.semibold)).foregroundStyle(.red)
                                .help("This thread has a draft that has not been sent")
                        }
                        Spacer(minLength: 4)
                        if let f = followUp {
                            if f.status == .due {
                                Text("No reply yet").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.15), in: Capsule())
                            } else {
                                Image(systemName: "bell").font(.caption).foregroundStyle(.secondary)
                                    .help("Back in your inbox \(f.dueAt.formatted(date: .abbreviated, time: .shortened)) if nobody replies")
                            }
                        }
                        if thread.hasAttachments { Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary) }
                        if thread.isStarred { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                        if hovering {
                            HoverActions(thread: thread, onSnooze: onSnooze)
                        } else {
                            Text(DateText.short(thread.lastMessageAt)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        model.badge(thread.accountId, size: 15)
                    }
                    Text(thread.subject).font(.callout).fontWeight(thread.isUnread ? .medium : .regular).lineLimit(1)
                    Text(thread.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(messages) { m in
                        Button { onSelectMessage(m.messageId) } label: {
                            HStack(spacing: 8) {
                                Circle().fill(m.isUnread ? Color.accentColor : .clear).frame(width: 6, height: 6)
                                Text(m.senderDisplay).font(.caption).fontWeight(m.isUnread ? .semibold : .regular).lineLimit(1).frame(width: 110, alignment: .leading)
                                if m.isDraft {
                                    Text("Draft").font(.caption.weight(.semibold)).foregroundStyle(.red)
                                        .help("Not sent: saved as a draft")
                                }
                                Text(m.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(DateText.short(m.date)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 36)
                .task(id: thread.lastMessageAt) {
                    messages = (try? await model.engine.mail.detail(accountId: thread.accountId, threadId: thread.threadId).messages) ?? []
                }
            }
        }
        .padding(.vertical, 4)
        .onHover { hovering = $0 }
    }
}

struct HoverActions: View {
    @EnvironmentObject var model: AppModel
    let thread: MailThread
    let onSnooze: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            icon("archivebox", "Archive") { try await model.engine.mail.archive(accountId: thread.accountId, threadId: thread.threadId) }
            Button(action: onSnooze) { Image(systemName: "clock") }.help("Snooze")
            icon("trash", "Trash") { try await model.engine.mail.trash(accountId: thread.accountId, threadId: thread.threadId) }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    private func icon(_ name: String, _ help: String, _ f: @escaping () async throws -> Void) -> some View {
        Button { model.perform(f) } label: { Image(systemName: name) }.help(help)
    }
}

struct ThreadMenu: View {
    @EnvironmentObject var model: AppModel
    let thread: MailThread
    let onSnooze: () -> Void
    var body: some View {
        let a = thread.accountId, t = thread.threadId, mail = model.engine.mail
        Button(thread.isUnread ? "Mark as Read" : "Mark as Unread") { model.perform { try await mail.markRead(accountId: a, threadId: t, read: thread.isUnread) } }
        Button(thread.isStarred ? "Remove Star" : "Star") { model.perform { try await mail.star(accountId: a, threadId: t, starred: !thread.isStarred) } }
        Divider()
        if thread.isInInbox {
            Button("Archive") { model.perform { try await mail.archive(accountId: a, threadId: t) } }
        } else {
            Button("Move to Inbox") { model.perform { try await mail.moveToInbox(accountId: a, threadId: t) } }
        }
        Button("Snooze…", action: onSnooze)
        Menu("Sort Sender Into") {
            ForEach(InboxBucket.allCases, id: \.self) { b in
                Button(b.title) { model.perform { try await mail.setBucket(accountId: a, threadId: t, bucket: b) } }
            }
        }
        LabelMenu(thread: thread)
        Divider()
        if thread.isSpam {
            Button("Not Spam") { model.perform { try await mail.notSpam(accountId: a, threadId: t) } }
        } else {
            Button("Mark as Spam") { model.perform { try await mail.markSpam(accountId: a, threadId: t) } }
        }
        if thread.isTrash {
            Button("Remove from Trash") { model.perform { try await mail.untrash(accountId: a, threadId: t) } }
        } else {
            Button("Move to Trash") { model.perform { try await mail.trash(accountId: a, threadId: t) } }
        }
    }
}

struct LabelMenu: View {
    @EnvironmentObject var model: AppModel
    let thread: MailThread
    @State private var labels: [MailLabelRecord] = []
    var body: some View {
        Menu("Labels") {
            ForEach(labels) { l in
                let on = thread.labels.contains(l.labelId)
                Button { model.perform {
                    try await model.engine.mail.modify(accountId: thread.accountId, threadId: thread.threadId, add: on ? [] : [l.labelId], remove: on ? [l.labelId] : [])
                } } label: {
                    if on { Label(l.name, systemImage: "checkmark") } else { Text(l.name) }
                }
            }
        }
        .task { labels = (try? await model.engine.mail.labels(accountId: thread.accountId)) ?? [] }
    }
}

struct SnoozeSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let thread: MailThread
    var onSnoozed: (() -> Void)? = nil
    @State private var custom = Calendar.current.date(byAdding: .day, value: 1, to: Date())!

    private var presets: [(String, Date)] {
        let c = Calendar.current, now = Date()
        func at(_ d: Date, _ h: Int) -> Date { c.date(bySettingHour: h, minute: 0, second: 0, of: d)! }
        let tomorrow = c.date(byAdding: .day, value: 1, to: now)!
        let monday = c.nextDate(after: now, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime)!
        var out: [(String, Date)] = [("In 3 hours", now.addingTimeInterval(3 * 3600))]
        if c.component(.hour, from: now) < 16 { out.append(("This evening", at(now, 18))) }
        out.append(("Tomorrow morning", at(tomorrow, 8)))
        out.append(("Next Monday", at(monday, 8)))
        out.append(("In a week", at(c.date(byAdding: .day, value: 7, to: now)!, 8)))
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Snooze until").font(.headline)
            ForEach(presets, id: \.0) { p in
                Button { snooze(p.1) } label: {
                    HStack { Text(p.0); Spacer(); Text(p.1.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            }
            Divider()
            DatePicker("Pick a time", selection: $custom, in: Date()...)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Snooze") { snooze(custom) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func snooze(_ d: Date) {
        onSnoozed?()
        dismiss()
        model.perform { try await model.engine.mail.snooze(accountId: thread.accountId, threadId: thread.threadId, until: d) }
    }
}

struct ReadingPane: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.threadWindow) private var threadWindow
    let thread: MailThread
    @Binding var focusedMessage: String?
    let onSnooze: () -> Void
    /// Runs when an action takes the thread out of view. A popped-out window closes itself here.
    var onLeave: (() -> Void)? = nil
    @State private var detail: ThreadDetail?
    @State private var expanded = Set<String>()
    @State private var snoozedUntil: Date?
    @State private var followUp: FollowUpRecord?
    /// The agenda beside the mail. It stays open from one email to the next until switched off.
    @AppStorage("mail.showAgenda") private var showAgenda = false

    var body: some View {
        HSplitView {
            mailColumn.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            if showAgenda {
                MailAgendaPanel(message: newestReceived, thread: thread, onClose: { showAgenda = false })
                    .frame(minWidth: 300, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The email to plan from: the newest one you received, or else the newest at all.
    private var newestReceived: MailMessage? {
        let list = detail?.messages.filter { !$0.isDraft } ?? []
        return list.last { !$0.labels.contains(GmailLabel.sent) } ?? list.last
    }

    /// The follow-up reminder on this thread: waiting, with a way to cancel it, or due, with a way to set it aside.
    private func followUpBar(_ f: FollowUpRecord) -> some View {
        HStack(spacing: 8) {
            Image(systemName: f.status == .due ? "bell.badge.fill" : "bell").foregroundStyle(f.status == .due ? .orange : .secondary)
            if f.status == .due {
                Text(f.nudgeDraftId == nil
                     ? "No reply since \(f.sentAt.formatted(date: .abbreviated, time: .omitted))."
                     : "No reply since \(f.sentAt.formatted(date: .abbreviated, time: .omitted)). A follow-up is drafted below.")
            } else {
                Text("Back in your inbox \(f.dueAt.formatted(date: .abbreviated, time: .shortened)) if nobody replies.")
            }
            Spacer()
            Button(f.status == .due ? "Done" : "Cancel Reminder") {
                model.perform { try await model.engine.followUps.dismiss(id: f.id) }
            }
            .controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background((f.status == .due ? Color.orange : Color.secondary).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private var mailColumn: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    if let f = followUp { followUpBar(f) }
                    ForEach(detail?.messages ?? []) { m in
                        MessageCard(message: m, attachments: detail?.attachments[m.messageId] ?? [],
                                    isExpanded: expanded.contains(m.messageId),
                                    toggle: {
                                        if expanded.contains(m.messageId) { expanded.remove(m.messageId) } else { expanded.insert(m.messageId) }
                                    })
                        .id(m.messageId)
                    }
                }
                .padding(20)
            }
            .onChange(of: focusedMessage) { _, id in
                guard let id else { return }
                expanded.insert(id)
                withAnimation { proxy.scrollTo(id, anchor: .top) }
            }
        }
        .task(id: thread.lastMessageAt) { await load() }
        .task(id: thread.id) {
            let a = thread.accountId, t = thread.threadId
            let o = ValueObservation.tracking { try FollowUps.open($0, accountId: a, threadId: t) }
            do { for try await v in o.values(in: model.engine.db.pool) { followUp = v } } catch {}
        }
        .task(id: thread.id) {
            snoozedUntil = try? await model.engine.mail.snoozeWake(accountId: thread.accountId, threadId: thread.threadId)
            // Opening a thread leaves it unread: the user marks it read themselves (the dot, u, or the toolbar button),
            // so it stays in an unread-only list while they read it.
        }
    }

    private func load() async {
        guard let d = try? await model.engine.mail.detail(accountId: thread.accountId, threadId: thread.threadId) else { return }
        detail = d
        if expanded.isEmpty {
            // The latest message and anything unread start open. Older ones stay collapsed.
            var open = Set(d.messages.filter(\.isUnread).map(\.messageId))
            if let last = d.messages.last { open.insert(last.messageId) }
            if let f = focusedMessage { open.insert(f) }
            expanded = open
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(thread.subject).font(.title2.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 10) {
                model.badge(thread.accountId, size: 16)
                Text(thread.accountId).font(.caption).foregroundStyle(.secondary)
                if let s = snoozedUntil {
                    Label("Snoozed until \(s.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock").font(.caption).foregroundStyle(.orange)
                    Button("Unsnooze") { model.perform {
                        try await model.engine.mail.unsnooze(accountId: thread.accountId, threadId: thread.threadId, markUnread: false)
                        snoozedUntil = nil
                    } }.buttonStyle(.link).font(.caption)
                }
                Spacer()
                toolbar
            }
        }
        .padding(.bottom, 4)
    }

    private var toolbar: some View {
        let mail = model.engine.mail, a = thread.accountId, t = thread.threadId
        let last = detail?.messages.last(where: { !$0.isDraft })
        return HStack(spacing: 10) {
            btn("arrowshape.turn.up.left", "Reply (r)") { if let last { model.reply(to: last, replyAll: false) } }
            btn("arrowshape.turn.up.left.2", "Reply all (a)") { if let last { model.reply(to: last, replyAll: true) } }
            btn("arrowshape.turn.up.right", "Forward (f)") { if let last { model.forward(last, attachments: detail?.attachments[last.messageId] ?? []) } }
            Divider().frame(height: 14)
            btn(thread.isUnread ? "envelope.open" : "envelope.badge", thread.isUnread ? "Mark as read (u)" : "Mark as unread (u)") { model.perform { try await mail.markRead(accountId: a, threadId: t, read: thread.isUnread) } }
            btn("archivebox", "Archive (e)") { model.perform { try await mail.archive(accountId: a, threadId: t) }; onLeave?() }
            btn("clock", "Snooze (s)", onSnooze)
            if thread.isSpam {
                btn("tray.and.arrow.up", "Not spam") { model.perform { try await mail.notSpam(accountId: a, threadId: t) } }
            } else {
                btn("xmark.octagon", "Mark as spam") { model.perform { try await mail.markSpam(accountId: a, threadId: t) }; onLeave?() }
            }
            btn("trash", "Move to trash (#)") { model.perform { try await mail.trash(accountId: a, threadId: t) }; onLeave?() }
            Divider().frame(height: 14)
            Button { showAgenda.toggle() } label: { Image(systemName: showAgenda ? "calendar.circle.fill" : "calendar") }
                .help(showAgenda ? "Hide calendar" : "Show calendar beside this mail")
            if threadWindow == nil {
                Divider().frame(height: 14)
                btn("arrow.up.forward.square", "Open in new window (o)") { openWindow(value: ThreadWindowRef(thread)) }
            }
        }
        .buttonStyle(.borderless)
    }

    private func btn(_ icon: String, _ help: String, _ f: @escaping () -> Void) -> some View {
        Button(action: f) { Image(systemName: icon) }.help(help)
    }
}

struct MessageCard: View {
    @EnvironmentObject var model: AppModel
    let message: MailMessage
    let attachments: [AttachmentRecord]
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var showDetails = false
    @State private var inline: [String: Data] = [:]

    private var files: [AttachmentRecord] { attachments.filter { !($0.contentId != nil && $0.mimeType.hasPrefix("image/") && (message.bodyHtml?.contains("cid:") ?? false)) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text(message.senderDisplay).fontWeight(.medium)
                    if message.isDraft { Text("Draft").font(.caption).foregroundStyle(.red) }
                    if !isExpanded { Text(message.snippet).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                    Text(message.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    // Each address starts a new mail when clicked and copies on right-click.
                    VStack(alignment: .leading, spacing: 3) {
                        AddressLine(label: "from", addresses: [GmailParser.recipient(name: message.fromName, email: message.fromEmail)], accountId: message.accountId)
                        if !message.toLine.isEmpty { AddressLine(label: "to", addresses: GmailParser.splitAddresses(message.toLine), accountId: message.accountId) }
                        if !message.ccLine.isEmpty { AddressLine(label: "cc", addresses: GmailParser.splitAddresses(message.ccLine), accountId: message.accountId) }
                        Button(showDetails ? "Hide full headers" : "Show full headers") { showDetails.toggle() }
                            .buttonStyle(.link).font(.caption2)
                    }
                    if showDetails {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("From: \(message.fromName) <\(message.fromEmail)>")
                            Text("To: \(message.toLine)")
                            if !message.ccLine.isEmpty { Text("Cc: \(message.ccLine)") }
                        }
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    MessageBodyView(message: message, inlineImages: inline) { to, subject in
                        model.compose(to: to, subject: subject, accountId: message.accountId)
                    }
                    if !files.isEmpty {
                        FlowChips(files: files)
                    }
                    if message.isDraft {
                        Button("Edit Draft") { model.openDraft(message) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .task { await loadInline() }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    /// Embedded images such as signature logos, fetched on demand.
    private func loadInline() async {
        guard message.bodyHtml?.contains("cid:") == true else { return }
        var out: [String: Data] = [:]
        for a in attachments {
            guard let cid = a.contentId, let url = try? await model.engine.mail.attachmentFile(a), let d = try? Data(contentsOf: url) else { continue }
            out[cid] = d
        }
        inline = out
    }
}

struct FlowChips: View {
    @EnvironmentObject var model: AppModel
    let files: [AttachmentRecord]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(files) { a in
                Button {
                    model.perform {
                        let url = try await model.engine.mail.attachmentFile(a)
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                        VStack(alignment: .leading, spacing: 0) {
                            Text(a.filename).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

enum DateText {
    static func short(_ d: Date) -> String {
        let c = Calendar.current
        if c.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if c.isDateInYesterday(d) { return "Yesterday" }
        if let days = c.dateComponents([.day], from: d, to: Date()).day, days < 7 { return d.formatted(.dateTime.weekday(.abbreviated)) }
        if c.component(.year, from: d) == c.component(.year, from: Date()) { return d.formatted(.dateTime.day().month(.abbreviated)) }
        return d.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

/// Listens for single keys only while nothing is being typed.
/// A text field or the composer takes every key, so typing "e" in search can never archive a thread.
struct KeyMonitor: NSViewRepresentable {
    let handler: (String) -> Bool

    final class Coordinator {
        var handler: (String) -> Bool = { _ in false }
        var monitor: Any?
        weak var view: NSView?
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let c = context.coordinator
        c.view = v
        c.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak c] event in
            guard let c, let window = c.view?.window, event.window === window, window.isKeyWindow, window.attachedSheet == nil else { return event }
            let responder = window.firstResponder
            if responder is NSTextView || responder is NSTextField { return event }
            let mods = event.modifierFlags.intersection([.command, .control, .option])
            guard mods.isEmpty else { return event }
            let key = event.keyCode == 51 ? "delete" : (event.charactersIgnoringModifiers ?? "")
            return c.handler(key.count == 1 ? (event.characters ?? key).lowercased() : key) ? nil : event
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { context.coordinator.handler = handler }
}
