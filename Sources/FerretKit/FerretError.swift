import Foundation

public enum FerretError: LocalizedError, Equatable, Sendable {
    /// The sign-in ended (disconnected in Settings, the key deleted, left the household): sign in again.
    case signedOut
    /// The person closed the sign-in, or tapped Cancel on Ferret's screen.
    case cancelled
    /// The address answers, but it isn't a Ferret.
    case notFerret
    /// This Ferret is too old for the app: its server admin needs to update it.
    case signInUnavailable
    case offline
    /// Cloudflare Access is in front of the server and didn't let the app through: no service token, or a wrong one.
    case accessBlocked
    case server(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .signedOut: String(localized: "You've been signed out. Sign in again.")
        case .cancelled: String(localized: "Sign-in cancelled.")
        case .notFerret: String(localized: "That address doesn't look like a Ferret server.")
        case .signInUnavailable: String(localized: "This Ferret is too old for the app. Ask whoever runs it to update Ferret.")
        case .offline: String(localized: "Can't reach the server. Check your connection.")
        case .accessBlocked: String(localized: "Cloudflare Access is in front of this server and didn't let the app in. Add a service token under Cloudflare Access, or check the one you added.")
        case .server(_, let message): message
        }
    }

    public var isNotFound: Bool {
        if case .server(404, _) = self { return true }
        return false
    }

    /// The network errors that mean "can't reach the server right now" (rather than a fault in what was sent).
    static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut, .dataNotAllowed,
        .dnsLookupFailed, .internationalRoamingOff, .callIsActive,
    ]

    /// Runs a network call, turning "can't reach it" errors into `offline` — for every call, refreshes included.
    static func mappingOffline<T>(isolation: isolated (any Actor)? = #isolation, _ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch let error as URLError where offlineCodes.contains(error.code) {
            throw FerretError.offline
        }
    }

    /// Cloudflare Access turned the request away: it redirects to its login page (`*.cloudflareaccess.com`), or answers
    /// 401/403 itself (its own responses carry `cf-access-…` headers or come from its domain).
    static func isAccessBlock(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        if http.url?.host()?.hasSuffix("cloudflareaccess.com") == true { return true }
        // Its redirect to the login page (not followed: it's another host).
        if (300 ..< 400).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"),
           URL(string: location)?.host()?.hasSuffix("cloudflareaccess.com") == true { return true }
        guard http.statusCode == 401 || http.statusCode == 403 else { return false }
        return http.allHeaderFields.keys.contains { ($0 as? String)?.lowercased().hasPrefix("cf-access") == true }
    }

    /// Ferret's error body: `{"error":{"code":"…","message":"…"}}`; OAuth's: `{"error_description":"…"}`.
    static func message(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let description = object["error_description"] as? String { return description }
        if let message = object["message"] as? String { return message }
        return nil
    }
}
