import Foundation

/// Cash is always stored in the smallest currency unit, never in binary floating point.
public struct Money: Codable, Hashable, Sendable {
    public let minorUnits: Int64
    public let currency: Currency
    public init(minorUnits: Int64, currency: Currency = .cny) {
        self.minorUnits = minorUnits; self.currency = currency
    }
    public static func parse(_ text: String, currency: Currency = .cny) throws -> Money {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw LedgerError.invalidAmount }
        let negative = input.first == "-"
        let digits = negative ? String(input.dropFirst()) : input
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }),
              parts.count == 1 || parts[1].count <= currency.fractionDigits else { throw LedgerError.invalidAmount }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        let raw = String(parts[0]) + fraction + String(repeating: "0", count: currency.fractionDigits - fraction.count)
        guard let value = Int64((negative ? "-" : "") + raw) else { throw LedgerError.overflow }
        return Money(minorUnits: value, currency: currency)
    }
    public var decimalString: String {
        let magnitude = minorUnits.magnitude
        let sign = minorUnits < 0 ? "-" : ""
        let fraction = String(magnitude % 100)
        return sign + String(magnitude / 100) + "." + (fraction.count == 1 ? "0" : "") + fraction
    }
    public func adding(_ other: Money) throws -> Money {
        guard currency == other.currency else { throw LedgerError.currencyMismatch }
        let result = minorUnits.addingReportingOverflow(other.minorUnits)
        guard !result.overflow else { throw LedgerError.overflow }
        return Money(minorUnits: result.partialValue, currency: currency)
    }
    public func subtracting(_ other: Money) throws -> Money {
        guard currency == other.currency else { throw LedgerError.currencyMismatch }
        let result = minorUnits.subtractingReportingOverflow(other.minorUnits)
        guard !result.overflow else { throw LedgerError.overflow }
        return Money(minorUnits: result.partialValue, currency: currency)
    }
}
