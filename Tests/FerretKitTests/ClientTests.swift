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

/// What the client handed back to be kept.
final class Kept: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [Session?] = []
    var session: Session?

    func record(_ change: Session?) { lock.withLock { changes.append(change); session = change } }
    var signedOut: Bool { lock.withLock { changes.contains { $0 == nil } } }
    var stored: Session? { lock.withLock { session } }
    func store(_ s: Session) { lock.withLock { session = s } }
}

@Suite(.serialized) struct ClientTests {
    let server = URL(string: "http://ferret.test")!
    static let tokenPath = "/api/auth/oauth2/token"

    func tokens(_ name: String, expiresIn: TimeInterval = 3600) -> OAuthTokens {
        OAuthTokens(accessToken: "at_\(name)", refreshToken: "rt_\(name)", expiresAt: Date().addingTimeInterval(expiresIn), clientId: "c", tokenEndpoint: URL(string: "http://ferret.test\(Self.tokenPath)")!, resource: "http://ferret.test/mcp")
    }

    func client(_ tokens: OAuthTokens, kept: Kept, reload: Bool = false) -> FerretClient {
        var reader: (@Sendable () -> Session?)?
        if reload { reader = { @Sendable in kept.stored } }
        return FerretClient(session: Session(server: server, credential: .oauth(tokens)), urlSession: Stub.session(), reload: reader, refreshRetries: [.zero, .zero], onSessionChange: { kept.record($0) })
    }

    static let issued = #"{"access_token":"at_new","refresh_token":"rt_new","expires_in":3600}"#
    static let me = #"{"user":{"id":"u","name":"Sam","email":"s@example.com"}}"#

    @Test func severalCallsShareOneRefresh() async throws {
        Stub.reset { r, _ in
            if r.url!.path == Self.tokenPath { return .reply(200, Self.issued) }
            return r.value(forHTTPHeaderField: "Authorization") == "Bearer at_new" ? .reply(200, Self.me) : .reply(401, "{}")
        }
        let kept = Kept()
        let c = client(tokens("old", expiresIn: 10), kept: kept)
        async let a = c.me()
        async let b = c.me()
        async let d = c.me()
        _ = try await (a, b, d)
        #expect(Stub.count(Self.tokenPath) == 1)
        if case .oauth(let saved) = kept.stored?.credential { #expect(saved.refreshToken == "rt_new") } else { Issue.record("not saved") }
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
