import Foundation

/// Picks a track's language from several windows instead of its first 30 seconds.
public enum LanguageVote {
    public struct Sample: Sendable, Equatable {
        public let start: Double
        public let language: String
        public let confidence: Float
        public init(start: Double, language: String, confidence: Float) { self.start = start; self.language = language; self.confidence = confidence }
    }
    public static let window: Double = 30
    public static let samples = 7
    /// A window counts when at least this share of its 100 ms frames is louder than the floor below.
    public static let minSpeechShare = 0.2
    public static let speechFloor: Float = 0.01

    /// Window starts spread evenly from the beginning to the last full window.
    public static func starts(duration: Double, count: Int) -> [Double] {
        let last = duration - window
        guard last > 1, count > 1 else { return [0] }
        let n = min(count, Int(duration / window))
        guard n > 1 else { return [0] }
        return (0..<n).map { (last * Double($0) / Double(n - 1)).rounded() }
    }

    /// Share of 100 ms frames (at 16 kHz) whose loudness clears the speech floor.
    public static func speechShare(_ samples: [Float]) -> Double {
        let frame = 1600
        guard samples.count >= frame else { return 0 }
        var loud = 0, total = 0
        var i = 0
        while i + frame <= samples.count {
            var sum: Float = 0
            for j in i..<(i + frame) { sum += samples[j] * samples[j] }
            if (sum / Float(frame)).squareRoot() >= speechFloor { loud += 1 }
            total += 1
            i += frame
        }
        return Double(loud) / Double(total)
    }

    /// The language with the most confidence summed over all windows.
    public static func winner(_ samples: [Sample]) -> String? {
        var score: [String: Float] = [:]
        for s in samples { score[s.language, default: 0] += s.confidence }
        return score.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }?.key
    }
}
