import Foundation

/// Where a Ferret lives. The app starts on the hosted Ferret; self-hosters type their own address.
public enum ServerAddress {
    public static let hosted = URL(string: "https://ferret.digitalempire.us")!

    /// What someone typed, as a server address: `ferret.example.com` → `https://ferret.example.com`,
    /// `192.168.1.20:8787` → `http://192.168.1.20:8787` (a LAN address over plain HTTP is normal for self-hosters).
    /// Paths, queries and fragments are dropped. Nil when it can't be an address.
    public static func parse(_ text: String) -> URL? {
        var typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !typed.contains(" ") else { return nil }
        if !typed.contains("://") {
            typed = (looksLocal(typed) ? "http://" : "https://") + typed
        }
        guard var parts = URLComponents(string: typed),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty
        else { return nil }
        parts.scheme = scheme
        parts.host = host.lowercased()
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.url
    }

    /// A bare IP address, `localhost`, or a `.local`/`.lan` name: most likely plain HTTP on a home network.
    static func looksLocal(_ typed: String) -> Bool {
        let host = typed.split(separator: "/").first.map(String.init) ?? typed
        let name = host.split(separator: ":").first.map(String.init)?.lowercased() ?? host
        if name == "localhost" || name.hasSuffix(".local") || name.hasSuffix(".lan") { return true }
        let octets = name.split(separator: ".")
        return octets.count == 4 && octets.allSatisfy { UInt8($0) != nil }
    }
}
