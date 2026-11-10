import Foundation
import GRDB

/// Who a speaker in a meeting's transcript is. One row per transcript label ("Me", "Others", "Speaker 2").
public struct MeetingSpeaker: PersistableModel, Hashable, Identifiable {
    public static let databaseTableName = "meeting_speaker"
    public enum Source: String, Codable, Sendable {
        /// Set by rule, when the calendar leaves no doubt: the recorder's own microphone, or the one guest on a call with one voice.
        case auto
        /// Read from the transcript by Claude. Not applied: shown as a question until the user confirms it.
        case suggested
        /// Chosen by the user. Postvak never changes it.
        case manual
    }
    public var meetingId: String
    public var label: String
    public var name: String
    public var email: String?
    public var source: Source
    public var id: String { "\(meetingId)/\(label)" }
    public init(meetingId: String, label: String, name: String, email: String? = nil, source: Source) {
        self.meetingId = meetingId; self.label = label; self.name = name; self.email = email; self.source = source
    }
    /// Whether the name shows in place of the label.
    public var isApplied: Bool { source != .suggested }
}

/// A person a speaker can be named after: a guest of the meeting, or the user.
public struct SpeakerCandidate: Hashable, Sendable {
    public var name: String
    public var email: String?
    public init(name: String, email: String?) { self.name = name; self.email = email }
}

public enum SpeakerNames {
    /// Labels that stay with an audio track whatever the voice separation finds: the mic, and the call when it had one voice.
    public static let trackLabels: Set<String> = ["Me", "Others"]

    /// Labels the summary may name a speaker by, and which a rename can therefore replace in its text.
    /// "Me" is left out because it is also an ordinary word.
    static func isReplaceableLabel(_ label: String) -> Bool {
        label == "Others" || label.range(of: #"^Speaker \d+$"#, options: .regularExpression) != nil
    }

    /// The name each label shows as. Labels without an applied name show as themselves.
    public static func displayNames(_ speakers: [MeetingSpeaker]) -> [String: String] {
        speakers.reduce(into: [:]) { if $1.isApplied { $0[$1.label] = $1.name } }
    }

    /// The rule. Names only what the recording and the invitation settle, and leaves the rest unlabeled rather than guess:
    /// - "Me", the recorder's own microphone on a call, is the user.
    /// - On a call the microphone is the user and the call audio is the other side. With one other guest invited, every
    ///   voice on the call audio is that guest, however many voices the separation thinks it heard.
    /// A room recording mixes everyone on one microphone, and a call with several guests can't tell them apart, so those
    /// get no names by rule.
    public static func rule(labels: Set<String>, isCall: Bool, me: SpeakerCandidate?, guests: [SpeakerCandidate]) -> [String: SpeakerCandidate] {
        guard isCall else { return [:] }
        var out: [String: SpeakerCandidate] = [:]
        if labels.contains("Me"), let me { out["Me"] = me }
        if guests.count == 1 {
            for voice in labels.subtracting(["Me"]) { out[voice] = guests[0] }
        }
        return out
    }
}

public extension MeetingStore {
    public func speakers(meetingId: String) async throws -> [MeetingSpeaker] {
        try await db.pool.read { try MeetingSpeaker.filter(Column("meetingId") == meetingId).order(Column("label")).fetchAll($0) }
    }

    /// Label to shown name, for the labels that have one.
    public func speakerNames(meetingId: String) async throws -> [String: String] {
        SpeakerNames.displayNames(try await speakers(meetingId: meetingId))
    }

    /// The people a speaker in this meeting can be: the user first, then the other guests.
    func speakerCandidates(meetingId: String) async throws -> [SpeakerCandidate] {
        try await db.pool.read { db in
            guard let m = try MeetingRecord.fetchOne(db, key: meetingId) else { return [] }
            let (me, guests) = try Self.people(of: m, db)
            return (me.map { [$0] } ?? []) + guests
        }
    }

    /// The user, and the guests who did not decline, with the names people know them by.
    static func people(of m: MeetingRecord, _ db: Database) throws -> (me: SpeakerCandidate?, guests: [SpeakerCandidate]) {
        let own = try Matching.ownAddresses(db)
        let accounts = try Account.fetchAll(db)
        // The name most of the user's accounts carry: one account can spell it differently.
        let names = accounts.map(\.displayName).filter { !$0.isEmpty }
        let myName = Dictionary(grouping: names, by: { $0 }).max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.key
        let myEmail = m.eventAccountId ?? accounts.first?.id
        let me = myName.map { SpeakerCandidate(name: $0, email: myEmail) }
        var seen = Set<String>()
        var guests: [SpeakerCandidate] = []
        for a in m.attendees where !a.isSelf && a.response != "declined" {
            let e = a.email.lowercased()
            guard !e.isEmpty, !own.contains(e), seen.insert(e).inserted else { continue }
            guests.append(SpeakerCandidate(name: try Matching.name(for: e, given: a.name, db), email: e))
        }
        return (me, guests)
    }

    /// Names the speakers the rule is sure of. Names the user chose stay; earlier automatic names are worked out again.
    func assignSpeakers(meetingId: String) async throws {
        // Looked up in a read, which never holds up mail sync; only the changes are written.
        let plan = try await db.pool.read { db -> [String: SpeakerCandidate]? in
            guard let m = try MeetingRecord.fetchOne(db, key: meetingId), m.source == "recorded" else { return nil }
            let labels = Set(try String.fetchAll(db, sql: "SELECT DISTINCT speaker FROM transcript_segment WHERE meetingId = ?", arguments: [meetingId]))
            guard !labels.isEmpty else { return nil }
            let (me, guests) = try Self.people(of: m, db)
            return SpeakerNames.rule(labels: labels, isCall: m.systemAudioPath != nil, me: me, guests: guests)
        }
        guard let named = plan else { return }
        try await db.pool.write { db in
            let existing = try MeetingSpeaker.filter(Column("meetingId") == meetingId).fetchAll(db)
            let current = Dictionary(existing.map { ($0.label, $0) }, uniquingKeysWith: { a, _ in a })
            for (label, who) in named where current[label]?.source != .manual {
                if let c = current[label], c.source == .auto, c.name == who.name, c.email == who.email { continue }
                try Self.apply(db, meetingId: meetingId, label: label, name: who.name, email: who.email, source: .auto)
            }
            // An automatic name the rule no longer gives goes back to the label.
            for s in existing where s.source == .auto && named[s.label] == nil {
                try Self.apply(db, meetingId: meetingId, label: s.label, name: nil, email: nil, source: .auto)
            }
        }
    }

    /// A new transcript separates voices again, so its "Speaker 2" may be someone else. Only names on a track label
    /// that is still there survive, and only those the user chose.
    func resetSpeakers(meetingId: String, labels: Set<String>) async throws {
        try await db.pool.write { db in
            for s in try MeetingSpeaker.filter(Column("meetingId") == meetingId).fetchAll(db) {
                let keep = s.source == .manual && SpeakerNames.trackLabels.contains(s.label) && labels.contains(s.label)
                if !keep { try s.delete(db) }
            }
        }
    }

    /// Names a speaker, or with a nil name takes the name away. The new name replaces the old one in the summary,
    /// decisions, action items and open questions, so nothing is written again.
    func renameSpeaker(meetingId: String, label: String, name: String?, email: String? = nil) async throws {
        try await db.pool.write { db in
            try Self.apply(db, meetingId: meetingId, label: label, name: name, email: email, source: .manual)
        }
    }

    /// Keeps Claude's suggestions for labels that have no name yet, and only those naming one of the meeting's guests.
    func suggestSpeakers(meetingId: String, _ suggestions: [(label: String, name: String)]) async throws {
        try await db.pool.write { db in
            guard let m = try MeetingRecord.fetchOne(db, key: meetingId) else { return }
            let labels = Set(try String.fetchAll(db, sql: "SELECT DISTINCT speaker FROM transcript_segment WHERE meetingId = ?", arguments: [meetingId]))
            let (_, guests) = try Self.people(of: m, db)
            let existing = try MeetingSpeaker.filter(Column("meetingId") == meetingId).fetchAll(db)
            for s in existing where s.source == .suggested { try s.delete(db) }
            let taken = Set(existing.filter(\.isApplied).map(\.label))
            for (label, name) in suggestions where labels.contains(label) && !taken.contains(label) {
                let key = name.lowercased()
                guard let guest = guests.first(where: { $0.name.lowercased() == key || $0.email == key }) else { continue }
                try MeetingSpeaker(meetingId: meetingId, label: label, name: guest.name, email: guest.email, source: .suggested).save(db)
            }
        }
    }

    func dismissSpeakerSuggestion(meetingId: String, label: String) async throws {
        try await db.pool.write { db in
            _ = try MeetingSpeaker.filter(Column("meetingId") == meetingId && Column("label") == label && Column("source") == MeetingSpeaker.Source.suggested.rawValue).deleteAll(db)
        }
    }

    /// Runs the rule again for every recorded meeting with a transcript. Names the user chose stay.
    func assignSpeakersEverywhere() async throws {
        let ids = try await db.pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT m.id FROM meeting m WHERE m.source = 'recorded'
                AND EXISTS (SELECT 1 FROM transcript_segment s WHERE s.meetingId = m.id)
                """)
        }
        for id in ids { try await assignSpeakers(meetingId: id) }
    }

    /// Sets or clears a label's name and carries the change into the summary.
    static func apply(_ db: Database, meetingId: String, label: String, name rawName: String?, email: String?, source: MeetingSpeaker.Source) throws {
        let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let current = try MeetingSpeaker.filter(Column("meetingId") == meetingId && Column("label") == label).fetchOne(db)
        let old = current.flatMap { $0.isApplied ? $0.name : nil } ?? label
        let new = name ?? label
        if let name {
            try MeetingSpeaker(meetingId: meetingId, label: label, name: name, email: email, source: source).save(db)
        } else {
            try current?.delete(db)
        }
        guard old != new, var s = try MeetingSummaryRecord.fetchOne(db, key: meetingId) else { return }
        // A label is replaced in the text only when it reads as one; owners are a field, so any exact match is safe.
        let inText = old != label || SpeakerNames.isReplaceableLabel(label)
        let swap = { (t: String) in inText ? Matching.replaceWhole(old, with: new, in: t) : t }
        s.summary = swap(s.summary)
        s.setDecisions(s.decisionItems.map { var d = $0; d.text = swap(d.text); return d })
        s.setOpenQuestions(s.openQuestions.map(swap))
        s.setActionItems(s.actionItems.map { a in
            var a = a
            a.task = swap(a.task)
            if a.owner == old || a.owner == label { a.owner = new } else if let o = a.owner { a.owner = swap(o) }
            return a
        })
        try s.update(db)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
