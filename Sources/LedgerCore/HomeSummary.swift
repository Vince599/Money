/// A transient home-page projection. Unavailable aggregates do not invalidate a valid book.
public struct HomeSummary: Equatable, Sendable {
    public let currencySummaries: [CurrencySummary]
    /// CNY expenses in the requested half-open interval, or nil if the aggregate exceeds Int64.
    public let monthlyConsumption: Money?
    /// At most five entries, newest occurrence then creation first, preserving input order on ties.
    public let recentEntries: [LedgerEntry]

    public init(currencySummaries: [CurrencySummary], monthlyConsumption: Money?, recentEntries: [LedgerEntry]) {
        self.currencySummaries = currencySummaries
        self.monthlyConsumption = monthlyConsumption
        self.recentEntries = recentEntries
    }

    public struct CurrencySummary: Equatable, Sendable {
        public let currency: Currency
        /// Nil when assets, liabilities, or net asset exceeds the public Int64 cash boundary.
        public let totals: AccountTotals?

        public init(currency: Currency, totals: AccountTotals?) {
            self.currency = currency
            self.totals = totals
        }
    }

    public struct AccountTotals: Equatable, Sendable {
        public let assets: Money
        public let liabilities: Money
        public let netAsset: Money

        public init(assets: Money, liabilities: Money, netAsset: Money) {
            self.assets = assets
            self.liabilities = liabilities
            self.netAsset = netAsset
        }
    }
}
