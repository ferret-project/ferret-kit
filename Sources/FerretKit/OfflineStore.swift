import CryptoKit
import Foundation

/// A thing kept on the phone for browsing with no signal: as the server sent it, its first photo, and when.
public struct OfflineThing: Identifiable, Sendable {
    public let item: Item
    public let photo: Data?
    public let savedAt: Date
    public var id: String { item.id }
}

/// The things this person looked at last (the server's Recently viewed — the same list and calls as the web app's
/// offline screen, web `lib/offline-recent.ts`), kept on the phone for one server: each one's JSON and thumbnail, in
/// Application Support (not backed up). Replaced whole on every refresh; cleared on sign-out.
public actor OfflineStore {
    /// How many are kept (as on the web).
    public static let count = 10

    private let folder: URL

    private struct Entry: Codable {
        let id: String
        let photoId: String?
        let savedAt: Date
    }

    public init(server: URL, root: URL? = nil) {
        let base = root ?? Self.defaultRoot
        let name = SHA256.hash(data: Data(server.absoluteString.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        folder = base.appending(path: name, directoryHint: .isDirectory)
    }

    static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "offline", directoryHint: .isDirectory)
    }

    private var index: URL { folder.appending(path: "index.json") }
    private func itemFile(_ id: String) -> URL { folder.appending(path: "item-\(id).json") }
    private func photoFile(_ photoId: String) -> URL { folder.appending(path: "photo-\(photoId)") }

    private func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: index) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    /// What's kept, viewed last first.
    public func things() -> [OfflineThing] {
        entries().compactMap { thing($0) }
    }

    public func thing(_ id: String) -> OfflineThing? {
        entries().first { $0.id == id }.flatMap { thing($0) }
    }

    private func thing(_ entry: Entry) -> OfflineThing? {
        guard let data = try? Data(contentsOf: itemFile(entry.id)), let item = try? JSONDecoder().decode(Item.self, from: data) else { return nil }
        return OfflineThing(item: item, photo: entry.photoId.flatMap { try? Data(contentsOf: photoFile($0)) }, savedAt: entry.savedAt)
    }

    /// The photo already kept, so an unchanged one isn't downloaded again.
    public func keptPhoto(_ photoId: String) -> Data? {
        try? Data(contentsOf: photoFile(photoId))
    }

    /// Replaces what's kept: each thing's JSON (as `/items/:id` sent it), the photo it's shown with, and that photo.
    public func replace(with things: [(id: String, json: Data, photoId: String?, photo: Data?)], now: Date = .now) throws {
        let staging = folder.deletingLastPathComponent().appending(path: folder.lastPathComponent + ".new", directoryHint: .isDirectory)
        let files = FileManager.default
        try? files.removeItem(at: staging)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        var kept: [Entry] = []
        for thing in things {
            try thing.json.write(to: staging.appending(path: "item-\(thing.id).json"))
            var photoId: String?
            if let id = thing.photoId, let photo = thing.photo {
                try photo.write(to: staging.appending(path: "photo-\(id)"))
                photoId = id
            }
            kept.append(Entry(id: thing.id, photoId: photoId, savedAt: now))
        }
        try JSONEncoder().encode(kept).write(to: staging.appending(path: "index.json"))
        // Swapped in whole: a refresh cut short leaves the last full set.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var marked = staging
        try? marked.setResourceValues(values)
        try? files.removeItem(at: folder)
        try files.moveItem(at: staging, to: folder)
    }

    /// Signing out: nothing of theirs stays on the phone.
    public func clear() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// `/recently-viewed`: only what the phone needs to keep each one.
struct RecentlyViewed: Decodable, Sendable {
    let id: String
}

public extension FerretClient {
    /// A thing's page was opened (it counts for Recently viewed, here and on the web).
    func viewed(_ itemId: String) async throws {
        let _: Empty = try await post("items/\(itemId)/viewed")
    }

    /// Keeps the things looked at last on the phone, replacing what was kept. Throws when the server can't be reached
    /// (what's kept stays).
    func keepRecentlyViewed(in store: OfflineStore) async throws {
        let recent: DataList<RecentlyViewed> = try await get("recently-viewed", query: ["limit": String(OfflineStore.count) as String?])
        var things: [(id: String, json: Data, photoId: String?, photo: Data?)] = []
        for entry in recent.data {
            guard let json = try? await data("items/\(entry.id)"), let item = try? JSONDecoder().decode(Item.self, from: json) else { continue }
            var photo: Data?
            if let photoId = item.photoId {
                if let kept = await store.keptPhoto(photoId) { photo = kept } else { photo = try? await thumbnail(photoId) }
            }
            things.append((id: item.id, json: json, photoId: item.photoId, photo: photo))
        }
        try await store.replace(with: things)
    }
}
