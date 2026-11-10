import SwiftUI
import AVFoundation
import GRDB
import PostvakCore
import PostvakAudio

struct MeetingsContainerView: View {
    @EnvironmentObject var model: AppModel
    @State private var meetings: [MeetingRecord] = []
    @State private var search = ""
    @State private var hits: [TranscriptHit] = []
    /// Empty for all projects, `unfiled`, or a project name.
    @AppStorage("meetings.projectFilter") private var projectFilter = ""
    @State private var projectNames: [String] = []
    static let unfiled = "\u{1}unfiled"

    var body: some View {
        HSplitView {
            List(selection: $model.selectedMeetingId) {
                if !search.isEmpty {
                    Section("In transcripts") {
                        ForEach(Array(hits.enumerated()), id: \.offset) { _, h in
                            Button { model.selectedMeetingId = h.meetingId } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(h.meetingTitle).font(.caption.weight(.medium)).lineLimit(1)
                                    Text("\(h.speaker): \(h.text)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                ForEach(filtered) { m in
                    MeetingRow(meeting: m).tag(m.id)
                }
            }
            .listStyle(.inset)
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 440)
            .overlay {
                if meetings.isEmpty {
                    ContentUnavailableView("No meetings yet", systemImage: "waveform", description: Text("Record a call or an in-person meeting to start."))
                }
            }

            Group {
                if let id = model.selectedMeetingId {
                    MeetingDetail(meetingId: id).id(id)
                } else {
                    ContentUnavailableView("No meeting selected", systemImage: "waveform")
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Meetings")
        .searchable(text: $search, placement: .toolbar, prompt: "Search meetings and transcripts")
        .toolbar {
            ToolbarItem {
                Picker("Project", selection: $projectFilter) {
                    Text("All Projects").tag("")
                    ForEach(projectNames, id: \.self) { Text($0).tag($0) }
                    Text("Unfiled").tag(Self.unfiled)
                }
                .pickerStyle(.menu)
                .help("Show the meetings of one project")
            }
            ToolbarItemGroup {
                if model.isRecording {
                    Button { model.stopRecording() } label: { Label("Stop Recording", systemImage: "stop.circle.fill") }.tint(.red)
                } else {
                    Menu {
                        Button("Record Call (Mac audio and microphone)") { model.startRecording() }
                        Button("Record In-Person Meeting (microphone)") { model.startRecording(captureSystem: false) }
                    } label: { Label("Record", systemImage: "record.circle") }
                }
            }
        }
        .task {
            let pool = model.engine.db.pool
            let o = ValueObservation.tracking { try MeetingRecord.order(Column("startedAt").desc).limit(500).fetchAll($0) }
            do {
                for try await v in o.values(in: pool) {
                    meetings = v
                    let configured = (try? await model.engine.meetings.projectConfig())?.names ?? []
                    projectNames = configured + Set(v.compactMap(\.project)).subtracting(configured).sorted()
                    if model.demoMode, model.selectedMeetingId == nil { model.selectedMeetingId = v.first?.id }
                }
            } catch {}
        }
        .task(id: search) {
            hits = (try? await model.engine.meetings.search(search, limit: 25)) ?? []
        }
    }

    private var filtered: [MeetingRecord] {
        var list = meetings
        switch projectFilter {
        case "": break
        case Self.unfiled: list = list.filter { $0.project == nil }
        default: list = list.filter { $0.project == projectFilter }
        }
        guard !search.isEmpty else { return list }
        return list.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.attendeesJSON.localizedCaseInsensitiveContains(search) }
    }
}

struct MeetingRow: View {
    let meeting: MeetingRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(meeting.title).fontWeight(.medium).lineLimit(1)
                Spacer()
                statusIcon
            }
            HStack(spacing: 6) {
                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                if let p = meeting.project {
                    Text(p).font(.caption2.weight(.medium)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule()).foregroundStyle(.secondary)
                }
            }
            if !meeting.attendees.isEmpty {
                Text(meeting.attendees.map { $0.name ?? $0.email }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
    @ViewBuilder private var statusIcon: some View {
        switch meeting.status {
        case .recording: Image(systemName: "record.circle.fill").foregroundStyle(.red)
        case .processing, .transcribing, .summarizing: ProgressView().controlSize(.mini)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .ready: EmptyView()
        }
    }
}

struct MeetingDetail: View {
    @EnvironmentObject var model: AppModel
    let meetingId: String
    @State private var meeting: MeetingRecord?
    @State private var summary: MeetingSummaryRecord?
    @State private var rewriting = false
    @State private var segments: [TranscriptSegmentRecord] = []
    @State private var editing = false
    @State private var draft = ""
    @State private var confirmDelete = false
    @State private var showTranscript = false
    @State private var speakers: [MeetingSpeaker] = []
    @State private var candidates: [SpeakerCandidate] = []
    /// The label whose name is being typed.
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var projectNames: [String] = []
    /// The transcript segment (position) a decision or action item was opened at.
    @State private var focusSegment: Int?
    @State private var related: [RelatedThread]?
    /// Threads to pick from when more than one fits the follow-up equally well.
    @State private var followUpChoices: [RelatedThread]?
    @Environment(\.openWindow) private var openWindow
    @StateObject private var player = TwoTrackPlayer()

    var body: some View {
        // The summary is what's usually needed; the transcript opens beside it on request.
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let m = meeting { header(m) }
                    summarySection
                    relatedMailSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 300, idealWidth: 520)

            if showTranscript { transcriptPane }
        }
        .task {
            let id = meetingId
            let pool = model.engine.db.pool
            let o = ValueObservation.tracking { db in
                (try MeetingRecord.fetchOne(db, key: id), try MeetingSummaryRecord.fetchOne(db, key: id),
                 try TranscriptSegmentRecord.filter(Column("meetingId") == id).order(Column("position")).fetchAll(db),
                 try MeetingSpeaker.filter(Column("meetingId") == id).fetchAll(db))
            }
            do {
                for try await (m, s, seg, spk) in o.values(in: pool) {
                    let attendeesChanged = m?.attendeesJSON != meeting?.attendeesJSON
                    meeting = m; summary = s; segments = seg; speakers = spk
                    if attendeesChanged {
                        candidates = (try? await model.engine.meetings.speakerCandidates(meetingId: id)) ?? []
                        related = (try? await model.engine.meetings.relatedThreads(meetingId: id)) ?? []
                    }
                    if let m, m.status != .recording { player.load(mic: m.micAudioPath, system: m.systemAudioPath) }
                }
            } catch {}
        }
        .sheet(item: Binding(get: { followUpChoices.map { ThreadChoices(threads: $0) } }, set: { if $0 == nil { followUpChoices = nil } })) { c in
            FollowUpThreadPicker(threads: c.threads) { picked in
                followUpChoices = nil
                model.draftMeetingFollowUp(meetingId: meetingId, thread: picked)
            } cancel: { followUpChoices = nil }
        }
        .alert("Name for \(renaming ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let label = renaming { rename(label, renameText, nil) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: { Text("Shown in the transcript, summary and action items of this meeting.") }
        .onDisappear { player.pause() }
        .confirmationDialog("Delete this meeting?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                model.selectedMeetingId = nil
                model.perform { try await model.engine.meetings.delete(meetingId) }
            }
        } message: { Text("The audio, transcript and summary are removed from this Mac.") }
    }

    private var transcriptPane: some View {
        VStack(spacing: 0) {
            if let m = meeting, m.micAudioPath != nil || m.systemAudioPath != nil {
                PlayerBar(player: player).padding(8)
                Divider()
            }
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    let names = SpeakerNames.displayNames(speakers)
                    ForEach(segments) { s in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Button { player.seek(to: s.startSeconds) } label: {
                                Text(timestamp(s.startSeconds)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 44, alignment: .trailing)
                            }
                            .buttonStyle(.plain)
                            speakerMenu(s.speaker) {
                                Text(names[s.speaker] ?? s.speaker).font(.caption.weight(.semibold)).foregroundStyle(color(s.speaker)).lineLimit(1)
                            }
                            .frame(width: 96, alignment: .leading)
                            .help("Click to name this speaker")
                            Button { player.seek(to: s.startSeconds) } label: {
                                Text(s.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 1)
                        .background(s.position == focusSegment ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .id(s.position)
                    }
                }
                .padding(14)
            }
            .task(id: focusSegment) {
                guard let f = focusSegment else { return }
                // The pane may have just opened: let the rows lay out first.
                try? await Task.sleep(for: .milliseconds(80))
                withAnimation { proxy.scrollTo(f, anchor: .center) }
            }
            }
            .overlay {
                if segments.isEmpty {
                    ContentUnavailableView("No transcript yet", systemImage: "text.alignleft")
                }
            }
        }
        .frame(minWidth: 340)
    }

    private func header(_ m: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TitleEditor(meeting: m)
            Text(dateLine(m)).font(.caption).foregroundStyle(.secondary)
            if !m.attendees.isEmpty {
                AddressLine(label: "with", addresses: m.attendees.map { GmailParser.recipient(name: $0.name ?? "", email: $0.email) }, accountId: m.eventAccountId)
            }
            if m.eventId != nil { Label("Linked to its calendar event", systemImage: "calendar").font(.caption).foregroundStyle(.secondary) }
            projectLine(m)
            speakersSection
            statusLine(m)
            HStack {
                Button(showTranscript ? "Hide Transcript" : (segments.isEmpty ? "Show Transcript" : "Show Transcript (\(segments.count) lines)")) {
                    showTranscript.toggle()
                    if !showTranscript { player.pause() }
                }
                Button { draftFollowUp() } label: {
                    Label(model.draftingFollowUps.contains(m.id) ? "Writing Follow-up…" : "Write Follow-up Email", systemImage: "envelope.badge")
                }
                .buttonStyle(.borderedProminent)
                .disabled(summary == nil || !m.attendees.contains { !$0.isSelf } || model.draftingFollowUps.contains(m.id))
                .help(summary == nil ? "Write the summary first" : "A reply in the thread with the guests, or a new mail, opened as a draft. Nothing is sent.")
                Menu("Actions") {
                    Button("Transcribe Again On This Mac") { model.perform { await model.pipeline.enqueue(meetingId: m.id) } }
                        .disabled(m.micAudioPath == nil && m.systemAudioPath == nil)
                    Button("Transcribe With Deepgram (sends audio to Deepgram)") { model.perform { await model.pipeline.enqueue(meetingId: m.id, useCloud: true) } }
                        .disabled(m.micAudioPath == nil && m.systemAudioPath == nil)
                    Button("Write Summary Again") { model.perform { try await model.summarizer.summarize(meetingId: m.id) } }
                        .disabled(segments.isEmpty)
                    Divider()
                    Button("Delete Meeting", role: .destructive) { confirmDelete = true }
                }
                .fixedSize()
            }
        }
    }

    @ViewBuilder private func statusLine(_ m: MeetingRecord) -> some View {
        switch m.status {
        case .ready:
            if let d = m.statusDetail { Label(d, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
        case .failed:
            Label(m.statusDetail ?? "Processing failed.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        case .recording:
            Label("Recording", systemImage: "record.circle.fill").font(.caption).foregroundStyle(.red)
        default:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(m.statusDetail ?? "Working").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func dateLine(_ m: MeetingRecord) -> String {
        var s = m.startedAt.formatted(date: .complete, time: .shortened)
        if let e = m.endedAt { s += ", \(Int(e.timeIntervalSince(m.startedAt) / 60)) min" }
        if let l = m.language { s += ", \(l)" }
        if m.source != "recorded" { s += ", imported from \(m.source)" }
        return s
    }

    @ViewBuilder private var summarySection: some View {
        if let s = summary {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Summary").font(.headline)
                    Spacer()
                    if let m = meeting, !editing, !segments.isEmpty {
                        // Rewrites the summary at the other length; the meeting keeps that choice.
                        Button(rewriting ? "Writing…" : (m.detailedSummary ? "Shorter" : "More Detail")) {
                            let id = meetingId, longer = !m.detailedSummary
                            rewriting = true
                            Task {
                                do { try await model.summarizer.summarize(meetingId: id, detailed: longer) }
                                catch {
                                    model.logFailure("Rewriting the summary", error)
                                    model.toast("The summary couldn't be rewritten: \(error.localizedDescription)", kind: .error, seconds: 10)
                                }
                                rewriting = false
                            }
                        }
                        .buttonStyle(.link).font(.caption).disabled(rewriting)
                        .help(m.detailedSummary ? "Write the short summary again" : "Write a longer summary, topic by topic, with the arguments and figures")
                    }
                    Button(editing ? "Save" : "Edit") {
                        if editing {
                            let text = draft
                            model.perform { try await model.engine.meetings.updateSummaryText(meetingId: meetingId, summary: text) }
                        } else { draft = s.summary }
                        editing.toggle()
                    }
                    .buttonStyle(.link).font(.caption)
                }
                if editing { TextEditor(text: $draft).frame(minHeight: 160).border(.separator) }
                else { SummaryText(text: s.summary) }
            }
            decisionsSection(s)
            if !s.actionItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Action items").font(.headline)
                    ForEach(s.actionItems, id: \.self) { a in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: a.status == .suggested ? "circle.dashed" : "circle").font(.caption2).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.task).textSelection(.enabled)
                                HStack(spacing: 6) {
                                    if let st = a.status {
                                        Text(st == .agreed ? "Agreed" : "Suggested").font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background((st == .agreed ? Color.green : Color.orange).opacity(0.18), in: Capsule())
                                            .foregroundStyle(st == .agreed ? Color.green : Color.orange)
                                    }
                                    let meta = [a.owner, a.due].compactMap { $0 }.joined(separator: ", ")
                                    if !meta.isEmpty { Text(meta).font(.caption).foregroundStyle(.secondary) }
                                    sourceLink(a.segment, expected: a.status != nil)
                                }
                            }
                        }
                    }
                }
            }
            list("Open questions", s.openQuestions)
        } else if !segments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No summary yet.").foregroundStyle(.secondary)
                Button("Write Summary") { model.perform { try await model.summarizer.summarize(meetingId: meetingId) } }
            }
        }
    }

    @ViewBuilder private func decisionsSection(_ s: MeetingSummaryRecord) -> some View {
        let items = s.decisionItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Decisions").font(.headline)
                ForEach(items, id: \.self) { d in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("• \(d.text)").textSelection(.enabled)
                        sourceLink(d.segment, expected: false)
                    }
                }
            }
        } else if s.model.hasPrefix("claude") {
            // Claude was told to list only real decisions, so an empty list means none were taken.
            VStack(alignment: .leading, spacing: 4) {
                Text("Decisions").font(.headline)
                Text("No decision taken").foregroundStyle(.secondary)
            }
        }
    }

    /// The moment in the transcript a point comes from. Opens the transcript there and plays from it.
    @ViewBuilder private func sourceLink(_ position: Int?, expected: Bool) -> some View {
        if let position, let seg = segments.first(where: { $0.position == position }) {
            Button {
                showTranscript = true
                focusSegment = position
                player.seek(to: seg.startSeconds)
            } label: {
                Label(timestamp(seg.startSeconds), systemImage: "text.quote").font(.caption.monospacedDigit())
            }
            .buttonStyle(.link)
            .help("“\(seg.text.prefix(160))”")
        } else if expected, !segments.isEmpty {
            Text("no source in the transcript").font(.caption2).foregroundStyle(.orange)
        }
    }

    @ViewBuilder private func list(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                ForEach(items, id: \.self) { Text("• \($0)").textSelection(.enabled) }
            }
        }
    }

    // MARK: follow-up

    private func draftFollowUp() {
        let id = meetingId
        model.perform {
            switch try await model.followUpTarget(meetingId: id) {
            case .reply(let t): model.draftMeetingFollowUp(meetingId: id, thread: t)
            case .new: model.draftMeetingFollowUp(meetingId: id, thread: nil)
            case .choose(let list): followUpChoices = list
            }
        }
    }

    // MARK: related mail

    /// Mail sent and received with the guests around the meeting, newest first, those with the guests themselves on top.
    @ViewBuilder private var relatedMailSection: some View {
        if let related, meeting?.attendees.contains(where: { !$0.isSelf }) == true {
            VStack(alignment: .leading, spacing: 5) {
                Text("Related email").font(.headline)
                if related.isEmpty {
                    Text("No mail with these guests between \(RelatedMail.daysBefore) days before and \(RelatedMail.daysAfter) days after the meeting.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(related) { t in
                    Button { openWindow(value: ThreadWindowRef(accountId: t.accountId, threadId: t.threadId)) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: t.lastFromMe ? "arrow.up.right" : "arrow.down.left").font(.caption)
                                .foregroundStyle(t.lastFromMe ? Color.accentColor : .green)
                                .help(t.lastFromMe ? "You wrote last" : "They wrote last")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.subject.isEmpty ? "(no subject)" : t.subject).lineLimit(1)
                                Text(relatedDetail(t)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func relatedDetail(_ t: RelatedThread) -> String {
        var parts = [t.lastAt.formatted(date: .abbreviated, time: .omitted)]
        if t.sent > 0 { parts.append("\(t.sent) sent") }
        if t.received > 0 { parts.append("\(t.received) received") }
        if t.guestsInThread == 0 { parts.append("colleagues of the guests") }
        parts.append(t.accountId)
        return parts.joined(separator: " · ")
    }

    // MARK: project

    private func projectLine(_ m: MeetingRecord) -> some View {
        let how: String = switch m.projectSource {
        case "manual": "set by you"
        case "rules": "from the attendees"
        case "mail": "from where the mail with these people is"
        case "import": "from its folder in the imported notes"
        default: ""
        }
        return HStack(spacing: 6) {
            Image(systemName: "folder").font(.caption).foregroundStyle(.secondary)
            Menu {
                ForEach(projectNames, id: \.self) { p in
                    Button(p) { setProject(p, manual: true) }
                }
                Button("Unfiled") { setProject(nil, manual: true) }
                if m.projectSource == "manual" {
                    Divider()
                    Button("File Automatically") { setProject(nil, manual: false) }
                }
            } label: {
                Text(m.project ?? "Unfiled").font(.caption.weight(.medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            if !how.isEmpty { Text(how).font(.caption2).foregroundStyle(.tertiary) }
        }
        .task { projectNames = (try? await model.engine.meetings.projectConfig())?.names ?? [] }
    }

    private func setProject(_ p: String?, manual: Bool) {
        let id = meetingId
        model.perform { try await model.engine.meetings.setProject(meetingId: id, project: p, manual: manual) }
    }

    // MARK: speakers

    /// Labels in the order they first speak.
    private var speakerLabels: [String] {
        var seen = Set<String>()
        return segments.map(\.speaker).filter { seen.insert($0).inserted }
    }

    @ViewBuilder private var speakersSection: some View {
        let labels = speakerLabels
        if !labels.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Speakers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(labels, id: \.self) { label in
                    let row = speakers.first { $0.label == label }
                    HStack(spacing: 6) {
                        Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                        speakerMenu(label) {
                            Text(row?.isApplied == true ? row!.name : "Name…").font(.caption.weight(.medium))
                                .foregroundStyle(row?.isApplied == true ? color(label) : .secondary)
                        }
                        .fixedSize()
                        if let row, row.source == .suggested {
                            Text("Probably \(row.name)?").font(.caption).foregroundStyle(.orange)
                            Button("Confirm") { rename(label, row.name, row.email) }.buttonStyle(.link).font(.caption)
                            Button { model.perform { try await model.engine.meetings.dismissSpeakerSuggestion(meetingId: meetingId, label: label) } } label: {
                                Image(systemName: "xmark").font(.caption2)
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Not this person")
                        } else if row?.source == .auto {
                            Text("from the calendar").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// A speaker's name that opens a menu: one of the meeting's people, a typed name, or no name.
    private func speakerMenu<L: View>(_ label: String, @ViewBuilder _ content: () -> L) -> some View {
        let row = speakers.first { $0.label == label }
        return Menu {
            ForEach(candidates, id: \.self) { c in
                Button(c.email.map { "\(c.name) (\($0))" } ?? c.name) { rename(label, c.name, c.email) }
            }
            if !candidates.isEmpty { Divider() }
            Button("Other Name…") { renameText = row?.isApplied == true ? row!.name : ""; renaming = label }
            if row?.isApplied == true { Button("Remove Name") { rename(label, nil, nil) } }
        } label: { content() }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private func rename(_ label: String, _ name: String?, _ email: String?) {
        let id = meetingId
        model.perform { try await model.engine.meetings.renameSpeaker(meetingId: id, label: label, name: name, email: email) }
    }

    private func timestamp(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    private func color(_ speaker: String) -> Color {
        if speaker == "Me" { return .accentColor }
        let palette: [Color] = [.green, .orange, .purple, .pink, .teal, .brown]
        return palette[abs(speaker.unicodeScalars.reduce(0) { $0 + Int($1.value) }) % palette.count]
    }
}

struct TitleEditor: View {
    @EnvironmentObject var model: AppModel
    let meeting: MeetingRecord
    @State private var text = ""
    var body: some View {
        TextField("Title", text: $text)
            .textFieldStyle(.plain).font(.title2.weight(.semibold))
            .onSubmit {
                var m = meeting
                m.title = text
                model.perform { try await model.engine.meetings.save(m) }
            }
            .onAppear { text = meeting.title }
            .onChange(of: meeting.title) { _, v in text = v }
    }
}

/// Plays both recorded tracks in step.
@MainActor
final class TwoTrackPlayer: ObservableObject {
    @Published var isPlaying = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    private var players: [AVPlayer] = []
    private var loaded: [String] = []
    /// How much later each track started than the first one (the microphone), so a seek lands on the same moment in both.
    private var offsets: [Double] = []
    private var observer: Any?

    func load(mic: String?, system: String?) {
        let paths = [mic, system].compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0) && !$0.hasSuffix(".caf") }
        guard paths != loaded else { return }
        loaded = paths
        pause()
        if let observer, let first = players.first { first.removeTimeObserver(observer) }
        observer = nil
        players = paths.map { AVPlayer(url: URL(fileURLWithPath: $0)) }
        offsets = paths.map { _ in 0 }
        if paths.count == 2 {
            offsets[1] = AudioFiles.callOffset(mic: URL(fileURLWithPath: paths[0]), system: URL(fileURLWithPath: paths[1]))
        }
        guard let first = players.first else { duration = 0; return }
        observer = first.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                self?.position = t.seconds
                if let d = first.currentItem?.duration.seconds, d.isFinite { self?.duration = d }
            }
        }
    }

    func toggle() { isPlaying ? pause() : play() }
    func play() { players.forEach { $0.play() }; isPlaying = !players.isEmpty }
    func pause() { players.forEach { $0.pause() }; isPlaying = false }
    func seek(to s: Double) {
        for (p, offset) in zip(players, offsets) {
            p.seek(to: CMTime(seconds: max(0, s - offset), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        position = s
        if !players.isEmpty && !isPlaying { play() }
    }
}

struct PlayerBar: View {
    @ObservedObject var player: TwoTrackPlayer
    var body: some View {
        HStack(spacing: 10) {
            Button(action: player.toggle) { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }.buttonStyle(.plain)
            Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }), in: 0...max(1, player.duration))
            Text("\(fmt(player.position)) / \(fmt(player.duration))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
    private func fmt(_ s: Double) -> String {
        guard s.isFinite else { return "0:00" }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

struct ThreadChoices: Identifiable {
    let threads: [RelatedThread]
    var id: String { threads.map(\.id).joined(separator: "|") }
}

/// Several threads with the guests fit the follow-up equally well: the user picks one, or a new mail.
struct FollowUpThreadPicker: View {
    let threads: [RelatedThread]
    let pick: (RelatedThread?) -> Void
    let cancel: () -> Void
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reply in which thread?").font(.headline)
            Text("More than one conversation with these guests fits. The follow-up is saved as a draft; nothing is sent.")
                .font(.callout).foregroundStyle(.secondary)
            List(threads, selection: $selection) { t in
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.subject.isEmpty ? "(no subject)" : t.subject).lineLimit(1)
                    Text("\(t.lastAt.formatted(date: .abbreviated, time: .shortened)) · \(t.sent + t.received) messages · \(t.accountId)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(t.id)
            }
            .frame(minHeight: 160)
            HStack {
                Button("New Email Instead") { pick(nil) }
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Draft Reply") { pick(threads.first { $0.id == selection }) }
                    .keyboardShortcut(.defaultAction).disabled(selection == nil)
            }
        }
        .padding(18)
        .frame(width: 480)
        .onAppear { selection = threads.first?.id }
    }
}
