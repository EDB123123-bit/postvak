import Foundation

/// A cal.com profile or event link, as people paste it: `cal.com/name`, `https://cal.com/name/slug`, or the bare name.
public struct CalLink: Hashable, Sendable {
    public let username: String
    public let slug: String?

    public init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("/") && !s.contains(".") {
            username = s; slug = nil
            return
        }
        if !s.contains("://") { s = "https://" + s }
        guard let u = URL(string: s), let host = u.host?.lowercased(), ["cal.com", "www.cal.com", "app.cal.com"].contains(host) else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        // Team pages use another API; only personal links are supported.
        guard let first = parts.first, first != "team" else { return nil }
        username = first
        slug = parts.count > 1 ? parts[1] : nil
    }

    public var profileURL: URL { URL(string: "https://cal.com/\(username)")! }
}

/// One public meeting type on a cal.com profile.
public struct CalEventType: Hashable, Sendable, Identifiable {
    public let id: Int
    public let username: String
    public let slug: String
    public let title: String
    public let minutes: Int
    /// The video service's display name, nil for in-person or phone meetings.
    public let video: String?
    public init(id: Int, username: String, slug: String, title: String, minutes: Int, video: String?) {
        self.id = id; self.username = username; self.slug = slug; self.title = title; self.minutes = minutes; self.video = video
    }
    public var pageURL: URL { URL(string: "https://cal.com/\(username)/\(slug)")! }
}

public enum BookingLanguage: String, CaseIterable, Sendable {
    case nl, en, fr
    public var displayName: String {
        switch self { case .nl: "Nederlands"; case .en: "English"; case .fr: "Français" }
    }
}

public struct BookingDay: Hashable, Sendable {
    /// yyyy-MM-dd in the card's time zone.
    public let day: String
    public let slots: [Date]
}

public struct BookingCard: Hashable, Sendable {
    public var event: CalEventType
    public var days: [BookingDay]
    public var timeZone: TimeZone
    public var language: BookingLanguage
    public init(event: CalEventType, days: [BookingDay], timeZone: TimeZone, language: BookingLanguage) {
        self.event = event; self.days = days; self.timeZone = timeZone; self.language = language
    }
}

/// A rendered card as it travels with a mail: HTML for the message, one line for the plain-text part.
public struct BookingInsert: Hashable, Sendable {
    public var html: String
    public var text: String
    public init(html: String, text: String) { self.html = html; self.text = text }
}

public enum BookingError: Error, LocalizedError {
    case noLink, unreachable(Int), unreadable
    public var errorDescription: String? {
        switch self {
        case .noLink: "Add your cal.com link in Settings → Booking first."
        case .unreachable(let s): "cal.com did not answer (\(s)). Try again in a moment."
        case .unreadable: "cal.com sent something Postvak could not read."
        }
    }
}

/// Reads public meeting types and free times. Both endpoints work without an API key.
public struct CalComClient: Sendable {
    let session: URLSession
    static let api = "https://api.cal.com/v2"
    public init(session: URLSession = .shared) { self.session = session }

    private func get(_ path: String, _ query: [String: String], version: String) async throws -> Data {
        var c = URLComponents(string: Self.api + path)!
        c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var r = URLRequest(url: c.url!)
        r.setValue(version, forHTTPHeaderField: "cal-api-version")
        r.timeoutInterval = 20
        let (data, resp) = try await session.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw BookingError.unreachable(status) }
        return data
    }

    static func videoName(_ integration: String) -> String? {
        switch integration {
        case "google-meet": "Google Meet"
        case "cal-video", "daily-video": "Cal Video"
        case "zoom": "Zoom"
        case "office365-video", "msteams": "Microsoft Teams"
        default: nil
        }
    }

    public func eventTypes(username: String) async throws -> [CalEventType] {
        struct Resp: Decodable {
            struct E: Decodable {
                struct L: Decodable { let type: String?; let integration: String? }
                let id: Int; let slug: String; let title: String; let lengthInMinutes: Int?; let hidden: Bool?; let locations: [L]?
            }
            let data: [E]?
        }
        let d = try await get("/event-types", ["username": username], version: "2024-06-14")
        guard let r = try? JSONDecoder().decode(Resp.self, from: d), let list = r.data else { throw BookingError.unreadable }
        return list.filter { $0.hidden != true }.map { e in
            let video = e.locations?.lazy.compactMap { $0.integration.flatMap(Self.videoName) }.first
            return CalEventType(id: e.id, username: username, slug: e.slug, title: e.title, minutes: e.lengthInMinutes ?? 30, video: video)
        }
    }

    public func slots(for e: CalEventType, from: Date, to: Date, timeZone: TimeZone) async throws -> [BookingDay] {
        struct Resp: Decodable { struct S: Decodable { let start: String }; let data: [String: [S]]? }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX"); day.timeZone = timeZone; day.dateFormat = "yyyy-MM-dd"
        let d = try await get("/slots", ["username": e.username, "eventTypeSlug": e.slug, "start": day.string(from: from),
                                         "end": day.string(from: to), "timeZone": timeZone.identifier], version: "2024-09-04")
        guard let r = try? JSONDecoder().decode(Resp.self, from: d), let data = r.data else { throw BookingError.unreadable }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return data.keys.sorted().compactMap { key in
            let times = (data[key] ?? []).compactMap { precise.date(from: $0.start) ?? plain.date(from: $0.start) }.sorted()
            return times.isEmpty ? nil : BookingDay(day: key, slots: times)
        }
    }

    /// The next few days that have room, a handful of times each. The full page shows everything else.
    public func card(for e: CalEventType, language: BookingLanguage, timeZone: TimeZone = .current, now: Date = Date(),
                     maxDays: Int = 3, maxPerDay: Int = 5) async throws -> BookingCard {
        let to = now.addingTimeInterval(21 * 86400)
        let all = try await slots(for: e, from: now, to: to, timeZone: timeZone)
        let days = all.compactMap { d -> BookingDay? in
            let upcoming = d.slots.filter { $0 > now }
            return upcoming.isEmpty ? nil : BookingDay(day: d.day, slots: Array(upcoming.prefix(maxPerDay)))
        }
        return BookingCard(event: e, days: Array(days.prefix(maxDays)), timeZone: timeZone, language: language)
    }
}

public enum BookingCardRenderer {
    struct Words {
        let minutes: (Int) -> String, video: (String) -> String, pick: String, all: String, zone: (String) -> String, locale: String
    }
    static func words(_ l: BookingLanguage) -> Words {
        switch l {
        case .nl: Words(minutes: { "\($0) minuten" }, video: { "Videogesprek via \($0)" }, pick: "Kies een moment",
                        all: "Alle beschikbare momenten", zone: { "Tijden in \($0)" }, locale: "nl_BE")
        case .en: Words(minutes: { "\($0) minutes" }, video: { "\($0) video call" }, pick: "Pick a time",
                        all: "See all available times", zone: { "Times shown in \($0)" }, locale: "en_GB")
        case .fr: Words(minutes: { "\($0) minutes" }, video: { "Visioconférence \($0)" }, pick: "Choisissez un créneau",
                        all: "Voir tous les créneaux", zone: { "Fuseau horaire : \($0)" }, locale: "fr_BE")
        }
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Opens the booking page with this time already chosen, the same link cal.com's own email embed makes.
    public static func slotURL(_ e: CalEventType, slot: Date, timeZone: TimeZone) -> URL {
        let utc = ISO8601DateFormatter()
        utc.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        utc.timeZone = TimeZone(identifier: "UTC")
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        let date = f.string(from: slot)
        f.dateFormat = "yyyy-MM"
        var c = URLComponents(url: e.pageURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "duration", value: String(e.minutes)), URLQueryItem(name: "date", value: date),
                        URLQueryItem(name: "month", value: f.string(from: slot)), URLQueryItem(name: "slot", value: utc.string(from: slot)),
                        URLQueryItem(name: "cal.tz", value: timeZone.identifier)]
        return c.url!
    }

    public static func text(_ c: BookingCard) -> String {
        let w = words(c.language)
        return "\(c.event.title) (\(w.minutes(c.event.minutes)))\n\(w.pick): \(c.event.pageURL.absoluteString)"
    }

    public static func html(_ c: BookingCard) -> String {
        let w = words(c.language)
        let locale = Locale(identifier: w.locale)
        let dayF = DateFormatter()
        dayF.locale = locale; dayF.timeZone = c.timeZone
        dayF.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        let timeF = DateFormatter()
        timeF.locale = locale; timeF.timeZone = c.timeZone
        timeF.setLocalizedDateFormatFromTemplate("jmm")
        let font = "font-family:-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"
        let line = "font-size:14px;line-height:22px;color:#444746;margin:0"

        var h = "<table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\" style=\"width:100%;max-width:520px;margin:12px 0;border-collapse:separate;background:#f0f4f9;border-radius:16px\">"
        h += "<tr><td style=\"padding:20px 24px;\(font);color:#1f1f1f\">"
        h += "<div style=\"font-size:20px;font-weight:600;line-height:26px;margin:0 0 10px;color:#1f1f1f\">\(esc(c.event.title))</div>"
        h += "<div style=\"\(line)\">&#128339;&nbsp; \(esc(w.minutes(c.event.minutes)))</div>"
        if let v = c.event.video { h += "<div style=\"\(line)\">&#128249;&nbsp; \(esc(w.video(v)))</div>" }
        if !c.days.isEmpty {
            h += "<div style=\"font-size:15px;font-weight:600;line-height:20px;margin:18px 0 2px;color:#1f1f1f\">\(esc(w.pick))</div>"
            for d in c.days {
                guard let first = d.slots.first else { continue }
                let label = dayF.string(from: first)
                h += "<div style=\"font-size:13px;line-height:18px;color:#444746;margin:10px 0 6px\">\(esc(label.prefix(1).uppercased() + label.dropFirst()))</div><div>"
                for s in d.slots {
                    h += "<a href=\"\(esc(slotURL(c.event, slot: s, timeZone: c.timeZone).absoluteString))\" style=\"display:inline-block;min-width:52px;text-align:center;padding:6px 10px;margin:0 6px 6px 0;border:1px solid #747775;border-radius:16px;color:#0b57d0;text-decoration:none;font-size:14px;line-height:18px\">\(esc(timeF.string(from: s)))</a>"
                }
                h += "</div>"
            }
            let zone = c.timeZone.localizedName(for: .generic, locale: locale) ?? c.timeZone.identifier
            h += "<div style=\"font-size:12px;line-height:16px;color:#747775;margin:4px 0 0\">\(esc(w.zone(zone)))</div>"
        }
        let button = c.days.isEmpty ? w.pick : w.all
        h += "<div style=\"margin:16px 0 0\"><a href=\"\(esc(c.event.pageURL.absoluteString))\" style=\"display:inline-block;padding:10px 20px;background:#0b57d0;color:#ffffff;border-radius:20px;text-decoration:none;font-size:14px;line-height:18px;font-weight:600\">\(esc(button))</a></div>"
        h += "</td></tr></table>"
        return h
    }

    public static func insert(_ c: BookingCard) -> BookingInsert {
        let t = text(c)
        return BookingInsert(html: BookingBlock.wrap(html: html(c), text: t), text: t)
    }
}

/// Marks the card inside a sent mail's HTML, so a queued mail opened again for editing gets its card back
/// instead of a second copy of its text. The plain-text line rides along, percent-encoded, in the opening comment.
public enum BookingBlock {
    static let open = "<!--postvak:booking "
    static let close = "<!--/postvak:booking-->"

    public static func wrap(html: String, text: String) -> String {
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return "\(open)\(encoded)-->\(html)\(close)"
    }

    /// The whole marked block and its plain-text line, if the HTML has one.
    public static func extract(from html: String) -> BookingInsert? {
        guard let a = html.range(of: open), let b = html.range(of: close, range: a.upperBound..<html.endIndex),
              let head = html.range(of: "-->", range: a.upperBound..<b.lowerBound) else { return nil }
        let text = String(html[a.upperBound..<head.lowerBound]).removingPercentEncoding ?? ""
        return BookingInsert(html: String(html[a.lowerBound..<b.upperBound]), text: text)
    }
}
