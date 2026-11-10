import SwiftUI
import AppKit
import Combine
import PostvakCore

/// One mail being written. Its window, the sidebar's list of minimized mails and the close question
/// all read this, so they see the text as it is now, not as it was when the composer opened.
@MainActor
final class ComposerDraft: ObservableObject, Identifiable {
    let id = UUID()
    @Published var state: ComposerState
    @Published var saving = false
    /// True while the mail is checked before sending.
    @Published var checking = false
    /// What the check found. Shown before sending, with Fix and Send Anyway.
    @Published var findings: [String] = []
    private var heldSend: Date??
    /// The last send or save failure, shown inside the composer so it can't hide behind another window.
    @Published var error: String?
    private let initial: ComposerState
    private unowned let model: AppModel
    /// Closes the window once the mail was sent, saved or discarded.
    var finish: () -> Void = {}

    init(state: ComposerState, model: AppModel) {
        self.state = state
        self.initial = state
        self.model = model
    }

    var title: String { Self.title(for: state) }

    nonisolated static func title(for s: ComposerState) -> String {
        let t = s.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "New Mail" : t
    }

    /// Changed since it opened, so closing it now would lose something.
    var isEdited: Bool {
        let a = state, b = initial
        return a.accountId != b.accountId || a.fromEmail != b.fromEmail || a.to != b.to || a.cc != b.cc || a.bcc != b.bcc || a.subject != b.subject
            || a.body.string != b.body.string || a.attachments.map(\.path) != b.attachments.map(\.path)
            || (a.booking == nil) != (b.booking == nil)
    }

    /// Checks the mail first. With nothing found it goes straight into the undo window.
    func send(at date: Date?) {
        guard !checking else { return }
        error = nil
        checking = true
        let s = state
        Task {
            let found = await model.checkBeforeSending(s)
            checking = false
            if found.isEmpty {
                deliver(at: date)
            } else {
                heldSend = .some(date)
                findings = found
            }
        }
    }

    func sendAnyway() {
        guard case .some(let date) = heldSend else { return }
        heldSend = nil
        findings = []
        deliver(at: date)
    }

    func fixFindings() {
        heldSend = nil
        findings = []
    }

    private func deliver(at date: Date?) {
        let s = state
        Task {
            do {
                try await model.send(s, sendAt: date)
                finish()
                model.keepUndoInReach()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func saveDraft() {
        saving = true
        error = nil
        let i = state.composeInput()
        Task {
            defer { saving = false }
            do {
                let d = try await model.engine.mail.saveDraft(i)
                state.draftId = d.draftId
                state.draftThreadId = d.threadId
                await model.retireReplaced(state)
                model.toast("Draft saved to Gmail.")
                finish()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func discard() {
        if let id = state.draftId {
            let a = state.accountId, t = state.draftThreadId, mail = model.engine.mail
            model.perform { try await mail.deleteDraft(accountId: a, draftId: id, threadId: t) }
        }
        let s = state
        Task { await model.retireReplaced(s) }
        finish()
    }
}

/// A composer in a window of its own: it can be dragged anywhere, onto another screen too,
/// and minimized to the Dock (⌘M or the yellow button) to pick back up later.
final class ComposerWindow: NSWindow {
    let draft: ComposerDraft
    private var titleWatch: AnyCancellable?

    @MainActor
    init(draft: ComposerDraft, content: NSViewController) {
        self.draft = draft
        super.init(contentRect: NSRect(x: 0, y: 0, width: 760, height: 660),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        contentViewController = content
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        title = draft.title
        // The subject names the window in the Dock, the Window menu and Mission Control.
        titleWatch = draft.$state.map { ComposerDraft.title(for: $0) }.removeDuplicates()
            .sink { [weak self] in self?.title = $0 }
    }

    @MainActor
    func bringForward() {
        if isMiniaturized { deminiaturize(nil) }
        makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Open composers with text that isn't sent or saved anywhere yet.
    @MainActor
    static var unsaved: [ComposerWindow] {
        NSApp.windows.compactMap { $0 as? ComposerWindow }.filter { ($0.isVisible || $0.isMiniaturized) && $0.draft.isEdited }
    }
}

/// Every open composer. Several mails can be open at once, so one can wait minimized while you write another.
@MainActor
final class ComposerWindows: NSObject, ObservableObject, NSWindowDelegate {
    /// Composers minimized to the Dock, also listed in the sidebar.
    @Published private(set) var minimized: [ComposerDraft] = []
    private var windows: [ComposerWindow] = []
    private unowned let model: AppModel
    /// Where the last composer was moved or resized to. The next one opens there.
    private static let frameKey = "composer.frame"

    init(model: AppModel) {
        self.model = model
    }

    func open(_ state: ComposerState) {
        // The same Gmail draft or queued mail comes forward instead of opening twice.
        if let w = windows.first(where: { Self.same($0.draft.state, state) }) {
            w.bringForward()
            return
        }
        let draft = ComposerDraft(state: state, model: model)
        let hosting = NSHostingController(rootView: ComposerView(draft: draft).environmentObject(model))
        hosting.sizingOptions = [.minSize]
        let w = ComposerWindow(draft: draft, content: hosting)
        w.setFrame(startFrame(), display: false)
        draft.finish = { [weak self, weak w] in
            guard let self, let w else { return }
            self.forget(w)
            w.close()
        }
        // Only after placing it, so its own opening position isn't remembered as a move.
        w.delegate = self
        windows.append(w)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func restore(_ draft: ComposerDraft) {
        windows.first { $0.draft === draft }?.bringForward()
    }

    /// True while a composer is editing this queued mail.
    func isEditing(outboxId: String) -> Bool {
        windows.contains { $0.draft.state.replacesOutboxId == outboxId }
    }

    /// Brings forward the composer editing this queued mail. False when none is open.
    @discardableResult
    func bringForward(outboxId: String) -> Bool {
        guard let w = windows.first(where: { $0.draft.state.replacesOutboxId == outboxId }) else { return false }
        w.bringForward()
        return true
    }

    private static func same(_ a: ComposerState, _ b: ComposerState) -> Bool {
        if let d = b.draftId, a.draftId == d { return true }
        if let o = b.replacesOutboxId, a.replacesOutboxId == o { return true }
        return false
    }

    private func forget(_ w: ComposerWindow) {
        windows.removeAll { $0 === w }
        minimized.removeAll { $0 === w.draft }
    }

    /// Where the composer was last put, or else centred over the window it was started from.
    /// A second one opens a little lower and to the right, so it never hides the first exactly.
    private func startFrame() -> NSRect {
        let size = NSSize(width: 760, height: 660)
        var f: NSRect
        if let s = UserDefaults.standard.string(forKey: Self.frameKey), case let saved = NSRectFromString(s),
           saved.width >= 300, saved.height >= 300, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
            f = saved
        } else {
            let over = NSApp.keyWindow?.frame ?? NSApp.mainWindow?.frame ?? NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: size)
            f = NSRect(x: over.midX - size.width / 2, y: over.midY - size.height / 2, width: size.width, height: size.height)
        }
        while windows.contains(where: { $0.isVisible && abs($0.frame.minX - f.minX) < 8 && abs($0.frame.maxY - f.maxY) < 8 }) {
            f = f.offsetBy(dx: 24, dy: -24)
        }
        if let v = (NSScreen.screens.first { $0.visibleFrame.intersects(f) } ?? NSScreen.main)?.visibleFrame {
            f.size.width = min(f.width, v.width)
            f.size.height = min(f.height, v.height)
            f.origin.x = min(max(f.minX, v.minX), v.maxX - f.width)
            f.origin.y = min(max(f.minY, v.minY), v.maxY - f.height)
        }
        return f
    }

    private func remember(_ n: Notification) {
        guard let w = n.object as? ComposerWindow, !w.isMiniaturized else { return }
        UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: Self.frameKey)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let w = sender as? ComposerWindow, w.draft.isEdited else { return true }
        let a = NSAlert()
        a.messageText = "Save this mail as a draft?"
        a.informativeText = "A saved draft stays in Gmail under Drafts. If you don't save, your changes are lost."
        a.addButton(withTitle: "Save Draft")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Don't Save")
        a.beginSheetModal(for: w) { [weak self, weak w] r in
            guard let w else { return }
            switch r {
            case .alertFirstButtonReturn:
                w.draft.saveDraft()
            case .alertThirdButtonReturn:
                // Leaves an existing Gmail draft or queued mail as it was.
                self?.model.releaseQueued(w.draft.state)
                self?.forget(w)
                w.close()
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? ComposerWindow else { return }
        // Still listed means it closed without being sent, saved or discarded (those forget it first),
        // so a queued mail it was editing goes back to how it was.
        if windows.contains(where: { $0 === w }) { model.releaseQueued(w.draft.state) }
        forget(w)
    }

    func windowDidMiniaturize(_ n: Notification) {
        guard let w = n.object as? ComposerWindow, !minimized.contains(where: { $0 === w.draft }) else { return }
        minimized.append(w.draft)
    }

    func windowDidDeminiaturize(_ n: Notification) {
        guard let w = n.object as? ComposerWindow else { return }
        minimized.removeAll { $0 === w.draft }
    }

    func windowDidMove(_ n: Notification) { remember(n) }
    func windowDidEndLiveResize(_ n: Notification) { remember(n) }
}

/// The bottom of the sidebar: composers minimized to the Dock, where one click brings a mail back, then the sync status.
struct SidebarFooter: View {
    @ObservedObject var composers: ComposerWindows

    var body: some View {
        let minimized = composers.minimized
        VStack(alignment: .leading, spacing: 0) {
            if !minimized.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Still writing").font(.caption).foregroundStyle(.secondary)
                    ForEach(minimized) { d in
                        MinimizedComposerRow(draft: d) { composers.restore(d) }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 8)
            }
            SyncStatusBar()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The sidebar list scrolls underneath, so it needs a backing once it lists anything.
        .background { if !minimized.isEmpty { Rectangle().fill(.regularMaterial) } }
    }
}

private struct MinimizedComposerRow: View {
    @ObservedObject var draft: ComposerDraft
    let restore: () -> Void

    var body: some View {
        Button(action: restore) {
            Label(draft.title, systemImage: "square.and.pencil")
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Pick this mail back up")
    }
}
