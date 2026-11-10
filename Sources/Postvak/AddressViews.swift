import SwiftUI
import AppKit
import PostvakCore

/// An email address as shown anywhere in the app. Clicking it starts a new mail to that address.
/// The copy button beside it shows on hover; right-clicking also offers to copy. The hover tip shows the address behind a name.
struct AddressButton: View {
    @EnvironmentObject var model: AppModel
    let name: String?
    let email: String
    /// The account the address was seen in, used to send the new mail.
    var accountId: String?
    /// Also show the address next to the name, as selectable text.
    var showEmail = false
    /// Runs before the composer opens, for example to close the sheet the address sits in.
    var beforeCompose: (() -> Void)?
    @State private var hovering = false
    @State private var copied = false

    private var displayName: String { (name?.isEmpty == false ? name : nil) ?? email }

    var body: some View {
        HStack(spacing: 4) {
            Button(displayName) { compose() }
                .buttonStyle(.link)
                .lineLimit(1)
                .help("New mail to \(email)")
            if showEmail, displayName != email {
                Text(email).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
            }
            Button {
                Self.copy(email)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .font(.caption2)
            .foregroundStyle(copied ? Color.green : .secondary)
            .help(copied ? "Copied" : "Copy \(email)")
            // Takes its place even while hidden, so addresses don't shift when the pointer passes over them.
            .opacity(hovering || copied ? 1 : 0)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("New Mail to \(email)") { compose() }
            Divider()
            Button("Copy Address") { Self.copy(email) }
            if displayName != email {
                Button("Copy Name and Address") { Self.copy(GmailParser.recipient(name: displayName, email: email)) }
            }
        }
    }

    private func compose() {
        let to = GmailParser.recipient(name: name ?? "", email: email)
        beforeCompose?()
        model.compose(to: to, accountId: accountId)
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// A labelled line of addresses ("to", "cc") that wraps.
struct AddressLine: View {
    let label: String
    let addresses: [String]
    var accountId: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            WrapLayout(spacing: 8, lineSpacing: 2) {
                ForEach(Array(addresses.enumerated()), id: \.offset) { _, raw in
                    let p = GmailParser.parseAddress(raw)
                    AddressButton(name: p.name.isEmpty ? nil : p.name, email: p.email, accountId: accountId)
                }
            }
        }
        .font(.caption)
    }
}

/// Places views left to right and wraps onto the next line when the row is full.
struct WrapLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            let w = min(s.width, width)
            if x > 0, x + w > width { x = 0; y += rowH + lineSpacing; rowH = 0 }
            x += w + spacing
            maxX = max(maxX, x - spacing)
            rowH = max(rowH, s.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            let w = min(s.width, bounds.width)
            if x > bounds.minX, x + w > bounds.maxX { x = bounds.minX; y += rowH + lineSpacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: w, height: s.height))
            x += w + spacing
            rowH = max(rowH, s.height)
        }
    }
}

enum MailtoLink {
    /// The addresses and subject of a mailto: link.
    static func parse(_ url: URL) -> (to: String, subject: String)? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let to = (comps?.path ?? "").removingPercentEncoding ?? comps?.path ?? ""
        let subject = comps?.queryItems?.first { $0.name.lowercased() == "subject" }?.value ?? ""
        return (to, subject)
    }
}

/// Every field where you type email addresses: comma separated, with suggestions for the part being typed
/// from people you had mail from and those in your calendar invites. ↓ and ↑ choose, Return or Tab takes
/// the suggestion, Escape hides the list.
struct AddressCompletionField: View {
    @EnvironmentObject var model: AppModel
    let title: String
    @Binding var text: String
    /// True while suggestions show, so a sheet's Return and Escape keys act on them instead of saving or closing.
    @Binding var suggesting: Bool
    /// The composer's look: the title in a column on the left and a borderless field.
    var inComposer = false
    /// Puts the cursor in the field when it appears, as when Cc is added by hand.
    var focusOnAppear = false
    @State private var suggestions: [String] = []
    @State private var highlighted = 0
    @State private var hiddenFor: String?
    @FocusState private var focused: Bool

    /// The address being typed: whatever follows the last comma.
    private var fragment: String {
        (text.components(separatedBy: ",").last ?? "").trimmingCharacters(in: .whitespaces)
    }
    private var showing: Bool { focused && !suggestions.isEmpty && hiddenFor != fragment }

    init(title: String, text: Binding<String>, suggesting: Binding<Bool> = .constant(false), inComposer: Bool = false, focusOnAppear: Bool = false) {
        self.title = title
        _text = text
        _suggesting = suggesting
        self.inComposer = inComposer
        self.focusOnAppear = focusOnAppear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if inComposer {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
                    field.textFieldStyle(.plain)
                }
            } else {
                field
            }
            if showing { list.padding(.leading, inComposer ? 62 : 0) }
        }
        .onChange(of: showing) { _, v in suggesting = v }
        .onAppear { if focusOnAppear { focused = true } }
        .task(id: fragment) {
            highlighted = 0
            guard fragment.count >= 2 else { suggestions = []; return }
            // Waits for a pause in typing.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let found = (try? await model.engine.mail.contacts(matching: fragment)) ?? []
            // Leaves out people already in the field, including an address typed out in full.
            let have = Set(GmailParser.splitAddresses(text).map { GmailParser.parseAddress($0).email.lowercased() })
            suggestions = found.filter { !have.contains(GmailParser.parseAddress($0).email.lowercased()) }
        }
    }

    private var field: some View {
        TextField(inComposer ? "" : title, text: $text)
            .focused($focused)
            .onKeyPress(.downArrow) { move(1) }
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.tab) { showing ? take(suggestions[highlighted]) : .ignored }
            .onKeyPress(.escape) {
                guard showing else { return .ignored }
                hiddenFor = fragment
                return .handled
            }
            .onSubmit { if showing { _ = take(suggestions[highlighted]) } }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element) { i, s in
                Button { _ = take(s) } label: {
                    Text(s).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3).padding(.horizontal, 6)
                        .background(i == highlighted ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(2)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private func move(_ d: Int) -> KeyPress.Result {
        guard showing else { return .ignored }
        highlighted = (highlighted + d + suggestions.count) % suggestions.count
        return .handled
    }

    /// Replaces the part being typed with the suggestion, ready for the next address.
    private func take(_ s: String) -> KeyPress.Result {
        var parts = text.components(separatedBy: ",").dropLast().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        parts.append(s)
        text = parts.joined(separator: ", ") + ", "
        suggestions = []
        return .handled
    }
}
