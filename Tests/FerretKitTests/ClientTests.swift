import Foundation
import Testing
@testable import FerretKit

/// Answers requests with a handler (status and body, or a network error), and records what was asked.
final class Stub: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable {
        let method: String
        let path: String
        let authorization: String?
        let body: Data
    }

    enum Answer {
        case reply(Int, String, headers: [String: String] = [:])
        case fail(URLError.Code)
    }

    nonisolated(unsafe) static var handler: (URLRequest, Data) -> Answer = { _, _ in .reply(404, "{}") }
    nonisolated(unsafe) static var seen: [Seen] = []
    static let lock = NSLock()

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return URLSession(configuration: configuration)
    }

    static func reset(_ handler: @escaping (URLRequest, Data) -> Answer) {
        lock.withLock {
            Stub.handler = handler
            Stub.seen = []
        }
    }

    static func count(_ path: String) -> Int { lock.withLock { seen.count { $0.path == path } } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let answer = Stub.lock.withLock {
            Stub.seen.append(Seen(method: request.httpMethod ?? "GET", path: request.url!.path, authorization: request.value(forHTTPHeaderField: "Authorization"), body: body))
            return Stub.handler(request, body)
        }
        switch answer {
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .reply(let status, let text, let headers):
            var all = ["Content-Type": "application/json"]
            all.merge(headers) { $1 }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: all)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// The store the client keeps the sign-in in, and what it told the app.
final class Kept: SessionKeeper, @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [Session?] = []
    private var session: Session?
    /// What the store held each time the app was told of new tokens (kept first?).
    private(set) var keptWhenTold: [Session?] = []

    func record(_ change: Session?) { lock.withLock { changes.append(change); keptWhenTold.append(session) } }
    var signedOut: Bool { lock.withLock { changes.contains { $0 == nil } } }
    var stored: Session? { lock.withLock { session } }
    func store(_ s: Session?) { lock.withLock { session = s } }

    func load() -> Session? { stored }
    func exists() -> Bool { stored != nil }
    func save(_ session: Session) throws { store(session) }
    func clear() { store(nil) }
}

@Suite(.serialized) struct ClientTests {
    let server = URL(string: "http://ferret.test")!
    static let tokenPath = "/api/auth/oauth2/token"

    func tokens(_ name: String, expiresIn: TimeInterval = 3600) -> OAuthTokens {
        OAuthTokens(accessToken: "at_\(name)", refreshToken: "rt_\(name)", expiresAt: Date().addingTimeInterval(expiresIn), clientId: "c", tokenEndpoint: URL(string: "http://ferret.test\(Self.tokenPath)")!, resource: "http://ferret.test/mcp")
    }

    /// `shared`: the client keeps its sign-in in `kept` (otherwise it has no store and `kept` only hears of changes).
    func client(_ tokens: OAuthTokens, kept: Kept, reload: Bool = false) -> FerretClient {
        FerretClient(session: Session(server: server, credential: .oauth(tokens)), store: reload ? kept : nil, urlSession: Stub.session(), refreshRetries: [.zero, .zero], onSessionChange: { kept.record($0) })
    }

    static let issued = #"{"access_token":"at_new","refresh_token":"rt_new","expires_in":3600}"#
    static let me = #"{"user":{"id":"u","name":"Sam","email":"s@example.com"}}"#

    @Test func severalCallsShareOneRefresh() async throws {
        Stub.reset { r, _ in
            if r.url!.path == Self.tokenPath { return .reply(200, Self.issued) }
            return r.value(forHTTPHeaderField: "Authorization") == "Bearer at_new" ? .reply(200, Self.me) : .reply(401, "{}")
        }
        let kept = Kept()
        kept.store(Session(server: server, credential: .oauth(tokens("old", expiresIn: 10))))
        let c = client(tokens("old", expiresIn: 10), kept: kept, reload: true)
        async let a = c.me()
        async let b = c.me()
        async let d = c.me()
        _ = try await (a, b, d)
        #expect(Stub.count(Self.tokenPath) == 1)
        if case .oauth(let saved) = kept.stored?.credential { #expect(saved.refreshToken == "rt_new") } else { Issue.record("not saved") }
        // Kept before the app heard of them.
        if case .oauth(let first) = kept.keptWhenTold.first??.credential { #expect(first.refreshToken == "rt_new") } else { Issue.record("told before keeping") }
    }

    @Test func anEndedSignInIsForgottenInTheStore() async {
        Stub.reset { r, _ in r.url!.path == Self.tokenPath ? .reply(400, #"{"error":"invalid_grant"}"#) : .reply(401, "{}") }
        let kept = Kept()
        kept.store(Session(server: server, credential: .oauth(tokens("old"))))
        await #expect(throws: FerretError.signedOut) { try await client(tokens("old"), kept: kept, reload: true).me() }
        #expect(kept.stored == nil)
        #expect(kept.signedOut)
    }

    @Test func askMayTakeMinutes() async throws {
        nonisolated(unsafe) var timeout: TimeInterval = 0
        Stub.reset { r, _ in
            if r.url!.path == "/api/v1/ask" { timeout = r.timeoutInterval }
            return .reply(200, #"{"answer":"x","found":true,"citations":[]}"#)
        }
        _ = try await client(tokens("t"), kept: Kept()).ask("where is the drill?")
        #expect(timeout >= 300)
    }

    @Test func aRedirectElsewhereIsNotFollowedOrSentTheToken() async {
        Stub.reset { _, _ in .reply(302, "", headers: ["Location": "https://elsewhere.example/api/v1/me"]) }
        do {
            _ = try await client(tokens("t"), kept: Kept()).me()
            Issue.record("followed")
        } catch {
            #expect(error is FerretError)
            #expect(error.localizedDescription.contains("elsewhere.example"))
        }
        #expect(Stub.seen.count == 1)
    }

    @Test func aTurnedAwayTokenIsRefreshedOnceAndTriedAgain() async throws {
        Stub.reset { r, _ in
            if r.url!.path == Self.tokenPath { return .reply(200, Self.issued) }
            return r.value(forHTTPHeaderField: "Authorization") == "Bearer at_new" ? .reply(200, Self.me) : .reply(401, "{}")
        }
        let kept = Kept()
        let me = try await client(tokens("old"), kept: kept).me()
        #expect(me.user.name == "Sam")
        #expect(Stub.count(Self.tokenPath) == 1)
        #expect(!kept.signedOut)
    }

    @Test func aRefusedRefreshSignsOut() async {
        Stub.reset { r, _ in r.url!.path == Self.tokenPath ? .reply(400, #"{"error":"invalid_grant"}"#) : .reply(401, "{}") }
        let kept = Kept()
        await #expect(throws: FerretError.signedOut) { try await client(tokens("old"), kept: kept).me() }
        #expect(kept.signedOut)
    }

    @Test func aRefreshCutShortIsTriedAgainAtOnce() async throws {
        var failures = 2
        Stub.reset { r, _ in
            if r.url!.path == Self.tokenPath {
                if failures > 0 { failures -= 1; return .fail(.networkConnectionLost) }
                return .reply(200, Self.issued)
            }
            return .reply(200, Self.me)
        }
        let kept = Kept()
        _ = try await client(tokens("old", expiresIn: 10), kept: kept).me()
        #expect(Stub.count(Self.tokenPath) == 3)
        #expect(!kept.signedOut)
    }

    @Test func noNetworkWhileRefreshingIsOfflineNotSignedOut() async {
        Stub.reset { _, _ in .fail(.notConnectedToInternet) }
        let kept = Kept()
        await #expect(throws: FerretError.offline) { try await client(tokens("old", expiresIn: 10), kept: kept).me() }
        #expect(Stub.count(Self.tokenPath) == 3) // the first try and both retries
        #expect(!kept.signedOut)
    }

    @Test func tokensAnotherProcessRefreshedAreUsedNotUsedUpAgain() async throws {
        Stub.reset { r, _ in
            if r.url!.path == Self.tokenPath { return .reply(400, #"{"error":"invalid_grant"}"#) }
            return r.value(forHTTPHeaderField: "Authorization") == "Bearer at_ext" ? .reply(200, Self.me) : .reply(401, "{}")
        }
        let kept = Kept()
        // The share extension refreshed and kept its tokens; this client still holds the used-up ones.
        kept.store(Session(server: server, credential: .oauth(tokens("ext"))))
        _ = try await client(tokens("old", expiresIn: 10), kept: kept, reload: true).me()
        #expect(Stub.count(Self.tokenPath) == 0)
        #expect(!kept.signedOut)
    }

    @Test func aRefreshLostToAnotherProcessDoesntSignOut() async throws {
        let kept = Kept()
        let server = server
        // Another process refreshes while this one is refreshing with the same (now used-up) token.
        Stub.reset { [tokens = tokens("ext")] r, _ in
            if r.url!.path == Self.tokenPath {
                kept.store(Session(server: server, credential: .oauth(tokens)))
                return .reply(400, #"{"error":"invalid_grant"}"#)
            }
            return r.value(forHTTPHeaderField: "Authorization") == "Bearer at_ext" ? .reply(200, Self.me) : .reply(401, "{}")
        }
        _ = try await client(tokens("old", expiresIn: 10), kept: kept, reload: true).me()
        #expect(!kept.signedOut)
    }

    @Test func accessTurningARefreshAwayKeepsTheSignIn() async {
        Stub.reset { r, _ in
            r.url!.path == Self.tokenPath ? .reply(401, "{}", headers: ["cf-access-domain": "ferret.test"]) : .reply(200, Self.me)
        }
        let kept = Kept()
        await #expect(throws: FerretError.accessBlocked) { try await client(tokens("old", expiresIn: 10), kept: kept).me() }
        #expect(!kept.signedOut)
    }

    @Test func uploadsStreamFromAFile() async throws {
        Stub.reset { _, _ in .reply(201, #"{"id":"a","itemId":"i","kind":"photo","filename":"x.jpg"}"#) }
        let file = FileManager.default.temporaryDirectory.appending(path: "big-\(UUID().uuidString).bin")
        let bytes = Data((0 ..< 3_000_000).map { UInt8($0 % 251) })
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let before = try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()).filter { $0.hasPrefix("ferret-upload-") }.count
        let kept = Kept()
        _ = try await client(tokens("t"), kept: kept).addFile(to: "i", fileAt: file, filename: "evil\r\nX-Injected: 1\".jpg", contentType: "image/jpeg")
        let sent = try #require(Stub.seen.first { $0.path == "/api/v1/items/i/attachments" })
        let text = String(decoding: sent.body.prefix(400), as: UTF8.self)
        #expect(text.contains("filename=\"evilX-Injected: 1.jpg\""))
        #expect(!text.contains("\r\nX-Injected"))
        #expect(text.contains("name=\"kind\"\r\n\r\nphoto"))
        #expect(sent.body.range(of: bytes) != nil)
        // The temporary body is gone afterwards.
        let after = try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()).filter { $0.hasPrefix("ferret-upload-") }.count
        #expect(after == before)
    }
}

@Suite struct KeychainTests {
    @Test func keepsReadsAndForgets() throws {
        let store = SessionStore(service: "us.digitalempire.ferret.test-\(UUID().uuidString)")
        defer { store.clear() }
        #expect(!store.exists())
        let session = Session(server: URL(string: "https://ferret.example.com")!, credential: .apiKey("ferret_x"))
        try store.save(session)
        #expect(store.exists())
        #expect(store.load() == session)
        try store.save(Session(server: session.server, credential: .apiKey("ferret_y")))
        #expect(store.load()?.credential == .apiKey("ferret_y"))
        store.clear()
        #expect(store.load() == nil)
    }

    @Test func aRefusalSaysWhy() {
        #expect(KeychainError(status: errSecMissingEntitlement).errorDescription?.contains("Keychain") == true)
    }
}

/// Sign-in against the same stub (one suite, so tests sharing it never run at once).
extension ClientTests {
    func endpoints(issuer: String? = "http://ferret.test/api/auth") -> OAuth.Endpoints {
        OAuth.Endpoints(authorization: URL(string: "http://ferret.test/api/auth/oauth2/authorize")!, token: URL(string: "http://ferret.test/api/auth/oauth2/token")!, registration: URL(string: "http://ferret.test/api/auth/oauth2/register")!, resource: "http://ferret.test/mcp", issuer: issuer)
    }

    @Test func aForgottenRegistrationIsNoticed() async {
        Stub.reset { r, _ in
            let id = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "client_id" }?.value
            return id == "gone"
                ? .reply(302, "", headers: ["Location": "http://ferret.test/api/auth/error?error=invalid_client&error_description=client+not+found"])
                : .reply(302, "", headers: ["Location": "http://ferret.test/#/connect/sign-in?client_id=\(id ?? "")"])
        }
        let e = endpoints()
        #expect(await OAuth.registrationGone(OAuth.authorizeURL(e, clientId: "gone", redirectURI: "x:/oauth", state: "s", verifier: "v"), session: Stub.session()))
        #expect(!(await OAuth.registrationGone(OAuth.authorizeURL(e, clientId: "known", redirectURI: "x:/oauth", state: "s", verifier: "v"), session: Stub.session())))
    }

    @Test func startRegistersAgainWhenTheServerForgotTheApp() async throws {
        Stub.reset { r, _ in
            switch r.url!.path {
            case "/.well-known/oauth-authorization-server":
                return .reply(200, #"{"issuer":"http://ferret.test/api/auth","authorization_endpoint":"http://ferret.test/api/auth/oauth2/authorize","token_endpoint":"http://ferret.test/api/auth/oauth2/token","registration_endpoint":"http://ferret.test/api/auth/oauth2/register"}"#)
            case "/.well-known/oauth-protected-resource/mcp":
                return .reply(200, #"{"resource":"http://ferret.test/mcp"}"#)
            case "/api/auth/oauth2/register":
                return .reply(201, #"{"client_id":"fresh"}"#)
            default:
                return .reply(302, "", headers: ["Location": "http://ferret.test/api/auth/error?error=invalid_client"])
            }
        }
        let start = try await OAuth.start(server: URL(string: "http://ferret.test")!, clientName: "Test", knownClientId: "gone", session: Stub.session())
        #expect(start.clientId == "fresh")
        #expect(start.url.absoluteString.contains("client_id=fresh"))
        #expect(start.endpoints.issuer == "http://ferret.test/api/auth")
    }

    @Test func aReplyFromAnotherServerIsRefused() async {
        Stub.reset { _, _ in .reply(200, #"{"access_token":"a","refresh_token":"r","expires_in":3600}"#) }
        let start = OAuth.Start(url: URL(string: "http://ferret.test")!, state: "s", verifier: "v", clientId: "c", endpoints: endpoints(), redirectURI: "x:/oauth")
        await #expect(throws: FerretError.self) {
            _ = try await OAuth.finish(start, callback: URL(string: "x:/oauth?code=abc&state=s&iss=https%3A%2F%2Fevil.example%2Fapi%2Fauth")!, session: Stub.session())
        }
        let ok = try? await OAuth.finish(start, callback: URL(string: "x:/oauth?code=abc&state=s&iss=http%3A%2F%2Fferret.test%2Fapi%2Fauth")!, session: Stub.session())
        #expect(ok?.accessToken == "a")
    }
}

@Suite struct RedirectTests {
    @Test func onlyTheSameHostAndUpToHttps() {
        let a = URL(string: "http://inventory.lan/api/v1/me")!
        #expect(SameHostRedirects.allowed(from: a, to: URL(string: "https://inventory.lan/api/v1/me")))
        #expect(SameHostRedirects.allowed(from: URL(string: "https://Inventory.lan/x"), to: URL(string: "https://inventory.lan/y")))
        #expect(!SameHostRedirects.allowed(from: URL(string: "https://inventory.lan/x"), to: URL(string: "http://inventory.lan/x")))
        #expect(!SameHostRedirects.allowed(from: a, to: URL(string: "https://elsewhere.example/api/v1/me")))
        #expect(!SameHostRedirects.allowed(from: URL(string: "https://inventory.lan:8443/x"), to: URL(string: "https://inventory.lan/x")))
    }

    @Test func accessLoginRedirectIsAccessBlocked() {
        let response = HTTPURLResponse(url: URL(string: "https://ferret.example.com/api/v1/me")!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://team.cloudflareaccess.com/cdn-cgi/access/login"])!
        #expect(FerretError.isAccessBlock(response))
    }

    @Test func oneSessionPerAccessToken() {
        let token = AccessToken(clientId: "id", clientSecret: "secret")
        #expect(URLSession.ferret(access: token) === URLSession.ferret(access: token))
        #expect(URLSession.ferret(access: nil) !== URLSession.ferret(access: token))
        #expect(URLSession.ferret(access: nil).configuration.httpAdditionalHeaders == nil)
    }
}

@Suite struct OfflineNameTests {
    @Test func idsNeverReachOutsideTheFolder() {
        let name = OfflineStore.fileName("item", "../../etc/passwd")
        #expect(!name.contains("/") && !name.contains(".."))
        #expect(name == OfflineStore.fileName("item", "../../etc/passwd"))
        #expect(name != OfflineStore.fileName("item", "other"))
    }
}
