import Foundation

public enum FerretError: LocalizedError, Equatable, Sendable {
    /// The sign-in ended (disconnected in Settings, the key deleted, left the household): sign in again.
    case signedOut
    /// The person closed the sign-in, or tapped Cancel on Ferret's screen.
    case cancelled
    /// The address answers, but it isn't a Ferret.
    case notFerret
    /// This Ferret is too old for app sign-in: an API key still works.
    case signInUnavailable
    case offline
    case server(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .signedOut: String(localized: "You've been signed out. Sign in again.")
        case .cancelled: String(localized: "Sign-in cancelled.")
        case .notFerret: String(localized: "That address doesn't look like a Ferret server.")
        case .signInUnavailable: String(localized: "This Ferret can't sign in apps yet. Use an API key from Settings → Claude & API instead.")
        case .offline: String(localized: "Can't reach the server. Check your connection.")
        case .server(_, let message): message
        }
    }

    public var isNotFound: Bool {
        if case .server(404, _) = self { return true }
        return false
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
