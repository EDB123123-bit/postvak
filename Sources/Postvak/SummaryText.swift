import SwiftUI

/// A meeting summary as text. A detailed summary has topic titles, each followed by lines starting with "• ";
/// those titles are set in bold.
struct SummaryText: View {
    let text: String

    var body: some View {
        let lines = text.components(separatedBy: "\n")
        if !lines.contains(where: { $0.hasPrefix("• ") }) {
            Text(text).textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty {
                        Spacer().frame(height: 4)
                    } else if Self.isTitle(i, lines) {
                        Text(t).fontWeight(.semibold).padding(.top, 2)
                    } else if t.hasPrefix("• ") {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(t.dropFirst(2))
                        }
                        .padding(.leading, 4)
                    } else {
                        Text(t)
                    }
                }
            }
            .textSelection(.enabled)
        }
    }

    /// A short line that is not a point itself, with points right under it.
    static func isTitle(_ i: Int, _ lines: [String]) -> Bool {
        let t = lines[i].trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("• "), t.count <= 100, i + 1 < lines.count else { return false }
        return lines[i + 1].trimmingCharacters(in: .whitespaces).hasPrefix("• ")
    }
}
