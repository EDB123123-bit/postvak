import SwiftUI
import AppKit
import PostvakCore
import PostvakAI

/// The welcome guide: shown once, on the first launch of a fresh install, and again from Help → Postvak Guide.
/// It walks a new user through what Postvak needs (their own Google client, optionally an Anthropic key) and how it works.
extension AppModel {
    static let onboardingDoneKey = "onboarding.done"

    /// Opens the guide on a fresh install. Someone who already has accounts never sees it unasked.
    func maybeShowOnboarding() async {
        guard !demoMode, !showOnboarding else { return }
        let db = engine.db
        guard db.setting(Self.onboardingDoneKey) != "1" else { return }
        let count = (try? await db.pool.read { try Account.fetchCount($0) }) ?? 0
        if count > 0 {
            try? db.setSetting(Self.onboardingDoneKey, "1")
            return
        }
        showOnboarding = true
    }

    func finishOnboarding() {
        try? engine.db.setSetting(Self.onboardingDoneKey, "1")
        showOnboarding = false
    }

    /// Both Claude clients run the bridge script, which reads the token from the Keychain. Nothing secret is copied.
    var claudeCodeCommand: String { "claude mcp add --scope user postvak -- \"\(mcpBridgePath)\"" }
    var claudeDesktopConfig: String {
        """
        "postvak": {
          "command": "\(mcpBridgePath)"
        }
        """
    }

    func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        toast("Copied.")
    }
}

struct OnboardingView: View {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome, google, ai, meetings, claude, tour
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .google: "Google accounts"
            case .ai: "Claude AI"
            case .meetings: "Meetings"
            case .claude: "Claude Code & Desktop"
            case .tour: "How it works"
            }
        }
        var icon: String {
            switch self {
            case .welcome: "hand.wave"
            case .google: "person.2"
            case .ai: "sparkles"
            case .meetings: "waveform"
            case .claude: "link"
            case .tour: "map"
            }
        }
        var optional: Bool { self == .ai || self == .meetings || self == .claude }
    }

    @EnvironmentObject var model: AppModel
    @State private var step: Step = .welcome

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Step.allCases) { s in
                    Button { step = s } label: {
                        HStack(spacing: 8) {
                            Image(systemName: done(s) ? "checkmark.circle.fill" : s.icon)
                                .foregroundStyle(done(s) ? Color.green : (s == step ? Color.accentColor : .secondary))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(s.title).fontWeight(s == step ? .semibold : .regular)
                                if s.optional { Text("Optional").font(.caption2).foregroundStyle(.secondary) }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 6).padding(.horizontal, 8)
                        .background(s == step ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 200)
            .background(.quaternary.opacity(0.4))

            Divider()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        page
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
                Divider()
                HStack {
                    if step != .welcome {
                        Button("Back") { move(-1) }
                    }
                    Spacer()
                    Button("Close Guide") { model.finishOnboarding() }
                        .help("You can open it again from Help → Postvak Guide")
                    if step == .tour {
                        Button("Start Using Postvak") { model.finishOnboarding() }
                            .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    } else {
                        Button(nextTitle) { move(1) }
                            .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 760, height: 580)
    }

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome: WelcomePage()
        case .google: GooglePage()
        case .ai: AIKeyPage()
        case .meetings: MeetingsPage()
        case .claude: ClaudePage()
        case .tour: TourPage()
        }
    }

    private var nextTitle: String {
        if step == .welcome { return "Get Started" }
        if step == .google && model.accounts.isEmpty { return "Skip for Now" }
        if step.optional && !done(step) { return "Skip" }
        return "Continue"
    }

    private func done(_ s: Step) -> Bool {
        switch s {
        case .google: !model.accounts.isEmpty
        case .ai: !(model.engine.secrets.get(SecretKey.anthropicKey) ?? "").isEmpty
        default: false
        }
    }

    private func move(_ by: Int) {
        if let s = Step(rawValue: step.rawValue + by) { step = s }
    }
}

// MARK: pages

private struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Note: View {
    let icon: String
    let text: String
    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: icon).foregroundStyle(.secondary) }
            .font(.callout)
    }
}

private struct NumberedSteps: View {
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, s in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                    Text(.init(s)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
    }
}

private struct WelcomePage: View {
    var body: some View {
        PageHeader(title: "Welcome to Postvak",
                   subtitle: "One Mac app for the mail and agendas of all your Gmail accounts, with your meetings recorded and transcribed on this Mac, and everything available to Claude.")
        VStack(alignment: .leading, spacing: 10) {
            Note(icon: "tray.2", text: "All your Gmail accounts in one inbox, sorted into People, Notifications and Newsletters.")
            Note(icon: "calendar", text: "Your calendars side by side, with a brief before each meeting.")
            Note(icon: "waveform", text: "Record a call or a meeting in a room. It is transcribed and summarised, and you can ask questions across all your meetings.")
            Note(icon: "link", text: "Claude Code and Claude Desktop can read and draft your mail through a local connection.")
        }
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Your data stays on this Mac", systemImage: "lock.shield").font(.headline)
                Text("Mail, calendar and transcripts are stored in a folder on this Mac. Postvak talks to Google with your own Google project, and to Claude only with your own API key. There is no Postvak server, no account and no tracking.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
        Text("This guide takes about 15 minutes, most of it in Google's console. Steps marked Optional can be done later in Settings.")
            .font(.callout).foregroundStyle(.secondary)
    }
}

private struct GooglePage: View {
    @EnvironmentObject var model: AppModel
    @State private var clientId = ""
    @State private var busy = false

    var body: some View {
        PageHeader(title: "Connect your Google accounts",
                   subtitle: "Postvak reaches Gmail and Google Calendar through a Google Cloud project of your own. It is free, and it means no one else's app ever holds access to your mail.")
        NumberedSteps(items: [
            "In the Google Cloud console, create a project named **Postvak**.",
            "Under **APIs & Services → Library**, enable **Gmail API** and **Google Calendar API**.",
            "Under **Google Auth Platform → Branding**, enter the app name and your address. Under **Audience**, choose **External** and add each address you will connect as a test user.",
            "Under **Data Access**, add the scopes `gmail.modify`, `gmail.settings.basic`, `calendar`, `userinfo.email`, `userinfo.profile` and `openid`.",
            "Under **Clients**, create a client of type **Desktop app**, and copy its ID and secret into the fields below.",
        ])
        Button("Open Google Cloud Console") {
            if let u = URL(string: "https://console.cloud.google.com") { NSWorkspace.shared.open(u) }
        }
        Note(icon: "exclamationmark.triangle",
             text: "While the project is in Testing, Google ends each sign-in after 7 days. To avoid that, publish it under Audience. The full steps are in docs/setup-google.md in the repository.")

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Client ID", text: $clientId)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { clientId = model.engine.secrets.get(SecretKey.googleClientId) ?? "" }
                    .onChange(of: clientId) { _, v in try? model.engine.secrets.set(SecretKey.googleClientId, v.trimmingCharacters(in: .whitespacesAndNewlines)) }
                SecretField(title: "Client secret", key: SecretKey.googleClientSecret)
                    .textFieldStyle(.roundedBorder)
                ForEach(model.accounts) { a in
                    HStack {
                        AccountBadge(account: a, size: 18)
                        Text(a.email)
                        Spacer()
                        Text(a.initialSyncDone ? "Synced" : "Syncing, \(a.syncedThreadCount) threads so far")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button(busy ? "Waiting for the browser…" : (model.accounts.isEmpty ? "Add Google Account" : "Add Another Account")) { signIn() }
                        .disabled(busy || clientId.isEmpty)
                    Text("Your browser opens to sign in. Add each address you want in Postvak.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
        Text("The first sync fetches 12 months of mail and can take a while on a large mailbox. You can carry on with this guide meanwhile.")
            .font(.caption).foregroundStyle(.secondary)
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

private struct AIKeyPage: View {
    var body: some View {
        PageHeader(title: "Add Claude for the smart features",
                   subtitle: "With an Anthropic API key, Postvak sorts the mail Gmail's categories miss, summarises meetings, answers questions about them, writes follow-up drafts and briefs, and checks a mail before it goes out. Without one, mail, calendar and recording all still work.")
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                SecretField(title: "Anthropic API key", key: SecretKey.anthropicKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Get a Key at console.anthropic.com") {
                        if let u = URL(string: "https://console.anthropic.com/settings/keys") { NSWorkspace.shared.open(u) }
                    }
                    Text("Usage is billed by Anthropic to your own account.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
        Note(icon: "hand.raised",
             text: "Only what a feature needs is sent, such as a meeting's transcript for its summary. Settings → AI says what each feature sends, and lets you switch it off.")
        Note(icon: "checkmark.bubble",
             text: "Nothing Claude writes is ever sent on its own. Drafts wait under Review Drafts until you approve them.")
    }
}

private struct MeetingsPage: View {
    @EnvironmentObject var model: AppModel
    @State private var autoRecord = false

    var body: some View {
        PageHeader(title: "Record and transcribe meetings",
                   subtitle: "Postvak records your microphone and, for calls, the sound of the call. It transcribes on this Mac, tells the speakers apart and files the meeting with its summary, decisions and action items.")
        VStack(alignment: .leading, spacing: 10) {
            Note(icon: "record.circle", text: "Start a recording with the Record button at the bottom of the sidebar, with ⇧⌘R, or from the menu bar icon. Right-click the button for a meeting in a room.")
            Note(icon: "bell", text: "Just before a meeting in your calendar, Postvak offers to record it.")
            Note(icon: "arrow.down.circle", text: "The first transcription downloads the speech model, about 650 MB. After that, nothing leaves this Mac unless you pick cloud transcription for a meeting.")
        }
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("macOS asks for two permissions the first time you record.").font(.callout)
                HStack {
                    Button("Microphone Settings") { open("Privacy_Microphone") }
                    Button("System Audio Recording Settings") { open("Privacy_AudioCapture") }
                }
                Toggle("Record calls automatically when I join", isOn: $autoRecord)
                    .onChange(of: autoRecord) { _, v in try? model.engine.db.setSetting("meetings.autoRecord", v ? "1" : "0") }
                Text("Off by default. When on, a notification appears each time, with a button to stop.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(6)
        }
        Note(icon: "exclamationmark.triangle", text: "Recording laws differ per country. Tell everyone before you record them.")
            .onAppear { autoRecord = model.engine.db.settingBool("meetings.autoRecord", default: false) }
    }

    private func open(_ anchor: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(u) }
    }
}

private struct ClaudePage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        PageHeader(title: "Let Claude work with your mail",
                   subtitle: "Postvak runs a small server on this Mac that Claude Code and Claude Desktop can connect to. Claude can then search your mail, meetings and calendar, and draft replies for you.")
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Copy Claude Code Command") { model.copyToPasteboard(model.claudeCodeCommand) }
                    Text("Then run it in a terminal.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Copy Claude Desktop Config") { model.copyToPasteboard(model.claudeDesktopConfig) }
                    Text("Paste it inside mcpServers in claude_desktop_config.json, then restart Claude Desktop.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
        }
        Note(icon: "key", text: "The first connection asks for Keychain access: click Always Allow. Node.js must be installed.")
        Note(icon: "lock", text: "Only apps on this Mac can connect, and only while Postvak runs. Claude can only send a mail you confirmed, and every send has a 5 second undo.")
        Note(icon: "exclamationmark.triangle", text: "Mail you receive can contain text written to trick an AI. Read what Claude proposes to send before you confirm it.")
    }
}

private struct TourPage: View {
    private let places: [(String, String, String)] = [
        ("tray.2", "Inbox", "All accounts together, split into People, Notifications and Newsletters. Each account also has its own inbox below in the sidebar. Right-click a thread to correct where a sender belongs."),
        ("clock", "Snooze and Scheduled", "Snooze a thread until later, or write now and send at a set time. Every send has 5 seconds to undo."),
        ("checkmark.bubble", "Review Drafts", "Follow-ups Claude wrote for threads that wait on you or got no answer. Edit, send or drop each one."),
        ("calendar", "Calendar", "All your calendars. Drag to create an event; each meeting gets a brief from your past mail with its guests."),
        ("waveform", "Meetings and Ask", "Every recorded or imported meeting with its transcript and summary. Ask Meetings answers questions across all of them."),
        ("briefcase", "Deals", "Companies you are working with, their stage and next step, kept up to date from your mail and meetings."),
        ("menubar.rectangle", "Menu bar", "Closing the window keeps Postvak running, so scheduled mail, snooze and Claude's access keep working."),
    ]
    private let shortcuts: [(String, String)] = [
        ("⌘N", "New mail"), ("⌘F", "Search"), ("⇧⌘R", "Record a call"), ("⇧⌘A", "Ask Meetings"), ("⌥⌘T", "Today's meetings"), ("⌘,", "Settings"),
    ]

    var body: some View {
        PageHeader(title: "Finding your way around", subtitle: "Everything lives in the sidebar on the left.")
        VStack(alignment: .leading, spacing: 10) {
            ForEach(places, id: \.1) { icon, title, text in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon).frame(width: 20).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).fontWeight(.semibold)
                        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        GroupBox("Shortcuts") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                ForEach(shortcuts, id: \.0) { key, what in
                    HStack(spacing: 6) {
                        Text(key).font(.system(.callout, design: .monospaced))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        Text(what).font(.callout)
                    }
                }
            }
            .padding(6)
        }
        Text("Open this guide again any time from Help → Postvak Guide.").font(.callout).foregroundStyle(.secondary)
    }
}
