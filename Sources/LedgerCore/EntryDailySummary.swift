import Foundation

/// Totals for matching entries on a complete Shanghai calendar day, not just a loaded page.
public struct EntryDaySummary: Equatable, Sendable {
    public let day: Date
    public let currencies: [CurrencyTotals]
    public var entryCount: Int { currencies.reduce(0) { $0 + $1.entryCount } }

    public struct CurrencyTotals: Equatable, Sendable {
        public let currency: Currency
        public let entryCount: Int
        public let transferCount: Int
        /// Nil means this individual total exceeds the Int64 money display boundary.
        public let expenses: Money?
        public let income: Money?
        public let recoveries: Money?
    }

    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    public static func day(containing date: Date) -> Date { calendar.startOfDay(for: date) }

    public static func summarize(_ entries: [LedgerEntry]) throws -> [EntryDaySummary] {
        var accumulator = EntryDailyAccumulator()
        for entry in entries { try accumulator.add(kind: entry.kind, amount: entry.amount, occurredAt: entry.occurredAt) }
        return accumulator.summaries
    }
}

/// Streams lightweight database projections using exact integer arithmetic.
public struct EntryDailyAccumulator: Sendable {
    private struct Key: Hashable, Sendable { let day: Date; let currency: Currency }
    private struct Bucket: Sendable {
        var count = 0
        var transfers = 0
        var expenses: Int128 = 0
        var income: Int128 = 0
        var recoveries: Int128 = 0
    }
    private var buckets: [Key: Bucket] = [:]
    private let calendar = EntryDaySummary.calendar
    public init() {}

    public mutating func add(kind: EntryKind, amount: Money, occurredAt: Date) throws {
        guard occurredAt.timeIntervalSinceReferenceDate.isFinite else { throw EntryQueryError.invalidDateRange }
        guard amount.minorUnits > 0 else { throw LedgerError.invalidAmount }
        let day = calendar.startOfDay(for: occurredAt)
        guard day.timeIntervalSinceReferenceDate.isFinite else { throw EntryQueryError.invalidDateRange }
        let key = Key(day: day, currency: amount.currency)
        var bucket = buckets[key, default: Bucket()]
        bucket.count += 1
        switch kind {
        case .expense: bucket.expenses += Int128(amount.minorUnits)
        case .income: bucket.income += Int128(amount.minorUnits)
        case .refund, .recovery: bucket.recoveries += Int128(amount.minorUnits)
        case .transfer: bucket.transfers += 1
        }
        buckets[key] = bucket
    }

    public var summaries: [EntryDaySummary] {
        Set(buckets.keys.map(\.day)).sorted(by: >).map { day in
            let totals = Currency.allCases.compactMap { currency -> EntryDaySummary.CurrencyTotals? in
                guard let bucket = buckets[Key(day: day, currency: currency)] else { return nil }
                func money(_ value: Int128) -> Money? {
                    Int64(exactly: value).map { Money(minorUnits: $0, currency: currency) }
                }
                return EntryDaySummary.CurrencyTotals(currency: currency, entryCount: bucket.count,
                    transferCount: bucket.transfers, expenses: money(bucket.expenses),
                    income: money(bucket.income), recoveries: money(bucket.recoveries))
            }
            return EntryDaySummary(day: day, currencies: totals)
        }
    }
}
