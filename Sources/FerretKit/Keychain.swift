import Foundation
import Security

/// The signed-in session, kept in the Keychain (never UserDefaults): it holds a token or an API key.
public struct SessionStore: Sendable {
    let item: KeychainItem

    /// `accessGroup`: a shared Keychain group, so the share extension and widgets can use the same sign-in.
    public init(service: String = "us.digitalempire.ferret", accessGroup: String? = nil) {
        item = KeychainItem(service: service, account: "session", accessGroup: accessGroup)
    }

    public func load() -> Session? { item.load().flatMap { try? JSONDecoder().decode(Session.self, from: $0) } }
    public func save(_ session: Session) { (try? JSONEncoder().encode(session)).map(item.save) }
    public func clear() { item.clear() }
}

/// Cloudflare Access tokens, one per server, kept after signing out (signing in again shouldn't mean typing it again).
public struct AccessTokenStore: Sendable {
    let service: String

    public init(service: String = "us.digitalempire.ferret") { self.service = service }

    public func load(for server: URL) -> AccessToken? {
        item(server).load().flatMap { try? JSONDecoder().decode(AccessToken.self, from: $0) }
    }

    /// Nil (or half a token) forgets it.
    public func save(_ token: AccessToken?, for server: URL) {
        if let token, token.isComplete, let data = try? JSONEncoder().encode(token) { item(server).save(data) } else { item(server).clear() }
    }

    private func item(_ server: URL) -> KeychainItem {
        KeychainItem(service: service, account: "access:\(server.absoluteString)", accessGroup: nil)
    }
}

/// One generic-password item.
struct KeychainItem: Sendable {
    let service: String
    let account: String
    let accessGroup: String?

    func load() -> Data? {
        var query = base()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    func save(_ data: Data) {
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(base() as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = base()
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func clear() {
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
