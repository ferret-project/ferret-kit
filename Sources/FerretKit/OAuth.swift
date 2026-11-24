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
        /// Who issues the codes: the sign-in's reply names it (`iss`, RFC 9207) and must match.
        public var issuer: String? = nil

        /// The server's own address, as it names itself (`https://ferret.example.com` from its resource
        /// `…/mcp`): use it rather than what was typed, which may be `http://` for a server that redirects to
        /// `https://` — and a redirect to another scheme drops the Authorization header from every API call.
        public var server: URL? {
            guard var parts = URLComponents(string: resource), let scheme = parts.scheme, scheme == "http" || scheme == "https", parts.host?.isEmpty == false else { return nil }
            parts.path = ""
            parts.query = nil
            parts.fragment = nil
            return parts.url
        }
    }

    public struct Start: Sendable {
        public var url: URL
        public var state: String
        public var verifier: String
        public var clientId: String
        public var endpoints: Endpoints
        /// Where the browser comes back to: each app has its own (`OAuth.redirectURI` is the iPhone app's).
        public var redirectURI: String
    }

    /// The redirect address for an app's own scheme (`us.digitalempire.ferret.menu` → `us.digitalempire.ferret.menu:/oauth`).
    public static func redirectURI(scheme: String) -> String { "\(scheme):/oauth" }

    /// Where to sign in on this server. Fails on a server too old for app sign-in (the app then offers an API key).
    public static func discover(server: URL, session: URLSession = .ferret(access: nil)) async throws -> Endpoints {
        struct Metadata: Decodable {
            let issuer: String?
            let authorization_endpoint: URL
            let token_endpoint: URL
            let registration_endpoint: URL?
        }
        struct Resource: Decodable { let resource: String }
        let metadata: Metadata = try await getJSON(server.appending(path: ".well-known/oauth-authorization-server"), session)
        let resource: Resource = try await getJSON(server.appending(path: ".well-known/oauth-protected-resource/mcp"), session)
        guard let registration = metadata.registration_endpoint else { throw FerretError.signInUnavailable }
        return Endpoints(authorization: metadata.authorization_endpoint, token: metadata.token_endpoint, registration: registration, resource: resource.resource, issuer: metadata.issuer)
    }

    /// Registers the app with the server (once per server; the client id is kept with the tokens).
    public static func register(_ endpoints: Endpoints, clientName: String, redirectURI: String = OAuth.redirectURI, session: URLSession = .ferret(access: nil)) async throws -> String {
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
        let (data, response) = try await FerretError.mappingOffline { try await session.data(for: request) }
        try check(response, data)
        return try JSONDecoder().decode(Registered.self, from: data).client_id
    }

    /// Everything up to opening the browser: endpoints, registration, PKCE, and the address to open.
    public static func start(server: URL, clientName: String, redirectURI: String = OAuth.redirectURI, knownClientId: String? = nil, session: URLSession = .ferret(access: nil)) async throws -> Start {
        let endpoints = try await discover(server: server, session: session)
        let verifier = randomURLSafe(32)
        let state = randomURLSafe(16)
        func address(_ clientId: String) -> URL { authorizeURL(endpoints, clientId: clientId, redirectURI: redirectURI, state: state, verifier: verifier) }
        var clientId: String
        if let knownClientId {
            clientId = knownClientId
            // Ferret forgets a registration a week after nothing uses it (disconnected, or never approved): register
            // again rather than open a sign-in page that can only say "client not found".
            if await registrationGone(address(clientId), session: session) {
                clientId = try await register(endpoints, clientName: clientName, redirectURI: redirectURI, session: session)
            }
        } else {
            clientId = try await register(endpoints, clientName: clientName, redirectURI: redirectURI, session: session)
        }
        return Start(url: address(clientId), state: state, verifier: verifier, clientId: clientId, endpoints: endpoints, redirectURI: redirectURI)
    }

    static func authorizeURL(_ endpoints: Endpoints, clientId: String, redirectURI: String, state: String, verifier: String) -> URL {
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
        return parts.url!
    }

    /// Whether the server no longer knows this registration: its sign-in address, asked without following the
    /// redirect, sends an unknown client to an error (`error=invalid_client`) instead of the sign-in page. Anything
    /// unclear (offline, another reply) counts as still known.
    static func registrationGone(_ authorize: URL, session: URLSession) async -> Bool {
        guard let (data, response) = try? await session.data(for: URLRequest(url: authorize), delegate: NoRedirects()),
              let http = response as? HTTPURLResponse
        else { return false }
        let location = http.value(forHTTPHeaderField: "Location") ?? ""
        return location.contains("error=invalid_client") || String(decoding: data.prefix(2000), as: UTF8.self).contains("invalid_client")
    }

    /// The browser came back to `redirectURI`: check the state and swap the code for tokens.
    public static func finish(_ start: Start, callback: URL, session: URLSession = .ferret(access: nil)) async throws -> OAuthTokens {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw error == "access_denied" ? FerretError.cancelled : FerretError.server(status: 400, message: value("error_description") ?? error)
        }
        guard value("state") == start.state, let code = value("code") else { throw FerretError.server(status: 400, message: "The sign-in didn't come back as expected. Try again.") }
        // The reply must come from the server the sign-in started at (RFC 9207: no mixing up two servers' replies).
        if let issuer = start.endpoints.issuer, let iss = value("iss"), iss != issuer {
            throw FerretError.server(status: 400, message: "The sign-in came back from a different server. Try again.")
        }
        return try await tokenRequest(start.endpoints.token, [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": start.redirectURI,
            "client_id": start.clientId,
            "code_verifier": start.verifier,
            "resource": start.endpoints.resource,
        ], clientId: start.clientId, resource: start.endpoints.resource, keepRefresh: nil, session: session)
    }

    /// A new access token from the refresh token (which rotates: the old one is used up).
    public static func refresh(_ tokens: OAuthTokens, session: URLSession = .ferret(access: nil)) async throws -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken else { throw FerretError.signedOut }
        return try await tokenRequest(tokens.tokenEndpoint, [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": tokens.clientId,
            "resource": tokens.resource,
        ], clientId: tokens.clientId, resource: tokens.resource, keepRefresh: refreshToken, session: session)
    }

    /// Signing out: the server forgets the refresh token (and the access tokens made from it), so a copy left anywhere
    /// is useless (RFC 7009). Best effort: a server without a revocation endpoint, or out of reach, is no reason to stay
    /// signed in, so this never throws.
    public static func revoke(_ tokens: OAuthTokens, server: URL, session: URLSession = .ferret(access: nil)) async {
        struct Metadata: Decodable { let revocation_endpoint: URL? }
        guard let metadata: Metadata = try? await getJSON(server.appending(path: ".well-known/oauth-authorization-server"), session),
              let endpoint = metadata.revocation_endpoint
        else { return }
        let (token, hint) = tokens.refreshToken.map { ($0, "refresh_token") } ?? (tokens.accessToken, "access_token")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(["token": token, "token_type_hint": hint, "client_id": tokens.clientId])
        _ = try? await session.data(for: request)
    }

    // MARK: - Pieces

    static func tokenRequest(_ endpoint: URL, _ form: [String: String], clientId: String, resource: String, keepRefresh: String?, session: URLSession) async throws -> OAuthTokens {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(form)
        let (data, response) = try await FerretError.mappingOffline { try await session.data(for: request) }
        // Cloudflare Access turning the app away isn't the sign-in ending: keep it, and say what's wrong.
        if FerretError.isAccessBlock(response) { throw FerretError.accessBlocked }
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
        let (data, response) = try await FerretError.mappingOffline { try await session.data(from: url) }
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

/// Hands back a redirect instead of following it (to read where the server would send a browser).
final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
