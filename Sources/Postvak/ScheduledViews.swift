import SwiftUI
import GRDB
import PostvakCore

/// Mail waiting in the outbox: scheduled with Send Later (from the composer or through Claude), plus mail whose
/// time passed while Postvak was closed and mail that failed. The few seconds of undo after Send don't show here.
struct ScheduledView: View {
    @EnvironmentObject var model: AppModel
    @State private var items: [ScheduledItem] = []
    @State private var loaded = false
    @State private var confirmSend: ScheduledItem?
    @State private var confirmDelete: ScheduledItem?
    @State private var picking: ScheduledItem?

    private struct DayGroup: Identifiable {
        let id: String
        let title: String
        let items: [ScheduledItem]
    }

    /// Mail that needs a decision first, then the rest by the day it goes out.
    private var groups: [DayGroup] {
        var out: [DayGroup] = []
        let stuck = items.filter { $0.row.status == .overdue || $0.row.status == .failed }
        if !stuck.isEmpty { out.append(DayGroup(id: "stuck", title: "Needs a decision", items: stuck)) }
        let cal = Calendar.current
        let waiting = items.filter { $0.row.status != .overdue && $0.row.status != .failed }
        for (day, list) in Dictionary(grouping: waiting, by: { cal.startOfDay(for: $0.row.sendAt) }).sorted(by: { $0.key < $1.key }) {
            out.append(DayGroup(id: day.ISO8601Format(), title: Self.dayTitle(day), items: list.sorted { $0.row.sendAt < $1.row.sendAt }))
        }
        return out
    }

    static func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Scheduled").font(.title2.weight(.semibold))
                if !items.isEmpty { Text("\(items.count)").foregroundStyle(.secondary).monospacedDigit() }
                Spacer()
                Text("Goes out only while Postvak is running.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
            Divider()
            if items.isEmpty {
                if loaded {
                    ContentUnavailableView("Nothing scheduled", systemImage: "calendar.badge.clock",
                                           description: Text("Mail you schedule with Send Later waits here until its time."))
                } else {
                    Spacer()
                }
            } else {
                List {
                    ForEach(groups) { g in
                        Section(g.title) {
                            ForEach(g.items) { item in
                                ScheduledRow(item: item, account: model.accounts.first { $0.id == item.row.accountId },
                                             edit: { model.editQueued(item.row) },
                                             sendNow: { confirmSend = item },
                                             reschedule: { reschedule(item, to: $0) },
                                             pickTime: { picking = item },
                                             delete: { confirmDelete = item })
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .task {
            let pool = model.engine.db.pool
            let o = ValueObservation.tracking { db in
                try OutboxRow.listed(db).map { ScheduledItem(row: $0, mail: try? JSONDecoder().decode(OutgoingMail.self, from: $0.payload)) }
            }
            do {
                for try await v in o.values(in: pool) { items = v; loaded = true }
            } catch {}
        }
        .confirmationDialog(confirmSend.map { "Send “\($0.subject)” now?" } ?? "",
                            isPresented: Binding(get: { confirmSend != nil }, set: { if !$0 { confirmSend = nil } }),
                            presenting: confirmSend) { item in
            Button("Send Now") { sendNow(item) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("It goes to \(item.recipients) right away instead of \(item.row.sendAt.formatted(date: .abbreviated, time: .shortened)).")
        }
        .confirmationDialog(confirmDelete.map { "Delete “\($0.subject)”?" } ?? "",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { item in
            Button("Delete", role: .destructive) { delete(item) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It won't be sent, and it isn't kept as a draft. To keep the text, use Edit and Save Draft instead.")
        }
        .sheet(item: $picking) { item in
            PickSendTime(start: max(item.row.sendAt, Date().addingTimeInterval(3600))) { date in
                picking = nil
                if let date { reschedule(item, to: date) }
            }
        }
    }

    private func sendNow(_ item: ScheduledItem) {
        model.perform { [model] in
            if try await model.engine.outbox.sendNow(id: item.row.id) {
                model.toast("Sending “\(item.subject)”.")
            } else {
                model.toast("This mail is being edited or already on its way.", kind: .error)
            }
        }
    }

    private func reschedule(_ item: ScheduledItem, to date: Date) {
        model.perform { [model] in
            if try await model.engine.outbox.reschedule(id: item.row.id, to: date) {
                model.toast("Rescheduled for \(date.formatted(date: .abbreviated, time: .shortened)).")
            } else {
                model.toast("This mail is being edited or already on its way.", kind: .error)
            }
        }
    }

    private func delete(_ item: ScheduledItem) {
        model.perform { [model] in
            guard try await model.engine.outbox.cancel(id: item.row.id) != nil else {
                model.toast("Too late: the mail already went out.", kind: .error)
                return
            }
            await model.engine.outbox.removeFiles(id: item.row.id)
            model.toast("Deleted “\(item.subject)”.")
        }
    }
}

struct ScheduledItem: Identifiable, Hashable {
    let row: OutboxRow
    /// Nil only when the stored mail can't be read; the row's summary still says what it is.
    let mail: OutgoingMail?
    var id: String { row.id }

    var subject: String {
        let s = mail?.subject.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? (mail == nil ? row.summary : "(no subject)") : s
    }

    /// Names where the mail has them, else addresses. Bcc is listed last.
    var recipients: String {
        guard let mail else { return "" }
        let all = mail.to + mail.cc + mail.bcc
        let names = all.map { raw -> String in
            let a = GmailParser.parseAddress(raw)
            return a.name.isEmpty ? a.email : a.name
        }
        switch names.count {
        case 0: return "no one"
        case 1...3: return names.joined(separator: ", ")
        default: return names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) more"
        }
    }

    var preview: String {
        (mail?.textBody ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.prefix(3).joined(separator: " ")
    }

    /// Files attached, not pictures inside the text.
    var fileCount: Int { mail?.attachments.filter { $0.contentId == nil }.count ?? 0 }
}

private struct ScheduledRow: View {
    let item: ScheduledItem
    let account: Account?
    let edit: () -> Void
    let sendNow: () -> Void
    let reschedule: (Date) -> Void
    let pickTime: () -> Void
    let delete: () -> Void

    private var status: OutboxRow.Status { item.row.status }
    /// Only a mail waiting for its time, a connection or a decision can be moved, sent or deleted.
    private var canAct: Bool { [.pending, .overdue, .failed, .waiting].contains(status) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.row.sendAt.formatted(date: .omitted, time: .shortened))
                    .font(.title3.weight(.medium)).monospacedDigit()
                if status == .pending && item.row.sendAt > Date() {
                    Text(item.row.sendAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                } else if status == .overdue || status == .failed {
                    Text(item.row.sendAt.formatted(.dateTime.day().month(.abbreviated))).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 84, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    AccountBadge(account: account, size: 15)
                    Text(item.recipients).fontWeight(.semibold).lineLimit(1)
                    if item.fileCount > 0 {
                        Label("\(item.fileCount)", systemImage: "paperclip").font(.caption).foregroundStyle(.secondary)
                            .help(item.fileCount == 1 ? "1 file attached" : "\(item.fileCount) files attached")
                    }
                }
                Text(item.subject).lineLimit(1)
                if !item.preview.isEmpty {
                    Text(item.preview).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text("From \(account?.email ?? item.row.accountId)").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    statusLabel
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Button(status == .held ? "Show" : "Edit", action: edit)
                    .disabled(status == .sending)
                    .help(status == .held ? "Bring its composer forward" : "Open it in the composer. It waits while you edit.")
                Menu("Reschedule") {
                    ForEach(Self.presets(), id: \.0) { title, date in
                        Button(title) { reschedule(date) }
                    }
                    Divider()
                    Button("Pick a Time…", action: pickTime)
                }
                .fixedSize()
                .disabled(!canAct)
                Button("Send Now", action: sendNow).disabled(!canAct)
                Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                    .disabled(!canAct).help("Delete without sending")
            }
            .controlSize(.small)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if status != .sending { edit() } }
    }

    @ViewBuilder private var statusLabel: some View {
        switch status {
        case .held:
            Text("· Paused while you edit it").font(.caption).foregroundStyle(.orange)
        case .sending:
            Text("· Sending…").font(.caption).foregroundStyle(.secondary)
        case .overdue:
            Text("· Its send time passed, so it waits for you").font(.caption).foregroundStyle(.orange)
        case .failed:
            Text("· Not sent: \(item.row.lastError ?? "unknown error")").font(.caption).foregroundStyle(.red).lineLimit(2)
                .textSelection(.enabled)
        case .waiting:
            Text("· No connection at its time. It goes as soon as you're back online").font(.caption).foregroundStyle(.orange)
                .help(item.row.lastError ?? "")
        case .pending:
            EmptyView()
        }
    }

    /// Quick times for Reschedule: in an hour, tomorrow morning, next Monday morning.
    static func presets(now: Date = Date(), calendar cal: Calendar = .current) -> [(String, Date)] {
        let tomorrow = cal.date(bySettingHour: 8, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: now)!)!
        let monday = cal.nextDate(after: now, matching: DateComponents(hour: 8, minute: 0, weekday: 2), matchingPolicy: .nextTime)!
        var out = [("In 1 Hour", now.addingTimeInterval(3600)), ("Tomorrow at 8:00", tomorrow)]
        if !cal.isDate(monday, inSameDayAs: tomorrow) { out.append(("Monday at 8:00", monday)) }
        return out
    }
}

/// Picks a new send time for a queued mail.
private struct PickSendTime: View {
    @State var date: Date
    let done: (Date?) -> Void

    init(start: Date, done: @escaping (Date?) -> Void) {
        _date = State(initialValue: start)
        self.done = done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send at").font(.headline)
            DatePicker("Send at", selection: $date, in: Date()...).labelsHidden()
            Text("Postvak needs to be running at that time. If it isn't, it asks you when it next opens.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Reschedule") { done(date) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 340)
    }
}
