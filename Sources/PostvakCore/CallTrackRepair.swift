import Foundation
import GRDB

public extension MeetingStore {
    /// The ratio by which call audio recorded at 44.1 kHz but saved as 48 kHz plays too fast.
    static let mislabelledRatio = 44_100.0 / 48_000.0

    /// Whether a call track is the mislabelled kind: shorter than the microphone track by exactly the 44.1/48 ratio.
    static func isMislabelled(callSeconds: Double, micSeconds: Double) -> Bool {
        guard micSeconds > 5 else { return false }
        return abs(callSeconds / micSeconds - mislabelledRatio) < 0.006
    }

    /// The call track's head start, from the two lengths: up to five seconds, else nothing is assumed.
    static func callOffset(micSeconds: Double, callSeconds: Double) -> Double {
        let d = micSeconds - callSeconds
        return d > 0 && d <= 5 ? d : 0
    }

    static func repairKey(_ meetingId: String) -> String { "repair.callRate.\(meetingId)" }

    /// Stretches the timestamps of the other side of a call (every speaker but "Me") by `factor` and moves them `offset`
    /// seconds later, puts the transcript back
    /// in time order, and moves the transcript links of action items and decisions along with their lines. Runs once per
    /// meeting: returns false when it already ran.
    @discardableResult
    func stretchCallTrack(meetingId: String, factor: Double, offset: Double = 0) async throws -> Bool {
        try await db.pool.write { db in
            guard try SettingRow.fetchOne(db, key: Self.repairKey(meetingId)) == nil else { return false }
            let segs = try TranscriptSegmentRecord.filter(Column("meetingId") == meetingId).order(Column("position")).fetchAll(db)
            let stretched = segs.map { s -> TranscriptSegmentRecord in
                guard s.speaker != "Me" else { return s }
                var s = s
                s.startSeconds = s.startSeconds * factor + offset
                s.endSeconds = s.endSeconds * factor + offset
                return s
            }
            let ordered = stretched.enumerated().sorted { ($0.element.startSeconds, $0.offset) < ($1.element.startSeconds, $1.offset) }.map(\.element)
            var newPosition: [Int: Int] = [:]
            for (i, s) in ordered.enumerated() { newPosition[s.position] = i }
            try TranscriptSegmentRecord.filter(Column("meetingId") == meetingId).deleteAll(db)
            for (i, var s) in ordered.enumerated() {
                s.position = i
                try s.insert(db)
            }
            if var sum = try MeetingSummaryRecord.fetchOne(db, key: meetingId) {
                sum.setActionItems(sum.actionItems.map { var a = $0; a.segment = a.segment.flatMap { newPosition[$0] }; return a })
                sum.setDecisions(sum.decisionItems.map { var d = $0; d.segment = d.segment.flatMap { newPosition[$0] }; return d })
                try sum.update(db)
            }
            try SettingRow(key: Self.repairKey(meetingId), value: ISO8601DateFormatter().string(from: Date())).save(db)
            return true
        }
    }
}
