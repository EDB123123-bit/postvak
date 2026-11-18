import SwiftUI
import AppKit
import PostvakCore

/// Tagging people with "@" in the composer's text. Typing "@" shows the people already on the mail, and
/// letters after it search everyone you had mail or meetings with. ↓ and ↑ choose, Return or Tab tags,
/// Escape hides the list. A tagged person shows as "@Name", linked to their address, and is added to To
/// when they aren't on the mail yet.
@MainActor
final class ComposerMentions: ObservableObject {
    weak var textView: ComposerTextView?
    @Published private(set) var suggestions: [String] = []
    @Published var highlighted = 0
    /// The bottom left of the tag being typed, in the editor's coordinates with the origin at the top.
    @Published private(set) var anchor: CGPoint = .zero
    private(set) var query: Mentions.Query?
    /// The "@" whose list Escape hid, so it stays hidden while typing on.
    private var hiddenAt: Int?
    private var search: Task<Void, Never>?

    /// The people on the mail now (To, Cc and Bcc).
    var onMail: () -> [String] = { [] }
    /// Everyone else who fits, from mail and calendar invites.
    var contacts: (String) async -> [String] = { _ in [] }
    /// The sender's own addresses, never suggested.
    var own: () -> Set<String> = { [] }
    /// Runs after someone is tagged, to put them on the mail.
    var onTag: (String) -> Void = { _ in }

    var showing: Bool { query != nil && !suggestions.isEmpty }

    /// Looks again at the text before the cursor, after typing or moving the cursor.
    func refresh() {
        guard let tv = textView, let ts = tv.textStorage else { return close() }
        let sel = tv.selectedRange()
        guard sel.length == 0, let q = Mentions.query(in: tv.string, cursor: sel.location),
              // The "@" of someone already tagged.
              ts.attribute(.link, at: q.range.location, effectiveRange: nil) == nil else { return close() }
        if hiddenAt == q.range.location { query = q; suggestions = []; return }
        hiddenAt = nil
        let changed = q.text != query?.text
        query = q
        anchor = Self.anchor(of: q.range, in: tv)
        guard changed || suggestions.isEmpty else { return }
        let onMail = onMail(), own = own(), typed = q.text
        search?.cancel()
        search = Task { [weak self] in
            var others: [String] = []
            let t = typed.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty {
                // Waits for a pause in typing.
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                others = await self.contacts(t)
            }
            guard !Task.isCancelled, let self, self.query?.text == typed else { return }
            let found = Mentions.suggestions(typed: typed, onMail: onMail, others: others, own: own)
            if found != self.suggestions { self.highlighted = 0 }
            self.suggestions = found
        }
    }

    func close() {
        search?.cancel()
        query = nil
        hiddenAt = nil
        if !suggestions.isEmpty { suggestions = [] }
    }

    /// The composer's keys while the list shows. False lets the text view handle the key as usual.
    func handle(_ selector: Selector) -> Bool {
        guard showing else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            highlighted = (highlighted + 1) % suggestions.count
        case #selector(NSResponder.moveUp(_:)):
            highlighted = (highlighted - 1 + suggestions.count) % suggestions.count
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            tag(suggestions[highlighted])
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
            hiddenAt = query?.range.location
            suggestions = []
        default:
            return false
        }
        return true
    }

    /// Puts "@Name" in place of what was typed, linked to the person's address, with a space after it.
    func tag(_ recipient: String) {
        guard let tv = textView, let q = query else { return }
        let email = GmailParser.parseAddress(recipient).email
        var plain = tv.typingAttributes
        plain[.link] = nil
        plain[.underlineStyle] = nil
        var linked = plain
        if let url = URL(string: "mailto:\(email)") { linked[.link] = url }
        let piece = NSMutableAttributedString(string: Mentions.label(for: recipient), attributes: linked)
        piece.append(NSAttributedString(string: " ", attributes: plain))
        tv.window?.makeFirstResponder(tv)
        tv.insertText(piece, replacementRange: q.range)
        tv.typingAttributes = plain
        close()
        onTag(recipient)
    }

    private static func anchor(of range: NSRange, in tv: NSTextView) -> CGPoint {
        guard let lm = tv.layoutManager, let tc = tv.textContainer, let scroll = tv.enclosingScrollView else { return .zero }
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1), actualCharacterRange: nil)
        var r = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        r.origin.x += tv.textContainerOrigin.x
        r.origin.y += tv.textContainerOrigin.y
        let inScroll = tv.convert(r, to: scroll)
        let bottom = scroll.isFlipped ? inScroll.maxY : scroll.bounds.height - inScroll.minY
        return CGPoint(x: inScroll.minX, y: bottom)
    }
}

/// The list of people to tag, shown under the "@" being typed, or above it near the bottom of the text.
struct MentionList: View {
    @ObservedObject var m: ComposerMentions
    private let rowHeight: CGFloat = 24
    private let width: CGFloat = 300

    var body: some View {
        GeometryReader { geo in
            if m.showing {
                let height = CGFloat(m.suggestions.count) * rowHeight + 4
                let below = m.anchor.y + 2 + height <= geo.size.height || m.anchor.y < height + 24
                list
                    .frame(width: width, height: height)
                    .offset(x: min(max(4, m.anchor.x), max(4, geo.size.width - width - 4)),
                            y: below ? m.anchor.y + 2 : m.anchor.y - height - 22)
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(m.suggestions.enumerated()), id: \.element) { i, s in
                let p = GmailParser.parseAddress(s)
                Button { m.tag(s) } label: {
                    HStack(spacing: 6) {
                        Text(p.name.isEmpty ? p.email : p.name).lineLimit(1)
                        if !p.name.isEmpty { Text(p.email).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: rowHeight)
                    .background(i == m.highlighted ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { m.highlighted = i } }
            }
        }
        .font(.callout)
        .padding(2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }
}
