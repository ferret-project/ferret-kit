import Foundation

/// Money is integer cents in the household's currency, as on the server.
public enum Money {
    public static func format(_ cents: Int, currency: String) -> String {
        Decimal(cents) / 100 == Decimal(cents / 100)
            ? (Decimal(cents) / 100).formatted(.currency(code: currency).precision(.fractionLength(0)))
            : (Decimal(cents) / 100).formatted(.currency(code: currency))
    }

    /// What someone typed ("12", "12.5", "1,299.99", "$40") as cents; nil when it isn't an amount.
    public static func cents(from text: String) -> Int? {
        let cleaned = text.filter { $0.isNumber || $0 == "." || $0 == "," }
        guard !cleaned.isEmpty else { return nil }
        // A comma followed by exactly two digits at the end is a decimal comma (12,50); otherwise commas group thousands.
        var normal = cleaned
        if let comma = cleaned.lastIndex(of: ","), cleaned.distance(from: comma, to: cleaned.endIndex) == 3, !cleaned.contains(".") {
            normal.replaceSubrange(comma ... comma, with: ".")
        }
        normal = normal.replacingOccurrences(of: ",", with: "")
        guard let value = Decimal(string: normal, locale: Locale(identifier: "en_US_POSIX")), value >= 0 else { return nil }
        var cents = value * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &cents, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    /// Cents as a typed amount for an edit field ("12.50"; "12" when whole).
    public static func editable(_ cents: Int?) -> String {
        guard let cents else { return "" }
        return cents % 100 == 0 ? String(cents / 100) : String(format: "%d.%02d", cents / 100, cents % 100)
    }
}
