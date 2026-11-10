import Foundation
import GRDB

public extension MeetingStore {
    /// Summaries written before points carried their source get one by matching words with the transcript, in plain code.
    /// Only points without a source are touched, so it is cheap to run on every launch.
    func anchorUnsourcedPoints() async throws {
        let todo = try await db.pool.read { db -> [(MeetingSummaryRecord, [TranscriptSegmentRecord])] in
            let summaries = try MeetingSummaryRecord.fetchAll(db).filter { s in
                s.actionItems.contains { $0.segment == nil } || s.decisionItems.contains { $0.segment == nil }
            }
            return try summaries.compactMap { s in
                let segs = try TranscriptSegmentRecord.filter(Column("meetingId") == s.meetingId).order(Column("position")).fetchAll(db)
                return segs.isEmpty ? nil : (s, segs)
            }
        }
        for (s, segs) in todo {
            let actions = s.actionItems.map { a -> ActionItem in
                var a = a
                if a.segment == nil { a.segment = TranscriptAnchor.anchor(nil, text: a.task, segments: segs) }
                return a
            }
            let decisions = s.decisionItems.map { d -> DecisionItem in
                var d = d
                if d.segment == nil { d.segment = TranscriptAnchor.anchor(nil, text: d.text, segments: segs) }
                return d
            }
            guard actions != s.actionItems || decisions != s.decisionItems else { continue }
            try await db.pool.write { db in
                // Read again: a rename may have changed the text meanwhile.
                guard var fresh = try MeetingSummaryRecord.fetchOne(db, key: s.meetingId), fresh.actionItemsJSON == s.actionItemsJSON,
                      fresh.decisionsJSON == s.decisionsJSON else { return }
                fresh.setActionItems(actions)
                fresh.setDecisions(decisions)
                try fresh.update(db)
            }
        }
    }
}

/// Ties what a summary states to the transcript segment it came from, in plain code, after Claude has cited one.
public enum TranscriptAnchor {
    /// Common words in Dutch, French and English that say nothing about the content.
    static let stopWords: Set<String> = [
        "deze", "voor", "zijn", "hebben", "wordt", "worden", "naar", "door", "over", "maar", "want", "omdat", "niet", "ook", "nog", "wel",
        "zou", "kunnen", "moet", "moeten", "gaan", "gaat", "met", "van", "een", "het", "dat", "die", "wat", "als", "dan", "bij",
        "pour", "dans", "avec", "sont", "être", "avoir", "fait", "faire", "cette", "mais", "plus", "nous", "vous", "leur", "comme", "aussi",
        "with", "that", "this", "will", "would", "should", "have", "from", "they", "them", "there", "about", "which", "their", "also",
    ]

    static func words(_ s: String) -> Set<String> {
        Set(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { ($0.count >= 4 || $0.allSatisfy(\.isNumber)) && !stopWords.contains($0) })
    }

    /// The segment a point comes from: the cited one when it or a neighbour shares words with the point, else the best
    /// match within ten segments, else the citation as given. Without a real citation, the best match in the whole
    /// transcript if it shares at least two words; nil when nothing does.
    public static func anchor(_ cited: Int?, text: String, segments: [TranscriptSegmentRecord]) -> Int? {
        guard !segments.isEmpty else { return nil }
        let w = words(text)
        func score(_ i: Int) -> Int { words(segments[i].text).intersection(w).count }
        /// The highest score in a range; on a tie, the one closest to `center`.
        func best(_ r: ClosedRange<Int>, near center: Int) -> Int? {
            r.max { (score($0), -abs($0 - center)) < (score($1), -abs($1 - center)) }
        }
        let last = segments.count - 1
        if let c = cited, let i = segments.firstIndex(where: { $0.position == c }) {
            if score(i) > 0 { return c }
            if let b = best(max(0, i - 1)...min(last, i + 1), near: i), score(b) > 0 { return segments[b].position }
            if let b = best(max(0, i - 10)...min(last, i + 10), near: i), score(b) >= 2 { return segments[b].position }
            return c
        }
        if let b = best(0...last, near: 0), score(b) >= 2 { return segments[b].position }
        return nil
    }
}
