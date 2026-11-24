import Foundation

/// How the app proves who it is to one server: an app sign-in (OAuth), or an API key pasted from Settings → Claude & API.
/// Either one stands for one person in one household, and may be read-only.
public enum Credential: Codable, Sendable, Equatable {
    case oauth(OAuthTokens)
    case apiKey(String)

    var bearer: String {
        switch self {
        case .oauth(let tokens): tokens.accessToken
        case .apiKey(let key): key
        }
    }
}

public struct OAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    /// This app's registration on the server (each server registers the app once).
    public var clientId: String
    public var tokenEndpoint: URL
    /// What the tokens are for (the server's protected resource).
    public var resource: String

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, clientId: String, tokenEndpoint: URL, resource: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.clientId = clientId
        self.tokenEndpoint = tokenEndpoint
        self.resource = resource
    }

    /// Refresh a minute early so a request never goes out with a token about to end.
    public var isExpiring: Bool { expiresAt.timeIntervalSinceNow < 60 }
}

/// A signed-in server: kept in the Keychain.
public struct Session: Codable, Sendable, Equatable {
    public var server: URL
    public var credential: Credential

    public init(server: URL, credential: Credential) {
        self.server = server
        self.credential = credential
    }
}
