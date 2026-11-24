import Foundation

/// The calls the app makes, named for what they do.
public extension FerretClient {
    func me() async throws -> Me { try await get("me") }
    func summary() async throws -> Summary { try await get("summary") }

    /// Things, newest change first; `query` searches (keywords and meaning), `locationId` includes places inside it.
    /// `missing`: things without that detail ("place", "photo", "value"…).
    func items(query: String? = nil, locationId: String? = nil, barcode: String? = nil, containerItemId: String? = nil, missing: String? = nil, topLevel: Bool = false, sort: String? = nil, limit: Int = 50, offset: Int = 0) async throws -> Page<Item> {
        try await get("items", query: [
            "q": query?.isEmpty == false ? query : nil,
            "locationId": locationId,
            "barcode": barcode,
            "containerItemId": containerItemId,
            "missing": missing,
            "topLevel": topLevel ? "true" : nil,
            "sort": sort,
            "limit": String(limit),
            "offset": offset > 0 ? String(offset) : nil,
        ])
    }

    func item(_ id: String) async throws -> Item { try await get("items/\(id)") }
    func createItem(_ changes: ItemChanges) async throws -> Item { try await send("POST", "items", body: changes) }
    func updateItem(_ id: String, _ changes: ItemChanges) async throws -> Item { try await send("PATCH", "items/\(id)", body: changes) }
    /// To the trash (kept 30 days).
    func deleteItem(_ id: String) async throws { try await delete("items/\(id)") }

    func attachments(of itemId: String) async throws -> [Attachment] {
        let list: DataList<Attachment> = try await get("items/\(itemId)/attachments")
        return list.data
    }

    /// Adds a photo (read by the vision model when the server has one) or a document to a thing.
    func addFile(to itemId: String, data: Data, filename: String, contentType: String, kind: String = "photo") async throws -> Attachment {
        try await upload("items/\(itemId)/attachments", file: data, filename: filename, contentType: contentType, fields: ["kind": kind])
    }

    func makeMainPhoto(_ attachmentId: String) async throws {
        let _: Empty = try await post("attachments/\(attachmentId)/main")
    }

    func deleteFile(_ attachmentId: String) async throws { try await delete("attachments/\(attachmentId)") }

    func thumbnail(_ attachmentId: String) async throws -> Data { try await data("attachments/\(attachmentId)/thumbnail") }
    func fileContent(_ attachmentId: String) async throws -> Data { try await data("attachments/\(attachmentId)/content") }

    func places() async throws -> PlaceTree { try await get("locations/tree") }

    /// A scanned Ferret label's code (from `…/l/CODE`).
    func label(_ code: String) async throws -> LabelTarget { try await get("labels/\(code)") }

    /// "Still here": seen today (for "not seen in a year" and room reviews).
    func markSeen(_ itemId: String) async throws {
        let _: Empty = try await post("items/\(itemId)/seen")
    }
}

/// Ferret label links: `https://<server>/l/ABC123` (QR codes and NFC stickers). Nil for anything else.
public func labelCode(in text: String) -> String? {
    guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.hasPrefix("http") == true else { return nil }
    let parts = url.path.split(separator: "/")
    guard parts.count == 2, parts[0] == "l" else { return nil }
    let code = String(parts[1])
    guard (4 ... 12).contains(code.count), code.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
    return code.uppercased()
}
