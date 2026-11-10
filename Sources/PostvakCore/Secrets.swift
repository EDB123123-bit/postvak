import Foundation
import Security

public protocol SecretStore: Sendable {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String?) throws
}

public enum SecretKey {
    public static let googleClientId = "google.clientId"
    public static let googleClientSecret = "google.clientSecret"
    public static let anthropicKey = "anthropic.apiKey"
    public static let deepgramKey = "deepgram.apiKey"
    public static let mcpToken = "mcp.token"
    public static func refreshToken(_ accountId: String) -> String { "google.refresh.\(accountId)" }
}

public struct SecretError: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String { "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")" }
}

public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service: String
    public init(service: String = "be.postvak.app") { self.service = service }

    public func get(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public func set(_ key: String, _ value: String?) throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        guard let value, !value.isEmpty else {
            let s = SecItemDelete(q as CFDictionary)
            if s != errSecSuccess && s != errSecItemNotFound { throw SecretError(status: s) }
            return
        }
        let data = Data(value.utf8)
        let s = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if s == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let a = SecItemAdd(add as CFDictionary, nil)
            if a != errSecSuccess { throw SecretError(status: a) }
        } else if s != errSecSuccess {
            throw SecretError(status: s)
        }
    }
}

/// In-memory store for tests and the demo seed. Never used by the shipped app path.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    public init(_ values: [String: String] = [:]) { self.values = values }
    public func get(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func set(_ key: String, _ value: String?) throws { lock.lock(); defer { lock.unlock() }; values[key] = value }
}
