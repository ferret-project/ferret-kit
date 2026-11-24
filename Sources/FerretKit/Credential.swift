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
    /// A Cloudflare Access service token, when the server sits behind Access.
    public var access: AccessToken?

    public init(server: URL, credential: Credential, access: AccessToken? = nil) {
        self.server = server
        self.credential = credential
        self.access = access
    }
}

/// A Cloudflare Access service token (Zero Trust → Access → Service credentials): sent as two headers with every
/// request, so a Ferret behind Access lets the app through. Access answers the first request with a
/// `CF_Authorization` cookie, which carries browser pages (the sign-in page, the web screens) after that.
public struct AccessToken: Codable, Sendable, Equatable {
    public var clientId: String
    public var clientSecret: String

    public init(clientId: String, clientSecret: String) {
        self.clientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var headers: [String: String] {
        ["CF-Access-Client-Id": clientId, "CF-Access-Client-Secret": clientSecret]
    }

    /// Both halves typed: anything less is treated as no token.
    public var isComplete: Bool { !clientId.isEmpty && !clientSecret.isEmpty }
}

public extension URLSession {
    /// The session for one server: plain, or adding the Access token's headers to every request.
    static func ferret(access: AccessToken?) -> URLSession {
        guard let access, access.isComplete else { return .shared }
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = access.headers
        return URLSession(configuration: configuration)
    }
}
