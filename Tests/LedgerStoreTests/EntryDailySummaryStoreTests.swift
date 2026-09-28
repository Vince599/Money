import Foundation
import LedgerCore
import LedgerStore
import Testing

@Suite("Complete daily totals with paginated history")
struct EntryDailySummaryStoreTests {
    private func fixture(_ body: (SQLiteLedgerStore, LedgerBook, String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("daily.sqlite").path
        let store = try SQLiteLedgerStore(path: path)
        let account = Account(name: "Bank", openingMinor: 1_000_000)
        let other = Account(name: "Wallet", includedInSummary: false)
        let usd = Account(name: "USD", currency: .usd)
        let date = try Date.ISO8601FormatStyle().parse("2026-01-16T04:00:00Z")
        var entries = (0..<70).map { index in
            LedgerEntry(kind: .expense, amount: Money(minorUnits: 2010), accountID: account.id,
                categoryID: SeedData.mealsID, occurredAt: date.addingTimeInterval(Double(index)),
                title: index % 2 == 0 ? "Lunch" : "Taxi")
        }
        entries += [LedgerEntry(kind: .refund, amount: Money(minorUnits: 100), accountID: other.id,
            occurredAt: date.addingTimeInterval(80), originalEntryID: entries[0].id),
            LedgerEntry(kind: .transfer, amount: Money(minorUnits: 100), accountID: account.id,
                destinationAccountID: other.id, occurredAt: date),
            LedgerEntry(kind: .expense, amount: Money(minorUnits: 50), accountID: usd.id,
                categoryID: SeedData.mealsID, occurredAt: date),
            LedgerEntry(kind: .expense, amount: Money(minorUnits: 300), accountID: account.id,
                categoryID: SeedData.mealsID, occurredAt: date.addingTimeInterval(-86_400))]
        let book = LedgerBook(accounts: [account, other, usd], entries: entries)
        try store.saveBook(book)
        try body(store, book, path)
    }

    @Test func firstPageHasEntireDayAndContinuationNeverMultipliesTotals() throws {
        try fixture { store, book, path in
            let expected = try EntryDaySummary.summarize(book.entries)
            let first = try store.entryPage(limit: 2)
            #expect(first.entries.count == 2)
            #expect(first.daySummaries == [expected[0]])
            #expect(first.daySummaries[0].entryCount == 73)
            #expect(first.daySummaries[0].currencies[0].expenses?.minorUnits == 140_700)
            var page = first
            var allEntries = page.entries
            while let next = page.nextCursor {
                page = try store.entryPage(after: next, limit: 17)
                let days = Set(page.entries.map { EntryDaySummary.day(containing: $0.occurredAt) })
                #expect(page.daySummaries == expected.filter { days.contains($0.day) })
                allEntries += page.entries
            }
            #expect(allEntries.count == book.entries.count)
            #expect(Set(allEntries.map(\.id)).count == book.entries.count)
            let reopened = try SQLiteLedgerStore(path: path)
            #expect(try reopened.entryPage(limit: 2).daySummaries == first.daySummaries)
        }
    }

    @Test func filteredTotalsUseSameSourceRelationAndDateConditionsAsRows() throws {
        try fixture { store, book, _ in
            let date = book.entries[0].occurredAt
            let filters = [EntryFilter(keyword: "Lunch"), EntryFilter(currency: .usd),
                EntryFilter(kind: .transfer), EntryFilter(recoveryLinkMode: .linked),
                EntryFilter(importSourceMode: .unlinked, recoveryLinkMode: .linked),
                EntryFilter(importSourceMode: .linked), EntryFilter(keyword: "absent"),
                EntryFilter(from: date.addingTimeInterval(5), to: date.addingTimeInterval(12)),
                EntryFilter(accountID: book.accounts[1].id)]
            for filter in filters {
                let matching = try EntryQuery.entries(in: book, matching: filter)
                let expected = try EntryDaySummary.summarize(matching)
                var page = try store.entryPage(matching: filter, limit: 3)
                repeat {
                    let days = Set(page.entries.map { EntryDaySummary.day(containing: $0.occurredAt) })
                    #expect(page.daySummaries == expected.filter { days.contains($0.day) })
                    #expect(page.totalCount == matching.count)
                    guard let cursor = page.nextCursor else { break }
                    page = try store.entryPage(matching: filter, after: cursor, limit: 3)
                } while true
            }
        }
    }

    @Test func changedBookRejectsCachedDayTotalsAndReloadUsesNewAmounts() throws {
        try fixture { store, book, _ in
            let page = try store.entryPage(limit: 1)
            let cursor = try #require(page.nextCursor)
            var updated = book
            updated.entries.removeAll { $0.kind == .refund }
            try store.saveBook(updated)
            #expect(throws: LedgerStoreError.staleHistoryCursor) { try store.entryPage(after: cursor, limit: 1) }
            let fresh = try store.entryPage(limit: 1)
            #expect(fresh.daySummaries[0].currencies[0].recoveries?.minorUnits == 0)
            #expect(fresh.daySummaries[0].entryCount == 72)
        }
    }
}
