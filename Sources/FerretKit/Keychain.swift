import Foundation
import Security

/// The signed-in session, kept in the Keychain (never UserDefaults): it holds a token or an API key.
public struct SessionStore: Sendable {
    let service: String
    let account = "session"
    /// A shared Keychain group, so the share extension and widgets can use the same sign-in. Nil: the app's own.
    let accessGroup: String?

    public init(service: String = "us.digitalempire.ferret", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func load() -> Session? {
        var query = base()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    public func save(_ session: Session) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(base() as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = base()
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func clear() {
        SecItemDelete(base() as CFDictionary)
    }

    private func base() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}
