import SwiftUI
import GRDB
import PostvakCore

enum CalendarMode: String, CaseIterable, Identifiable {
    /// The raw values are what's saved in settings. `workWeek` is Monday to Friday, `week` all seven days.
    case day = "Day", workWeek = "Work Week", week = "Week", month = "Month"
    var id: String { rawValue }
    var label: String { rawValue }
}

struct CalendarContainerView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("calendarMode") private var mode: CalendarMode = .week
    @State private var anchor = Date()
    @State private var events: [CalendarEvent] = []
    @State private var calendars: [CalendarRecord] = []
    @State private var editor: EventEditorState?
    @State private var detail: CalendarEvent?
    @State private var showCalendars = false

    private let cal = Calendar.current

    private var range: (Date, Date) {
        switch mode {
        case .day:
            let s = cal.startOfDay(for: anchor)
            return (s, cal.date(byAdding: .day, value: 1, to: s)!)
        case .workWeek, .week:
            // Starts on Monday whatever the system's first weekday; the work week stops after Friday.
            var monday = cal
            monday.firstWeekday = 2
            let s = monday.dateInterval(of: .weekOfYear, for: anchor)!.start
            return (s, cal.date(byAdding: .day, value: mode == .week ? 7 : 5, to: s)!)
        case .month:
            let first = cal.dateInterval(of: .month, for: anchor)!.start
            let s = cal.dateInterval(of: .weekOfYear, for: first)!.start
            return (s, cal.date(byAdding: .day, value: 42, to: s)!)
        }
    }

    private var title: String {
        switch mode {
        case .day:
            return anchor.formatted(date: .complete, time: .omitted)
        case .workWeek, .week:
            let (s, e) = range
            return "\(s.formatted(.dateTime.day().month(.abbreviated))) – \(cal.date(byAdding: .day, value: -1, to: e)!.formatted(.dateTime.day().month(.abbreviated).year()))"
        case .month:
            return anchor.formatted(.dateTime.month(.wide).year())
        }
    }

    private func step(_ d: Int) {
        let unit: Calendar.Component = mode == .day ? .day : mode == .month ? .month : .weekOfYear
        anchor = cal.date(byAdding: unit, value: d, to: anchor)!
    }

    private var rangeKey: String { "\(range.0.timeIntervalSince1970)-\(range.1.timeIntervalSince1970)" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button("Today") { anchor = Date() }
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                Text(title).font(.title3.weight(.semibold))
                Spacer()
                CalendarSearchField(text: $model.calendarSearch)
                Button { showCalendars.toggle() } label: { Label("Calendars", systemImage: "line.3.horizontal.decrease.circle") }
                    .popover(isPresented: $showCalendars) { CalendarPicker(calendars: calendars).environmentObject(model) }
                Picker("", selection: $mode) { ForEach(CalendarMode.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 320).labelsHidden()
                Button { newEvent(at: nextHour()) } label: { Label("New Event", systemImage: "plus") }
            }
            .padding(10)
            Divider()
            if !model.calendarSearch.trimmingCharacters(in: .whitespaces).isEmpty {
                CalendarSearchResults(text: model.calendarSearch, colorFor: color, onOpen: { detail = $0 }, onShowDay: { e in
                    anchor = e.startAt
                    model.calendarSearch = ""
                })
            } else {
                grid
            }
        }
        .navigationTitle("Calendar")
        .task(id: rangeKey) {
            let (s, e) = range
            let pool = model.engine.db.pool
            let o = ValueObservation.tracking { db in
                (try CalendarService.eventsRequest(from: s, to: e).fetchAll(db), try CalendarRecord.order(Column("accountId"), Column("summary")).fetchAll(db))
            }
            do {
                for try await (ev, c) in o.values(in: pool) {
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

    @ViewBuilder private var grid: some View {
        switch mode {
        case .month:
            MonthGrid(start: range.0, anchor: anchor, events: events, colorFor: color, onSelect: { detail = $0 }, onCreate: { d in
                newEvent(at: cal.date(bySettingHour: 9, minute: 0, second: 0, of: d)!)
            })
        case .day, .workWeek, .week:
            TimeGrid(days: days, events: events, colorFor: color, onSelect: { detail = $0 }, onCreate: { newEvent(at: $0, until: $1) }, onMove: move)
        }
    }

    /// True when at least one connected account may change the event's calendar.
    private func canEdit(_ e: CalendarEvent) -> Bool {
        calendars.contains { $0.calendarId == e.calendarId && $0.canWrite }
    }

    private var days: [Date] {
        let (s, e) = range
        var out: [Date] = [], d = s
        while d < e { out.append(d); d = cal.date(byAdding: .day, value: 1, to: d)! }
        return out
    }

    private func nextHour() -> Date {
        let base = cal.isDate(anchor, inSameDayAs: Date()) ? Date() : cal.date(bySettingHour: 9, minute: 0, second: 0, of: anchor)!
        return cal.nextDate(after: base, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? base
    }

    private func newEvent(at d: Date, until end: Date? = nil) {
        guard let c = calendars.first(where: { $0.isPrimary && $0.canWrite }) ?? calendars.first(where: \.canWrite) else {
            model.toast("Add a Google account in Settings first.", kind: .error)
            return
        }
        editor = EventEditorState(calendarKey: c.id, start: d, end: end)
    }

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

    private func color(_ e: CalendarEvent) -> Color { model.color(for: e.accountId) }
}

struct CalendarPicker: View {
    @EnvironmentObject var model: AppModel
    let calendars: [CalendarRecord]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.accounts) { a in
                VStack(alignment: .leading, spacing: 4) {
                    Text(a.email).font(.caption).foregroundStyle(.secondary)
                    ForEach(calendars.filter { $0.accountId == a.id }) { c in
                        Toggle(c.summary, isOn: Binding(get: { c.isSelected }, set: { v in
                            model.perform { try await model.engine.calendar.setSelected(accountId: c.accountId, calendarId: c.calendarId, selected: v) }
                        }))
                    }
                }
            }
        }
        .padding(14).frame(minWidth: 260)
    }
}

/// Places overlapping events side by side. Pure layout, returns column and column count per event.
enum DayLayout {
    static func columns(_ events: [CalendarEvent]) -> [String: (col: Int, of: Int)] {
        var out: [String: (Int, Int)] = [:]
        let sorted = events.sorted { ($0.startAt, $1.endAt) < ($1.startAt, $0.endAt) }
        var cluster: [CalendarEvent] = []
        var clusterEnd = Date.distantPast
        func flush() {
            var colEnds: [Date] = []
            var assigned: [(String, Int)] = []
            for e in cluster {
                if let i = colEnds.firstIndex(where: { $0 <= e.startAt }) {
                    colEnds[i] = e.endAt
                    assigned.append((e.id, i))
                } else {
                    colEnds.append(e.endAt)
                    assigned.append((e.id, colEnds.count - 1))
                }
            }
            for (id, c) in assigned { out[id] = (c, colEnds.count) }
            cluster = []
        }
        for e in sorted {
            if !cluster.isEmpty && e.startAt >= clusterEnd { flush(); clusterEnd = .distantPast }
            cluster.append(e)
            clusterEnd = max(clusterEnd, e.endAt)
        }
        flush()
        return out
    }
}

struct TimeGrid: View {
    let days: [Date]
    let events: [CalendarEvent]
    let colorFor: (CalendarEvent) -> Color
    let onSelect: (CalendarEvent) -> Void
    /// A new event from the start to the end the user picked (double-click: one hour; drag: the dragged span).
    let onCreate: (Date, Date) -> Void
    let onMove: (CalendarEvent, Date) -> Void

    /// The span being dragged out on an empty slot: day index and the two edges, in points from midnight.
    @State private var sketch: (day: Int, from: CGFloat, to: CGFloat)?

    /// Between days: clearly stronger than the hour lines, so days stay apart at a glance.
    static let dayLine = Color.secondary.opacity(0.45)

    private let hourHeight: CGFloat = 52
    private let gutter: CGFloat = 50
    private let cal = Calendar.current

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    GeometryReader { geo in
                        let colWidth = (geo.size.width - gutter) / CGFloat(days.count)
                        ZStack(alignment: .topLeading) {
                            hourLines(width: geo.size.width)
                            ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                                dayColumn(day: day, index: i, width: colWidth, gridWidth: geo.size.width)
                            }
                            nowLine(width: colWidth)
                        }
                    }
                    .frame(height: hourHeight * 24)
                    .overlay(alignment: .top) {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: hourHeight * 7.5)
                            Color.clear.frame(height: 1).id("morning")
                            Spacer(minLength: 0)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .task {
                    // Waits for layout, then opens on the working day rather than midnight.
                    try? await Task.sleep(for: .milliseconds(150))
                    proxy.scrollTo("morning", anchor: .top)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            ForEach(days, id: \.self) { day in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption).foregroundStyle(.secondary)
                        Text(day.formatted(.dateTime.day()))
                            .font(.callout.weight(cal.isDateInToday(day) ? .bold : .regular))
                            .foregroundStyle(cal.isDateInToday(day) ? Color.accentColor : .primary)
                    }
                    ForEach(allDay(day)) { e in
                        Button { onSelect(e) } label: {
                            Text(e.summary).font(.caption).lineLimit(1).padding(.horizontal, 5).padding(.vertical, 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(colorFor(e).opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) { Rectangle().fill(TimeGrid.dayLine).frame(width: 1) }
            }
        }
    }

    private func allDay(_ day: Date) -> [CalendarEvent] {
        let next = cal.date(byAdding: .day, value: 1, to: day)!
        return events.filter { $0.isAllDay && $0.startAt < next && $0.endAt > day }
    }

    private func hourLines(width: CGFloat) -> some View {
        ForEach(0..<24, id: \.self) { h in
            let y = CGFloat(h) * hourHeight
            Path { p in p.move(to: CGPoint(x: gutter, y: y)); p.addLine(to: CGPoint(x: width, y: y)) }
                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
            Text(String(format: "%02d:00", h)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: gutter - 8, alignment: .trailing).position(x: (gutter - 8) / 2, y: y + (h == 0 ? 7 : 0))
        }
    }

    private func timed(_ day: Date) -> [CalendarEvent] {
        let next = cal.date(byAdding: .day, value: 1, to: day)!
        return events.filter { !$0.isAllDay && $0.startAt < next && $0.endAt > day }
    }

    private func y(_ d: Date, on day: Date) -> CGFloat {
        CGFloat(max(0, min(24 * 3600, d.timeIntervalSince(day)))) / 3600 * hourHeight
    }

    @ViewBuilder
    private func dayColumn(day: Date, index: Int, width: CGFloat, gridWidth: CGFloat) -> some View {
        let x = gutter + CGFloat(index) * width
        let list = timed(day)
        let layout = DayLayout.columns(list)
        Color.clear
            .frame(width: width, height: hourHeight * 24)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) { Rectangle().fill(TimeGrid.dayLine).frame(width: 1) }
            .gesture(SpatialTapGesture(count: 2).onEnded { v in
                let minutes = Int((v.location.y / hourHeight * 60 / 30).rounded(.down)) * 30
                let start = cal.date(byAdding: .minute, value: minutes, to: day)!
                onCreate(start, start.addingTimeInterval(3600))
            })
            // Click and drag on a free slot, as in Google Calendar: the span becomes the new event's time.
            .simultaneousGesture(DragGesture(minimumDistance: 4)
                .onChanged { v in sketch = (index, v.startLocation.y, v.location.y) }
                .onEnded { v in
                    sketch = nil
                    let (a, b) = span(v.startLocation.y, v.location.y)
                    onCreate(cal.date(byAdding: .minute, value: a, to: day)!, cal.date(byAdding: .minute, value: b, to: day)!)
                })
            .offset(x: x)
        if let s = sketch, s.day == index {
            let (a, b) = span(s.from, s.to)
            let top = CGFloat(a) / 60 * hourHeight, h = CGFloat(b - a) / 60 * hourHeight
            VStack(alignment: .leading, spacing: 0) {
                Text("New event").font(.caption.weight(.medium))
                Text("\(label(a, on: day)) – \(label(b, on: day))").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 5).padding(.vertical, 3)
            .frame(width: width - 4, height: max(h, 18), alignment: .topLeading)
            .background(Color.accentColor.opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 1))
            .offset(x: x + 2, y: top)
            .allowsHitTesting(false)
            .zIndex(20)
        }
        ForEach(list) { e in
            let top = y(e.startAt, on: day)
            let h = max(20, y(e.endAt, on: day) - top)
            let pos = layout[e.id] ?? (0, 1)
            let w = (width - 4) / CGFloat(pos.of)
            EventBlock(event: e, color: colorFor(e), height: h, hourHeight: hourHeight, onSelect: { onSelect(e) }, onDrop: { dy, dx in
                let minutes = (Double(dy) / Double(hourHeight) * 60 / 15).rounded() * 15
                let dayShift = (Double(dx) / Double(width)).rounded()
                guard minutes != 0 || dayShift != 0 else { return }
                var start = e.startAt.addingTimeInterval(minutes * 60)
                start = cal.date(byAdding: .day, value: Int(dayShift), to: start)!
                onMove(e, start)
            })
            .frame(width: w - 1, height: h)
            .offset(x: x + 2 + CGFloat(pos.col) * w, y: top)
        }
    }

    /// The dragged edges as minutes from midnight, snapped to 15 minutes, at least 15 long and inside the day.
    private func span(_ y1: CGFloat, _ y2: CGFloat) -> (Int, Int) {
        func snap(_ y: CGFloat) -> Int { min(24 * 60, max(0, Int((y / hourHeight * 60 / 15).rounded()) * 15)) }
        var a = snap(min(y1, y2)), b = snap(max(y1, y2))
        if b - a < 15 { if b + 15 <= 24 * 60 { b = a + 15 } else { a = b - 15 } }
        return (a, b)
    }

    private func label(_ minutes: Int, on day: Date) -> String {
        cal.date(byAdding: .minute, value: minutes, to: day)!.formatted(date: .omitted, time: .shortened)
    }

    @ViewBuilder
    private func nowLine(width: CGFloat) -> some View {
        if let i = days.firstIndex(where: { cal.isDateInToday($0) }) {
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                Rectangle().fill(.red).frame(width: width, height: 1.5)
                    .offset(x: gutter + CGFloat(i) * width, y: y(ctx.date, on: days[i]))
            }
        }
    }
}

struct EventBlock: View {
    let event: CalendarEvent
    let color: Color
    let height: CGFloat
    let hourHeight: CGFloat
    let onSelect: () -> Void
    let onDrop: (CGFloat, CGFloat) -> Void
    @State private var drag: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(event.summary).font(.caption.weight(.medium)).lineLimit(height > 40 ? 2 : 1)
            if height > 34 {
                Text("\(event.startAt.formatted(date: .omitted, time: .shortened)) – \(event.endAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if height > 60, !event.location.isEmpty { Text(event.location).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(.horizontal, 5).padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(event.selfResponse == "needsAction" ? 0.08 : 0.22), in: RoundedRectangle(cornerRadius: 5))
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3) }
        .overlay {
            if event.selfResponse == "needsAction" {
                RoundedRectangle(cornerRadius: 5).strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [3]))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .offset(drag)
        .zIndex(drag == .zero ? 0 : 10)
        .onTapGesture(perform: onSelect)
        .gesture(DragGesture(minimumDistance: 6)
            .onChanged { drag = $0.translation }
            .onEnded { v in
                drag = .zero
                onDrop(v.translation.height, v.translation.width)
            })
    }
}

struct MonthGrid: View {
    let start: Date
    let anchor: Date
    let events: [CalendarEvent]
    let colorFor: (CalendarEvent) -> Color
    let onSelect: (CalendarEvent) -> Void
    let onCreate: (Date) -> Void
    private let cal = Calendar.current

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(cal.date(byAdding: .day, value: i, to: start)!.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 4)
                }
            }
            Divider()
            GeometryReader { geo in
                let rowH = geo.size.height / 6
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { r in
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { c in
                                cell(cal.date(byAdding: .day, value: r * 7 + c, to: start)!, height: rowH)
                            }
                        }
                    }
                }
            }
        }
    }

    private func cell(_ d: Date, height: CGFloat) -> some View {
        let next = cal.date(byAdding: .day, value: 1, to: d)!
        let list = events.filter { $0.startAt < next && $0.endAt > d }.sorted { ($0.isAllDay ? 0 : 1, $0.startAt) < ($1.isAllDay ? 0 : 1, $1.startAt) }
        let maxRows = max(1, Int((height - 24) / 17))
        let inMonth = cal.isDate(d, equalTo: anchor, toGranularity: .month)
        return VStack(alignment: .leading, spacing: 1) {
            Text(d.formatted(.dateTime.day()))
                .font(.caption.weight(cal.isDateInToday(d) ? .bold : .regular))
                .foregroundStyle(cal.isDateInToday(d) ? Color.accentColor : (inMonth ? .primary : .secondary))
                .padding(.bottom, 1)
            ForEach(list.prefix(maxRows)) { e in
                Button { onSelect(e) } label: {
                    HStack(spacing: 3) {
                        Circle().fill(colorFor(e)).frame(width: 6, height: 6)
                        if !e.isAllDay { Text(e.startAt.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary) }
                        Text(e.summary).lineLimit(1)
                    }
                    .font(.caption2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if list.count > maxRows { Text("+\(list.count - maxRows) more").font(.caption2).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(height: height)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onCreate(d) }
        .overlay(Rectangle().strokeBorder(TimeGrid.dayLine, lineWidth: 0.5))
    }
}

struct EventDetail: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let event: CalendarEvent
    let canEdit: Bool
    let onEdit: () -> Void
    @State private var confirmDelete = false
    @State private var recorded: MeetingRecord?
    @State private var project: String?
    @State private var summary: MeetingSummaryRecord?
    @State private var loaded = false
    @State private var followUpChoices: [RelatedThread]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                model.badge(event.accountId, size: 18).padding(.top, 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.summary).font(.title3.weight(.semibold)).textSelection(.enabled)
                    Text(timeText).foregroundStyle(.secondary)
                    Text(event.accountId).font(.caption).foregroundStyle(.secondary)
                    if let project { Label(project, systemImage: "folder").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
            // Who the meeting is with comes first: the other guests on top, you last.
            if !event.attendees.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("With · \(event.attendees.count) attendees").font(.caption).foregroundStyle(.secondary)
                    ForEach(event.attendees.filter { !$0.isSelf } + event.attendees.filter(\.isSelf), id: \.email) { a in
                        HStack(spacing: 6) {
                            Image(systemName: responseIcon(a.response)).foregroundStyle(responseColor(a.response)).font(.caption)
                            // Click for a new mail, right-click or select to copy.
                            AddressButton(name: a.name, email: a.email, accountId: event.accountId, showEmail: true, beforeCompose: { dismiss() })
                                .fontWeight(a.isSelf ? .regular : .medium)
                        }
                    }
                }
            }
            if !event.location.isEmpty { Label(event.location, systemImage: "mappin.and.ellipse").textSelection(.enabled) }
            if let link = event.meetingLink, let url = URL(string: link) {
                Link(destination: url) { Label("Join meeting", systemImage: "video") }
            }
            if PrepBriefs.isOver(event) {
                // Once the meeting is over, what was said matters, not the prep.
                if let m = recorded {
                    VStack(alignment: .leading, spacing: 8) {
                        if let s = summary, !s.summary.isEmpty {
                            ScrollView { summaryText(s).frame(maxWidth: .infinity, alignment: .leading) }
                                .frame(maxHeight: 230)
                        } else {
                            Text(m.status == .ready || m.status == .failed ? "This meeting has no summary." : "The summary isn't ready yet.")
                                .foregroundStyle(.secondary)
                        }
                        openMeeting(m, "Open in Meetings")
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                } else if loaded, PrepBriefs.wantsBrief(event) {
                    Label("This meeting wasn't recorded.", systemImage: "waveform.slash").foregroundStyle(.secondary)
                }
            } else {
                if let m = recorded {
                    openMeeting(m, m.status == .ready ? "Open meeting summary" : "Open meeting (summary not ready yet)")
                }
                if PrepBriefs.wantsBrief(event) {
                    ScrollView { PrepBriefView(event: event, beforeOpening: { dismiss() }) }
                        .frame(maxHeight: 230)
                        .padding(10)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            if !event.details.isEmpty {
                ScrollView { Text(GmailParser.htmlToText(event.details)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 130)
            }
            if event.selfResponse != nil {
                HStack {
                    Text("Going?").foregroundStyle(.secondary)
                    respond("Yes", "accepted"); respond("Maybe", "tentative"); respond("No", "declined")
                }
            }
            Divider()
            HStack {
                if PrepBriefs.isOver(event) && event.attendees.contains(where: { !$0.isSelf }) {
                    let busy = model.draftingFollowUps.contains(AppModel.followUpKey(event))
                    Button { writeFollowUp() } label: {
                        Label(busy ? "Writing Follow-up…" : "Write Follow-up Email", systemImage: "envelope.badge")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                    .help(summary == nil ? "A short thank-you to the guests, opened as a draft. Nothing is sent."
                                         : "The agreed next steps from the summary, opened as a draft. Nothing is sent.")
                } else {
                    Button {
                        dismiss()
                        model.startRecording(title: event.summary)
                    } label: { Label("Record This Meeting", systemImage: "record.circle") }
                    .disabled(model.isRecording)
                }
                Spacer()
                if canEdit {
                    Button("Edit") { dismiss(); DispatchQueue.main.async { onEdit() } }
                    Button("Delete", role: .destructive) { confirmDelete = true }
                } else {
                    Text("Read only").foregroundStyle(.secondary)
                        .help("None of your accounts may change this calendar.")
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .task {
            recorded = try? await model.engine.meetings.meeting(for: event)
            if let id = recorded?.id { summary = try? await model.engine.db.pool.read { try MeetingSummaryRecord.fetchOne($0, key: id) } }
            loaded = true
            if let p = recorded?.project { project = p } else { project = (try? await model.engine.meetings.project(for: event))?.project }
        }
        .sheet(item: Binding(get: { followUpChoices.map { ThreadChoices(threads: $0) } }, set: { if $0 == nil { followUpChoices = nil } })) { c in
            FollowUpThreadPicker(threads: c.threads) { picked in
                followUpChoices = nil
                startFollowUp(picked)
            } cancel: { followUpChoices = nil }
        }
        .confirmationDialog("Delete “\(event.summary)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                dismiss()
                model.perform("Deleting “\(event.summary)”") {
                    try await model.engine.calendar.delete(accountId: event.accountId, calendarId: event.calendarId, eventId: event.eventId)
                }
            }
        } message: {
            Text(event.attendees.count > 1 ? "Google will tell the attendees." : "This removes it from Google Calendar.")
        }
    }

    /// Replies in the thread with the guests when one clearly fits, asks when several do, else starts a new mail.
    private func writeFollowUp() {
        model.perform("Drafting the follow-up") {
            switch try await model.followUpTarget(event: event) {
            case .reply(let t): startFollowUp(t)
            case .new: startFollowUp(nil)
            case .choose(let list): followUpChoices = list
            }
        }
    }

    /// The pop-up closes; the draft opens in its own window once Claude has written it.
    private func startFollowUp(_ thread: RelatedThread?) {
        model.draftEventFollowUp(event, thread: thread)
        dismiss()
    }

    private var timeText: String {
        if event.isAllDay { return event.startAt.formatted(date: .complete, time: .omitted) }
        return "\(event.startAt.formatted(date: .abbreviated, time: .shortened)) – \(event.endAt.formatted(date: .omitted, time: .shortened))"
    }

    private func openMeeting(_ m: MeetingRecord, _ title: String) -> some View {
        Button {
            dismiss()
            model.selectedMeetingId = m.id
            model.destination = .meetings
        } label: { Label(title, systemImage: "doc.text.magnifyingglass") }
        .buttonStyle(.link)
    }

    /// The summary and what was agreed, short enough for the pop-up; the rest is one click away in Meetings.
    private func summaryText(_ s: MeetingSummaryRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SummaryText(text: s.summary)
            let items = s.actionItems
            if !items.isEmpty {
                Text("Action items").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(items.enumerated()), id: \.offset) { _, a in
                    Label {
                        Text(a.owner.map { "\(a.task) · \($0)" } ?? a.task).textSelection(.enabled)
                    } icon: { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
                    .font(.callout)
                }
            }
        }
    }

    private func respond(_ title: String, _ value: String) -> some View {
        Button(title) {
            dismiss()
            model.perform("Answering “\(event.summary)”") { _ = try await model.engine.calendar.respond(accountId: event.accountId, calendarId: event.calendarId, eventId: event.eventId, response: value) }
        }
        .buttonStyle(.bordered)
        .tint(event.selfResponse == value ? .accentColor : nil)
    }
    private func responseIcon(_ r: String) -> String {
        switch r { case "accepted": "checkmark.circle.fill"; case "declined": "xmark.circle.fill"; case "tentative": "questionmark.circle.fill"; default: "circle" }
    }
    private func responseColor(_ r: String) -> Color {
        switch r { case "accepted": .green; case "declined": .red; case "tentative": .orange; default: .secondary }
    }
}

struct EventEditorState: Identifiable {
    let id = UUID()
    var existing: CalendarEvent?
    var calendarKey: String
    var summary = ""
    var details = ""
    var location = ""
    var start: Date
    var end: Date
    var isAllDay = false
    var attendees = ""
    var repeatRule = ""
    /// New timed meetings get their own Meet link unless switched off.
    var addMeet = true

    init(calendarKey: String, start: Date, end: Date? = nil) {
        self.calendarKey = calendarKey
        self.start = start
        self.end = end ?? start.addingTimeInterval(3600)
    }
    init(event e: CalendarEvent) {
        existing = e
        calendarKey = "\(e.accountId)/\(e.calendarId)"
        summary = e.summary; details = e.details; location = e.location
        start = e.startAt; end = e.endAt; isAllDay = e.isAllDay
        attendees = e.attendees.filter { !$0.isSelf }.map(\.email).joined(separator: ", ")
    }
}

struct EventEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var state: EventEditorState
    let calendars: [CalendarRecord]
    @State private var saving = false
    @State private var failure: String?
    @State private var suggesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Title", text: $state.summary)
                if state.existing == nil {
                    Picker("Calendar", selection: $state.calendarKey) {
                        ForEach(calendars) { c in Text("\(c.summary) · \(c.accountId)").tag(c.id) }
                    }
                }
                Toggle("All day", isOn: $state.isAllDay)
                DatePicker("Starts", selection: $state.start, displayedComponents: state.isAllDay ? [.date] : [.date, .hourAndMinute])
                DatePicker("Ends", selection: $state.end, in: state.start..., displayedComponents: state.isAllDay ? [.date] : [.date, .hourAndMinute])
                TextField("Location", text: $state.location)
                AddressCompletionField(title: "Invite (addresses, comma separated)", text: $state.attendees, suggesting: $suggesting)
                if state.existing == nil {
                    Picker("Repeat", selection: $state.repeatRule) {
                        Text("Never").tag("")
                        Text("Every day").tag("RRULE:FREQ=DAILY")
                        Text("Every week").tag("RRULE:FREQ=WEEKLY")
                        Text("Every month").tag("RRULE:FREQ=MONTHLY")
                    }
                    Toggle("Add Google Meet link", isOn: $state.addMeet)
                } else if state.existing?.recurringEventId != nil {
                    Text("This changes only this occurrence.").font(.caption).foregroundStyle(.secondary)
                }
                TextField("Notes", text: $state.details, axis: .vertical).lineLimit(3...6)
            }
            .formStyle(.grouped)
            HStack {
                if let failure {
                    Label("Not saved: \(failure)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.callout).lineLimit(3).textSelection(.enabled)
                }
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                // While suggestions show, Return takes one and Escape hides them, instead of saving or closing.
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(suggesting ? nil : .cancelAction)
                Button(state.existing == nil ? "Create" : "Save") { save() }
                    .keyboardShortcut(suggesting ? nil : .defaultAction).disabled(state.summary.isEmpty || saving)
            }
            .padding(12)
        }
        .frame(width: 500, height: 560)
        .onChange(of: state.start) { old, new in
            // Moving the start keeps the duration.
            state.end = new.addingTimeInterval(max(900, state.end.timeIntervalSince(old)))
        }
        .onChange(of: state.isAllDay) { _, allDay in
            // All-day entries are rarely calls, so they start without a link; the toggle can still add one.
            if state.existing == nil { state.addMeet = !allDay }
        }
    }

    /// Stays open until Google has the change, and shows why when it doesn't, so an edit can't vanish unnoticed.
    private func save() {
        let s = state
        let list = GmailParser.splitAddresses(s.attendees)
        let cal = calendars.first { $0.id == s.calendarKey }
        let bad = list.filter { !GmailParser.isValidRecipient($0) }
        guard bad.isEmpty else {
            failure = "not an email address: \(bad.joined(separator: ", "))"
            return
        }
        saving = true
        failure = nil
        Task {
            do {
                // Google's all-day end date is exclusive; the picker shows the last day.
                let end = s.isAllDay ? Calendar.current.date(byAdding: .day, value: s.existing?.isAllDay == true ? 0 : 1, to: s.end)! : s.end
                if let e = s.existing {
                    let existingEmails = e.attendees.filter { !$0.isSelf }.map(\.email)
                    let keepSelf = e.attendees.filter(\.isSelf).map(\.email)
                    let changed = Set(list.map { GmailParser.parseAddress($0).email }) != Set(existingEmails)
                    _ = try await model.engine.calendar.update(
                        accountId: e.accountId, calendarId: e.calendarId, eventId: e.eventId,
                        patch: EventPatch(summary: s.summary, details: s.details, location: s.location, start: s.start, end: end,
                                          isAllDay: s.isAllDay, attendees: changed ? list + keepSelf : nil))
                } else if let cal {
                    _ = try await model.engine.calendar.create(EventInput(
                        accountId: cal.accountId, calendarId: cal.calendarId, summary: s.summary,
                        details: s.details.isEmpty ? nil : s.details, location: s.location.isEmpty ? nil : s.location,
                        start: s.start, end: end, isAllDay: s.isAllDay, attendees: list,
                        recurrence: s.repeatRule.isEmpty ? [] : [s.repeatRule], addMeetLink: s.addMeet))
                }
                dismiss()
            } catch {
                model.logFailure("Saving “\(s.summary)”", error)
                failure = error.localizedDescription
                saving = false
            }
        }
    }
}
