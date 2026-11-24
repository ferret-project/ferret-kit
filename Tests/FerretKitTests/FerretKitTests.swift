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
