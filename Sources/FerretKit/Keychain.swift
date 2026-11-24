import Foundation
import LocalAuthentication
import Security

/// Where a sign-in is kept: the Keychain (`SessionStore`), or a stand-in for tests.
public protocol SessionKeeper: Sendable {
    func load() -> Session?
    /// Whether one is kept, without reading it (no Keychain prompt).
    func exists() -> Bool
    func save(_ session: Session) throws
    func clear()
}

/// The signed-in session, kept in the Keychain (never UserDefaults): it holds a token or an API key.
public struct SessionStore: SessionKeeper {
    let item: KeychainItem

    /// `accessGroup`: a shared Keychain group, so the share extension and widgets can use the same sign-in.
    public init(service: String = "us.digitalempire.ferret", accessGroup: String? = nil) {
        item = KeychainItem(service: service, account: "session", accessGroup: accessGroup)
    }

    public func load() -> Session? { item.load().flatMap { try? JSONDecoder().decode(Session.self, from: $0) } }
    /// Whether one is saved, without reading it (so macOS never asks to allow access just for this).
    public func exists() -> Bool { item.exists() }
    /// Throws when the Keychain won't keep it (the sign-in would be gone at the next launch).
    public func save(_ session: Session) throws { try item.save(JSONEncoder().encode(session)) }
    public func clear() { item.clear() }
}

/// Cloudflare Access tokens, one per server, kept after signing out (signing in again shouldn't mean typing it again).
public struct AccessTokenStore: Sendable {
    let service: String

    public init(service: String = "us.digitalempire.ferret") { self.service = service }

    public func load(for server: URL) -> AccessToken? {
        item(server).load().flatMap { try? JSONDecoder().decode(AccessToken.self, from: $0) }
    }

    /// Nil (or half a token) forgets it. Throws when the Keychain won't keep it.
    public func save(_ token: AccessToken?, for server: URL) throws {
        if let token, token.isComplete { try item(server).save(JSONEncoder().encode(token)) } else { item(server).clear() }
    }

    private func item(_ server: URL) -> KeychainItem {
        KeychainItem(service: service, account: "access:\(server.absoluteString)", accessGroup: nil)
    }
}

/// The Keychain refused to keep something.
public struct KeychainError: LocalizedError, Equatable, Sendable {
    public let status: OSStatus

    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "\(status)"
        return String(localized: "Couldn't save your sign-in in the Keychain (\(detail)).")
    }
}

/// One generic-password item.
///
/// On the iPhone every item is in the data protection keychain. On a Mac an app can use it only when signed with a
/// team (a Developer ID or App Store build); otherwise items go in the older file-based keychain, whose access is tied
/// to each build's signature, so macOS asks again after an update. So: the data protection keychain when the app may
/// use it (moving an item kept in the older one across the first time), the older one when it may not.
struct KeychainItem: Sendable {
    let service: String
    let account: String
    let accessGroup: String?

    /// Whether this app may use the data protection keychain on a Mac, found once by keeping and removing a throwaway
    /// item: without a team, writing gets errSecMissingEntitlement (reading only finds nothing, so it can't tell).
    static let dataProtection: Bool = {
        #if os(macOS)
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "us.digitalempire.ferret.probe",
            kSecAttrAccount as String: UUID().uuidString,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var add = probe
        add[kSecValueData as String] = Data()
        let status = SecItemAdd(add as CFDictionary, nil)
        SecItemDelete(probe as CFDictionary)
        return status == errSecSuccess
        #else
        return true
        #endif
    }()

    func load() -> Data? {
        if let data = read(modern: Self.dataProtection) { return data }
        #if os(macOS)
        // Kept by a build without a team: move it across now that this one may use the data protection keychain.
        if Self.dataProtection, let old = read(modern: false) {
            if (try? write(old, modern: true)) != nil { SecItemDelete(base(modern: false) as CFDictionary) }
            return old
        }
        #endif
        return nil
    }

    func exists() -> Bool {
        has(modern: Self.dataProtection) || (Self.dataProtection && has(modern: false))
    }

    func save(_ data: Data) throws {
        try write(data, modern: Self.dataProtection)
    }

    func clear() {
        SecItemDelete(base(modern: Self.dataProtection) as CFDictionary)
        #if os(macOS)
        if Self.dataProtection { SecItemDelete(base(modern: false) as CFDictionary) }
        #endif
    }

    private func read(modern: Bool) -> Data? {
        var query = base(modern: modern)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    private func has(modern: Bool) -> Bool {
        var query = base(modern: modern)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    private func write(_ data: Data, modern: Bool) throws {
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(base(modern: modern) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(modern: modern)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func base(modern: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        #if os(macOS)
        if modern { query[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return query
    }
}
