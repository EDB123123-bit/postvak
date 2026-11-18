import Foundation

/// An account's automatic reply while the user is away. Gmail itself sends it (its "vacation responder"),
/// so replies go out with the Mac asleep or off, and Gmail web shows the same setting.
public struct OutOfOffice: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var subject: String
    /// The reply as plain text, the way the user writes it.
    public var message: String
    /// The reply as Gmail holds it, set in Gmail web perhaps with formatting. Kept on saving while `message` is unchanged.
    public var html: String?
    /// Only people in the account's Google contacts get the reply.
    public var contactsOnly: Bool
    /// Only people at the account's own company domain get the reply. Google Workspace accounts only.
    public var domainOnly: Bool
    /// The first moment replies go out. None: from now on.
    public var start: Date?
    /// The moment replies stop. None: until turned off.
    public var end: Date?

    public init(enabled: Bool = false, subject: String = "", message: String = "", html: String? = nil,
                contactsOnly: Bool = false, domainOnly: Bool = false, start: Date? = nil, end: Date? = nil) {
        self.enabled = enabled; self.subject = subject; self.message = message; self.html = html
        self.contactsOnly = contactsOnly; self.domainOnly = domainOnly; self.start = start; self.end = end
    }

    public enum State: Equatable, Sendable { case off, scheduled, on, ended }

    public func state(now: Date = Date()) -> State {
        guard enabled else { return .off }
        if let end, end <= now { return .ended }
        if let start, start > now { return .scheduled }
        return .on
    }

    /// Replies go out right now.
    public func isActive(now: Date = Date()) -> Bool { state(now: now) == .on }

    /// The last day replies go out, for showing: `end` is the midnight after it.
    public func lastDay(calendar: Calendar = .current) -> Date? {
        end.map { calendar.startOfDay(for: $0.addingTimeInterval(-1)) }
    }

    /// Sets the dates from a first and last day, both included: from the start of the first to the midnight after the last.
    public mutating func setDays(first: Date?, last: Date?, calendar: Calendar = .current) {
        start = first.map { calendar.startOfDay(for: $0) }
        end = last.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) }
    }

    /// One line for a list: "Off", "On until Fri 20 Nov", "From Mon 16 Nov to Fri 20 Nov".
    public func statusText(now: Date = Date(), calendar: Calendar = .current) -> String {
        let day = { (d: Date) in d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }
        switch state(now: now) {
        case .off: return "Off"
        case .ended: return "Ended \(lastDay(calendar: calendar).map(day) ?? "")"
        case .on: return lastDay(calendar: calendar).map { "On until \(day($0))" } ?? "On, until you turn it off"
        case .scheduled:
            let from = start.map(day) ?? ""
            return lastDay(calendar: calendar).map { "From \(from) to \(day($0))" } ?? "From \(from)"
        }
    }

    /// The HTML to save: Gmail's own while the text is what it showed, otherwise the text with its line breaks.
    var htmlToSave: String {
        if let html, GmailParser.htmlToText(html) == message { return html }
        return Self.html(fromText: message)
    }

    static func html(fromText text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    /// Gmail can only limit replies to the account's domain on Google Workspace, not on a free Gmail address.
    public static func supportsDomainOnly(_ accountId: String) -> Bool {
        let domain = accountId.split(separator: "@").last.map { $0.lowercased() } ?? ""
        return !["gmail.com", "googlemail.com"].contains(domain)
    }
}

/// Gmail's `users.settings.vacation` resource. Times are milliseconds since 1970, as strings.
struct VacationDTO: Codable {
    var enableAutoReply: Bool?
    var responseSubject: String?
    var responseBodyPlainText: String?
    var responseBodyHtml: String?
    var restrictToContacts: Bool?
    var restrictToDomain: Bool?
    var startTime: String?
    var endTime: String?

    init(_ o: OutOfOffice, accountId: String) {
        enableAutoReply = o.enabled
        responseSubject = o.subject
        responseBodyPlainText = o.message
        responseBodyHtml = o.htmlToSave
        restrictToContacts = o.contactsOnly
        restrictToDomain = OutOfOffice.supportsDomainOnly(accountId) && o.domainOnly
        startTime = o.start.map { String(Int64($0.timeIntervalSince1970 * 1000)) }
        endTime = o.end.map { String(Int64($0.timeIntervalSince1970 * 1000)) }
    }

    var outOfOffice: OutOfOffice {
        let date = { (s: String?) in s.flatMap(Int64.init).map { Date(timeIntervalSince1970: Double($0) / 1000) } }
        let html = responseBodyHtml.flatMap { $0.isEmpty ? nil : $0 }
        let text = responseBodyPlainText.flatMap { $0.isEmpty ? nil : $0 } ?? html.map(GmailParser.htmlToText) ?? ""
        return OutOfOffice(enabled: enableAutoReply ?? false, subject: responseSubject ?? "", message: text, html: html,
                           contactsOnly: restrictToContacts ?? false, domainOnly: restrictToDomain ?? false,
                           start: date(startTime), end: date(endTime))
    }
}

extension GmailClient {
    func vacation(_ a: String) async throws -> VacationDTO {
        try JSONDecoder().decode(VacationDTO.self, from: try await api.call(account: a, url: Self.base + "/settings/vacation"))
    }
    func updateVacation(_ a: String, _ v: VacationDTO) async throws -> VacationDTO {
        let json = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(v))
        let data = try await api.call(account: a, method: "PUT", url: Self.base + "/settings/vacation", json: json)
        return (try? JSONDecoder().decode(VacationDTO.self, from: data)) ?? v
    }
}

extension MailService {
    static func outOfOfficeKey(_ accountId: String) -> String { "outOfOffice.\(accountId.lowercased())" }

    /// The account's automatic reply as Gmail holds it now. Kept on this Mac too, for showing before Gmail answers.
    public func outOfOffice(accountId: String) async throws -> OutOfOffice {
        let o = try await gmail.vacation(accountId).outOfOffice
        cacheOutOfOffice(o, accountId: accountId)
        return o
    }

    /// Saves the automatic reply to Gmail and returns what Gmail stored.
    @discardableResult
    public func setOutOfOffice(accountId: String, _ o: OutOfOffice) async throws -> OutOfOffice {
        if o.enabled {
            if o.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw MailError.invalid("Write the reply first.") }
            if let s = o.start, let e = o.end, e <= s { throw MailError.invalid("The last day comes before the first day.") }
        }
        let saved = try await gmail.updateVacation(accountId, VacationDTO(o, accountId: accountId)).outOfOffice
        cacheOutOfOffice(saved, accountId: accountId)
        return saved
    }

    /// Turns the automatic reply off and keeps its text and dates for next time.
    @discardableResult
    public func turnOffOutOfOffice(accountId: String) async throws -> OutOfOffice {
        var o = try await outOfOffice(accountId: accountId)
        guard o.enabled else { return o }
        o.enabled = false
        return try await setOutOfOffice(accountId: accountId, o)
    }

    public func cachedOutOfOffice(accountId: String) -> OutOfOffice? {
        db.setting(Self.outOfOfficeKey(accountId)).flatMap { try? JSONDecoder().decode(OutOfOffice.self, from: Data($0.utf8)) }
    }

    private func cacheOutOfOffice(_ o: OutOfOffice, accountId: String) {
        guard let data = try? JSONEncoder().encode(o) else { return }
        try? db.setSetting(Self.outOfOfficeKey(accountId), String(decoding: data, as: UTF8.self))
    }
}
