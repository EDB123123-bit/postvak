import SwiftUI
import GRDB
import PostvakCore
import PostvakAI

extension AppModel {
    /// Reads the deals again in the background. Changed companies only, unless `force`; just `keys` when given.
    func refreshDeals(force: Bool = false, keys: Set<String>? = nil) {
        guard !dealsRunning, claude.hasKey else { return }
        dealsRunning = true
        dealsError = nil
        let analyzer = dealAnalyzer
        Task {
            do { try await analyzer.run(force: force, keys: keys) }
            catch { dealsError = error.localizedDescription }
            dealsRunning = false
        }
    }

    /// Reads the CRM when the last look is over ten minutes old, and has Claude read again the deals it changed.
    func syncCRMIfStale() {
        guard crm.isConnected, !dealsRunning else { return }
        if let s = engine.db.setting("crm.lastSync"), let t = Double(s), Date().timeIntervalSince1970 - t < 600 { return }
        let crm = crm
        Task {
            do {
                let r = try await crm.sync()
                if !r.changed.isEmpty { refreshDeals(keys: r.changed) }
            } catch {
                try? engine.db.setSetting("crm.lastError", error.localizedDescription)
            }
        }
    }

    /// Saves the note, sends it to the CRM when the deal has a record there, and has Claude read the deal again with it.
    func addDealNote(_ text: String, to deal: DealRecord) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let notes = dealNotes, crm = crm
        Task {
            do {
                try await notes.add(t, to: deal.key)
                await crm.pushNotes()
                refreshDeals(keys: [deal.key])
            } catch { toast(error.localizedDescription, kind: .error) }
        }
    }

    func setDealDone(_ deal: DealRecord, _ done: Bool) {
        let notes = dealNotes
        Task {
            do { if done { try await notes.markDone(deal) } else { try await notes.undoDone(deal.key) } }
            catch { toast(error.localizedDescription, kind: .error) }
        }
    }

    func setCRMStage(_ stage: String, for deal: DealRecord) {
        let crm = crm, notes = dealNotes
        Task {
            do {
                let reason = try await notes.notes(for: deal.key).last?.text ?? (deal.risk.isEmpty ? nil : deal.risk)
                try await crm.setStage(stage, for: deal.key, reason: reason)
                toast("\(deal.company) is now \(stage) in \(crm.config.name)")
            } catch { toast(error.localizedDescription, kind: .error) }
        }
    }

    func dismissCRMStage(_ stage: String, for deal: DealRecord) {
        let crm = crm
        Task { try? await crm.dismissProposal(stage, for: deal.key) }
    }
}

/// The most important deals across the user's ventures: where each stands, what happens next and who owes it.
struct DealsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var records: [DealRecord] = []
    @State private var marks: [String: [Deals.Mark]] = [:]
    @State private var venture: String?
    @State private var stage: DealRecord.Stage?
    @State private var showShelved = false
    @State private var replies: [Deals.FirstMailGroup] = []
    @State private var repliesTotal: Deals.FirstMailGroup?
    @State private var followUps: [Deals.MeetingFollowUp] = []
    @State private var followUpMedian: Double?
    @State private var followUpCount = 0
    @State private var lastRun: Date?
    @State private var enabled = true
    @State private var states: [String: DealState] = [:]
    @State private var notes: [String: [DealNote]] = [:]
    @State private var noteDeal: DealRecord?
    @State private var showDone = false

    static let back: TimeInterval = 61 * 86400
    static let ahead: TimeInterval = 30 * 86400

    private var deals: [DealRecord] { records.filter(\.isDeal) }
    private var ventures: [String] {
        let counts = Dictionary(grouping: deals, by: \.venture).mapValues(\.count)
        return counts.keys.sorted { a, b in
            if (a == "Unclear") != (b == "Unclear") { return b == "Unclear" }
            return counts[a]! != counts[b]! ? counts[a]! > counts[b]! : a < b
        }
    }
    private var pool: [DealRecord] { deals.filter { venture == nil || $0.venture == venture } }
    private var open: [DealRecord] { pool.filter(\.stage.isOpen).sorted(by: Self.rank) }
    private var shelved: [DealRecord] { pool.filter { !$0.stage.isOpen }.sorted { $0.company < $1.company } }
    /// How many deals get a big card on the overview.
    static let topCount = 4
    private func isDone(_ d: DealRecord) -> Bool { states[d.key]?.isDone(d) ?? false }
    private var youOwe: [DealRecord] { open.filter { $0.owner == .you && !isDone($0) } }
    /// Steps the user marked done, hidden until new mail or a meeting arrives.
    private var doneList: [DealRecord] { open.filter { $0.owner == .you && isDone($0) } }
    /// Open deals below the big cards that are not already in the "you owe" list.
    private var otherOpen: [DealRecord] { open.dropFirst(Self.topCount).filter { $0.owner != .you } }
    /// Deals whose CRM stage Claude's reading says should change, waiting for the user's yes.
    private var proposals: [(deal: DealRecord, stage: String)] {
        pool.compactMap { d in SupabaseCRM.proposedStage(for: d, state: states[d.key]).map { (d, $0) } }
    }

    static func rank(_ a: DealRecord, _ b: DealRecord) -> Bool {
        if a.importance != b.importance { return a.importance > b.importance }
        let order: [DealRecord.Owner: Int] = [.you: 0, .meeting: 1, .them: 2, .none: 3]
        if order[a.owner]! != order[b.owner]! { return order[a.owner]! < order[b.owner]! }
        return a.company < b.company
    }

    func color(_ v: String) -> Color {
        guard v != "Unclear", let i = ventures.firstIndex(of: v) else { return .gray }
        return Color(hex: [Engine.accountColors[2], Engine.accountColors[1], Engine.accountColors[4], Engine.accountColors[5], Engine.accountColors[0], Engine.accountColors[3]][i % 6])
    }

    var body: some View {
        Group {
            if !model.claude.hasKey {
                ContentUnavailableView {
                    Label("Add your Claude API key", systemImage: "briefcase")
                } description: {
                    Text("Claude reads your mail and meetings to find your deals, where each one stands and what happens next.")
                } actions: {
                    SettingsLink { Text("Open Settings") }
                }
            } else if !enabled {
                ContentUnavailableView("Deals are switched off", systemImage: "briefcase",
                                       description: Text("Turn them on in Settings, under AI."))
            } else if deals.isEmpty {
                VStack(spacing: 12) {
                    if model.dealsRunning {
                        ProgressView()
                        Text("Reading your mail and meetings with your busiest companies…").foregroundStyle(.secondary)
                        Text("The first time takes about a minute.").font(.caption).foregroundStyle(.secondary)
                    } else if let e = model.dealsError {
                        Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Button("Try Again") { model.refreshDeals(force: true) }
                    } else {
                        ContentUnavailableView("No deals found yet", systemImage: "briefcase",
                                               description: Text("Deals appear once you exchange mail or meet with a company."))
                        Button("Read My Mail Now") { model.refreshDeals(force: true) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        if !proposals.isEmpty { proposalSection }
                        tiles
                        board
                        cardList
                        if stage == nil {
                            youOweSection
                            if !otherOpen.isEmpty { otherDeals }
                        }
                        shelvedSection
                        secondary
                        Text("Stages, next steps and amounts are read by Claude from your mails and meeting notes, your own notes and your CRM. Right-click a deal to add a note. Company size comes from what was said, or from general knowledge where marked. The most important deals are ranked by stage, company size and the amount quoted.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .frame(maxWidth: 1240, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Deals")
        .toolbar {
            ToolbarItem {
                Button { model.refreshDeals(force: true) } label: { Label("Read Again", systemImage: "arrow.clockwise") }
                    .disabled(model.dealsRunning || !model.claude.hasKey)
                    .help("Read every busy company's mail and meetings again")
            }
        }
        .task {
            enabled = model.engine.db.settingBool("ai.deals", default: true)
            let o = ValueObservation.tracking { try DealRecord.fetchAll($0) }
            do { for try await v in o.values(in: model.engine.db.pool) { records = v } } catch {}
        }
        .task {
            let o = ValueObservation.tracking { db in (try DealState.fetchAll(db), try DealNote.order(Column("createdAt")).fetchAll(db)) }
            do {
                for try await (s, n) in o.values(in: model.engine.db.pool) {
                    states = Dictionary(uniqueKeysWithValues: s.map { ($0.key, $0) })
                    notes = Dictionary(grouping: n, by: \.dealKey)
                }
            } catch {}
        }
        .task { model.syncCRMIfStale() }
        .sheet(item: $noteDeal) { d in
            DealNoteSheet(deal: d, notes: notes[d.key] ?? [], state: states[d.key], crmName: model.crm.config.name, crmConnected: model.crm.isConnected)
        }
        .task(id: records.map(\.key).joined(separator: ",")) {
            let keys = Set(records.filter(\.isDeal).map(\.key))
            let now = Date()
            marks = (try? await model.deals.marks(for: keys, from: now.addingTimeInterval(-Self.back), to: now.addingTimeInterval(Self.ahead))) ?? [:]
        }
        .task(id: model.dealsRunning) {
            if let s = model.engine.db.setting("deals.lastRun"), let t = Double(s) { lastRun = Date(timeIntervalSince1970: t) }
            guard !model.dealsRunning else { return }
            if let r = try? await model.deals.firstMailReplies() { replies = r.groups; repliesTotal = r.total }
            if let f = try? await model.deals.meetingFollowUps() { followUps = f.recent; followUpMedian = f.medianHours; followUpCount = f.measured }
            if model.dealAnalyzer.isDue() { model.refreshDeals() }
        }
    }

    // MARK: header and filters

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if model.dealsRunning {
                    ProgressView().controlSize(.small)
                    Text("Reading new mail and meetings…")
                } else if let lastRun {
                    Text("Read by Claude \(lastRun.formatted(.relative(presentation: .named))) from \(records.count) companies")
                }
                if let e = model.dealsError, !model.dealsRunning {
                    Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(1)
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                chip("All ventures", count: deals.count, dot: nil, selected: venture == nil) { venture = nil; stage = nil }
                ForEach(ventures, id: \.self) { v in
                    chip(v == "Unclear" ? "Venture unclear" : v, count: deals.filter { $0.venture == v }.count, dot: color(v), selected: venture == v) {
                        venture = v; stage = nil
                    }
                }
            }
        }
    }

    private func chip(_ title: String, count: Int, dot: Color?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
                Text(title)
                Text("\(count)").foregroundStyle(selected ? Color(nsColor: .windowBackgroundColor).opacity(0.8) : .secondary)
            }
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(selected ? Color(nsColor: .windowBackgroundColor) : .primary)
            .background(Capsule().fill(selected ? Color.primary : Color.clear))
            .overlay(Capsule().strokeBorder(selected ? Color.primary : Color.secondary.opacity(0.3)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: tiles

    private var tiles: some View {
        let youOwe = self.youOwe
        let theyOwe = open.filter { $0.owner == .them }
        let soonLimit = Date().addingTimeInterval(7 * 86400)
        let soon = open.filter { d in (marks[d.key] ?? []).contains { $0.kind == .booked && $0.date <= soonLimit } }
        let proposals = open.filter { $0.stage == .proposal }.sorted { $0.amountEUR > $1.amountEUR }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
            tile("You owe the next step", youOwe.count, youOwe.isEmpty ? "Nothing waits on you" : names(youOwe))
            tile("Waiting on them", theyOwe.count, theyOwe.isEmpty ? "Nobody owes you a step" : names(theyOwe))
            tile("Meetings in the next 7 days", soon.count, soon.isEmpty ? "None booked" : names(soon))
            tile("Proposals out", proposals.count, proposals.first.map { $0.amount.isEmpty ? names(proposals) : "Largest: \($0.company), \($0.amount)" } ?? "No open proposals")
        }
    }

    private func names(_ list: [DealRecord], max: Int = 4) -> String {
        let n = list.map(\.company)
        return n.count <= max ? n.joined(separator: ", ") : n.prefix(max).joined(separator: ", ") + " and \(n.count - max) more"
    }

    private func tile(_ title: String, _ value: Int, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            Text("\(value)").font(.system(size: 32, weight: .semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.15)))
    }

    // MARK: stage board

    private var board: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Where every open deal stands").font(.headline)
                Spacer()
                Text("Click a stage to list its deals. \(shelved.count) parked or lost deals are left out.").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(DealRecord.Stage.pipeline, id: \.self) { s in
                    let xs = open.filter { $0.stage == s }
                    Button { stage = stage == s ? nil : s } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            StageBar(stage: s, segment: 9, height: 4)
                            Text(s.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text("\(xs.count)").font(.system(size: 24, weight: .semibold))
                            ForEach(xs.prefix(5)) { d in
                                HStack(spacing: 5) {
                                    Circle().fill(color(d.venture)).frame(width: 6, height: 6)
                                    Text(d.company).lineLimit(1)
                                }
                                .font(.caption)
                            }
                            if xs.count > 5 { Text("+ \(xs.count - 5) more").font(.caption).foregroundStyle(.secondary) }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(stage == s ? Color.primary.opacity(0.06) : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(stage == s ? Color.primary : Color.secondary.opacity(0.2)))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.15)))
    }

    // MARK: deal cards

    private var cardList: some View {
        let list = stage.map { s in open.filter { $0.stage == s } } ?? Array(open.prefix(Self.topCount))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(stage.map { "\($0.title) · \(list.count)" } ?? "Most important deals").font(.title3.weight(.semibold))
                    Text(stage == nil ? "Ranked by how far along they are, company size and the amount you quoted." : "Every open deal at this stage, most important first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if stage != nil { Button("Back to Most Important") { stage = nil }.buttonStyle(.link) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 470), spacing: 14)], spacing: 14) {
                ForEach(list) { d in
                    DealCard(deal: d, ventureColor: color(d.venture), marks: marks[d.key] ?? [], open: openLatest)
                        .contextMenu { dealMenu(d) }
                }
            }
        }
    }

    private func openLatest(_ d: DealRecord) {
        guard let t = d.latestThread, let slash = t.firstIndex(of: "/") else { return }
        openWindow(value: ThreadWindowRef(accountId: String(t[..<slash]), threadId: String(t[t.index(after: slash)...])))
    }

    @ViewBuilder private func dealMenu(_ d: DealRecord) -> some View {
        Button("Add Note…") { noteDeal = d }
        if d.owner == .you {
            if isDone(d) { Button("Mark Step Not Done") { model.setDealDone(d, false) } }
            else { Button("Mark Step Done") { model.setDealDone(d, true) } }
        }
        if d.latestThread != nil { Button("Open Latest Mail") { openLatest(d) } }
    }

    // MARK: CRM stage proposals

    private var proposalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Update \(model.crm.config.name)?").font(.headline)
            ForEach(proposals, id: \.deal.key) { p in
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
                    Text("\(p.deal.company) reads as \(p.deal.stage.title.lowercased()), but \(model.crm.config.name) still says \(states[p.deal.key]?.crmStage ?? "something else").")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Not Now") { model.dismissCRMStage(p.stage, for: p.deal) }
                    Button("Set to \(p.stage)") { model.setCRMStage(p.stage, for: p.deal) }.buttonStyle(.borderedProminent)
                }
                .font(.callout)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.blue.opacity(0.3)))
    }

    // MARK: you owe, other and shelved deals

    private var youOweSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("You owe the next step · \(youOwe.count)").font(.headline)
                Spacer()
                Text("Every open deal waiting on you, most important first.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)
            if youOwe.isEmpty {
                Text("Nothing waits on you.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(youOwe) { d in
                OwedRow(deal: d, ventureColor: color(d.venture), lastContact: DealCard.lastContact(marks[d.key] ?? []), open: openLatest,
                        note: notes[d.key]?.last?.text, crmStage: states[d.key]?.crmStage, crmName: model.crm.config.name,
                        done: { model.setDealDone(d, true) }, addNote: { noteDeal = d })
                    .contextMenu { dealMenu(d) }
                if d.id != youOwe.last?.id { Divider() }
            }
            if !doneList.isEmpty {
                DisclosureGroup(isExpanded: $showDone) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(doneList) { d in
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text(d.company).fontWeight(.semibold).frame(width: 190, alignment: .leading).lineLimit(1)
                                Text(states[d.key]?.doneStep ?? d.nextStep).strikethrough().foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button("Undo") { model.setDealDone(d, false) }.buttonStyle(.link)
                            }
                            .font(.callout)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Done, back when new mail or a meeting arrives · \(doneList.count)").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 10)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.15)))
    }

    private var otherDeals: some View {
        let rest = otherOpen
        return VStack(alignment: .leading, spacing: 0) {
            Text("Other open deals · \(rest.count)").font(.headline).padding(.bottom, 8)
            ForEach(rest) { d in
                DealRow(deal: d, ventureColor: color(d.venture), lastContact: DealCard.lastContact(marks[d.key] ?? []), open: openLatest, note: notes[d.key]?.last?.text)
                    .contextMenu { dealMenu(d) }
                Divider()
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.15)))
    }

    private var shelvedSection: some View {
        DisclosureGroup(isExpanded: $showShelved) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(shelved) { d in
                    DealRow(deal: d, ventureColor: color(d.venture), lastContact: DealCard.lastContact(marks[d.key] ?? []), open: openLatest, note: notes[d.key]?.last?.text)
                        .contextMenu { dealMenu(d) }
                    Divider()
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Parked and lost · \(shelved.count)").font(.headline)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.15)))
    }

    // MARK: secondary measures

    private var secondary: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 14, alignment: .top)], spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Who answers a first mail").font(.headline)
                Text(repliesTotal.map { "First mails to new addresses in the last 12 weeks, answered within 7 days. \($0.replied) of \($0.sent) overall." } ?? "Counting…")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(replies, id: \.self) { g in
                    HStack(spacing: 10) {
                        Text(g.subject).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        GeometryReader { geo in
                            HStack(spacing: 6) {
                                UnevenRoundedRectangle(cornerRadii: .init(bottomTrailing: 4, topTrailing: 4))
                                    .fill(Color.blue).frame(width: max(0, geo.size.width * 0.75 * rate(g)), height: 12)
                                Text("\(Int((rate(g) * 100).rounded()))%").font(.caption.weight(.semibold)).monospacedDigit()
                            }
                            .frame(maxHeight: .infinity)
                        }
                        .frame(width: 160, height: 18)
                        Text("\(g.replied) of \(g.sent)").font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                    .font(.callout)
                    Divider()
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.15)))

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Follow-up after meetings").font(.headline)
                        Text("Time from the end of a meeting to your first mail to that company").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(followUpMedian.map(Self.lag) ?? "–").font(.title3.weight(.semibold))
                        Text("median, \(followUpCount) meetings").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(followUps, id: \.self) { f in
                    HStack(spacing: 10) {
                        Text(f.date.formatted(.dateTime.day().month(.abbreviated))).foregroundStyle(.secondary).monospacedDigit().frame(width: 52, alignment: .leading)
                        Text(f.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Circle().fill(Self.followColor(f)).frame(width: 8, height: 8)
                        Text(Self.followText(f)).frame(width: 150, alignment: .leading)
                    }
                    .font(.callout)
                    Divider()
                }
                Text("A later meeting booked with the same company counts as invite only.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.15)))
        }
    }

    private func rate(_ g: Deals.FirstMailGroup) -> Double { g.sent == 0 ? 0 : Double(g.replied) / Double(g.sent) }

    static func lag(_ h: Double) -> String {
        if h < 1 { return "within the hour" }
        if h < 48 { return h < 10 ? String(format: "%.1f h", h) : "\(Int(h.rounded())) h" }
        return "\(Int((h / 24).rounded())) days"
    }

    static func followText(_ f: Deals.MeetingFollowUp) -> String {
        if let h = f.lagHours { return h < 1 ? "Mail within the hour" : "Mail after \(lag(h))" }
        return f.invited ? "Invite only" : "Nothing yet"
    }

    static func followColor(_ f: Deals.MeetingFollowUp) -> Color {
        if let h = f.lagHours { return h <= 24 ? .green : .orange }
        return f.invited ? .yellow : .red
    }
}

/// Six short bars filled up to the deal's stage.
struct StageBar: View {
    let stage: DealRecord.Stage
    var segment: CGFloat = 14
    var height: CGFloat = 5
    var body: some View {
        let index = DealRecord.Stage.pipeline.firstIndex(of: stage) ?? -1
        HStack(spacing: 2) {
            ForEach(0..<6, id: \.self) { i in
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(i <= index ? Color.blue : Color.secondary.opacity(0.22))
                    .frame(width: segment, height: height)
            }
        }
        .accessibilityHidden(true)
    }
}

struct OwnerBadge: View {
    let owner: DealRecord.Owner
    var body: some View {
        let label: String = switch owner {
        case .you: "You owe it"
        case .them: "They owe it"
        case .meeting: "Meeting booked"
        case .none: "No next step"
        }
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(owner == .you ? Color(nsColor: .windowBackgroundColor) : owner == .none ? .secondary : .primary)
            .background(Capsule().fill(owner == .you ? Color.primary : Color.clear))
            .overlay(Capsule().strokeBorder(owner == .you ? Color.primary : Color.secondary.opacity(0.4)))
            .fixedSize()
    }
}

/// One important deal: stage, next step and who owes it, amount, size and last contact.
struct DealCard: View {
    let deal: DealRecord
    let ventureColor: Color
    let marks: [Deals.Mark]
    let open: (DealRecord) -> Void

    static func lastContact(_ marks: [Deals.Mark], now: Date = Date()) -> Int? {
        marks.filter { $0.kind != .booked && $0.date <= now }.map(\.date).max().map { Calendar.current.dateComponents([.day], from: $0, to: now).day ?? 0 }
    }

    static func lastContactText(_ days: Int?) -> String {
        guard let days else { return "No contact in two months" }
        return days == 0 ? "Last contact today" : days == 1 ? "Last contact yesterday" : "Last contact \(days) days ago"
    }

    var body: some View {
        let last = Self.lastContact(marks)
        let quiet = (last ?? 0) > 21 && !marks.contains { $0.kind == .booked }
        Button { open(deal) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(deal.company).font(.headline).lineLimit(1)
                            HStack(spacing: 4) {
                                Circle().fill(ventureColor).frame(width: 7, height: 7)
                                Text(deal.venture == "Unclear" ? "Venture unclear" : deal.venture)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            if !deal.risk.isEmpty { RiskChip(text: deal.risk, color: .red) }
                            if quiet, let last { RiskChip(text: "Quiet \(last) days", color: .orange) }
                        }
                        if !deal.contacts.isEmpty { Text(deal.contacts).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(deal.stage.title).font(.caption.weight(.semibold))
                        StageBar(stage: deal.stage)
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    OwnerBadge(owner: deal.owner)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(deal.nextStep).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                        if !deal.due.isEmpty { Text(deal.due).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Divider()
                HStack(spacing: 18) {
                    Text(deal.amount.isEmpty ? "No amount yet" : deal.amount).fontWeight(deal.amount.isEmpty ? .regular : .semibold)
                    Text(deal.size == "unknown" ? "Size unknown" : "\(deal.size.capitalized) company").help(deal.sizeSource.isEmpty ? "Not mentioned in mail or calls" : deal.sizeSource)
                    Text(Self.lastContactText(last))
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.15)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help(deal.latestThread == nil ? "" : "Open the latest mail with \(deal.company)")
    }
}

struct RiskChip: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.35)))
        .fixedSize()
    }
}

struct DealRow: View {
    let deal: DealRecord
    let ventureColor: Color
    let lastContact: Int?
    let open: (DealRecord) -> Void
    var note: String? = nil
    var body: some View {
        Button { open(deal) } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(deal.company).fontWeight(.semibold).lineLimit(1)
                    HStack(spacing: 4) {
                        Circle().fill(ventureColor).frame(width: 7, height: 7)
                        Text(deal.venture == "Unclear" ? "Venture unclear" : deal.venture)
                        if !deal.risk.isEmpty { Text("· \(deal.risk)") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 200, alignment: .leading)
                Text(deal.stage.title).frame(width: 120, alignment: .leading)
                OwnerBadge(owner: deal.owner).frame(width: 110, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(deal.nextStep).fixedSize(horizontal: false, vertical: true)
                    if !deal.due.isEmpty { Text(deal.due).font(.caption).foregroundStyle(.secondary) }
                    if let note { NoteLine(text: note) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(DealCard.lastContactText(lastContact)).font(.caption).foregroundStyle(.secondary).frame(width: 150, alignment: .trailing)
            }
            .font(.callout)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The user's latest note on a deal, under its next step.
struct NoteLine: View {
    let text: String
    var body: some View {
        Label { Text(text).lineLimit(2) } icon: { Image(systemName: "note.text") }
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// A deal waiting on the user: what to do, by when, and how long since the last contact.
/// The circle marks the step done; the note button adds context Claude then reads as fact.
struct OwedRow: View {
    let deal: DealRecord
    let ventureColor: Color
    let lastContact: Int?
    let open: (DealRecord) -> Void
    var note: String? = nil
    var crmStage: String? = nil
    var crmName = "CRM"
    var done: () -> Void = {}
    var addNote: () -> Void = {}
    @State private var hoverCheck = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: done) {
                Image(systemName: hoverCheck ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(hoverCheck ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .onHover { hoverCheck = $0 }
            .help("Mark this step done. It comes back when new mail or a meeting arrives.")
            .padding(.top, 6)
            Button { open(deal) } label: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(deal.company).fontWeight(.semibold).lineLimit(1)
                        HStack(spacing: 4) {
                            Circle().fill(ventureColor).frame(width: 7, height: 7)
                            Text(deal.venture == "Unclear" ? "Venture unclear" : deal.venture)
                            Text("· \(deal.stage.title)")
                        }
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let crmStage { Text("\(crmName): \(crmStage)").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    .frame(width: 210, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(deal.nextStep).fixedSize(horizontal: false, vertical: true)
                        if !deal.due.isEmpty { Text(deal.due).font(.caption).foregroundStyle(.secondary) }
                        if let note { NoteLine(text: note) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(DealCard.lastContactText(lastContact)).font(.caption).foregroundStyle(.secondary).frame(width: 150, alignment: .trailing)
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(deal.latestThread == nil ? "" : "Open the latest mail with \(deal.company)")
            Button(action: addNote) { Image(systemName: note == nil ? "square.and.pencil" : "note.text") }
                .buttonStyle(.borderless)
                .help("Add a note: context Claude takes as fact, like \"Lost, they built it themselves\"")
                .padding(.top, 8)
        }
        .font(.callout)
    }
}

/// The user's notes on one deal, and a field for a new one. Claude reads them as fact the next time it reads the deal,
/// which happens right after saving; the CRM gets a copy when the deal has a record there.
struct DealNoteSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let deal: DealRecord
    let notes: [DealNote]
    let state: DealState?
    let crmName: String
    let crmConnected: Bool
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes on \(deal.company)").font(.title3.weight(.semibold))
                Text("Next step now: \(deal.nextStep)").font(.callout).foregroundStyle(.secondary)
                Text(crmLine).font(.caption).foregroundStyle(.secondary)
            }
            if !notes.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(notes) { n in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(n.text).fixedSize(horizontal: false, vertical: true)
                                    Text(status(n)).font(.caption).foregroundStyle(n.crmError == nil ? Color.secondary : Color.orange)
                                }
                                Spacer()
                                Button { Task { try? await model.dealNotes.delete(n.id) } } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .help(n.crmPushedAt == nil ? "Delete this note" : "Delete this note in Postvak. The copy in \(crmName) stays.")
                            }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Like: Lost on 6 Oct, they built it themselves. Or: Waiting until their budget is approved in January.")
                            .foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                    }
                }
            Text("Claude takes your notes as fact, above mail and meetings, and reads this deal again as soon as you save.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Note") {
                    model.addDealNote(text, to: deal)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var crmLine: String {
        guard crmConnected else { return "No CRM connected. Notes stay in Postvak (Settings → CRM to connect one)." }
        guard let s = state, s.crmLeadId != nil else { return "No matching record in \(crmName), so notes stay in Postvak." }
        return "\(crmName): \(s.crmCompany ?? deal.company), \(s.crmStage ?? "no stage"). New notes are copied there."
    }

    private func status(_ n: DealNote) -> String {
        let when = n.createdAt.formatted(date: .abbreviated, time: .shortened)
        if n.crmPushedAt != nil { return "\(when) · in \(crmName)" }
        if let e = n.crmError { return "\(when) · not in \(crmName) yet: \(e)" }
        return when
    }
}
