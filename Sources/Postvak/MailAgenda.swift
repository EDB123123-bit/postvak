import SwiftUI
import GRDB
import PostvakCore

/// Your agenda beside an open email, so you can see when you're free without leaving the mail.
/// Double-clicking an empty slot starts an event filled in from the email: its subject, the sender and the people in Cc.
struct MailAgendaPanel: View {
    @EnvironmentObject var model: AppModel
    let message: MailMessage?
    let thread: MailThread
    let onClose: () -> Void

    @AppStorage("mailAgenda.days") private var dayCount = 3
    @State private var anchor = Calendar.current.startOfDay(for: Date())
    @State private var events: [CalendarEvent] = []
    @State private var calendars: [CalendarRecord] = []
    @State private var editor: EventEditorState?
    @State private var detail: CalendarEvent?

    private let cal = Calendar.current

    private var days: [Date] { (0..<dayCount).map { cal.date(byAdding: .day, value: $0, to: anchor)! } }
    private var rangeKey: String { "\(anchor.timeIntervalSince1970)-\(dayCount)" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("Today") { anchor = cal.startOfDay(for: Date()) }
                Button { anchor = cal.date(byAdding: .day, value: -dayCount, to: anchor)! } label: { Image(systemName: "chevron.left") }
                Button { anchor = cal.date(byAdding: .day, value: dayCount, to: anchor)! } label: { Image(systemName: "chevron.right") }
                Text(anchor.formatted(.dateTime.month(.wide).year())).font(.headline).lineLimit(1)
                Spacer()
                Picker("", selection: $dayCount) {
                    Text("1 day").tag(1); Text("3 days").tag(3); Text("5 days").tag(5)
                }
                .labelsHidden().fixedSize()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .help("Close calendar")
            }
            .buttonStyle(.borderless)
            .padding(8)
            Divider()
            TimeGrid(days: days, events: events, colorFor: { model.color(for: $0.accountId) },
                     onSelect: { detail = $0 }, onCreate: { newEvent(at: $0, until: $1) }, onMove: move)
            Divider()
            Text("Double-click or drag over a free slot to plan a meeting with the people on this email.")
                .font(.caption).foregroundStyle(.secondary).padding(6)
        }
        .task(id: rangeKey) {
            let s = anchor, e = cal.date(byAdding: .day, value: dayCount, to: anchor)!
            let o = ValueObservation.tracking { db in
                (try CalendarService.eventsRequest(from: s, to: e).fetchAll(db), try CalendarRecord.order(Column("accountId"), Column("summary")).fetchAll(db))
            }
            do {
                for try await (ev, c) in o.values(in: model.engine.db.pool) {
                    events = ev.filter { $0.status != "cancelled" }
                    calendars = c
                }
            } catch {}
        }
        .sheet(item: $editor) { st in EventEditor(state: st, calendars: calendars.filter(\.canWrite)).environmentObject(model) }
        .sheet(item: $detail) { e in
            EventDetail(event: e, canEdit: canEdit(e), onEdit: { editor = EventEditorState(event: e) }).environmentObject(model)
        }
    }

    /// A new event at the double-clicked or dragged time, filled in from the email.
    private func newEvent(at d: Date, until end: Date) {
        let writable = calendars.filter(\.canWrite)
        // The calendar of the account the email came in on.
        guard let c = writable.first(where: { $0.accountId == thread.accountId && $0.calendarId == thread.accountId })
                ?? writable.first(where: { $0.accountId == thread.accountId && $0.isPrimary })
                ?? writable.first(where: \.isPrimary) ?? writable.first else {
            model.toast("Add a Google account in Settings first.", kind: .error)
            return
        }
        var st = EventEditorState(calendarKey: c.id, start: d, end: end)
        st.summary = Self.title(from: thread.subject)
        if let m = message { st.attendees = Self.guests(of: m, mine: Set(model.accounts.map { $0.id.lowercased() })).joined(separator: ", ") }
        editor = st
    }

    private func canEdit(_ e: CalendarEvent) -> Bool { calendars.contains { $0.calendarId == e.calendarId && $0.canWrite } }

    private func move(_ e: CalendarEvent, to start: Date) {
        guard canEdit(e) else {
            model.toast("“\(e.summary)” is in a read-only calendar and can't be moved.", kind: .error, seconds: 7)
            return
        }
        let end = start.addingTimeInterval(e.endAt.timeIntervalSince(e.startAt))
        model.perform("Moving “\(e.summary)”") {
            _ = try await model.engine.calendar.update(accountId: e.accountId, calendarId: e.calendarId, eventId: e.eventId, patch: EventPatch(start: start, end: end))
        }
    }

    /// The subject without "Re:", "Fwd:" and the like.
    static func title(from subject: String) -> String {
        var s = subject.trimmingCharacters(in: .whitespaces)
        while let r = s.range(of: #"^(re|fw|fwd|tr|aw|antw)\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) { s.removeSubrange(r) }
        return s
    }

    /// Everyone on the email except your own addresses: the sender, then To and Cc.
    static func guests(of m: MailMessage, mine: Set<String>) -> [String] {
        var seen = Set<String>(), out: [String] = []
        let everyone = [GmailParser.recipient(name: m.fromName, email: m.fromEmail)]
            + GmailParser.splitAddresses(m.toLine) + GmailParser.splitAddresses(m.ccLine)
        for raw in everyone {
            let email = GmailParser.parseAddress(raw).email
            guard !email.isEmpty, !mine.contains(email), seen.insert(email).inserted else { continue }
            out.append(email)
        }
        return out
    }
}
