import Foundation
import Testing
@testable import LedgerCore

@Suite("Daily entry totals")
struct EntryDailySummaryTests {
    private let date = Date(timeIntervalSince1970: 1_768_435_200)
    private func entry(_ kind: EntryKind, _ amount: Int64, currency: Currency = .cny, at: Date? = nil) -> LedgerEntry {
        LedgerEntry(kind: kind, amount: Money(minorUnits: amount, currency: currency), accountID: UUID(),
            occurredAt: at ?? date)
    }

    @Test func emptyAndMixedKindsKeepTransfersAndRecoveriesSeparate() throws {
        #expect(try EntryDaySummary.summarize([]).isEmpty)
        let entries = [entry(.expense, 2010), entry(.expense, 5), entry(.income, 3000),
                       entry(.refund, 400), entry(.recovery, 100), entry(.transfer, 90_000)]
        let day = try #require(EntryDaySummary.summarize(entries).first)
        let totals = try #require(day.currencies.first)
        #expect(day.entryCount == 6)
        #expect(totals.expenses?.decimalString == "20.15")
        #expect(totals.income?.minorUnits == 3000)
        #expect(totals.recoveries?.minorUnits == 500)
        #expect(totals.transferCount == 1)
    }

    @Test func shanghaiMidnightSplitsDaysAndOrdersNewestFirst() throws {
        let midnight = try Date.ISO8601FormatStyle().parse("2026-01-15T16:00:00Z")
        let previous = midnight.addingTimeInterval(-1)
        let days = try EntryDaySummary.summarize([entry(.expense, 1, at: previous), entry(.income, 2, at: midnight)])
        #expect(days.count == 2)
        #expect(days[0].day == midnight)
        #expect(days[1].day == midnight.addingTimeInterval(-86_400))
        #expect(days[0].currencies[0].income?.minorUnits == 2)
        #expect(days[1].currencies[0].expenses?.minorUnits == 1)
    }

    @Test func currenciesNeverCombineAndTransferOnlyDayStaysVisible() throws {
        let days = try EntryDaySummary.summarize([entry(.income, 100, currency: .usd),
            entry(.expense, 100, currency: .cny), entry(.transfer, 100, currency: .hkd)])
        let day = try #require(days.first)
        #expect(day.currencies.map(\.currency) == [.cny, .hkd, .usd])
        #expect(day.currencies[1].entryCount == 1)
        #expect(day.currencies[1].transferCount == 1)
        #expect(day.currencies[1].expenses?.minorUnits == 0)
        #expect(day.currencies[1].income?.minorUnits == 0)
    }

    @Test func overflowingTotalDoesNotHideOtherAmountsOrWrap() throws {
        let day = try #require(EntryDaySummary.summarize([entry(.expense, Int64.max), entry(.expense, 1),
            entry(.income, 7), entry(.refund, Int64.max), entry(.recovery, 1)]).first)
        #expect(day.currencies[0].expenses == nil)
        #expect(day.currencies[0].income?.minorUnits == 7)
        #expect(day.currencies[0].recoveries == nil)
        #expect(day.entryCount == 5)
    }

    @Test func matchingEntriesOnlyAndStreamingOrderGiveIdenticalTotals() throws {
        let account = Account(name: "Wallet", includedInSummary: false)
        let entries = (1...60).map { value in
            LedgerEntry(kind: .expense, amount: Money(minorUnits: Int64(value)), accountID: account.id,
                categoryID: SeedData.mealsID, occurredAt: date, title: value % 2 == 0 ? "Lunch" : "Taxi")
        }
        let book = LedgerBook(accounts: [account], entries: entries)
        let filtered = try EntryQuery.entries(in: book, matching: EntryFilter(keyword: "Lunch"))
        let expected = try EntryDaySummary.summarize(filtered)
        #expect(expected[0].entryCount == 30)
        #expect(expected[0].currencies[0].expenses?.minorUnits == 930)
        var stream = EntryDailyAccumulator()
        for value in filtered.reversed() { try stream.add(kind: value.kind, amount: value.amount, occurredAt: value.occurredAt) }
        #expect(stream.summaries == expected)
        #expect(book.entries == entries)
    }

    @Test func invalidProjectionAmountsAndDatesAreRejected() throws {
        var stream = EntryDailyAccumulator()
        #expect(throws: LedgerError.invalidAmount) { try stream.add(kind: .expense, amount: Money(minorUnits: 0), occurredAt: date) }
        #expect(throws: LedgerError.invalidAmount) { try stream.add(kind: .expense, amount: Money(minorUnits: -1), occurredAt: date) }
        #expect(throws: EntryQueryError.invalidDateRange) {
            try stream.add(kind: .expense, amount: Money(minorUnits: 1), occurredAt: Date(timeIntervalSinceReferenceDate: .infinity))
        }
        #expect(stream.summaries.isEmpty)
    }
}
