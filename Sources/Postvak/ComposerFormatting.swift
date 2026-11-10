import SwiftUI
import AppKit
import PostvakCore

/// What the formatting bar shows as on, for the selection or the cursor, and the text view it acts on.
@MainActor
final class ComposerFormatting: ObservableObject {
    weak var textView: ComposerTextView?
    @Published var bold = false
    @Published var italic = false
    @Published var underline = false
    @Published var strikethrough = false
    @Published var list: RichTextList.Kind?
    @Published var link: String?

    func refresh() {
        guard let tv = textView, let ts = tv.textStorage else { return }
        let r = tv.selectedRange()
        let attrs = r.length > 0 && r.location < ts.length ? ts.attributes(at: r.location, effectiveRange: nil) : tv.typingAttributes
        let traits = (attrs[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
        bold = traits.contains(.boldFontMask)
        italic = traits.contains(.italicFontMask)
        underline = (attrs[.underlineStyle] as? Int ?? 0) != 0 && attrs[.link] == nil
        strikethrough = (attrs[.strikethroughStyle] as? Int ?? 0) != 0
        link = (attrs[.link] as? URL)?.absoluteString ?? attrs[.link] as? String
        let ns = tv.string as NSString
        let para = ns.paragraphRange(for: NSRange(location: min(r.location, ns.length), length: 0))
        list = RichTextList.marker(of: ns.substring(with: para))?.kind
    }

    /// Runs a change on the text, then puts the cursor back in it and updates the bar.
    func apply(_ change: (ComposerTextView) -> Void) {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
        change(tv)
        refresh()
    }
}

/// Bold, italic, underline, strikethrough, lists and links, with Gmail's shortcuts.
struct FormattingBar: View {
    @ObservedObject var f: ComposerFormatting
    @State private var editingLink = false
    @State private var url = ""

    var body: some View {
        HStack(spacing: 2) {
            toggle("bold", on: f.bold, help: "Bold (⌘B)", key: "b") { $0.toggleTrait(.boldFontMask) }
            toggle("italic", on: f.italic, help: "Italic (⌘I)", key: "i") { $0.toggleTrait(.italicFontMask) }
            toggle("underline", on: f.underline, help: "Underline (⌘U)", key: "u") { $0.toggleLine(.underlineStyle) }
            toggle("strikethrough", on: f.strikethrough, help: "Strikethrough (⇧⌘X)", key: "x", shift: true) { $0.toggleLine(.strikethroughStyle) }
            Divider().frame(height: 16).padding(.horizontal, 4)
            toggle("list.bullet", on: f.list == .bullet, help: "Bulleted list (⇧⌘8)", key: "8", shift: true) { $0.toggleList(.bullet) }
            toggle("list.number", on: f.list == .number, help: "Numbered list (⇧⌘7)", key: "7", shift: true) { $0.toggleList(.number) }
            Divider().frame(height: 16).padding(.horizontal, 4)
            Button {
                url = f.link ?? ""
                editingLink = true
            } label: {
                icon("link", on: f.link != nil)
            }
            .keyboardShortcut("k")
            .help("Link (⌘K)")
            .popover(isPresented: $editingLink, arrowEdge: .bottom) { linkEditor }
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    private func toggle(_ symbol: String, on: Bool, help: String, key: KeyEquivalent, shift: Bool = false,
                        _ action: @escaping (ComposerTextView) -> Void) -> some View {
        Button { f.apply(action) } label: { icon(symbol, on: on) }
            .keyboardShortcut(key, modifiers: shift ? [.command, .shift] : .command)
            .help(help)
    }

    private func icon(_ symbol: String, on: Bool) -> some View {
        Image(systemName: symbol)
            .frame(width: 26, height: 22)
            .foregroundStyle(on ? Color.accentColor : .secondary)
            .background(on ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
    }

    private var linkEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("https://", text: $url).frame(width: 280).onSubmit(applyLink)
            HStack {
                if f.link != nil {
                    Button("Remove Link") {
                        f.apply { $0.setLink(nil) }
                        editingLink = false
                    }
                }
                Spacer()
                Button("Cancel") { editingLink = false }.keyboardShortcut(.cancelAction)
                Button("Apply", action: applyLink).keyboardShortcut(.defaultAction)
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
    }

    /// A bare address gets https:// in front, and an email address mailto:.
    private func applyLink() {
        let t = url.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        let full = t.contains("://") || t.hasPrefix("mailto:") ? t : (t.contains("@") && !t.contains("/") ? "mailto:\(t)" : "https://\(t)")
        if let u = URL(string: full) { f.apply { $0.setLink(u) } }
        editingLink = false
    }
}

extension ComposerTextView {
    /// Bold or italic on the selection, or for what is typed next. Off when the whole selection already has it.
    func toggleTrait(_ trait: NSFontTraitMask) {
        let fm = NSFontManager.shared
        let r = selectedRange()
        let base = NSFont.systemFont(ofSize: 14)
        if r.length == 0 {
            let f = typingAttributes[.font] as? NSFont ?? base
            typingAttributes[.font] = fm.traits(of: f).contains(trait) ? fm.convert(f, toNotHaveTrait: trait) : fm.convert(f, toHaveTrait: trait)
            return
        }
        guard let ts = textStorage, shouldChangeText(in: r, replacementString: nil) else { return }
        var all = true
        ts.enumerateAttribute(.font, in: r) { v, _, _ in
            if !fm.traits(of: v as? NSFont ?? base).contains(trait) { all = false }
        }
        ts.beginEditing()
        ts.enumerateAttribute(.font, in: r) { v, sub, _ in
            let f = v as? NSFont ?? base
            ts.addAttribute(.font, value: all ? fm.convert(f, toNotHaveTrait: trait) : fm.convert(f, toHaveTrait: trait), range: sub)
        }
        ts.endEditing()
        didChangeText()
    }

    /// Underline or strikethrough, the same way.
    func toggleLine(_ key: NSAttributedString.Key) {
        let r = selectedRange()
        let single = NSUnderlineStyle.single.rawValue
        if r.length == 0 {
            typingAttributes[key] = (typingAttributes[key] as? Int ?? 0) != 0 ? nil : single
            return
        }
        guard let ts = textStorage, shouldChangeText(in: r, replacementString: nil) else { return }
        var all = true
        ts.enumerateAttribute(key, in: r) { v, _, _ in if (v as? Int ?? 0) == 0 { all = false } }
        ts.beginEditing()
        if all { ts.removeAttribute(key, range: r) } else { ts.addAttribute(key, value: single, range: r) }
        ts.endEditing()
        didChangeText()
    }

    /// Turns the selected lines into a list, or back into plain lines.
    func toggleList(_ kind: RichTextList.Kind) {
        guard let ts = textStorage else { return }
        let r = selectedRange()
        let para = (string as NSString).paragraphRange(for: r)
        let replaced = RichTextList.toggled(kind, in: ts.attributedSubstring(from: para), typing: typingAttributes)
        guard shouldChangeText(in: para, replacementString: replaced.string) else { return }
        ts.replaceCharacters(in: para, with: replaced)
        didChangeText()
        // The cursor goes to the end of the first line, where typing continues.
        let firstLine = (replaced.string as NSString).range(of: "\n")
        setSelectedRange(NSRange(location: para.location + (firstLine.location == NSNotFound ? replaced.length : firstLine.location), length: 0))
    }

    /// Return in a list: the next item gets its marker, and an empty item ends the list.
    func continueList() -> Bool {
        let r = selectedRange()
        guard r.length == 0 else { return false }
        let ns = string as NSString
        let para = ns.paragraphRange(for: r)
        var line = ns.substring(with: para)
        if line.hasSuffix("\n") { line.removeLast() }
        // Only at the end of the line; Return in the middle splits it as usual.
        guard r.location == para.location + (line as NSString).length else { return false }
        switch RichTextList.continuation(of: line) {
        case .notList:
            return false
        case .end:
            let marker = NSRange(location: para.location, length: (line as NSString).length)
            guard shouldChangeText(in: marker, replacementString: "") else { return true }
            textStorage?.replaceCharacters(in: marker, with: "")
            didChangeText()
            return true
        case .next(let mark):
            insertText("\n" + mark, replacementRange: r)
            return true
        }
    }

    /// Links the selection, or inserts the address as a link when nothing is selected. Nil removes the link.
    func setLink(_ url: URL?) {
        guard let ts = textStorage else { return }
        var r = selectedRange()
        if r.length == 0, url == nil {
            // The whole link around the cursor.
            guard r.location < ts.length, ts.attribute(.link, at: r.location, longestEffectiveRange: &r, in: NSRange(location: 0, length: ts.length)) != nil else { return }
        }
        if r.length == 0, let url {
            var attrs = typingAttributes
            attrs[.link] = url
            insertText(NSAttributedString(string: url.absoluteString, attributes: attrs), replacementRange: r)
            return
        }
        guard shouldChangeText(in: r, replacementString: nil) else { return }
        if let url { ts.addAttribute(.link, value: url, range: r) } else { ts.removeAttribute(.link, range: r) }
        didChangeText()
    }
}
