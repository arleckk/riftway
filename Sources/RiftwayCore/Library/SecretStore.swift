import Foundation
import Security

/// Secrets a game's Play button needs (a launch link with a session token and
/// an e-mail address) live in the login Keychain, never in the bottle's files
/// or logs.
public enum SecretStore {
    public static let service = "com.riftway.launch-link"

    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let status: OSStatus
        public var description: String {
            "Keychain error \(status): " + ((SecCopyErrorMessageString(status, nil) as String?) ?? "unknown")
        }
    }

    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public static func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure(status: update) }
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Riftway: enlace para jugar"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    public static func read(account: String) throws -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    public static func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
