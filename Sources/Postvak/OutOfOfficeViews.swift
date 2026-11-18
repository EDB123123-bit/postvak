import SwiftUI
import PostvakCore
import GRDB

/// Each account's out-of-office reply as Gmail holds it, for the banner and Settings. Read from this Mac at launch,
/// then from Gmail every half hour and whenever Settings opens.
@MainActor
final class OutOfOfficeStatus: ObservableObject {
    @Published private(set) var byAccount: [String: OutOfOffice] = [:]
    /// Moves on every few minutes, so a reply that just started or ended shows without waiting for Gmail.
    @Published private(set) var now = Date()
    private unowned let model: AppModel
    private var ticker: Task<Void, Never>?
    private var lastRefresh = Date.distantPast

    init(model: AppModel) { self.model = model }

    func start() {
        for a in storedAccounts() { byAccount[a.id] = model.engine.mail.cachedOutOfOffice(accountId: a.id) }
        guard !model.demoMode else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.now = Date()
                if self.now.timeIntervalSince(self.lastRefresh) > 30 * 60 { await self.refresh() }
                try? await Task.sleep(for: .seconds(5 * 60))
            }
        }
    }

    func refresh() async {
        lastRefresh = Date()
        for a in storedAccounts() where !a.needsReauth {
            if let o = try? await model.engine.mail.outOfOffice(accountId: a.id) { byAccount[a.id] = o }
        }
        now = Date()
    }

    /// Straight from the database: the model's own list fills in a moment after launch.
    private func storedAccounts() -> [Account] {
        (try? model.engine.db.pool.read { try Account.fetchAll($0) }) ?? []
    }

    func save(_ o: OutOfOffice, for account: String) async throws -> OutOfOffice {
        let saved = try await model.engine.mail.setOutOfOffice(accountId: account, o)
        byAccount[account] = saved
        now = Date()
        return saved
    }

    func turnOff(_ accounts: [String]) async throws {
        for a in accounts { byAccount[a] = try await model.engine.mail.turnOffOutOfOffice(accountId: a) }
        now = Date()
    }

    /// Accounts replying right now, in sidebar order.
    var active: [(account: String, reply: OutOfOffice)] {
        model.accounts.compactMap { a in byAccount[a.id].flatMap { $0.isActive(now: now) ? (a.id, $0) : nil } }
    }
}

// MARK: banner

/// While automatic replies go out, a quiet reminder above the page, so they aren't left on after coming back.
struct OutOfOfficeBanner: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var status: OutOfOfficeStatus
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsView.tabKey) private var settingsTab = ""
    /// Hide keeps the banner away until the accounts or their dates change.
    @AppStorage("outOfOffice.bannerHidden") private var hidden = ""

    var body: some View {
        let active = status.active
        let key = active.map { "\($0.account)|\($0.reply.end?.timeIntervalSince1970 ?? 0)" }.joined(separator: ",")
        if !active.isEmpty, key != hidden {
            HStack {
                Image(systemName: "airplane").foregroundStyle(Color.accentColor)
                Text(Self.text(active)).lineLimit(2)
                Spacer()
                Button("Hide") { hidden = key }
                Button("Edit") { settingsTab = SettingsView.outOfOfficeTab; openSettings() }
                Button("Turn Off") {
                    let accounts = active.map(\.account)
                    model.perform {
                        try await status.turnOff(accounts)
                        model.toast("Automatic replies are off.")
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .bannerStyle()
        }
    }

    static func text(_ active: [(account: String, reply: OutOfOffice)]) -> String {
        let day = { (o: OutOfOffice) in o.lastDay().map { " until \($0.formatted(.dateTime.weekday(.wide).day().month(.wide)))" } ?? "" }
        let ends = Set(active.map { day($0.reply) })
        if ends.count == 1 {
            return "Automatic replies are on for \(ListFormatter.localizedString(byJoining: active.map(\.account)))\(ends.first!)."
        }
        return "Automatic replies are on for " + ListFormatter.localizedString(byJoining: active.map { "\($0.account)\(day($0.reply))" }) + "."
    }
}

// MARK: settings

struct OutOfOfficePane: View {
    @EnvironmentObject var model: AppModel
    @State private var account = ""
    /// What each account's form holds, edited or not; switching accounts keeps the edits.
    @State private var drafts: [String: OutOfOffice] = [:]
    @State private var loading = false
    @State private var saving = false

    private var status: OutOfOfficeStatus { model.outOfOffice }
    private var saved: OutOfOffice? { status.byAccount[account] }
    private var draft: Binding<OutOfOffice> {
        Binding(get: { drafts[account] ?? saved ?? OutOfOffice() }, set: { drafts[account] = $0 })
    }
    private var changed: Bool { drafts[account].map { $0 != (saved ?? OutOfOffice()) } ?? false }
    private var today: Date { Calendar.current.startOfDay(for: Date()) }

    var body: some View {
        Form {
            Section {
                ForEach(model.accounts) { a in accountRow(a) }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Gmail sends these replies, so they go out even when this Mac is off, and Gmail web shows the same setting. Each sender gets one reply every few days, not one per mail.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !account.isEmpty { editor }
        }
        .formStyle(.grouped)
        .onAppear { if account.isEmpty { account = model.accounts.first?.id ?? "" } }
        .task {
            loading = true
            await status.refresh()
            loading = false
        }
    }

    private func accountRow(_ a: Account) -> some View {
        let o = status.byAccount[a.id]
        let on = o?.isActive(now: status.now) == true
        return Button { account = a.id } label: {
            HStack {
                AccountBadge(account: a, size: 20)
                VStack(alignment: .leading) {
                    Text(a.email)
                    Text(o?.statusText(now: status.now) ?? (loading ? "Reading Gmail…" : "Unknown"))
                        .font(.caption).foregroundStyle(on ? Color.green : Color.secondary)
                }
                Spacer()
                if drafts[a.id].map({ $0 != (status.byAccount[a.id] ?? OutOfOffice()) }) == true {
                    Text("Edited").font(.caption).foregroundStyle(.orange)
                }
                Image(systemName: account == a.id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(account == a.id ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var editor: some View {
        Section("Reply from \(account)") {
            Toggle("Send automatic replies", isOn: draft.enabled)
            Toggle("Start on a set day", isOn: Binding(
                get: { draft.wrappedValue.start != nil },
                set: { on in draft.wrappedValue.setDays(first: on ? today : nil, last: draft.wrappedValue.lastDay()) }))
            if let start = draft.wrappedValue.start {
                DatePicker("First day", selection: Binding(
                    get: { start },
                    set: { d in
                        var last = draft.wrappedValue.lastDay()
                        if let l = last, l < d { last = d }
                        draft.wrappedValue.setDays(first: d, last: last)
                    }), displayedComponents: .date)
            }
            Toggle("End on a set day", isOn: Binding(
                get: { draft.wrappedValue.end != nil },
                set: { on in
                    let from = max(draft.wrappedValue.start ?? today, today)
                    draft.wrappedValue.setDays(first: draft.wrappedValue.start,
                                               last: on ? Calendar.current.date(byAdding: .day, value: 6, to: from) : nil)
                }))
            if let last = draft.wrappedValue.lastDay() {
                DatePicker("Last day", selection: Binding(
                    get: { last },
                    set: { draft.wrappedValue.setDays(first: draft.wrappedValue.start, last: $0) }),
                           in: (draft.wrappedValue.start ?? today)..., displayedComponents: .date)
            }
        }
        Section("Message") {
            TextField("Subject", text: draft.subject, prompt: Text("Out of office"))
            TextEditor(text: draft.message).font(.body).frame(minHeight: 130)
                .overlay(alignment: .topLeading) {
                    if draft.wrappedValue.message.isEmpty {
                        Text("Thank you for your mail. I'm away until …, with limited access to mail. For anything urgent, please contact …")
                            .foregroundStyle(.tertiary).padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                    }
                }
        }
        Section("Who gets a reply") {
            Toggle("Only people in my contacts", isOn: draft.contactsOnly)
            if OutOfOffice.supportsDomainOnly(account) {
                Toggle("Only people at \(account.split(separator: "@").last.map(String.init) ?? "my company")", isOn: draft.domainOnly)
            }
        }
        HStack {
            Menu("Copy From") {
                ForEach(model.accounts.filter { $0.id != account }) { a in
                    let source = drafts[a.id] ?? status.byAccount[a.id]
                    Button(a.email) { if let source { copy(source) } }
                        .disabled(source.map { $0.message.isEmpty && $0.subject.isEmpty } ?? true)
                }
            }
            .fixedSize()
            .help("Takes the dates, subject and message of another account. Check the company details in the text before saving.")
            Spacer()
            if changed { Button("Revert") { drafts[account] = nil } }
            Button(saving ? "Saving…" : "Save to Gmail") { save() }
                .buttonStyle(.borderedProminent)
                .disabled(!changed || saving)
                .keyboardShortcut("s", modifiers: .command)
        }
    }

    private func copy(_ source: OutOfOffice) {
        var o = draft.wrappedValue
        o.enabled = source.enabled
        o.subject = source.subject
        o.message = source.message
        o.html = nil
        o.start = source.start
        o.end = source.end
        o.contactsOnly = source.contactsOnly
        o.domainOnly = source.domainOnly && OutOfOffice.supportsDomainOnly(account)
        drafts[account] = o
    }

    private func save() {
        let acct = account
        var o = draft.wrappedValue
        if o.subject.trimmingCharacters(in: .whitespaces).isEmpty { o.subject = "Out of office" }
        saving = true
        model.perform {
            defer { saving = false }
            let stored = try await status.save(o, for: acct)
            drafts[acct] = nil
            model.toast(stored.enabled ? "Saved for \(acct): \(stored.statusText())." : "Automatic replies are off for \(acct).")
        }
    }
}
