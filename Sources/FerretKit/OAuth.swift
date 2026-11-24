import CryptoKit
import Foundation

/// "Sign in to Ferret": OAuth 2.1 with PKCE against the server's own authorization server (Better Auth's
/// oauth-provider). The app registers itself once per server (RFC 7591, a public native client with its own
/// address scheme), the person signs in and picks a household on Ferret's #/connect screen, and the code comes back
/// to `redirectURI`. The browser part (ASWebAuthenticationSession) is the app's; everything else is here.
public enum OAuth {
    public static let callbackScheme = "us.digitalempire.ferret"
    /// A reverse-domain private-use address (RFC 8252 §7.1): no host, so no one else's app can claim it by accident.
    public static let redirectURI = "\(callbackScheme):/oauth"
    public static let scopes = "ferret offline_access"

    public struct Endpoints: Sendable, Equatable {
        public var authorization: URL
        public var token: URL
        public var registration: URL
        /// What the tokens are for, as the server names it (RFC 9728).
        public var resource: String
    }

    public struct Start: Sendable {
        public var url: URL
        public var state: String
        public var verifier: String
        public var clientId: String
        public var endpoints: Endpoints
    }

    /// Where to sign in on this server. Fails on a server too old for app sign-in (the app then offers an API key).
    public static func discover(server: URL, session: URLSession = .shared) async throws -> Endpoints {
        struct Metadata: Decodable {
            let authorization_endpoint: URL
            let token_endpoint: URL
            let registration_endpoint: URL?
        }
        struct Resource: Decodable { let resource: String }
        let metadata: Metadata = try await getJSON(server.appending(path: ".well-known/oauth-authorization-server"), session)
        let resource: Resource = try await getJSON(server.appending(path: ".well-known/oauth-protected-resource/mcp"), session)
        guard let registration = metadata.registration_endpoint else { throw FerretError.signInUnavailable }
        return Endpoints(authorization: metadata.authorization_endpoint, token: metadata.token_endpoint, registration: registration, resource: resource.resource)
    }

    /// Registers the app with the server (once per server; the client id is kept with the tokens).
    public static func register(_ endpoints: Endpoints, clientName: String, session: URLSession = .shared) async throws -> String {
        var request = URLRequest(url: endpoints.registration)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": clientName,
            "redirect_uris": [redirectURI],
            "application_type": "native",
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "scope": scopes,
        ])
        struct Registered: Decodable { let client_id: String }
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return try JSONDecoder().decode(Registered.self, from: data).client_id
    }

    /// Everything up to opening the browser: endpoints, registration, PKCE, and the address to open.
    public static func start(server: URL, clientName: String, knownClientId: String? = nil, session: URLSession = .shared) async throws -> Start {
        let endpoints = try await discover(server: server, session: session)
        let clientId: String
        if let knownClientId { clientId = knownClientId } else { clientId = try await register(endpoints, clientName: clientName, session: session) }
        let verifier = randomURLSafe(32)
        let state = randomURLSafe(16)
        var parts = URLComponents(url: endpoints.authorization, resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: endpoints.resource),
        ]
        return Start(url: parts.url!, state: state, verifier: verifier, clientId: clientId, endpoints: endpoints)
    }

    /// The browser came back to `redirectURI`: check the state and swap the code for tokens.
    public static func finish(_ start: Start, callback: URL, session: URLSession = .shared) async throws -> OAuthTokens {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw error == "access_denied" ? FerretError.cancelled : FerretError.server(status: 400, message: value("error_description") ?? error)
        }
        guard value("state") == start.state, let code = value("code") else { throw FerretError.server(status: 400, message: "The sign-in didn't come back as expected. Try again.") }
        return try await tokenRequest(start.endpoints.token, [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": start.clientId,
            "code_verifier": start.verifier,
            "resource": start.endpoints.resource,
        ], clientId: start.clientId, resource: start.endpoints.resource, keepRefresh: nil, session: session)
    }

    /// A new access token from the refresh token (which rotates: the old one is used up).
    public static func refresh(_ tokens: OAuthTokens, session: URLSession = .shared) async throws -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken else { throw FerretError.signedOut }
        return try await tokenRequest(tokens.tokenEndpoint, [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": tokens.clientId,
            "resource": tokens.resource,
        ], clientId: tokens.clientId, resource: tokens.resource, keepRefresh: refreshToken, session: session)
    }

    // MARK: - Pieces

    static func tokenRequest(_ endpoint: URL, _ form: [String: String], clientId: String, resource: String, keepRefresh: String?, session: URLSession) async throws -> OAuthTokens {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(form)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 400 || http.statusCode == 401, form["grant_type"] == "refresh_token" {
            // A refresh token that's used up, revoked (Disconnect in Settings) or expired: sign in again.
            throw FerretError.signedOut
        }
        try check(response, data)
        struct Issued: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
        }
        let issued = try JSONDecoder().decode(Issued.self, from: data)
        return OAuthTokens(
            accessToken: issued.access_token,
            refreshToken: issued.refresh_token ?? keepRefresh,
            expiresAt: Date().addingTimeInterval(issued.expires_in ?? 3600),
            clientId: clientId,
            tokenEndpoint: endpoint,
            resource: resource
        )
    }

    static func formBody(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)!
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func getJSON<T: Decodable>(_ url: URL, _ session: URLSession) async throws -> T {
        let (data, response) = try await session.data(from: url)
        if FerretError.isAccessBlock(response) { throw FerretError.accessBlocked }
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { throw FerretError.signInUnavailable }
        try check(response, data)
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw FerretError.notFerret }
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        if FerretError.isAccessBlock(response) { throw FerretError.accessBlocked }
        guard let http = response as? HTTPURLResponse else { throw FerretError.notFerret }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw FerretError.server(status: http.statusCode, message: FerretError.message(in: data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }
}
