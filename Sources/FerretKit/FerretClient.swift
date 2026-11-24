import Foundation

/// Talks to one Ferret server's REST API (`/api/v1`) as one signed-in person.
///
/// An actor so a token refresh happens once even when several requests hit an expired token together; the new
/// tokens are handed to `onSessionChange` to be saved.
public actor FerretClient {
    public nonisolated let server: URL
    private var credential: Credential
    private var refreshing: Task<OAuthTokens, Error>?
    private let urlSession: URLSession
    private let onSessionChange: @Sendable (Session?) -> Void

    private let access: AccessToken?

    /// `urlSession`: for tests; otherwise one that adds the server's Cloudflare Access headers, if it has any.
    public init(session: Session, urlSession: URLSession? = nil, onSessionChange: @escaping @Sendable (Session?) -> Void = { _ in }) {
        server = session.server
        credential = session.credential
        access = session.access
        self.urlSession = urlSession ?? .ferret(access: session.access)
        self.onSessionChange = onSessionChange
    }

    /// Whether the person signed in with an API key (Settings shows it, so they know what to delete on the server).
    public var usesAPIKey: Bool {
        if case .apiKey = credential { return true }
        return false
    }

    // MARK: - Calls

    public func get<T: Decodable>(_ path: String, query: [String: String?] = [:]) async throws -> T {
        try decode(await perform(request(path, query: query)))
    }

    public func send<T: Decodable>(_ method: String, _ path: String, body: some Encodable) async throws -> T {
        var r = request(path)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(body)
        return try decode(await perform(r))
    }

    public func post<T: Decodable>(_ path: String) async throws -> T {
        var r = request(path)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data("{}".utf8)
        return try decode(await perform(r))
    }

    public func delete(_ path: String) async throws {
        var r = request(path)
        r.httpMethod = "DELETE"
        _ = try await perform(r)
    }

    /// Bytes of a file (a photo's thumbnail or the file itself).
    public func data(_ path: String) async throws -> Data {
        try await perform(request(path))
    }

    /// Uploads a file as multipart/form-data (`file`, plus text fields such as `kind`).
    public func upload<T: Decodable>(_ path: String, file: Data, filename: String, contentType: String, fields: [String: String] = [:]) async throws -> T {
        let boundary = "ferret-\(UUID().uuidString)"
        var body = Data()
        func line(_ s: String) { body.append(Data((s + "\r\n").utf8)) }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            line("--\(boundary)")
            line("Content-Disposition: form-data; name=\"\(name)\"")
            line("")
            line(value)
        }
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename.replacingOccurrences(of: "\"", with: ""))\"")
        line("Content-Type: \(contentType)")
        line("")
        body.append(file)
        line("")
        line("--\(boundary)--")
        var r = request(path)
        r.httpMethod = "POST"
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        r.timeoutInterval = 120
        return try decode(await perform(r))
    }

    // MARK: - Plumbing

    private func request(_ path: String, query: [String: String?] = [:]) -> URLRequest {
        var parts = URLComponents(url: server.appending(path: "api/v1").appending(path: path), resolvingAgainstBaseURL: false)!
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }.sorted { $0.name < $1.name }
        if !items.isEmpty { parts.queryItems = items }
        var r = URLRequest(url: parts.url!)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    private func perform(_ base: URLRequest, retried: Bool = false) async throws -> Data {
        var r = base
        r.setValue("Bearer \(try await currentBearer())", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: r)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut, .dataNotAllowed].contains(error.code) {
            throw FerretError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw FerretError.notFerret }
        if FerretError.isAccessBlock(http) { throw FerretError.accessBlocked }
        if http.statusCode == 401 {
            // An access token can end early (signed out on the web, server restarted): refresh once, then give up.
            if case .oauth = credential, !retried {
                _ = try await refreshedTokens(force: true)
                return try await perform(base, retried: true)
            }
            signOut()
            throw FerretError.signedOut
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw FerretError.server(status: http.statusCode, message: FerretError.message(in: data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        return data
    }

    private func currentBearer() async throws -> String {
        if case .oauth(let tokens) = credential, tokens.isExpiring {
            return try await refreshedTokens(force: false).accessToken
        }
        return credential.bearer
    }

    private func refreshedTokens(force: Bool) async throws -> OAuthTokens {
        if let refreshing { return try await refreshing.value }
        guard case .oauth(let tokens) = credential else { throw FerretError.signedOut }
        if !force, !tokens.isExpiring { return tokens }
        let session = urlSession
        let task = Task { try await OAuth.refresh(tokens, session: session) }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            credential = .oauth(fresh)
            onSessionChange(Session(server: server, credential: credential, access: access))
            return fresh
        } catch FerretError.signedOut {
            signOut()
            throw FerretError.signedOut
        }
    }

    private func signOut() {
        onSessionChange(nil)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        if T.self == Empty.self { return Empty() as! T }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw FerretError.server(status: 200, message: "Unexpected reply from the server (\(error.localizedDescription))")
        }
    }
}

/// For calls whose reply the app doesn't need.
public struct Empty: Decodable, Sendable {
    public init() {}
}
