import Foundation

public struct TrackSegment: Sendable, Hashable {
    public var start: Double
    public var end: Double
    public var speaker: String
    public var text: String
    public init(start: Double, end: Double, speaker: String, text: String) {
        self.start = start; self.end = end; self.speaker = speaker; self.text = text
    }
}

/// Merges the mic and system tracks into one timeline.
public enum TranscriptMerger {
    /// When someone uses speakers instead of headphones, the mic also hears the other side.
    /// A mic segment overlapping a system segment with mostly the same words is that echo, so it is dropped.
    public static func merge(mic: [TrackSegment], system: [TrackSegment], echoThreshold: Double = 0.6) -> [TrackSegment] {
        let kept = mic.filter { m in
            !system.contains { s in
                overlaps(m, s) && similarity(m.text, s.text) >= echoThreshold
            }
        }
        return (kept + system)
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    static func overlaps(_ a: TrackSegment, _ b: TrackSegment) -> Bool {
        let slack = 1.5
        return a.start < b.end + slack && b.start < a.end + slack
    }

    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    /// Share of the shorter text's words found in the other one.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count))
    }

    /// Whisper repeats filler on silence. These segments carry no speech.
    public static func isNoise(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if t.hasPrefix("[") && t.hasSuffix("]") { return true }
        if t.hasPrefix("(") && t.hasSuffix(")") { return true }
        return false
    }
}
