import SwiftUI
import GRDB
import PostvakCore

/// The calendar's search field. ⌘F jumps to it and Escape clears it.
struct CalendarSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search all events", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Clear search")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(width: 240)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))
        .background { Button("") { focused = true }.keyboardShortcut("f").hidden() }
    }
}

/// Events matching a search, in every account and every calendar shown. Stored events (three months back,
/// a year ahead) appear at once; older ones come from Google's own search a moment later.
struct CalendarSearchResults: View {
    @EnvironmentObject var model: AppModel
    let text: String
    let colorFor: (CalendarEvent) -> Color
    let onOpen: (CalendarEvent) -> Void
    let onShowDay: (CalendarEvent) -> Void

    private enum Older: Equatable { case idle, searching, done, failed(String) }

    @State private var stored: [CalendarEvent] = []
    @State private var older: [CalendarEvent] = []
    @State private var olderState = Older.idle

    private var olderFrom: Date { CalendarService.storedFrom() }

    private var upcoming: [CalendarEvent] {
        let now = Date()
        return stored.filter { $0.endAt >= now }
    }

    private var earlier: [CalendarEvent] {
        let now = Date()
        let seen = Set(stored.map { "\($0.calendarId)/\($0.eventId)" })
        let past = stored.filter { $0.endAt < now } + older.filter { !seen.contains("\($0.calendarId)/\($0.eventId)") }
        return past.sorted { $0.startAt > $1.startAt }
    }

    var body: some View {
        let soon = upcoming, before = earlier
        List {
            if !soon.isEmpty {
                Section("Coming up · \(soon.count)") {
                    ForEach(soon) { row($0) }
                }
            }
            if !before.isEmpty {
                Section("Earlier · \(before.count)") {
                    ForEach(before) { row($0) }
                }
            }
            Section { olderStatus }
        }
        .overlay {
            if soon.isEmpty && before.isEmpty && olderState != .searching {
                ContentUnavailableView.search(text: text)
            }
        }
        .task(id: text) {
            stored = []
            older = []
            olderState = .idle
            // Waits for a pause in typing, so every letter doesn't start a search.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let request = CalendarService.searchRequest(text) else { return }
            async let olderSearch: Void = searchOlder()
            // Live, so an event changed from its details updates here too.
            let o = ValueObservation.tracking { try request.fetchAll($0) }
            do {
                for try await v in o.values(in: model.engine.db.pool) { stored = v }
            } catch {}
            await olderSearch
        }
    }

    private func searchOlder() async {
        // Demo mode never contacts Google.
        guard !model.demoMode else { return }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        olderState = .searching
        do {
            let found = try await model.engine.calendar.searchOlder(text, before: olderFrom)
            guard !Task.isCancelled else { return }
            older = found
            olderState = .done
        } catch {
            guard !Task.isCancelled else { return }
            olderState = .failed(error.localizedDescription)
        }
    }

    @ViewBuilder private var olderStatus: some View {
        let year = Calendar.current.component(.year, from: olderFrom) - 5
        switch olderState {
        case .idle:
            if model.demoMode {
                Text("Demo mode searches stored events only.").font(.caption).foregroundStyle(.secondary)
            }
        case .searching:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Searching Google for older events…").font(.caption).foregroundStyle(.secondary)
            }
        case .done:
            Text("Searched back to \(String(year)).").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Label("Older events couldn't be searched: \(message)", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private func row(_ e: CalendarEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(colorFor(e)).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.summary.isEmpty ? "(no title)" : e.summary).font(.body.weight(.medium)).lineLimit(1)
                Text(Self.when(e)).font(.callout).foregroundStyle(.secondary)
                if !e.location.isEmpty {
                    Label(e.location, systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button { onShowDay(e) } label: { Image(systemName: "calendar") }
                .buttonStyle(.borderless).help("Show this day in the calendar")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { onOpen(e) }
        .help("Open “\(e.summary)”")
    }

    /// "Thu 12 Nov 2026, 10:00 – 11:00", or "Thu 12 Nov 2026 · All day".
    static func when(_ e: CalendarEvent) -> String {
        let day = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated).year()
        if e.isAllDay {
            // An all-day event ends at midnight after its last day.
            let last = Calendar.current.date(byAdding: .day, value: -1, to: e.endAt) ?? e.startAt
            if Calendar.current.isDate(last, inSameDayAs: e.startAt) || last < e.startAt { return "\(e.startAt.formatted(day)) · All day" }
            return "\(e.startAt.formatted(day)) – \(last.formatted(day))"
        }
        let time = Date.FormatStyle().hour().minute()
        if Calendar.current.isDate(e.endAt, inSameDayAs: e.startAt) {
            return "\(e.startAt.formatted(day)), \(e.startAt.formatted(time)) – \(e.endAt.formatted(time))"
        }
        return "\(e.startAt.formatted(day)), \(e.startAt.formatted(time)) – \(e.endAt.formatted(day)), \(e.endAt.formatted(time))"
    }
}
