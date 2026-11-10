import SwiftUI
import GRDB
import PostvakCore
import PostvakAI

/// The chat about past meetings. It lives on AppModel, so the conversation survives switching to Mail and back,
/// and every question is saved with its answer, so earlier chats can be read and continued after a restart.
@MainActor
final class AskModel: ObservableObject {
    struct Turn: Identifiable, Equatable {
        var id = UUID()
        let question: String
        var steps: [String] = []
        var answer: String?
        var error: String?
        var askedAt = Date()
        /// The chat it belongs to, so an answer that arrives after switching chats is filed under the right one.
        var chatId = ""
    }

    @Published private(set) var turns: [Turn] = []
    @Published private(set) var busy = false
    /// Earlier chats, newest first.
    @Published private(set) var chats: [AskChatSummary] = []
    /// The chat on screen.
    @Published private(set) var chatId = UUID().uuidString
    private let chat: MeetingChat
    private let history: AskHistory
    private var task: Task<Void, Never>?
    private var observer: Task<Void, Never>?

    init(chat: MeetingChat, history: AskHistory, db: AppDatabase) {
        self.chat = chat
        self.history = history
        let pool = db.pool
        observer = Task { [weak self] in
            let o = ValueObservation.tracking { try AskHistory.chats($0) }
            do { for try await v in o.values(in: pool) { self?.chats = v } } catch {}
        }
    }

    func ask(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !busy else { return }
        var turn = Turn(question: question)
        turn.chatId = chatId
        turns.append(turn)
        save(turn.id)
        busy = true
        let chat = chat
        task = Task { [weak self] in
            do {
                let answer = try await chat.ask(question) { step in
                    Task { @MainActor in self?.update(turn.id) { $0.steps.append(step) } }
                }
                self?.update(turn.id) { $0.answer = answer }
            } catch {
                let stopped = error is CancellationError || (error as? URLError)?.code == .cancelled
                self?.update(turn.id) { $0.error = stopped ? "Stopped." : error.localizedDescription }
            }
            self?.busy = false
        }
    }

    func stop() { task?.cancel() }

    func newChat() {
        task?.cancel()
        task = nil
        turns = []
        busy = false
        chatId = UUID().uuidString
        let chat = chat
        Task { await chat.reset() }
    }

    /// Shows an earlier chat. A follow-up question continues it, with its answers as context.
    func open(_ id: String) {
        guard id != chatId else { return }
        task?.cancel()
        task = nil
        busy = false
        chatId = id
        turns = []
        let history = history, chat = chat
        Task {
            let records = (try? await history.turns(chatId: id)) ?? []
            guard chatId == id else { return }
            turns = records.map {
                Turn(id: UUID(uuidString: $0.id) ?? UUID(), question: $0.question, steps: $0.steps, answer: $0.answer, error: $0.error,
                     askedAt: $0.askedAt, chatId: id)
            }
            await chat.restore(records.compactMap { r in r.answer.map { (question: r.question, answer: $0) } })
        }
    }

    func delete(_ id: String) {
        if id == chatId { newChat() }
        let history = history
        Task { try? await history.deleteChat(id) }
    }

    private func update(_ id: UUID, _ change: (inout Turn) -> Void) {
        guard let i = turns.firstIndex(where: { $0.id == id }) else { return }
        change(&turns[i])
        if turns[i].answer != nil || turns[i].error != nil { save(id) }
    }

    /// Kept when asked, and again once the answer or failure is in.
    private func save(_ id: UUID) {
        guard let t = turns.first(where: { $0.id == id }) else { return }
        let record = AskTurnRecord(id: t.id.uuidString, chatId: t.chatId, question: t.question, answer: t.answer, error: t.error,
                                   steps: t.steps, askedAt: t.askedAt)
        let history = history
        Task { try? await history.save(record) }
    }
}

/// Ask Meetings in a window of its own, to move aside or minimize to the Dock and pick back up.
/// It shares the conversation with Ask Meetings in the main window.
let askWindowId = "ask"

private struct AskWindowKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside the separate Ask Meetings window.
    var isAskWindow: Bool {
        get { self[AskWindowKey.self] }
        set { self[AskWindowKey.self] = newValue }
    }
}

struct AskView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.isAskWindow) private var isAskWindow
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var ask: AskModel
    @State private var draft = ""
    @FocusState private var focused: Bool
    @AppStorage("ask.showHistory") private var showHistory = true

    private let examples = [
        "What did I promise to send after my meetings this week?",
        "What price did I last quote, and to whom?",
        "What did we decide in my last meeting?",
    ]

    var body: some View {
        HStack(spacing: 0) {
            if showHistory {
                AskHistoryList(ask: ask, onOpen: { focused = true }).frame(width: 250)
                Divider()
            }
            chatColumn
        }
        .navigationTitle("Ask Meetings")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showHistory.toggle() } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    .help(showHistory ? "Hide earlier chats" : "Show earlier chats")
            }
            if !isAskWindow {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: popOut) { Label("Open in Separate Window", systemImage: "arrow.up.forward.square") }
                        .help("Open Ask Meetings in its own window (⇧⌘A)")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { ask.newChat(); focused = true } label: { Label("New Chat", systemImage: "square.and.pencil") }
                    .disabled(ask.turns.isEmpty)
                    .help("Start a new conversation. This one stays in History.")
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            // An email cited in an answer opens in a window of its own.
            if url.scheme == "postvak", url.host == "mail" {
                let parts = url.pathComponents.filter { $0 != "/" }
                if parts.count == 2 { openWindow(value: ThreadWindowRef(accountId: parts[0], threadId: parts[1])) }
                return .handled
            }
            guard url.scheme == "postvak", url.host == "meeting" else { return .systemAction }
            model.selectedMeetingId = url.lastPathComponent
            model.destination = .meetings
            // From the separate window, the meeting opens in the main window, which may be closed or behind.
            if isAskWindow { openWindow(id: mainWindowId) }
            return .handled
        })
        .onAppear { focused = true }
    }

    private var chatColumn: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(ask.turns) { t in
                            AskTurnView(turn: t) { ask.ask(t.question) }.id(t.id)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: ask.turns) { _, turns in
                    if let last = turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            .overlay { if ask.turns.isEmpty { emptyState } }
            Divider()
            inputBar
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Ask about your meetings and email").font(.title2.weight(.semibold))
            Text("Answers come from your meetings and your email in every account, with links to the meetings and emails they use.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            VStack(spacing: 8) {
                ForEach(examples, id: \.self) { q in
                    Button(q) { ask.ask(q) }.buttonStyle(.bordered)
                }
            }
            .padding(.top, 6)
        }
        .padding(40)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask about your meetings and email", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit(send)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            if ask.busy {
                Button { ask.stop() } label: { Image(systemName: "stop.circle.fill").font(.title) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Stop")
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Ask")
            }
        }
        .padding(12)
        .frame(maxWidth: 804)
        .frame(maxWidth: .infinity)
    }

    /// The chat moves to its own window, and the main window goes back to the inbox.
    private func popOut() {
        openWindow(id: askWindowId)
        model.destination = .mail(folder: .inbox, accountId: nil, bucket: nil)
    }

    private func send() {
        guard !ask.busy else { return }
        let q = draft
        draft = ""
        ask.ask(q)
    }
}

struct AskTurnView: View {
    let turn: AskModel.Turn
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 120)
                Text(turn.question)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
            }
            if let answer = turn.answer {
                if !turn.steps.isEmpty {
                    DisclosureGroup(turn.steps.count == 1 ? "1 lookup" : "\(turn.steps.count) lookups") { steps }
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(Self.markdown(answer))
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let error = turn.error {
                if !turn.steps.isEmpty { steps }
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled)
                    Button("Ask Again", action: retry).controlSize(.small)
                }
                .font(.callout)
            } else {
                steps
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(turn.steps.isEmpty ? "Thinking" : "Working").foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(turn.steps.enumerated()), id: \.offset) { _, s in
                Label(s, systemImage: s.hasPrefix("Reading") ? "doc.text" : "magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Earlier Ask Meetings chats, newest first, named after their first question. Click one to read it and ask on;
/// right-click or the Delete key removes it.
struct AskHistoryList: View {
    @ObservedObject var ask: AskModel
    var onOpen: () -> Void = {}

    private var selection: Binding<String?> {
        Binding(get: { ask.chatId }, set: { if let id = $0 { ask.open(id); onOpen() } })
    }

    var body: some View {
        List(selection: selection) {
            Section("History") {
                ForEach(ask.chats) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title).lineLimit(2)
                        Text(c.questions == 1 ? DateText.short(c.lastAskedAt) : "\(DateText.short(c.lastAskedAt)) · \(c.questions) questions")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(c.id)
                    .contextMenu {
                        Button("Delete Chat", role: .destructive) { ask.delete(c.id) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand { if ask.chats.contains(where: { $0.id == ask.chatId }) { ask.delete(ask.chatId) } }
        .overlay {
            if ask.chats.isEmpty {
                Text("Your questions are kept here, to read again or ask on.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            }
        }
    }
}
