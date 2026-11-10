import Foundation
import AppKit

/// Converts composer text to self-contained inline HTML for the mail.
/// Written by hand because Apple's exporter bakes in the sender's dark-mode white text and relies on a style block many mail clients drop.
public enum RichTextHTML {
    /// A picture pasted into the text, to send inside the mail.
    public struct InlineImage: Sendable {
        public let contentId: String
        public let data: Data
        public let mimeType: String
        public var filename: String { "image-\(contentId.prefix(8)).\(mimeType == "image/png" ? "png" : "jpg")" }
    }

    /// Pictures wider than this are shown smaller, in the composer and in the mail.
    public static let maxImageWidth: CGFloat = 560

    public static func html(from s: NSAttributedString) -> String { content(from: s).html }

    /// The HTML, and the pictures it shows as `cid:` references. Lines starting with "• " or "1. " become lists.
    public static func content(from s: NSAttributedString) -> (html: String, images: [InlineImage]) {
        guard s.length > 0 else { return ("", []) }
        var out = ""
        var images: [InlineImage] = []
        var list: RichTextList.Kind?
        func close() {
            if let l = list { out += l == .bullet ? "</ul>" : "</ol>" }
            list = nil
        }
        for (i, line) in RichTextList.lineRanges(s.string as NSString).enumerated() {
            if let m = RichTextList.marker(of: (s.string as NSString).substring(with: line)) {
                if list != m.kind {
                    close()
                    out += m.kind == .bullet ? "<ul style=\"margin:0;padding-left:1.4em\">" : "<ol style=\"margin:0;padding-left:1.4em\">"
                    list = m.kind
                }
                out += "<li>" + inline(s, NSRange(location: line.location + m.length, length: line.length - m.length), &images) + "</li>"
            } else {
                // A list is a block of its own, so the line after it needs no break.
                if list != nil { close() } else if i > 0 { out += "<br>" }
                out += inline(s, line, &images)
            }
        }
        close()
        // A trailing line break leaves an empty last line, as it did before lists.
        if s.string.hasSuffix("\n"), list == nil, !out.hasSuffix("</ul>"), !out.hasSuffix("</ol>") { out += "<br>" }
        return ("<div style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px\">\(out)</div>", images)
    }

    /// One line's text with its formatting, links and pictures.
    static func inline(_ s: NSAttributedString, _ lineRange: NSRange, _ images: inout [InlineImage]) -> String {
        var out = ""
        guard lineRange.length > 0 else { return out }
        s.enumerateAttributes(in: lineRange) { attrs, range, _ in
            if let a = attrs[.attachment] as? NSTextAttachment {
                if let img = image(a) {
                    images.append(img)
                    let w = a.bounds.width > 0 ? a.bounds.width : min(maxImageWidth, displaySize(a)?.width ?? maxImageWidth)
                    out += "<img src=\"cid:\(img.contentId)\" width=\"\(Int(w.rounded()))\" style=\"max-width:100%;height:auto\" alt=\"\">"
                }
                return
            }
            let raw = s.attributedSubstring(from: range).string
            var text = raw.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\n", with: "<br>").replacingOccurrences(of: "\u{2028}", with: "<br>")
            if let f = attrs[.font] as? NSFont {
                let traits = f.fontDescriptor.symbolicTraits
                if traits.contains(.bold) { text = "<b>\(text)</b>" }
                if traits.contains(.italic) { text = "<i>\(text)</i>" }
            }
            if (attrs[.underlineStyle] as? Int ?? 0) != 0, attrs[.link] == nil { text = "<u>\(text)</u>" }
            if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { text = "<s>\(text)</s>" }
            if let c = attrs[.foregroundColor] as? NSColor, let hex = explicitHex(c) {
                text = "<span style=\"color:\(hex)\">\(text)</span>"
            }
            if let link = attrs[.link] {
                let href = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                if ["http", "https", "mailto"].contains(URL(string: href)?.scheme?.lowercased() ?? "") {
                    let safe = href.replacingOccurrences(of: "\"", with: "%22")
                    text = "<a href=\"\(safe)\">\(text)</a>"
                }
            }
            out += text
        }
        return out
    }

    /// The plain-text version of the text, with "[image]" where a picture sits.
    public static func plainText(from s: NSAttributedString) -> String {
        s.string.replacingOccurrences(of: "\u{FFFC}", with: "[image]")
    }

    /// PNG keeps screenshots sharp; a large picture goes as JPEG so the mail stays small.
    static func image(_ a: NSTextAttachment) -> InlineImage? {
        var img = a.image
        if img == nil, let d = a.contents ?? a.fileWrapper?.regularFileContents { img = NSImage(data: d) }
        guard let tiff = img?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let id = UUID().uuidString.lowercased() + "@postvak"
        if let png = rep.representation(using: .png, properties: [:]), png.count <= 1_500_000 {
            return InlineImage(contentId: id, data: png, mimeType: "image/png")
        }
        guard let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return nil }
        return InlineImage(contentId: id, data: jpg, mimeType: "image/jpeg")
    }

    static func displaySize(_ a: NSTextAttachment) -> CGSize? {
        if let i = a.image { return i.size }
        if let d = a.contents ?? a.fileWrapper?.regularFileContents { return NSImage(data: d)?.size }
        return nil
    }

    /// nil for the system's adaptive text colours, so the reader's own default applies.
    static func explicitHex(_ c: NSColor) -> String? {
        let adaptive: [NSColor] = [.textColor, .labelColor, .controlTextColor, .secondaryLabelColor, .tertiaryLabelColor, .headerTextColor]
        if adaptive.contains(c) { return nil }
        if c.type == .catalog { return nil }
        guard let rgb = c.usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02x%02x%02x", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
}
