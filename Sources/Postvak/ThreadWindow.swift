import SwiftUI
import GRDB
import PostvakCore

/// Identifies a thread opened in its own window. Opening the same thread again brings its window forward.
struct ThreadWindowRef: Hashable, Codable {
    let accountId: String
    let threadId: String

    init(_ thread: MailThread) {
        accountId = thread.accountId
        threadId = thread.threadId
    }

    init(accountId: String, threadId: String) {
        self.accountId = accountId
        self.threadId = threadId
    }
}

// Written out by hand: the @Entry macro needs a plugin that only ships with full Xcode.
private struct ThreadWindowKey: EnvironmentKey {
    static let defaultValue: ThreadWindowRef? = nil
}

extension EnvironmentValues {
    /// The popped-out window a view lives in. Nil in the main window.
    var threadWindow: ThreadWindowRef? {
        get { self[ThreadWindowKey.self] }
        set { self[ThreadWindowKey.self] = newValue }
    }
}

/// A single thread in a window of its own, to move to another screen or keep beside the inbox.
struct ThreadWindowView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let ref: ThreadWindowRef
    @State private var thread: MailThread?
    @State private var loaded = false
    @State private var focusedMessage: String?
    @State private var snoozeTarget: MailThread?
    @State private var didSnooze = false

    var body: some View {
        // A ZStack, because a Group with nothing in it yet would never start the task below.
        ZStack {
            if let thread {
                ReadingPane(thread: thread, focusedMessage: $focusedMessage,
                            onSnooze: { snoozeTarget = thread }, onLeave: { dismiss() })
            } else if loaded {
                ContentUnavailableView("This mail is no longer here", systemImage: "envelope.open")
            }
        }
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .navigationTitle(thread?.subject ?? "Mail")
        .environment(\.threadWindow, ref)
        .overlay(alignment: .bottom) { ToastStack().padding(.bottom, 20) }
        .sheet(item: $snoozeTarget, onDismiss: { if didSnooze { dismiss() } }) { t in
            SnoozeSheet(thread: t, onSnoozed: { didSnooze = true }).environmentObject(model)
        }
        .background {
            KeyMonitor { key in
                model.handleThreadKey(key, thread: thread, onSnooze: { snoozeTarget = $0 }, onLeave: { dismiss() })
            }
        }
        .onAppear { model.openThreadWindows.insert(ref) }
        .onDisappear { model.openThreadWindows.remove(ref) }
        .task {
            let key = ["accountId": ref.accountId, "threadId": ref.threadId]
            let o = ValueObservation.tracking { try MailThread.fetchOne($0, key: key) }
            do {
                for try await v in o.values(in: model.engine.db.pool) {
                    thread = v
                    loaded = true
                }
            } catch {}
        }
    }
}

extension AppModel {
    /// Single-key commands on an open thread, shared by the main window and popped-out windows.
    /// Returns true when the key was used. `onLeave` runs when the thread leaves the current view.
    func handleThreadKey(_ key: String, thread: MailThread?, onSnooze: (MailThread) -> Void, onLeave: () -> Void) -> Bool {
        let mail = engine.mail
        switch key {
        case "e":
            if let t = thread {
                perform { try await mail.archive(accountId: t.accountId, threadId: t.threadId) }
                onLeave()
            }
        case "#", "delete":
            if let t = thread {
                perform { try await mail.trash(accountId: t.accountId, threadId: t.threadId) }
                onLeave()
            }
        case "u":
            if let t = thread { perform { try await mail.markRead(accountId: t.accountId, threadId: t.threadId, read: t.isUnread) } }
        case "s":
            if let t = thread { onSnooze(t) }
        case "c":
            compose()
        case "r", "a":
            if let t = thread { replyLatest(in: t, all: key == "a") }
        case "f":
            if let t = thread { forwardLatest(in: t) }
        default:
            return false
        }
        return true
    }

    private func replyLatest(in t: MailThread, all: Bool) {
        Task {
            guard let d = try? await engine.mail.detail(accountId: t.accountId, threadId: t.threadId),
                  let m = d.messages.last(where: { !$0.isDraft }) else { return }
            reply(to: m, replyAll: all)
        }
    }

    private func forwardLatest(in t: MailThread) {
        Task {
            guard let d = try? await engine.mail.detail(accountId: t.accountId, threadId: t.threadId),
                  let m = d.messages.last(where: { !$0.isDraft }) else { return }
            forward(m, attachments: d.attachments[m.messageId] ?? [])
        }
    }
}
