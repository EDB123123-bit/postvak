import Foundation
import GRDB

/// Something the user wrote about a deal, like "Lost on 6 Oct, they built it themselves". Claude reads it as fact.
public struct DealNote: PersistableModel, Identifiable, Hashable {
    public static let databaseTableName = "deal_note"
    public var id: String
    public var dealKey: String
    public var text: String
    public var createdAt: Date
    /// When the note reached the CRM, or nil while it has not (yet).
    public var crmPushedAt: Date?
    public var crmError: String?

    public init(id: String = UUID().uuidString, dealKey: String, text: String, createdAt: Date = Date(), crmPushedAt: Date? = nil, crmError: String? = nil) {
        self.id = id; self.dealKey = dealKey; self.text = text; self.createdAt = createdAt; self.crmPushedAt = crmPushedAt; self.crmError = crmError
    }
}

/// What the user and the CRM say about a deal, kept apart from Claude's reading so a new reading never wipes it.
public struct DealState: PersistableModel, Identifiable, Hashable {
    public static let databaseTableName = "deal_state"
    public var key: String
    /// The next step the user marked done, and the activity it was marked against. It stays hidden until mail or a meeting changes that.
    public var doneStep: String?
    public var doneAt: Date?
    public var doneActivityKey: String?
    /// The matching CRM record.
    public var crmLeadId: String?
    public var crmUserId: String?
    public var crmProject: String?
    public var crmCompany: String?
    public var crmStage: String?
    /// The CRM's lost reason and latest notes, as Claude gets them.
    public var crmContext: String?
    public var crmFingerprint: String?
    /// When the CRM record last changed as seen from here, so the deal is read again.
    public var crmChangedAt: Date?
    /// A CRM stage the user chose not to set, so Postvak stops asking.
    public var crmProposalDismissed: String?

    public var id: String { key }

    public init(key: String) { self.key = key }

    /// Marked done, with no mail or meeting since. When Claude read the deal again after that (a note, a CRM change)
    /// it knew the step was done, so a different step it gave stands.
    public func isDone(_ deal: DealRecord) -> Bool {
        guard let doneActivityKey, doneActivityKey == deal.activityKey, let doneAt else { return false }
        return deal.analyzedAt <= doneAt || deal.nextStep == doneStep
    }
}

/// Reads and writes the user's notes, done steps and the CRM state of each deal.
public final class DealNotes: Sendable {
    let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    public func notes(for key: String) async throws -> [DealNote] {
        try await db.pool.read { try DealNote.filter(Column("dealKey") == key).order(Column("createdAt")).fetchAll($0) }
    }

    public func allNotes() async throws -> [DealNote] {
        try await db.pool.read { try DealNote.order(Column("createdAt")).fetchAll($0) }
    }

    @discardableResult
    public func add(_ text: String, to key: String, now: Date = Date()) async throws -> DealNote {
        let note = DealNote(dealKey: key, text: text.trimmingCharacters(in: .whitespacesAndNewlines), createdAt: now)
        try await db.pool.write { try note.insert($0) }
        return note
    }

    public func delete(_ id: String) async throws {
        _ = try await db.pool.write { try DealNote.deleteOne($0, key: id) }
    }

    public func state(_ key: String) async throws -> DealState {
        try await db.pool.read { try DealState.fetchOne($0, key: key) } ?? DealState(key: key)
    }

    public func allStates() async throws -> [String: DealState] {
        try await db.pool.read { db in Dictionary(uniqueKeysWithValues: try DealState.fetchAll(db).map { ($0.key, $0) }) }
    }

    public func update(_ key: String, _ change: @escaping @Sendable (inout DealState) -> Void) async throws {
        try await db.pool.write { db in
            var s = try DealState.fetchOne(db, key: key) ?? DealState(key: key)
            change(&s)
            try s.save(db)
        }
    }

    /// Marks the deal's current next step done. It leaves "You owe the next step" until new mail or a meeting arrives.
    public func markDone(_ deal: DealRecord, now: Date = Date()) async throws {
        let step = deal.nextStep, activity = deal.activityKey
        try await update(deal.key) { $0.doneStep = step; $0.doneAt = now; $0.doneActivityKey = activity }
    }

    public func undoDone(_ key: String) async throws {
        try await update(key) { $0.doneStep = nil; $0.doneAt = nil; $0.doneActivityKey = nil }
    }

    /// What Claude gets about each deal besides mail and meetings: the user's notes, the step they finished, and the CRM.
    public struct Context: Sendable {
        public var notes: [DealNote] = []
        public var state: DealState?
        public var crmName: String = "CRM"
        /// The newest thing the user or the CRM added, so the deal is read again after it.
        public var changedAt: Date? {
            ([notes.map(\.createdAt).max(), state?.crmChangedAt].compactMap { $0 }).max()
        }
    }

    public func contexts(crmName: String) async throws -> [String: Context] {
        let notes = Dictionary(grouping: try await allNotes(), by: \.dealKey)
        let states = try await allStates()
        var out: [String: Context] = [:]
        for k in Set(notes.keys).union(states.keys) { out[k] = Context(notes: notes[k] ?? [], state: states[k], crmName: crmName) }
        return out
    }
}
