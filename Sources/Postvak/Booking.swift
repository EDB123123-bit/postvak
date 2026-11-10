import SwiftUI
import PostvakCore

extension AppModel {
    static let calLinkKey = "booking.calLink"
    static let bookingLanguageKey = "booking.language"

    var calLink: CalLink? { engine.db.setting(Self.calLinkKey).flatMap(CalLink.init) }
    var bookingLanguage: BookingLanguage { engine.db.setting(Self.bookingLanguageKey).flatMap(BookingLanguage.init) ?? .nl }

    func loadCalEventTypes(force: Bool = false) async {
        guard force || calEventTypes.isEmpty else { return }
        guard let link = calLink else { calEventTypes = []; calEventTypesError = nil; return }
        do {
            calEventTypes = try await CalComClient(session: engine.session).eventTypes(username: link.username)
            calEventTypesError = calEventTypes.isEmpty ? "No public meeting types on cal.com/\(link.username)." : nil
        } catch {
            calEventTypesError = error.localizedDescription
        }
    }

    /// Fetches the meeting types again, so one added on cal.com shows up without restarting Postvak.
    /// If cal.com can't be reached, the list already shown stays.
    func refreshCalEventTypes() async {
        guard let link = calLink else { return }
        guard let fresh = try? await CalComClient(session: engine.session).eventTypes(username: link.username) else {
            if calEventTypes.isEmpty { await loadCalEventTypes(force: true) }
            return
        }
        calEventTypes = fresh
        calEventTypesError = fresh.isEmpty ? "No public meeting types on cal.com/\(link.username)." : nil
    }

    func bookingInsert(for e: CalEventType) async throws -> BookingInsert {
        let card = try await CalComClient(session: engine.session).card(for: e, language: bookingLanguage)
        return BookingCardRenderer.insert(card)
    }
}

/// The card as it will appear in the mail, on the white page mail clients use.
struct BookingPreview: View {
    let html: String
    @State private var height: CGFloat = 160

    var body: some View {
        ScrollView {
            MailWebView(html: "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"color-scheme\" content=\"light\"><style>html,body{margin:0;padding:0 8px;background:#fff}</style></head><body>\(html)</body></html>",
                        allowRemote: false, height: $height)
                .frame(height: height)
        }
        .frame(height: min(height, 240))
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Composer button: pick a meeting type, get a card with your next free times.
struct BookingMenu: View {
    @EnvironmentObject var model: AppModel
    @Binding var state: ComposerState
    @Binding var loading: Bool

    var body: some View {
        Menu {
            if model.calLink == nil {
                Text("Add your cal.com link first")
            } else if let err = model.calEventTypesError {
                Text(err)
                Button("Try Again") { Task { await model.loadCalEventTypes(force: true) } }
            } else if model.calEventTypes.isEmpty {
                Text("Loading meeting types…")
            } else {
                Section("Insert a booking card") {
                    ForEach(model.calEventTypes) { e in
                        Button("\(e.title) · \(e.minutes) min") { insert(e) }
                    }
                }
            }
            Divider()
            SettingsLink { Text("Booking Settings…") }
        } label: {
            if loading { ProgressView().controlSize(.small) } else { Image(systemName: "calendar.badge.plus") }
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Insert a booking card with your free times")
        .disabled(loading)
        .task { await model.refreshCalEventTypes() }
    }

    private func insert(_ e: CalEventType) {
        loading = true
        Task {
            defer { loading = false }
            do {
                state.booking = try await model.bookingInsert(for: e)
                state.bookingEvent = e
            } catch {
                model.toast(error.localizedDescription, kind: .error, seconds: 7)
            }
        }
    }
}

struct BookingPane: View {
    @EnvironmentObject var model: AppModel
    @State private var link = ""
    @State private var language: BookingLanguage = .nl
    @State private var checking = false

    var body: some View {
        Form {
            Section("cal.com") {
                TextField("Your cal.com link", text: $link, prompt: Text("cal.com/your-name"))
                Picker("Card language", selection: $language) {
                    ForEach(BookingLanguage.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .onChange(of: language) { _, v in try? model.engine.db.setSetting(AppModel.bookingLanguageKey, v.rawValue) }
                Text("The composer's calendar button inserts a card with your next free times and a button to your full booking page. Times come straight from cal.com, so they match what it would let people book.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Meeting types") {
                if let err = model.calEventTypesError {
                    Text(err).foregroundStyle(.red)
                } else if model.calEventTypes.isEmpty {
                    Text(model.calLink == nil ? "Save a link to see your meeting types." : "Loading…").foregroundStyle(.secondary)
                } else {
                    ForEach(model.calEventTypes) { e in
                        HStack {
                            Text(e.title)
                            Spacer()
                            Text([("\(e.minutes) min"), e.video].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button(checking ? "Checking…" : "Save") { save() }.disabled(checking)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            link = model.calLink?.profileURL.absoluteString ?? ""
            language = model.bookingLanguage
        }
        .task { await model.loadCalEventTypes() }
    }

    private func save() {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? model.engine.db.setSetting(AppModel.calLinkKey, nil)
            model.calEventTypes = []
            model.calEventTypesError = nil
            return
        }
        guard let parsed = CalLink(trimmed) else {
            model.toast("That is not a cal.com link. It looks like cal.com/your-name.", kind: .error)
            return
        }
        try? model.engine.db.setSetting(AppModel.calLinkKey, parsed.profileURL.absoluteString)
        link = parsed.profileURL.absoluteString
        checking = true
        Task {
            defer { checking = false }
            await model.loadCalEventTypes(force: true)
            if model.calEventTypesError == nil { model.toast("Booking card ready: \(model.calEventTypes.count) meeting types.") }
        }
    }
}
