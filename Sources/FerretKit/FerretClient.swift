import Foundation

/// Talks to one Ferret server's REST API (`/api/v1`) as one signed-in person.
///
/// An actor so a token refresh happens once even when several requests hit an expired token together; the new
/// tokens are handed to `onSessionChange` to be saved.
///
/// Refresh tokens rotate: each refresh uses the old one up, and Ferret accepts it again for only 60 seconds
/// (`refreshTokenReuseInterval`) before treating a reuse as theft and ending every sign-in of this app. So a refresh
/// whose reply was lost is tried again at once, inside that minute; new tokens are kept in `store` before anything else
/// happens (so quitting a moment later can't leave used-up ones behind); and before refreshing the client reads the
/// store in case another process sharing it (a share extension, a widget) refreshed first.
public actor FerretClient {
    public nonisolated let server: URL
    private var credential: Credential
    private var refreshing: Task<OAuthTokens, Error>?
    private let urlSession: URLSession
    private let onSessionChange: @Sendable (Session?) -> Void
    private let store: (any SessionKeeper)?
    private let onKeepFailed: @Sendable (Error) -> Void
    /// How long to wait before each new try of a refresh the network cut short (all well inside Ferret's minute).
    let refreshRetries: [Duration]

    private let access: AccessToken?

    /// `store`: where the sign-in is kept (the Keychain). The client keeps refreshed tokens there itself, at once, reads
    /// it before refreshing (another process may have refreshed), and forgets the sign-in there when it ends.
    /// `onSessionChange`: new tokens (already kept), or nil when the sign-in ended. `onKeepFailed`: the store refused.
    /// `urlSession`: for tests; otherwise one that adds the server's Cloudflare Access headers, if it has any.
    public init(session: Session, store: (any SessionKeeper)? = nil, urlSession: URLSession? = nil, onKeepFailed: @escaping @Sendable (Error) -> Void = { _ in }, onSessionChange: @escaping @Sendable (Session?) -> Void = { _ in }) {
        self.init(session: session, store: store, urlSession: urlSession, refreshRetries: [.seconds(1), .seconds(4), .seconds(10)], onKeepFailed: onKeepFailed, onSessionChange: onSessionChange)
    }

    init(session: Session, store: (any SessionKeeper)?, urlSession: URLSession?, refreshRetries: [Duration], onKeepFailed: @escaping @Sendable (Error) -> Void = { _ in }, onSessionChange: @escaping @Sendable (Session?) -> Void) {
        server = session.server
        credential = session.credential
        access = session.access
        self.urlSession = urlSession ?? .ferret(access: session.access)
        self.store = store
        self.refreshRetries = refreshRetries
        self.onKeepFailed = onKeepFailed
        self.onSessionChange = onSessionChange
    }

    /// How long a call may take: Ask Ferret's model can take minutes on a busy self-hosted GPU (Ferret allows 5).
    public static let slowCall: TimeInterval = 330

    /// Whether the person signed in with an API key (Settings shows it, so they know what to delete on the server).
    public var usesAPIKey: Bool {
        if case .apiKey = credential { return true }
        return false
    }

    /// A one-time link (good once, for a minute) that signs the app's web view in to Ferret's web screens, with the
    /// app's own limits; Ferret sets the cookie itself when the web view opens it. `to` is the screen (`#/…`). Nil when
    /// signed in with an API key (debug builds only): those screens then ask for a sign-in of their own.
    public func webSignInLink(to route: String?) async throws -> WebSignInLink? {
        guard case .oauth = credential else { return nil }
        return try await send("POST", "/app/web-session", body: WebSignInRequest(to: route))
    }

    /// Signing out: the web screens' sign-ins for this app end on the server too.
    public func endWebSignIns() async throws {
        guard case .oauth = credential else { return }
        try await delete("/app/web-session")
    }

    // MARK: - Calls

    /// `timeout`: for a call that may take longer than a minute (`FerretClient.slowCall`).
    public func get<T: Decodable>(_ path: String, query: [String: String?] = [:], timeout: TimeInterval? = nil) async throws -> T {
        var r = request(path, query: query)
        if let timeout { r.timeoutInterval = timeout }
        return try decode(await perform(r))
    }

    public func send<T: Decodable>(_ method: String, _ path: String, body: some Encodable, timeout: TimeInterval? = nil) async throws -> T {
        var r = request(path)
        if let timeout { r.timeoutInterval = timeout }
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

    /// Uploads bytes already in memory (a photo just taken) as multipart/form-data: `file`, plus text fields such as
    /// `kind`. They go through a temporary file like any other upload.
    public func upload<T: Decodable>(_ path: String, file: Data, filename: String, contentType: String, fields: [String: String] = [:]) async throws -> T {
        let source = FileManager.default.temporaryDirectory.appending(path: "ferret-source-\(UUID().uuidString)")
        try file.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        return try await upload(path, fileAt: source, filename: filename, contentType: contentType, fields: fields)
    }

    /// Uploads a file on disk as multipart/form-data, streamed: the body is written to a temporary file a piece at a
    /// time and sent from there, so a large file is never held in memory whole.
    public func upload<T: Decodable>(_ path: String, fileAt url: URL, filename: String, contentType: String, fields: [String: String] = [:]) async throws -> T {
        let boundary = "ferret-\(UUID().uuidString)"
        let body = try Multipart.write(file: url, filename: filename, contentType: contentType, fields: fields, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: body) }
        var r = request(path)
        r.httpMethod = "POST"
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 120
        return try decode(await perform(r, bodyFile: body))
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

    /// Sends a request with the current token (refreshed first if it's about to end); `bodyFile` is sent from disk.
    private func perform(_ base: URLRequest, bodyFile: URL? = nil, retried: Bool = false) async throws -> Data {
        var r = base
        let bearer = try await currentBearer()
        r.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await FerretError.mappingOffline {
            if let bodyFile { try await self.urlSession.upload(for: r, fromFile: bodyFile) } else { try await self.urlSession.data(for: r) }
        }
        guard let http = response as? HTTPURLResponse else { throw FerretError.notFerret }
        if FerretError.isAccessBlock(http) { throw FerretError.accessBlocked }
        if http.statusCode == 401 {
            // An access token can end early (signed out on the web, server restarted): try once more with newer tokens
            // (refreshed meanwhile here or by another process, else refreshed now), then give up.
            if case .oauth = credential, !retried {
                if credential.bearer == bearer, !adoptKept() {
                    _ = try await refreshedTokens(force: true)
                }
                return try await perform(base, bodyFile: bodyFile, retried: true)
            }
            signOut()
            throw FerretError.signedOut
        }
        if (300 ..< 400).contains(http.statusCode) {
            // A redirect to another address isn't followed (it would carry the sign-in and Access token there).
            let to = (http.value(forHTTPHeaderField: "Location")).flatMap { URL(string: $0, relativeTo: base.url)?.host() } ?? "?"
            throw FerretError.server(status: http.statusCode, message: String(localized: "The server sent the app to another address (\(to)). Sign in with that address instead."))
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

    /// Takes the kept session when another process has newer tokens for this server. True when it did.
    private func adoptKept() -> Bool {
        guard let kept = store?.load(), kept.server == server, case .oauth(let keptTokens) = kept.credential,
              case .oauth(let tokens) = credential, keptTokens.refreshToken != tokens.refreshToken || keptTokens.accessToken != tokens.accessToken
        else { return false }
        credential = kept.credential
        return true
    }

    private func refreshedTokens(force: Bool) async throws -> OAuthTokens {
        if let refreshing { return try await refreshing.value }
        // Another process may have refreshed already: its tokens are good, and ours are used up.
        if adoptKept(), case .oauth(let kept) = credential, !kept.isExpiring { return kept }
        guard case .oauth(let tokens) = credential else { throw FerretError.signedOut }
        if !force, !tokens.isExpiring { return tokens }
        let session = urlSession
        let retries = refreshRetries
        let task = Task { try await Self.refresh(tokens, session: session, retries: retries) }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            credential = .oauth(fresh)
            let session = Session(server: server, credential: credential, access: access)
            // Kept before anything else: the old refresh token is used up from now on.
            do { try store?.save(session) } catch { onKeepFailed(error) }
            onSessionChange(session)
            return fresh
        } catch FerretError.signedOut {
            // Turned away: unless another process refreshed meanwhile (then ours was simply used up), sign in again.
            if adoptKept(), case .oauth(let kept) = credential { return kept }
            signOut()
            throw FerretError.signedOut
        }
    }

    /// A refresh, tried again at once when the network cut it short: the server may have rotated the tokens before the
    /// reply was lost, and the old refresh token only works again for a minute.
    static func refresh(_ tokens: OAuthTokens, session: URLSession, retries: [Duration]) async throws -> OAuthTokens {
        var waits = retries[...]
        while true {
            do {
                return try await OAuth.refresh(tokens, session: session)
            } catch FerretError.offline {
                guard let wait = waits.popFirst() else { throw FerretError.offline }
                try await Task.sleep(for: wait)
            }
        }
    }

    /// The sign-in ended: forgotten in the store too, unless the store already holds a different one (signed in again
    /// meanwhile, perhaps in another process).
    private func signOut() {
        if let store, let kept = store.load(), kept.server == server, Self.same(kept.credential, credential) { store.clear() }
        onSessionChange(nil)
    }

    /// The same sign-in (its refresh token, or key), whatever else changed.
    static func same(_ a: Credential, _ b: Credential) -> Bool {
        switch (a, b) {
        case let (.oauth(x), .oauth(y)): (x.refreshToken ?? x.accessToken) == (y.refreshToken ?? y.accessToken)
        case let (.apiKey(x), .apiKey(y)): x == y
        default: false
        }
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

/// multipart/form-data bodies, written to a temporary file in pieces.
enum Multipart {
    /// A header value with nothing that could end the line it's on (a filename with a line break would start new
    /// headers or parts) or the quotes around it.
    static func safe(_ value: String) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.newlines.contains($0) && $0 != "\"" && $0 != "\0" })
    }

    static func write(file: URL, filename: String, contentType: String, fields: [String: String], boundary: String) throws -> URL {
        let out = FileManager.default.temporaryDirectory.appending(path: "ferret-upload-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: out.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let writer = try FileHandle(forWritingTo: out)
            defer { try? writer.close() }
            func line(_ text: String) throws { try writer.write(contentsOf: Data((text + "\r\n").utf8)) }
            for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
                try line("--\(boundary)")
                try line("Content-Disposition: form-data; name=\"\(safe(name))\"")
                try line("")
                try line(value)
            }
            try line("--\(boundary)")
            try line("Content-Disposition: form-data; name=\"file\"; filename=\"\(safe(filename))\"")
            try line("Content-Type: \(safe(contentType))")
            try line("")
            let reader = try FileHandle(forReadingFrom: file)
            defer { try? reader.close() }
            while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
                try writer.write(contentsOf: chunk)
            }
            try line("")
            try line("--\(boundary)--")
            return out
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }
}

struct WebSignInRequest: Encodable, Sendable {
    let to: String?
}

/// Where the web view goes to sign in (`url`, a path on the server), and when that sign-in will end.
public struct WebSignInLink: Decodable, Sendable {
    public let url: String
    let expiresAt: String

    public var expires: Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt)
    }
}

/// For calls whose reply the app doesn't need.
public struct Empty: Decodable, Sendable {
    public init() {}
}
