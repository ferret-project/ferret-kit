import Foundation

// What the REST API sends back (`/api/v1`). Only the fields the app uses; everything the server may leave out is
// optional, so a newer server adding fields never breaks an older app. Dates stay as the server's strings
// (ISO `yyyy-mm-dd` for days, ISO 8601 for moments) and are parsed where they're shown.

public struct Page<T: Decodable & Sendable>: Decodable, Sendable {
    public let data: [T]
    public let total: Int?
    /// What everything on this page is worth (lists of things), in cents.
    public let valueCents: Int?
}

public struct DataList<T: Decodable & Sendable>: Decodable, Sendable {
    public let data: [T]
}

public struct Me: Decodable, Sendable {
    public struct User: Decodable, Sendable {
        public let id: String
        public let name: String
        public let email: String
    }

    public struct Features: Decodable, Sendable {
        public let photoAi: Bool?
        public let textAi: Bool?
        public let speech: Bool?
        public let roomScan: Bool?
    }

    /// The household this sign-in is for, the person's role in it, and whether it may change things (a read-only
    /// key or app, or a viewer). Older servers leave it out.
    public struct Household: Decodable, Sendable {
        public let id: String
        public let name: String
        public let role: String?
        public let readOnly: Bool?
    }

    public let user: User
    public let activeHouseholdId: String?
    public let household: Household?
    public let serverAdmin: Bool?
    public let features: Features?
}

/// `/summary`: the household at a glance.
public struct Summary: Decodable, Sendable {
    public let household: String
    public let things: Int
    public let valueCents: Int
    public let currency: String
    public let needsAttention: Int
    public let urgent: Int
    public let toBuy: Int
}

/// A thing as lists show it (`/items`), and as its page shows it (`/items/:id`, which adds the optional extras).
public struct Item: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var description: String?
    public var brand: String?
    public var model: String?
    public var serialNumber: String?
    public var barcode: String?
    public var quantity: Int?
    public var purchaseDate: String?
    public var purchasePriceCents: Int?
    public var valueCents: Int?
    public var notes: String?
    public var favorite: Bool?
    public var categoryId: String?
    public var locationId: String?
    public var isContainer: Bool?
    public var containerItemId: String?
    public var disposition: String?
    public var wanted: Bool?
    public var origin: String?
    public var updatedAt: String?
    public var createdAt: String?

    // From the listing: names to show.
    /// "Home › Garage › Workbench shelf".
    public var place: String?
    /// "Tools › Power tools".
    public var category: String?
    public var tags: [String]?
    /// The main photo's attachment id.
    public var photoId: String?

    // Only on the thing's own page.
    public var addedBy: String?
    /// How many things are directly inside it (a box).
    public var contents: Int?
    public var labelCode: String?

    /// What it's worth: its value, else what was paid.
    public var worthCents: Int? { valueCents ?? purchasePriceCents }

    public var subtitle: String? {
        let made = [brand, model].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
        return made.isEmpty ? nil : made
    }
}

/// What the app sends to add or change a thing. Only set fields are sent (a PATCH changes only those).
public struct ItemChanges: Encodable, Sendable {
    public var name: String?
    public var description: String?
    public var brand: String?
    public var model: String?
    public var serialNumber: String?
    public var barcode: String?
    public var quantity: Int?
    public var purchaseDate: String?
    public var purchasePriceCents: Int?
    public var valueCents: Int?
    public var notes: String?
    public var favorite: Bool?
    public var locationId: String?
    public var containerItemId: String?
    public var tags: [String]?
    /// Which of the app's ways added it (only on create).
    public var origin: String?

    /// Fields to clear (sent as null). Without this, nil means "leave it as it is".
    public var clear: Set<String> = []

    public init() {}

    enum Key: String, CodingKey {
        case name, description, brand, model, serialNumber, barcode, quantity, purchaseDate, purchasePriceCents, valueCents, notes, favorite, locationId, containerItemId, tags, origin
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        func put<V: Encodable>(_ value: V?, _ key: Key) throws {
            if let value { try c.encode(value, forKey: key) } else if clear.contains(key.rawValue) { try c.encodeNil(forKey: key) }
        }
        try put(name, .name)
        try put(description, .description)
        try put(brand, .brand)
        try put(model, .model)
        try put(serialNumber, .serialNumber)
        try put(barcode, .barcode)
        try put(quantity, .quantity)
        try put(purchaseDate, .purchaseDate)
        try put(purchasePriceCents, .purchasePriceCents)
        try put(valueCents, .valueCents)
        try put(notes, .notes)
        try put(favorite, .favorite)
        try put(locationId, .locationId)
        try put(containerItemId, .containerItemId)
        try put(tags, .tags)
        try put(origin, .origin)
    }
}

public struct Attachment: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let itemId: String?
    /// "photo" or "document".
    public let kind: String
    public let filename: String
    public let contentType: String?
    public let size: Int?
    /// "pending", "done", "failed"… while the vision model reads a photo.
    public let analysisStatus: String?
    public let createdAt: String?

    public var isPhoto: Bool { kind == "photo" }
}

/// `/locations/tree`: every property with its places nested.
public struct PlaceTree: Decodable, Sendable {
    public let properties: [Property]
    /// Things with no place yet.
    public let unplacedItems: Int?

    /// Every place, depth first, with how deep it is: for a picker.
    public var flattened: [(place: Place, depth: Int)] {
        var out: [(Place, Int)] = []
        func walk(_ places: [Place], _ depth: Int) {
            for p in places {
                out.append((p, depth))
                walk(p.children ?? [], depth + 1)
            }
        }
        for property in properties { walk(property.locations, 0) }
        return out
    }
}

public struct Property: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let type: String?
    public let locations: [Place]
}

public struct Place: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// "Home › Garage".
    public let path: String
    public let itemCount: Int?
    public let totalCount: Int?
    public let totalValueCents: Int?
    public let children: [Place]?
}

/// A scanned Ferret label (`/labels/:code`): the thing or place it's stuck on, if any yet.
public struct LabelTarget: Decodable, Sendable {
    public struct Thing: Decodable, Sendable {
        public let id: String
        public let name: String
        public let isContainer: Bool?
    }

    public struct Spot: Decodable, Sendable {
        public let id: String
        public let path: String
    }

    public let code: String
    public let item: Thing?
    public let location: Spot?
}

/// `/attention`: something that needs doing now (the bell): maintenance due, a warranty ending, a recall…
public struct AttentionItem: Decodable, Identifiable, Hashable, Sendable {
    /// "maintenance", "warranty", "return", "claim", "recall", "loan", "shopping", "backup"…
    public let kind: String
    /// "urgent" (overdue or today) or "soon" (coming up or waiting).
    public let severity: String
    /// What it's about (a task, warranty, claim or thing); not unique across kinds, so `key` is the list's id.
    public let id: String
    public let title: String
    public let detail: String
    /// The thing to open, if there is one.
    public let itemId: String?
    /// When it's due or ends (`yyyy-mm-dd`).
    public let date: String?
    /// Where in Ferret it's dealt with (`#/…`) when that isn't the thing's page.
    public let href: String?
    public let photoId: String?

    public var isUrgent: Bool { severity == "urgent" }
    /// Unique in one list: the same thing can need a warranty claim and maintenance.
    public var key: String { "\(kind):\(id)" }

    /// Where it opens in Ferret's web app (`#/…`).
    public var route: String {
        if let href, href.hasPrefix("#/") { return href }
        if let itemId { return itemRoute(itemId) }
        return "#/"
    }

    public init(kind: String, severity: String, id: String, title: String, detail: String, itemId: String? = nil, date: String? = nil, href: String? = nil, photoId: String? = nil) {
        self.kind = kind
        self.severity = severity
        self.id = id
        self.title = title
        self.detail = detail
        self.itemId = itemId
        self.date = date
        self.href = href
        self.photoId = photoId
    }
}

/// `/ask`: Ask Ferret's answer from the household's own things and documents.
public struct AskAnswer: Decodable, Sendable {
    public struct Citation: Decodable, Hashable, Sendable {
        public let itemId: String?
        public let itemName: String?
        public let attachmentId: String?
        public let filename: String?
        public let section: String?

        /// What to show for it: the thing, and the document it's from.
        public var label: String {
            let doc = [filename, section].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " › ")
            switch (itemName, doc.isEmpty) {
            case let (name?, false): return "\(name) — \(doc)"
            case let (name?, true): return name
            case (nil, false): return doc
            default: return String(localized: "A document")
            }
        }
    }

    public let answer: String
    /// False when the inventory doesn't say (the answer then explains that rather than guessing).
    public let found: Bool
    public let citations: [Citation]
}

/// A thing's page in Ferret's web app (`#/items/<id>`).
public func itemRoute(_ id: String) -> String {
    "#/items/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id)"
}

/// A route in Ferret's web app (`#/…`) as an address on the server, to open in the browser.
public func webURL(server: URL, route: String) -> URL {
    let path = route.hasPrefix("#") ? route : "#/" + route.drop(while: { $0 == "/" })
    return URL(string: server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path) ?? server
}
