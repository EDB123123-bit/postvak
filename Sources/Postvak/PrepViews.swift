import SwiftUI
import PostvakCore
import PostvakAI

extension AppModel {
    /// The brief for a meeting: the kept one, or a new one written from the latest mail and meetings.
    func prepBrief(for e: CalendarEvent, refresh: Bool = false) async throws -> String {
        if !refresh, let kept = try await prepBriefs.cached(e) { return kept.text }
        let context = try await prepBriefs.context(for: e)
        let text = try await prepWriter.brief(for: e, context: context)
        try await prepBriefs.save(e, text: text)
        return text
    }

    /// The first time Postvak comes to the front each day, today's meetings with their briefs.
    func maybeShowMorningOverview() async {
        guard !demoMode, !showMorningOverview, !showOnboarding else { return }
        let key = "morning.lastShown"
        let today = Calendar.current.startOfDay(for: Date())
        if let last = UserDefaults.standard.object(forKey: key) as? Date, last >= today { return }
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let events = (try? await engine.calendar.events(from: Date(), to: tomorrow)) ?? []
        guard events.contains(where: PrepBriefs.wantsBrief) else { return }
        UserDefaults.standard.set(Date(), forKey: key)
        showMorningOverview = true
    }
}

/// A meeting's prep brief: written the first time it is shown, kept after that, and rewritten on request.
struct PrepBriefView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let event: CalendarEvent
    /// Runs before a link opens something elsewhere, for example to close the sheet the brief sits in.
    var beforeOpening: () -> Void = {}
    @State private var text: String?
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Prep", systemImage: "list.bullet.clipboard").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if text != nil, !loading {
                    Button { Task { await load(refresh: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Write it again with the latest mail and meetings")
                }
            }
            if !model.claude.hasKey {
                Text("Add your Claude API key in Settings to get a brief before each meeting.").font(.callout).foregroundStyle(.secondary)
            } else if loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading your mail and meetings with these guests…").font(.callout).foregroundStyle(.secondary)
                }
            } else if let failure {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(failure).font(.callout).lineLimit(3)
                    Button("Try Again") { Task { await load(refresh: true) } }.controlSize(.small)
                }
            } else if let text {
                Text(AskTurnView.markdown(text)).font(.callout).lineSpacing(2).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "postvak" else { return .systemAction }
            let parts = url.pathComponents.filter { $0 != "/" }
            if url.host == "mail", parts.count == 2 {
                openWindow(value: ThreadWindowRef(accountId: parts[0], threadId: parts[1]))
            } else if url.host == "meeting", let id = parts.first {
                beforeOpening()
                model.selectedMeetingId = id
                model.destination = .meetings
                model.reopenMainWindow?()
            }
            return .handled
        })
        .task(id: event.id) { await load(refresh: false) }
    }

    private func load(refresh: Bool) async {
        guard model.claude.hasKey else { return }
        loading = true
        failure = nil
        defer { loading = false }
        do { text = try await model.prepBrief(for: event, refresh: refresh) }
        catch { failure = error.localizedDescription }
    }
}

/// Today's meetings with other guests, each with its brief. Shown the first time Postvak opens each day.
struct MorningOverview: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var events: [CalendarEvent] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today's meetings").font(.title2.weight(.semibold))
                    Text(Date().formatted(date: .complete, time: .omitted)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if loaded && events.isEmpty {
                        Text("No more meetings with other people today.").foregroundStyle(.secondary)
                    }
                    ForEach(events) { e in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(e.startAt.formatted(date: .omitted, time: .shortened))–\(e.endAt.formatted(date: .omitted, time: .shortened))")
                                    .monospacedDigit().foregroundStyle(.secondary)
                                model.badge(e.accountId, size: 15)
                                Text(e.summary).font(.headline)
                            }
                            PrepBriefView(event: e, beforeOpening: { dismiss() })
                                .padding(12)
                                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 600, height: 680)
        .task {
            let today = Calendar.current.startOfDay(for: Date())
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
            let all = (try? await model.engine.calendar.events(from: Date(), to: tomorrow)) ?? []
            events = all.filter(PrepBriefs.wantsBrief)
            loaded = true
        }
    }
}
