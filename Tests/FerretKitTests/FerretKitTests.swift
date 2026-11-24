import Foundation
import Testing
@testable import FerretKit

@Suite struct ServerAddressTests {
    @Test func typedAddresses() {
        #expect(ServerAddress.parse("ferret.example.com")?.absoluteString == "https://ferret.example.com")
        #expect(ServerAddress.parse("  https://Ferret.Example.com/#/items  ")?.absoluteString == "https://ferret.example.com")
        #expect(ServerAddress.parse("192.168.1.20:8787")?.absoluteString == "http://192.168.1.20:8787")
        #expect(ServerAddress.parse("inventory.lan")?.absoluteString == "http://inventory.lan")
        #expect(ServerAddress.parse("https://inventory.lan")?.absoluteString == "https://inventory.lan")
        #expect(ServerAddress.parse("ftp://x.com") == nil)
        #expect(ServerAddress.parse("not an address") == nil)
        #expect(ServerAddress.parse("") == nil)
    }
}

@Suite struct MoneyTests {
    @Test func typedAmounts() {
        #expect(Money.cents(from: "12") == 1200)
        #expect(Money.cents(from: "12.5") == 1250)
        #expect(Money.cents(from: "$1,299.99") == 129_999)
        #expect(Money.cents(from: "12,50") == 1250)
        #expect(Money.cents(from: "abc") == nil)
        #expect(Money.editable(1250) == "12.50")
        #expect(Money.editable(1200) == "12")
        #expect(Money.editable(nil) == "")
    }
}

@Suite struct LabelTests {
    @Test func labelLinks() {
        #expect(labelCode(in: "https://ferret.example.com/l/abc123") == "ABC123")
        #expect(labelCode(in: "http://10.0.0.2:8787/l/K7Q2") == "K7Q2")
        #expect(labelCode(in: "https://ferret.example.com/items/1") == nil)
        #expect(labelCode(in: "0123456789012") == nil)
    }
}

@Suite struct OAuthTests {
    @Test func pkceChallenge() {
        // RFC 7636 appendix B.
        #expect(OAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func formEncoding() {
        let body = String(decoding: OAuth.formBody(["redirect_uri": "us.digitalempire.ferret:/oauth", "a": "b c"]), as: UTF8.self)
        #expect(body == "a=b%20c&redirect_uri=us.digitalempire.ferret%3A%2Foauth")
    }
}

@Suite struct ItemChangesTests {
    @Test func onlySetFieldsAndClearsAreSent() throws {
        var changes = ItemChanges()
        changes.name = "Drill"
        changes.clear = ["notes"]
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(changes)) as! [String: Any]
        #expect(json["name"] as? String == "Drill")
        #expect(json["notes"] is NSNull)
        #expect(json.count == 2)
    }

    @Test func decodesAListing() throws {
        let json = #"{"data":[{"id":"1","name":"Drill kit","brand":"DEWALT","model":"DCD771C2","quantity":2,"valueCents":11000,"place":"Home › Garage","tags":["DIY"],"photoId":"p1","somethingNew":{"x":1}}],"total":1,"valueCents":11000,"limit":50,"offset":0}"#
        let page = try JSONDecoder().decode(Page<Item>.self, from: Data(json.utf8))
        #expect(page.data.first?.subtitle == "DEWALT DCD771C2")
        #expect(page.data.first?.worthCents == 11000)
        #expect(page.total == 1)
    }
}

@Suite struct AccessTokenTests {
    @Test func headersAndCompleteness() {
        let token = AccessToken(clientId: " abc.access ", clientSecret: "s3cret\n")
        #expect(token.headers == ["CF-Access-Client-Id": "abc.access", "CF-Access-Client-Secret": "s3cret"])
        #expect(token.isComplete)
        #expect(!AccessToken(clientId: "abc", clientSecret: " ").isComplete)
        #expect(URLSession.ferret(access: nil) === URLSession.shared)
        #expect(URLSession.ferret(access: token).configuration.httpAdditionalHeaders?["CF-Access-Client-Id"] as? String == "abc.access")
    }

    @Test func recognisesAccessTurningTheAppAway() {
        let login = HTTPURLResponse(url: URL(string: "https://team.cloudflareaccess.com/cdn-cgi/access/login")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        #expect(FerretError.isAccessBlock(login))
        let refused = HTTPURLResponse(url: URL(string: "https://ferret.example.com/api/v1/me")!, statusCode: 403, httpVersion: nil, headerFields: ["cf-access-domain": "ferret.example.com"])!
        #expect(FerretError.isAccessBlock(refused))
        let ferrets = HTTPURLResponse(url: URL(string: "https://ferret.example.com/api/v1/me")!, statusCode: 401, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        #expect(!FerretError.isAccessBlock(ferrets))
    }

    @Test func oldSessionsWithoutATokenStillDecode() throws {
        let json = #"{"server":"https://ferret.example.com","credential":{"apiKey":{"_0":"ferret_x"}}}"#
        let session = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        #expect(session.access == nil)
    }
}

@Suite struct OfflineStoreTests {
    private func store() -> (OfflineStore, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "offline-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (OfflineStore(server: URL(string: "https://ferret.example.com")!, root: root), root)
    }

    private func json(_ id: String, _ name: String, photoId: String? = nil) -> Data {
        Data("{\"id\":\"\(id)\",\"name\":\"\(name)\"\(photoId.map { ",\"photoId\":\"\($0)\"" } ?? "")}".utf8)
    }

    @Test func keepsThingsInOrderWithPhotos() async throws {
        let (store, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.replace(with: [
            (id: "b", json: json("b", "Drill", photoId: "p1"), photoId: "p1", photo: Data([1, 2, 3])),
            (id: "a", json: json("a", "Ladder"), photoId: nil, photo: nil),
        ])
        let kept = await store.things()
        #expect(kept.map(\.item.name) == ["Drill", "Ladder"])
        #expect(kept.first?.photo == Data([1, 2, 3]))
        #expect(await store.keptPhoto("p1") == Data([1, 2, 3]))
        #expect(await store.thing("a")?.item.name == "Ladder")
    }

    @Test func replacesWholeAndClears() async throws {
        let (store, root) = store()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.replace(with: [(id: "a", json: json("a", "Ladder"), photoId: nil, photo: nil)])
        try await store.replace(with: [(id: "c", json: json("c", "Rake"), photoId: nil, photo: nil)])
        #expect(await store.things().map(\.id) == ["c"])
        #expect(await store.thing("a") == nil)
        await store.clear()
        #expect(await store.things().isEmpty)
    }

    @Test func oneFolderPerServer() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "offline-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = OfflineStore(server: URL(string: "https://one.example.com")!, root: root)
        let two = OfflineStore(server: URL(string: "http://10.0.0.2:8787")!, root: root)
        try await one.replace(with: [(id: "a", json: json("a", "Ladder"), photoId: nil, photo: nil)])
        #expect(await two.things().isEmpty)
    }
}
