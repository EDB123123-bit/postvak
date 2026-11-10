import Foundation
import GRDB
import PostvakCore

/// Repairs call recordings made before the capture used the device's real sample rate: the call track was saved as 48 kHz
/// while holding 44.1 kHz audio, so it played 9% fast and its transcript times drifted from the microphone's.
public enum CallAudioRepair {
    /// Returns the titles of the meetings repaired. The original file stays next to the new one as `system-original-48k.m4a`.
    public static func run(store: MeetingStore) async -> [String] {
        let meetings = (try? await store.db.pool.read { db in
            try MeetingRecord.filter(Column("source") == "recorded" && Column("status") == MeetingRecord.Status.ready.rawValue
                                     && Column("systemAudioPath") != nil && Column("micAudioPath") != nil).fetchAll(db)
        }) ?? []
        var repaired: [String] = []
        for m in meetings {
            guard let micPath = m.micAudioPath, let sysPath = m.systemAudioPath, sysPath.hasSuffix(".m4a"),
                  FileManager.default.fileExists(atPath: micPath), FileManager.default.fileExists(atPath: sysPath) else { continue }
            let sys = URL(fileURLWithPath: sysPath)
            guard let micSeconds = AudioFiles.duration(URL(fileURLWithPath: micPath)), let callSeconds = AudioFiles.duration(sys),
                  AudioFiles.sampleRate(sys) == 48_000, MeetingStore.isMislabelled(callSeconds: callSeconds, micSeconds: micSeconds) else { continue }
            do {
                let fixed = try AudioFiles.relabel(sys, as: 44_100)
                let offset = MeetingStore.callOffset(micSeconds: micSeconds, callSeconds: callSeconds * 48_000 / 44_100)
                try await store.stretchCallTrack(meetingId: m.id, factor: 48_000 / 44_100, offset: offset)
                let backup = sys.deletingLastPathComponent().appendingPathComponent("system-original-48k.m4a")
                try? FileManager.default.removeItem(at: backup)
                try FileManager.default.moveItem(at: sys, to: backup)
                try FileManager.default.moveItem(at: fixed, to: sys)
                repaired.append(m.title)
            } catch {
                NSLog("Postvak: repairing the call audio of %@ failed: %@", m.title, error.localizedDescription)
            }
        }
        return repaired
    }
}
