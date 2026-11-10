import SwiftUI
import AppKit
import ServiceManagement
import PostvakCore
import PostvakAudio
import PostvakAI
import GRDB

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsPane().tabItem { Label("Accounts", systemImage: "person.2") }
            SignaturesPane().tabItem { Label("Signatures", systemImage: "signature") }
            BookingPane().tabItem { Label("Booking", systemImage: "calendar.badge.plus") }
            MeetingsPane().tabItem { Label("Meetings", systemImage: "waveform") }
            AIPane().tabItem { Label("AI", systemImage: "sparkles") }
            CRMPane().tabItem { Label("CRM", systemImage: "briefcase") }
            MCPPane().tabItem { Label("Claude", systemImage: "link") }
            GeneralPane().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 620, height: 520)
    }
}

struct SecretField: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let key: String
    @State private var value = ""
    var body: some View {
        SecureField(title, text: $value)
            .onAppear { value = model.engine.secrets.get(key) ?? "" }
            .onChange(of: value) { _, v in
                do { try model.engine.secrets.set(key, v.trimmingCharacters(in: .whitespacesAndNewlines)) }
                catch { model.toast(error.localizedDescription, kind: .error) }
            }
    }
}

/// The letter shown inside an account's colour. Empty goes back to the default.
struct BadgeField: View {
    @EnvironmentObject var model: AppModel
    let account: Account
    @State private var text = ""

    var body: some View {
        TextField(Account.defaultBadge(for: account.id), text: $text)
            .frame(width: 28).multilineTextAlignment(.center)
            .help("The letter inside this account's colour. Leave empty for \(Account.defaultBadge(for: account.id)).")
            .onAppear { text = account.badge ?? "" }
            .onChange(of: text) { _, v in
                let letter = v.trimmingCharacters(in: .whitespaces).prefix(1).uppercased()
                if text != letter { text = letter; return }
                let id = account.id, value: String? = letter.isEmpty ? nil : letter
                model.perform { try await model.engine.setAccountBadge(id, value) }
            }
    }
}

struct AccountsPane: View {
    @EnvironmentObject var model: AppModel
    @State private var busy = false
    @State private var removing: Account?
    @State private var clientId = ""

    var body: some View {
        Form {
            Section("Google OAuth client") {
                TextField("Client ID", text: $clientId)
                    .onAppear { clientId = model.engine.secrets.get(SecretKey.googleClientId) ?? "" }
                    .onChange(of: clientId) { _, v in try? model.engine.secrets.set(SecretKey.googleClientId, v.trimmingCharacters(in: .whitespacesAndNewlines)) }
                SecretField(title: "Client secret", key: SecretKey.googleClientSecret)
                Text("Setup steps are in docs/setup-google.md in the Postvak repository.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Accounts") {
                ForEach(model.accounts) { a in
                    HStack {
                        AccountBadge(account: a, size: 20)
                        VStack(alignment: .leading) {
                            Text(a.email)
                            Text(status(a)).font(.caption).foregroundStyle(a.lastError == nil ? Color.secondary : Color.orange).lineLimit(2)
                        }
                        Spacer()
                        BadgeField(account: a)
                        if a.needsReauth { Button("Sign In") { signIn() } }
                        Button("Remove") { removing = a }
                    }
                }
                Button(busy ? "Waiting for the browser…" : "Add Google Account") { signIn() }.disabled(busy || clientId.isEmpty)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove \(removing?.email ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let a = removing { model.perform { try await model.engine.removeAccount(a.id) } }
            }
        } message: { Text("Removes this account's mail and events from this Mac. Nothing changes in Gmail.") }
    }

    private func status(_ a: Account) -> String {
        if let e = a.lastError { return e }
        if !a.initialSyncDone { return "Syncing, \(a.syncedThreadCount) threads so far" }
        if let d = a.lastSyncAt { return "Synced \(d.formatted(date: .omitted, time: .shortened))" }
        return "Waiting to sync"
    }

    private func signIn() {
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await model.engine.addAccount { url in DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
            } catch { model.toast(error.localizedDescription, kind: .error, seconds: 8) }
        }
    }
}

struct SignaturesPane: View {
    @EnvironmentObject var model: AppModel
    @State private var account = ""
    @State private var html = ""
    @State private var loading = false

    var body: some View {
        Form {
            Picker("Account", selection: $account) {
                ForEach(model.accounts) { Text($0.email).tag($0.id) }
            }
            Section("Signature (HTML). Saved to Gmail, so Gmail web shows the same one.") {
                TextEditor(text: $html).font(.system(.body, design: .monospaced)).frame(minHeight: 180)
            }
            Section("Preview") {
                Text(GmailParser.htmlToText(html)).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Save to Gmail") {
                    let a = account, h = html
                    model.perform {
                        try await model.engine.mail.setSignature(accountId: a, html: h)
                        model.toast("Signature saved for \(a).")
                    }
                }
                .disabled(account.isEmpty || loading)
            }
        }
        .formStyle(.grouped)
        .onAppear { if account.isEmpty { account = model.accounts.first?.id ?? "" } }
        .task(id: account) {
            guard !account.isEmpty else { return }
            html = model.engine.mail.cachedSignature(accountId: account)
            loading = true
            defer { loading = false }
            if let s = try? await model.engine.mail.signature(accountId: account) { html = s.html }
        }
    }
}

struct MeetingsPane: View {
    @EnvironmentObject var model: AppModel
    @State private var language = "auto"
    @State private var diarize = true
    @State private var notify = true
    @State private var detect = false
    @State private var autoStop = true
    @State private var autoRecord = false
    @State private var autoRecordRooms = false

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Language", selection: $language) {
                    Text("Detect per meeting").tag("auto")
                    Text("Dutch").tag("nl")
                    Text("French").tag("fr")
                    Text("English").tag("en")
                }
                .onChange(of: language) { _, v in try? model.engine.db.setSetting("transcribe.language", v) }
                Toggle("Separate multiple speakers", isOn: $diarize)
                    .onChange(of: diarize) { _, v in try? model.engine.db.setSetting("transcribe.diarize", v ? "1" : "0") }
                Text("Runs on this Mac. The first meeting downloads the model, about 650 MB, plus the speaker model.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Cloud transcription (optional)") {
                SecretField(title: "Deepgram API key", key: SecretKey.deepgramKey)
                Text("Only used when you choose it for a meeting. That meeting's audio then goes to Deepgram.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Recording") {
                Toggle("Record calls automatically when I join", isOn: $autoRecord)
                    .onChange(of: autoRecord) { _, v in try? model.engine.db.setSetting("meetings.autoRecord", v ? "1" : "0") }
                Text("Records the microphone and the call's sound as soon as you join: when Zoom, Teams or Webex uses the microphone, or Google Meet in your browser or FaceTime during a meeting in your calendar. It stops when the call ends. A notification tells you each time, with a button to stop.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Record meetings in a room automatically", isOn: $autoRecordRooms)
                    .onChange(of: autoRecordRooms) { _, v in try? model.engine.db.setSetting("meetings.autoRecordRooms", v ? "1" : "0") }
                Text("Records the microphone from the start time of a meeting you accepted, with other guests and no video link. It stops 10 minutes after the scheduled end.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Reminders") {
                Toggle("Offer to record just before a meeting", isOn: $notify)
                    .onChange(of: notify) { _, v in try? model.engine.db.setSetting("meetings.notifyEvents", v ? "1" : "0") }
                    .disabled(autoRecord && autoRecordRooms)
                Toggle("Offer to record when a call app uses the microphone", isOn: $detect)
                    .onChange(of: detect) { _, v in try? model.engine.db.setSetting("meetings.detectCalls", v ? "1" : "0") }
                    .disabled(autoRecord)
                Toggle("Stop recording when the call ends", isOn: $autoStop)
                    .onChange(of: autoStop) { _, v in try? model.engine.db.setSetting("meetings.autoStop", v ? "1" : "0") }
                Text("A call recording stops 20 seconds after Meet, Zoom, Teams or another call app stops using the microphone, for example when you close the Meet tab.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Projects") {
                ProjectsEditor()
            }
            Section("Permissions") {
                Button("Open Microphone Settings") { open("Privacy_Microphone") }
                Button("Open System Audio Recording Settings") { open("Privacy_AudioCapture") }
                Text("Recording laws differ per country. Tell everyone in the meeting before you record.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            let db = model.engine.db
            language = db.setting("transcribe.language") ?? "auto"
            diarize = db.settingBool("transcribe.diarize", default: true)
            notify = db.settingBool("meetings.notifyEvents", default: true)
            detect = db.settingBool("meetings.detectCalls", default: false)
            autoStop = db.settingBool("meetings.autoStop", default: true)
            autoRecord = db.settingBool("meetings.autoRecord", default: false)
            autoRecordRooms = db.settingBool("meetings.autoRecordRooms", default: autoRecord)
        }
    }

    private func open(_ anchor: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(u) }
    }
}

struct AIPane: View {
    @EnvironmentObject var model: AppModel
    @State private var classify = true
    @State private var deals = true
    @State private var followUps = FollowUpReview.Frequency.weekly
    var body: some View {
        Form {
            Section("Anthropic API") {
                SecretField(title: "API key", key: SecretKey.anthropicKey)
                Text("Postvak uses \(ClaudeClient.model) for inbox sorting, meeting summaries, Ask, the check before sending, mail follow-up drafts and the follow-up review, prep briefs and deals. Meeting follow-up mails use \(MeetingFollowUpWriter.model).").font(.caption).foregroundStyle(.secondary)
            }
            Section("Usage") { AIUsageView() }
            Section("Smart inbox") {
                Toggle("Ask Claude about threads Gmail's categories get wrong", isOn: $classify)
                    .onChange(of: classify) { _, v in try? model.engine.db.setSetting("ai.classify", v ? "1" : "0") }
                Text("Sends the sender, subject and first 300 characters of those threads to Anthropic. Without it, Gmail's own categories still sort the inbox. Right-click a thread to correct a sender.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Deals") {
                Toggle("Keep a deals overview from your mail and meetings", isOn: $deals)
                    .onChange(of: deals) { _, v in try? model.engine.db.setSetting("ai.deals", v ? "1" : "0") }
                Text("Every six hours, sends the latest mails and meeting notes with your 60 busiest companies to Anthropic, but only for companies with something new. Claude returns each deal's stage, next step and quoted amount.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Follow-up review") {
                Picker("Draft follow-ups", selection: $followUps) {
                    ForEach(FollowUpReview.Frequency.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .onChange(of: followUps) { _, v in try? model.engine.db.setSetting(FollowUpReview.settingKey, v.rawValue) }
                Text("At 8:15, after mail scheduled for 8:00 went out, Postvak looks at the last two weeks for threads where someone waits on you or your mail got no answer, and business meetings nobody wrote to since. It skips anything you already followed up from any account, or queued. For each, it sends the thread to Anthropic, which decides whether a follow-up is worth it and writes it, at most ten per run. The drafts wait under Mail → Review Drafts: nothing is sent until you approve.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            classify = model.engine.db.settingBool("ai.classify", default: true)
            deals = model.engine.db.settingBool("ai.deals", default: true)
            followUps = model.draftReview.frequency
        }
    }
}

/// A CRM kept in Supabase (like one built with Lovable): its address and publishable key, and who Postvak signs in as.
/// Postvak reads each deal's stage, lost reason and notes there, and writes the user's notes and confirmed stage changes back.
struct CRMPane: View {
    @EnvironmentObject var model: AppModel
    @State private var config = SupabaseCRM.Config(name: "", url: "", key: "")
    @State private var logins: [SupabaseCRM.Login] = []
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var status = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section("CRM") {
                TextField("Name", text: $config.name, prompt: Text("Like: Sales CRM"))
                TextField("Supabase URL", text: $config.url, prompt: Text("https://….supabase.co"))
                TextField("Publishable key", text: $config.key, prompt: Text("The anon key the CRM's web app uses"))
                Text("A CRM built on Supabase with leads, activities and lost_reasons tables, like one made with Lovable. The URL and publishable key are in the project's .env file. Deals are matched to leads by company email domain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: config) { _, c in try? model.crm.setConfig(c) }
            Section("Signed in as") {
                ForEach(logins, id: \.self) { l in
                    HStack {
                        Text(l.email)
                        Spacer()
                        Button("Sign Out") { try? model.crm.signOut(l.email); reload() }
                    }
                }
                TextField("Email", text: $email)
                SecureField("Password", text: $password)
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    if let error { Text(error).foregroundStyle(.orange).font(.caption).lineLimit(2) }
                    Spacer()
                    Button("Sign In") { signIn() }
                        .disabled(busy || email.isEmpty || password.isEmpty || !config.isComplete)
                }
                Text("Your CRM's own login. Postvak keeps only a sign-in token, in the Keychain. Sign in with every account that owns leads.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sync") {
                Text(status).font(.callout).foregroundStyle(.secondary)
                Button("Sync Now") { syncNow() }.disabled(busy || !model.crm.isConnected)
                Text("Before each deals reading, and when you open Deals. A deal the CRM marks lost leaves your list, and notes you add to a deal are copied to the CRM. Stage changes are only written after you confirm them on the Deals page.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
    }

    private func reload() {
        config = model.crm.config
        if config.name == "CRM" { config.name = "" }
        logins = model.crm.logins
        let db = model.engine.db
        var s = "Not synced yet."
        if let t = db.setting("crm.lastSync").flatMap(Double.init) {
            s = "Last synced \(Date(timeIntervalSince1970: t).formatted(.relative(presentation: .named)))."
        }
        if let e = db.setting("crm.lastError") { s += " Last error: \(e)" }
        status = s
    }

    private func signIn() {
        busy = true; error = nil
        let crm = model.crm, e = email.trimmingCharacters(in: .whitespaces), p = password
        Task {
            do {
                try await crm.signIn(email: e, password: p)
                password = ""; email = ""
                reload()
                syncNow()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func syncNow() {
        busy = true
        let crm = model.crm
        Task {
            do {
                let r = try await crm.sync()
                status = "Matched \(r.matched) deals, \(r.changed.count) changed, \(r.pushed) notes sent."
                if !r.changed.isEmpty { model.refreshDeals(keys: r.changed) }
            } catch { status = error.localizedDescription }
            busy = false
        }
    }
}

/// Anthropic use this month, per feature, with an estimate from list prices. The bill itself is at console.anthropic.com.
struct AIUsageView: View {
    @EnvironmentObject var model: AppModel
    @State private var month: [ApiUsageRecord] = []
    @State private var today: [ApiUsageRecord] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 24) {
                total("Today", today)
                total("This month", month)
            }
            if month.isEmpty {
                Text("Nothing yet. Each answered request is counted from now on.").font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("Feature"); Text("Requests").gridColumnAlignment(.trailing)
                        Text("Tokens in").gridColumnAlignment(.trailing); Text("Out").gridColumnAlignment(.trailing)
                        Text("Est. cost").gridColumnAlignment(.trailing)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach(month, id: \.self) { r in
                        GridRow {
                            Text(r.model == ClaudeClient.model ? r.feature : "\(r.feature) (\(r.model))")
                            Text("\(r.requests)").monospacedDigit()
                            Text(Self.tokens(r.inputTokens + r.cacheReadTokens + r.cacheWriteTokens)).monospacedDigit()
                            Text(Self.tokens(r.outputTokens)).monospacedDigit()
                            Text(Self.dollars(r.costMicros)).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
            }
            Text("An estimate from Anthropic's list prices, counted on this Mac. Your actual bill is at console.anthropic.com → Usage.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .task {
            let cal = Calendar.current
            let monthStart = cal.dateInterval(of: .month, for: Date())!.start
            let dayStart = cal.startOfDay(for: Date())
            let o = ValueObservation.tracking { db in (try ApiUsage.totals(db, since: monthStart), try ApiUsage.totals(db, since: dayStart)) }
            do { for try await (m, d) in o.values(in: model.engine.db.pool) { month = m; today = d } } catch {}
        }
    }

    private func total(_ label: String, _ rows: [ApiUsageRecord]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(Self.dollars(rows.reduce(0) { $0 + $1.costMicros })).font(.title3.weight(.semibold)).monospacedDigit()
            Text("\(rows.reduce(0) { $0 + $1.requests }) requests").font(.caption).foregroundStyle(.secondary)
        }
    }

    static func dollars(_ micros: Int) -> String {
        let d = Double(micros) / 1_000_000
        return d < 0.01 && micros > 0 ? "< $0.01" : String(format: "$%.2f", d)
    }

    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000) : n >= 1000 ? String(format: "%.0fK", Double(n) / 1000) : "\(n)"
    }
}

struct MCPPane: View {
    @EnvironmentObject var model: AppModel
    @State private var port = ""
    @State private var reveal = false

    private var token: String { model.mcpToken() }
    private var url: String { "http://127.0.0.1:\(model.mcpPort)/mcp" }

    var body: some View {
        Form {
            Section("MCP server") {
                LabeledContent("Address", value: url)
                LabeledContent("State", value: model.mcpError ?? (model.mcpServer == nil ? "Starting" : "Running"))
                TextField("Port", text: $port).onSubmit {
                    if let p = UInt16(port) {
                        try? model.engine.db.setSetting("mcp.port", String(p))
                        Task { await model.startMCP() }
                    }
                }
                HStack {
                    Text(reveal ? token : String(repeating: "•", count: 24)).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                    Spacer()
                    Button(reveal ? "Hide" : "Show Token") { reveal.toggle() }
                    Button("New Token") { model.rotateMCPToken() }
                }
                Text("The server listens on this Mac only, and only while Postvak runs. The token stays in the Keychain: Claude connects through a small script that reads it there, so no configuration file holds it. New Token cuts off everything connected with the old one.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Connect Claude") {
                Button("Copy Claude Code Command") { model.copyToPasteboard(model.claudeCodeCommand) }
                Button("Copy Claude Desktop Config") { model.copyToPasteboard(model.claudeDesktopConfig) }
                Text("For Claude Desktop, paste the block inside mcpServers in claude_desktop_config.json, then restart it. The first connection asks for Keychain access: click Always Allow. Node.js is needed. See docs/setup-claude.md.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { port = String(model.mcpPort) }
    }
}

struct GeneralPane: View {
    @EnvironmentObject var model: AppModel
    @State private var window = 365
    @State private var login = SMAppService.mainApp.status == .enabled
    var body: some View {
        Form {
            Section("Mail") {
                Picker("Keep locally", selection: $window) {
                    Text("3 months").tag(90)
                    Text("12 months").tag(365)
                    Text("2 years").tag(730)
                    Text("5 years").tag(1825)
                }
                .onChange(of: window) { _, v in try? model.engine.db.setSetting("sync.windowDays", String(v)) }
                Text("A longer window applies to accounts added after the change. Search can always ask Gmail for older mail.").font(.caption).foregroundStyle(.secondary)
            }
            Section("App") {
                Toggle("Open at login", isOn: $login).onChange(of: login) { _, v in
                    do { if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { model.toast(error.localizedDescription, kind: .error) }
                }
                Text("Scheduled mail, snooze and Claude's access only work while Postvak runs. Closing the window keeps it running in the menu bar.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Data") {
                Button("Show Data Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.engine.paths.root]) }
            }
        }
        .formStyle(.grouped)
        .onAppear { window = Int(model.engine.db.setting("sync.windowDays") ?? "") ?? 365 }
    }
}

/// The rules that file meetings under projects. They are data in the database, so changing them needs no new build.
struct ProjectsEditor: View {
    @EnvironmentObject var model: AppModel
    struct Draft: Identifiable {
        let id = UUID()
        var name = "", accounts = "", addresses = "", domains = ""
    }
    @State private var drafts: [Draft] = []
    @State private var saved = true

    var body: some View {
        ForEach($drafts) { $d in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("Project", text: $d.name).font(.headline)
                    Button(role: .destructive) { drafts.removeAll { $0.id == d.id }; saved = false } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove this project")
                }
                TextField("Your accounts", text: $d.accounts, prompt: Text("you@yourcompany.com"))
                TextField("Exact addresses", text: $d.addresses, prompt: Text("info@yourcompany.com, a client at gmail.com"))
                TextField("Company domains", text: $d.domains, prompt: Text("yourcompany.com, supplier.com"))
            }
            .padding(.vertical, 4)
            .onChange(of: d.name) { saved = false }
            .onChange(of: d.accounts) { saved = false }
            .onChange(of: d.addresses) { saved = false }
            .onChange(of: d.domains) { saved = false }
        }
        HStack {
            Button("Add Project") { drafts.append(Draft()); saved = false }
            Spacer()
            Button("Save and File Meetings Again") { save() }.disabled(saved)
        }
        Text("""
        A meeting goes to a project when a guest's exact address or company domain is listed there; otherwise when the invitation \
        went to one of your company addresses of that project; otherwise when at least 80% of the mail with its guests belongs to \
        that project. An imported meeting tagged like "[Acme] Demo" follows its tag. Clues pointing at two projects leave the \
        meeting unfiled. Generic providers such as gmail.com never count as a company. Separate entries with commas. Meetings you \
        filed by hand keep their project.
        """)
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        .task { await load() }
    }

    private func load() async {
        guard let c = try? await model.engine.meetings.projectConfig() else { return }
        drafts = c.projects.map { Draft(name: $0.name, accounts: $0.accounts.joined(separator: ", "),
                                        addresses: $0.addresses.joined(separator: ", "), domains: $0.domains.joined(separator: ", ")) }
        saved = true
    }

    private func save() {
        func list(_ s: String) -> [String] { s.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " }).map(String.init) }
        let config = ProjectConfig(projects: drafts.map {
            ProjectRule(name: $0.name, accounts: list($0.accounts), addresses: list($0.addresses), domains: list($0.domains))
        })
        model.perform {
            try await model.engine.meetings.saveProjectConfig(config)
            await load()
        }
    }
}
