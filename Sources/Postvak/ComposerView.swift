import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PostvakCore

/// Takes pictures into the text: pasted ones (a screenshot, an image copied from a browser or Preview) and
/// picture files pasted or dropped in. Other files go to the mail's attachments instead of into the text.
final class ComposerTextView: NSTextView {
    var onFiles: ([URL]) -> Void = { _ in }

    override func readSelection(from pboard: NSPasteboard) -> Bool {
        if insertFiles(from: pboard) || insertImage(from: pboard) { return true }
        return super.readSelection(from: pboard)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if type == .fileURL, insertFiles(from: pboard) { return true }
        if type == .png || type == .tiff, insertImage(from: pboard) { return true }
        return super.readSelection(from: pboard, type: type)
    }

    private func insertFiles(from pboard: NSPasteboard) -> Bool {
        guard let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        var others: [URL] = []
        for url in urls {
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true, let img = NSImage(contentsOf: url) {
                insert(img)
            } else {
                others.append(url)
            }
        }
        if !others.isEmpty { onFiles(others) }
        return true
    }

    /// A picture on its own. Rich text that carries its own pictures pastes as it is.
    private func insertImage(from pboard: NSPasteboard) -> Bool {
        let types = pboard.types ?? []
        guard !types.contains(.rtf), !types.contains(.rtfd), types.contains(.png) || types.contains(.tiff),
              let img = NSImage(pasteboard: pboard) else { return false }
        insert(img)
        return true
    }

    /// Shown no wider than the mail will show it.
    func insert(_ image: NSImage) {
        let att = NSTextAttachment()
        att.image = image
        let scale = min(1, RichTextHTML.maxImageWidth / max(image.size.width, 1))
        att.bounds = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
        let piece = NSMutableAttributedString(attachment: att)
        piece.addAttributes(typingAttributes, range: NSRange(location: 0, length: piece.length))
        let r = selectedRange()
        guard shouldChangeText(in: r, replacementString: piece.string) else { return }
        textStorage?.replaceCharacters(in: r, with: piece)
        didChangeText()
        setSelectedRange(NSRange(location: r.location + piece.length, length: 0))
    }
}

struct RichTextEditor: NSViewRepresentable {
    @Binding var text: NSAttributedString
    /// Files dropped or pasted into the text that aren't pictures.
    var onFiles: ([URL]) -> Void = { _ in }
    /// The formatting bar above the text.
    var formatting: ComposerFormatting?

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        init(_ p: RichTextEditor) { parent = p }
        func textDidChange(_ n: Notification) {
            if let v = n.object as? NSTextView { parent.text = v.attributedString() }
            MainActor.assumeIsolated { parent.formatting?.refresh() }
        }
        func textViewDidChangeSelection(_ n: Notification) {
            MainActor.assumeIsolated { parent.formatting?.refresh() }
        }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)), let v = textView as? ComposerTextView else { return false }
            return MainActor.assumeIsolated { v.continueList() }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let v = ComposerTextView(frame: .zero)
        v.minSize = .zero
        v.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        v.isVerticallyResizable = true
        v.isHorizontallyResizable = false
        v.autoresizingMask = [.width]
        v.textContainer?.widthTracksTextView = true
        v.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = v
        v.onFiles = onFiles
        formatting?.textView = v
        v.isRichText = true
        v.allowsUndo = true
        v.usesFontPanel = true
        // Pictures go inside the text and are sent inside the mail.
        v.importsGraphics = true
        v.isAutomaticLinkDetectionEnabled = true
        v.isAutomaticQuoteSubstitutionEnabled = false
        v.isContinuousSpellCheckingEnabled = true
        v.font = .systemFont(ofSize: 14)
        v.typingAttributes = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor]
        v.textContainerInset = NSSize(width: 4, height: 8)
        v.delegate = context.coordinator
        v.textStorage?.setAttributedString(text)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        (scroll.documentView as? ComposerTextView)?.onFiles = onFiles
        guard let v = scroll.documentView as? NSTextView, v.attributedString() != text else { return }
        v.textStorage?.setAttributedString(text)
    }
}

struct ComposerView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var draft: ComposerDraft
    @State private var showCc = false
    @State private var showBcc = false
    @State private var pickingReminderDate = false
    @State private var reminderDate = FollowUps.workingDays(3, after: Date())
    @StateObject private var formatting = ComposerFormatting()
    @State private var showLater = false
    @State private var laterDate = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date().addingTimeInterval(86400))!
    @State private var signature = ""
    /// The current account's Gmail send-as addresses other than itself, such as a company address kept in a personal Gmail.
    @State private var aliases: [SendAsDTO] = []
    @State private var loadingBooking = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    Text("From").foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                    Picker("", selection: sender) {
                        // A reply stays in its thread's account, so only that account's addresses are offered.
                        ForEach(model.accounts.filter { draft.state.replyTo == nil || $0.id == draft.state.accountId }) { a in Text(a.email).tag(a.id) }
                        ForEach(aliasChoices, id: \.self) { al in Text("\(al)  (via \(draft.state.accountId))").tag("\(draft.state.accountId)|\(al)") }
                    }
                    .labelsHidden()
                    .disabled(draft.state.replyTo != nil && aliasChoices.isEmpty)
                    Spacer()
                }
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    AddressCompletionField(title: "To", text: $draft.state.to, inComposer: true)
                    // Each opens its own field, with the cursor in it.
                    Group {
                        if !ccShown {
                            Button("Cc") { showCc = true }.keyboardShortcut("c", modifiers: [.command, .option]).help("Add Cc (⌥⌘C)")
                        }
                        if !bccShown {
                            Button("Bcc") { showBcc = true }.keyboardShortcut("b", modifiers: [.command, .option]).help("Add Bcc (⌥⌘B)")
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                if ccShown {
                    Divider()
                    AddressCompletionField(title: "Cc", text: $draft.state.cc, inComposer: true, focusOnAppear: showCc)
                }
                if bccShown {
                    Divider()
                    AddressCompletionField(title: "Bcc", text: $draft.state.bcc, inComposer: true, focusOnAppear: showBcc)
                }
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Text("Subject").foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                    TextField("", text: $draft.state.subject).textFieldStyle(.plain).font(.body.weight(.medium))
                }
                Divider()
            }
            .padding([.horizontal, .top], 14)

            FormattingBar(f: formatting)
            RichTextEditor(text: $draft.state.body, onFiles: { $0.forEach(add) }, formatting: formatting).frame(minHeight: 140)

            if let b = draft.state.booking {
                HStack(alignment: .top, spacing: 8) {
                    BookingPreview(html: b.html)
                    VStack(spacing: 8) {
                        Button { draft.state.booking = nil; draft.state.bookingEvent = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove the booking card")
                        if let e = draft.state.bookingEvent {
                            Button { refreshBooking(e) } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("Refresh the free times")
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
            }

            if !signature.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Signature").font(.caption2).foregroundStyle(.tertiary)
                    Text(GmailParser.htmlToText(signature)).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.vertical, 6)
            }
            if draft.state.quotedHtml != nil {
                Text("The earlier message is quoted below your text.").font(.caption2).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 4)
            }
            if !draft.state.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(draft.state.attachments, id: \.path) { a in
                            HStack(spacing: 4) {
                                Image(systemName: "paperclip")
                                Text(a.filename).lineLimit(1)
                                Button { draft.state.attachments.removeAll { $0.path == a.path } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                            }
                            .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .padding(.bottom, 6)
            }
            if let e = draft.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(e).font(.callout).lineLimit(4).textSelection(.enabled)
                    Spacer()
                    Button { draft.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Hide this message")
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
            }
            if let at = draft.state.scheduledAt {
                Label("Scheduled for \(at.formatted(date: .complete, time: .shortened)). Schedule keeps that time; Change Time moves it or sends it now.",
                      systemImage: "calendar.badge.clock")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.08))
            }
            Divider()
            HStack {
                Button { pickFiles() } label: { Image(systemName: "paperclip") }.help("Attach files")
                BookingMenu(state: $draft.state, loading: $loadingBooking)
                Button("Discard", role: .destructive) { draft.discard() }
                Spacer()
                Button(draft.saving ? "Saving…" : "Save Draft") { draft.saveDraft() }.disabled(draft.saving)
                reminderMenu
                Button { showLater = true } label: { Label(draft.state.scheduledAt == nil ? "Send Later" : "Change Time", systemImage: "clock") }
                    .popover(isPresented: $showLater) { laterPopover }
                if let at = draft.state.scheduledAt {
                    // Editing a scheduled mail keeps its time. Past it by now, it goes with the usual undo window.
                    Button(draft.checking ? "Checking…" : "Schedule") { draft.send(at: at.timeIntervalSinceNow > Outbox.undoSeconds ? at : nil) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(draft.checking)
                        .help("Goes out \(at.formatted(date: .abbreviated, time: .shortened)), as planned")
                } else {
                    Button(draft.checking ? "Checking…" : "Send") { draft.send(at: nil) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(draft.checking)
                }
            }
            .padding(12)
            .onAppear { if let at = draft.state.scheduledAt, at > Date() { laterDate = at } }
        }
        // Its own window now, so it may shrink to sit beside the inbox.
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { add(url) } }
                }
            }
            return true
        }
        .sheet(isPresented: Binding(get: { !draft.findings.isEmpty }, set: { if !$0 { draft.fixFindings() } })) { findingsSheet }
        .task(id: "\(draft.state.accountId)|\(draft.state.fromEmail ?? "")") {
            let account = draft.state.accountId
            aliases = await model.engine.mail.sendAsList(accountId: account)
                .filter { $0.usable && $0.sendAsEmail.lowercased() != account.lowercased() }
            if let f = draft.state.fromEmail?.lowercased(), let a = aliases.first(where: { $0.sendAsEmail.lowercased() == f }) {
                signature = a.signature ?? ""
                return
            }
            signature = model.engine.mail.cachedSignature(accountId: account)
            if signature.isEmpty, let s = try? await model.engine.mail.signature(accountId: account) { signature = s.html }
        }
    }

    /// The account and, when chosen, the send-as address, as one picker value: "account" or "account|alias".
    private var sender: Binding<String> {
        Binding(get: { draft.state.fromEmail.map { "\(draft.state.accountId)|\($0)" } ?? draft.state.accountId },
                set: { v in
                    let parts = v.split(separator: "|", maxSplits: 1).map(String.init)
                    draft.state.accountId = parts[0]
                    draft.state.fromEmail = parts.count > 1 ? parts[1] : nil
                })
    }

    /// The send-as addresses to offer, the one in use included even before the list has loaded.
    private var aliasChoices: [String] {
        var out = aliases.map { $0.sendAsEmail.lowercased() }
        if let f = draft.state.fromEmail?.lowercased(), !out.contains(f) { out.append(f) }
        return out
    }

    private var ccShown: Bool { showCc || !draft.state.cc.isEmpty }
    private var bccShown: Bool { showBcc || !draft.state.bcc.isEmpty }

    /// Remind me if no reply: off, after 1, 3 or 5 working days, or on a date. It starts counting when the mail is sent.
    private var reminderMenu: some View {
        Menu {
            Button("Don't Remind Me") { draft.state.followUp = nil }
            Divider()
            Button("In 1 Working Day") { draft.state.followUp = .workingDays(1) }
            Button("In 3 Working Days") { draft.state.followUp = .workingDays(3) }
            Button("In 1 Week") { draft.state.followUp = .workingDays(5) }
            Button("On a Date…") { pickingReminderDate = true }
        } label: {
            Label(reminderLabel, systemImage: draft.state.followUp == nil ? "bell" : "bell.fill")
        } primaryAction: {
            // A click switches it on with 3 working days, or off again.
            draft.state.followUp = draft.state.followUp == nil ? .workingDays(3) : nil
        }
        .fixedSize()
        .help("Bring this thread back to the top of your inbox, with a follow-up drafted, if nobody replies")
        .popover(isPresented: $pickingReminderDate) {
            VStack(alignment: .leading, spacing: 10) {
                DatePicker("Remind me on", selection: $reminderDate, in: Date()...)
                Button("Set Reminder") {
                    draft.state.followUp = .date(reminderDate)
                    pickingReminderDate = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(14).frame(width: 300)
        }
    }

    private var reminderLabel: String {
        switch draft.state.followUp {
        case nil: return "Remind Me"
        case .workingDays(1): return "Remind in 1 day"
        case .workingDays(5): return "Remind in 1 week"
        case .workingDays(let n): return "Remind in \(n) days"
        case .date(let d): return "Remind \(d.formatted(date: .abbreviated, time: .omitted))"
        }
    }

    /// What the check before sending found, with the choice to fix it or send as it is.
    private var findingsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Before this goes", systemImage: "exclamationmark.bubble").font(.headline)
            ForEach(draft.findings, id: \.self) { f in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle.fill").font(.system(size: 5)).padding(.top, 6).foregroundStyle(.secondary)
                    Text(f).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            HStack {
                Spacer()
                Button("Send Anyway") { draft.sendAnyway() }
                Button("Fix") { draft.fixFindings() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private var laterPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker("Send at", selection: $laterDate, in: Date()...)
            Text("Postvak needs to be running at that time. If it isn't, it asks you when it next opens.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Schedule") { showLater = false; draft.send(at: laterDate) }.buttonStyle(.borderedProminent)
                if draft.state.scheduledAt != nil {
                    Button("Send Now") { showLater = false; draft.send(at: nil) }
                }
            }
        }
        .padding(14).frame(width: 320)
    }

    private func add(_ url: URL) {
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        draft.state.attachments.append(OutgoingAttachment(filename: url.lastPathComponent, mimeType: type, path: url.path))
    }

    private func pickFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        if p.runModal() == .OK { p.urls.forEach(add) }
    }

    private func refreshBooking(_ e: CalEventType) {
        loadingBooking = true
        Task {
            defer { loadingBooking = false }
            do { draft.state.booking = try await model.bookingInsert(for: e) }
            catch { draft.error = error.localizedDescription }
        }
    }
}
