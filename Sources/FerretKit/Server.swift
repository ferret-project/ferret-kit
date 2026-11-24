import Foundation

/// Where a Ferret lives. The app starts on the hosted Ferret; self-hosters type their own address.
public enum ServerAddress {
    public static let hosted = URL(string: "https://ferret.digitalempire.us")!

    /// What someone typed, as a server address: `https://` unless `http://` is typed (`ferret.example.com` →
    /// `https://ferret.example.com`; a server on plain HTTP is typed as `http://192.168.1.20:8787`).
    /// Paths, queries and fragments are dropped. Nil when it can't be an address.
    public static func parse(_ text: String) -> URL? {
        var typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !typed.contains(" ") else { return nil }
        if !typed.contains("://") {
            typed = "https://" + typed
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
}
