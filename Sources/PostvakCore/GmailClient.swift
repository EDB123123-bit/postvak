import Foundation

public struct GmailHeader: Codable, Sendable {
    public let name: String; public let value: String
    public init(name: String, value: String) { self.name = name; self.value = value }
}
public struct GmailBody: Codable, Sendable {
    public let attachmentId: String?; public let size: Int?; public let data: String?
    public init(attachmentId: String?, size: Int?, data: String?) { self.attachmentId = attachmentId; self.size = size; self.data = data }
}
public struct GmailPart: Codable, Sendable {
    public let partId: String?
    public let mimeType: String?
    public let filename: String?
    public let headers: [GmailHeader]?
    public let body: GmailBody?
    public let parts: [GmailPart]?
    public init(partId: String?, mimeType: String?, filename: String?, headers: [GmailHeader]?, body: GmailBody?, parts: [GmailPart]?) {
        self.partId = partId; self.mimeType = mimeType; self.filename = filename; self.headers = headers; self.body = body; self.parts = parts
    }
}
public struct GmailMessage: Codable, Sendable {
    public let id: String
    public let threadId: String?
    public let labelIds: [String]?
    public let snippet: String?
    public let historyId: String?
    public let internalDate: String?
    public let payload: GmailPart?
    public init(id: String, threadId: String?, labelIds: [String]?, snippet: String?, historyId: String?, internalDate: String?, payload: GmailPart?) {
        self.id = id; self.threadId = threadId; self.labelIds = labelIds; self.snippet = snippet
        self.historyId = historyId; self.internalDate = internalDate; self.payload = payload
    }
}
public struct GmailThreadDTO: Codable, Sendable {
    public let id: String
    public let historyId: String?
    public let messages: [GmailMessage]?
    public init(id: String, historyId: String?, messages: [GmailMessage]?) { self.id = id; self.historyId = historyId; self.messages = messages }
}
struct ThreadListDTO: Codable { struct T: Codable { let id: String }; let threads: [T]?; let nextPageToken: String? }
struct HistoryDTO: Codable {
    struct M: Codable { struct Msg: Codable { let id: String; let threadId: String? }; let message: Msg }
    struct H: Codable { let messagesAdded: [M]?; let messagesDeleted: [M]?; let labelsAdded: [M]?; let labelsRemoved: [M]? }
    let history: [H]?; let nextPageToken: String?; let historyId: String?
}
struct LabelDTO: Codable { let id: String; let name: String; let type: String? }
struct LabelListDTO: Codable { let labels: [LabelDTO]? }
struct ProfileDTO: Codable { let emailAddress: String; let historyId: String }
public struct SendAsDTO: Codable, Sendable {
    public let sendAsEmail: String
    public let displayName: String?
    public let signature: String?
    public let isDefault: Bool?
    public let isPrimary: Bool?
    /// "accepted" once Gmail verified an alias; absent for the account's own address.
    public let verificationStatus: String?
    /// Gmail lets the account send as this address.
    public var usable: Bool { isPrimary == true || verificationStatus == nil || verificationStatus == "accepted" }
}
struct SendAsList: Codable { let sendAs: [SendAsDTO]? }
struct DraftDTO: Codable { struct M: Codable { let id: String; let threadId: String? }; let id: String; let message: M? }
struct DraftList: Codable { let drafts: [DraftDTO]?; let nextPageToken: String? }
struct AttachmentDTO: Codable { let data: String? }

public final class GmailClient: Sendable {
    let api: GoogleAPI
    static let base = "https://gmail.googleapis.com/gmail/v1/users/me"
    public init(api: GoogleAPI) { self.api = api }

    private func get<T: Decodable>(_ a: String, _ path: String, query: [String: String?] = [:]) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await api.call(account: a, url: Self.base + path, query: query))
    }
    private func post<T: Decodable>(_ a: String, _ path: String, json: Any, method: String = "POST") async throws -> T {
        try JSONDecoder().decode(T.self, from: try await api.call(account: a, method: method, url: Self.base + path, json: json))
    }

    func profile(_ a: String) async throws -> ProfileDTO { try await get(a, "/profile") }
    func labels(_ a: String) async throws -> [LabelDTO] { (try await get(a, "/labels") as LabelListDTO).labels ?? [] }

    func createLabel(_ a: String, name: String) async throws -> LabelDTO {
        try await post(a, "/labels", json: ["name": name, "labelListVisibility": "labelShow", "messageListVisibility": "show"])
    }

    func listThreads(_ a: String, q: String?, pageToken: String?, includeSpamTrash: Bool, maxResults: Int = 100) async throws -> ThreadListDTO {
        try await get(a, "/threads", query: ["q": q, "pageToken": pageToken, "includeSpamTrash": includeSpamTrash ? "true" : "false", "maxResults": String(maxResults)])
    }

    func thread(_ a: String, id: String) async throws -> GmailThreadDTO {
        try await get(a, "/threads/\(id)", query: ["format": "full"])
    }

    func history(_ a: String, startHistoryId: String, pageToken: String?) async throws -> HistoryDTO {
        try await get(a, "/history", query: ["startHistoryId": startHistoryId, "pageToken": pageToken, "maxResults": "500"])
    }

    public func modifyThread(_ a: String, id: String, add: [String], remove: [String]) async throws {
        _ = try await api.call(account: a, method: "POST", url: Self.base + "/threads/\(id)/modify",
                               json: ["addLabelIds": add, "removeLabelIds": remove])
    }
    public func trashThread(_ a: String, id: String) async throws {
        _ = try await api.call(account: a, method: "POST", url: Self.base + "/threads/\(id)/trash")
    }
    public func untrashThread(_ a: String, id: String) async throws {
        _ = try await api.call(account: a, method: "POST", url: Self.base + "/threads/\(id)/untrash")
    }

    /// Gets a fresh access token if the cached one has run out. A failure here means nothing was sent.
    public func prepareAccess(_ a: String) async throws {
        _ = try await api.tokens.accessToken(for: a)
    }

    public func send(_ a: String, raw: Data, threadId: String?) async throws -> (messageId: String, threadId: String) {
        var json: [String: Any] = [:]
        if let threadId { json["threadId"] = threadId }
        let m: GmailMessage
        if Self.needsUpload(raw) {
            m = try await upload(a, "/messages/send", metadata: json, raw: raw)
        } else {
            json["raw"] = raw.base64URL
            m = try await post(a, "/messages/send", json: json)
        }
        return (m.id, m.threadId ?? threadId ?? m.id)
    }

    static let uploadBase = "https://gmail.googleapis.com/upload/gmail/v1/users/me"
    /// Above this, a mail goes through Gmail's upload endpoint (up to 35 MB) instead of as base64 inside JSON,
    /// which makes the request a third bigger and is meant for small messages only.
    static let uploadThreshold = 2_000_000
    static func needsUpload(_ raw: Data) -> Bool { raw.count > uploadThreshold }

    /// Sends the message as it is, next to its JSON metadata, in one multipart/related request.
    private func upload<T: Decodable>(_ a: String, _ path: String, metadata: [String: Any], raw: Data, method: String = "POST") async throws -> T {
        let boundary = "postvak-" + UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body.append(try JSONSerialization.data(withJSONObject: metadata))
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: message/rfc822\r\n\r\n".utf8))
        body.append(raw)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let data = try await api.call(account: a, method: method, url: Self.uploadBase + path, query: ["uploadType": "multipart"],
                                      body: (body, "multipart/related; boundary=\(boundary)"))
        return try JSONDecoder().decode(T.self, from: data)
    }

    public func attachment(_ a: String, messageId: String, attachmentId: String) async throws -> Data {
        let d: AttachmentDTO = try await get(a, "/messages/\(messageId)/attachments/\(attachmentId)")
        guard let s = d.data, let data = Data(base64URL: s) else { throw GoogleAPIError(status: 0, message: "Empty attachment") }
        return data
    }

    public func sendAs(_ a: String) async throws -> [SendAsDTO] {
        (try await get(a, "/settings/sendAs") as SendAsList).sendAs ?? []
    }
    public func updateSignature(_ a: String, sendAsEmail: String, signature: String) async throws {
        let path = sendAsEmail.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sendAsEmail
        _ = try await api.call(account: a, method: "PATCH", url: Self.base + "/settings/sendAs/\(path)", json: ["signature": signature])
    }

    func createDraft(_ a: String, raw: Data, threadId: String?) async throws -> DraftDTO {
        try await saveDraft(a, path: "/drafts", method: "POST", raw: raw, threadId: threadId)
    }
    func updateDraft(_ a: String, draftId: String, raw: Data, threadId: String?) async throws -> DraftDTO {
        try await saveDraft(a, path: "/drafts/\(draftId)", method: "PUT", raw: raw, threadId: threadId)
    }
    private func saveDraft(_ a: String, path: String, method: String, raw: Data, threadId: String?) async throws -> DraftDTO {
        var message: [String: Any] = [:]
        if let threadId { message["threadId"] = threadId }
        if Self.needsUpload(raw) { return try await upload(a, path, metadata: ["message": message], raw: raw, method: method) }
        message["raw"] = raw.base64URL
        return try await post(a, path, json: ["message": message], method: method)
    }
    /// The message a draft holds now, and its thread.
    func draftMessage(_ a: String, draftId: String) async throws -> (id: String, threadId: String?)? {
        guard let m = (try await get(a, "/drafts/\(draftId)", query: ["format": "minimal"]) as DraftDTO).message else { return nil }
        return (m.id, m.threadId)
    }
    func deleteDraft(_ a: String, draftId: String) async throws {
        _ = try await api.call(account: a, method: "DELETE", url: Self.base + "/drafts/\(draftId)")
    }
    func draftId(_ a: String, forMessage messageId: String) async throws -> String? {
        var token: String?
        repeat {
            let list: DraftList = try await get(a, "/drafts", query: ["pageToken": token, "maxResults": "100"])
            if let hit = list.drafts?.first(where: { $0.message?.id == messageId }) { return hit.id }
            token = list.nextPageToken
        } while token != nil
        return nil
    }
}
