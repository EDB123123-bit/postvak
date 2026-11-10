import Foundation
import AppKit

/// Lists in the composer are lines that start with a marker, "• " or "1. ", so they read the same in the
/// plain-text version of the mail. The HTML version turns them into real lists.
public enum RichTextList {
    public enum Kind: Equatable, Sendable { case bullet, number }

    public static let bullet = "• "

    /// The list marker a line starts with, and its length in UTF-16 units.
    public static func marker(of line: String) -> (kind: Kind, length: Int)? {
        if line.hasPrefix(bullet) { return (.bullet, (bullet as NSString).length) }
        let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return (.number, digits.count + 2)
    }

    public enum Continuation: Equatable { case notList, end, next(String) }

    /// What Return does at the end of a line: carry on with the next marker, or end the list on an empty item.
    public static func continuation(of line: String) -> Continuation {
        guard let m = marker(of: line) else { return .notList }
        if (line as NSString).length == m.length { return .end }
        switch m.kind {
        case .bullet: return .next(bullet)
        case .number: return .next("\((Int(line.prefix(while: \.isNumber)) ?? 0) + 1). ")
        }
    }

    /// The lines of `text` with the list switched on, or off when every line already is that kind of list.
    /// `text` is whole paragraphs, as `NSString.paragraphRange(for:)` gives them. Blank lines in a longer
    /// selection stay blank. `typing` styles a marker added to an empty line.
    public static func toggled(_ kind: Kind, in text: NSAttributedString, typing: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        let lines = lineRanges(text.string as NSString)
        let strings = lines.map { (text.string as NSString).substring(with: $0) }
        let off = strings.allSatisfy { marker(of: $0)?.kind == kind }
        let skipBlank = lines.count > 1
        var number = strings.filter { !(skipBlank && $0.isEmpty) }.count
        // From the last line back, so earlier ranges stay valid.
        for (r, line) in zip(lines, strings).reversed() {
            let existing = marker(of: line)
            if let m = existing { out.deleteCharacters(in: NSRange(location: r.location, length: m.length)) }
            if off || (skipBlank && line.isEmpty) { continue }
            let mark = kind == .bullet ? bullet : "\(number). "
            number -= 1
            let attrs = r.length > (existing?.length ?? 0) ? text.attributes(at: r.location + (existing?.length ?? 0), effectiveRange: nil) : typing
            out.insert(NSAttributedString(string: mark, attributes: attrs), at: r.location)
        }
        return out
    }

    /// Each line without its line break. A trailing break ends the last line rather than starting an empty one.
    static func lineRanges(_ s: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var start = 0
        while true {
            let nl = s.range(of: "\n", range: NSRange(location: start, length: s.length - start))
            if nl.location == NSNotFound {
                if start < s.length || out.isEmpty { out.append(NSRange(location: start, length: s.length - start)) }
                return out
            }
            out.append(NSRange(location: start, length: nl.location - start))
            start = nl.location + 1
        }
    }
}
