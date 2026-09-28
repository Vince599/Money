import Foundation
import LedgerCore
import LedgerStore
import Testing

@Suite("SQLite recovery association pages")
struct EntryRecoveryPageTests {
    private func fixture(_ body: (SQLiteLedgerStore, LedgerBook, LedgerEntry, [LedgerEntry], String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("recovery.sqlite").path
        let store = try SQLiteLedgerStore(path: path)
        let paying = Account(name: "Bank", openingMinor: 200_000)
        let receiving = Account(name: "Wallet")
        let day = Date(timeIntervalSince1970: 1_768_435_200)
        let original = LedgerEntry(kind: .expense, amount: Money(minorUnits: 100_000), accountID: paying.id,
            categoryID: SeedData.mealsID, occurredAt: day, title: "Original")
        let plain = LedgerEntry(kind: .expense, amount: Money(minorUnits: 50_000), accountID: paying.id,
            categoryID: SeedData.mealsID, occurredAt: day, title: "Plain")
        var book = LedgerBook(accounts: [paying, receiving])
        for entry in [original, plain] { book = try LedgerEngine.record(entry, in: book) }
        let children = [EntryKind.refund, .recovery].map {
            LedgerEntry(kind: $0, amount: Money(minorUnits: 10_000), accountID: receiving.id,
                occurredAt: day.addingTimeInterval(40 * 86_400), originalEntryID: original.id)
        }
        for entry in children { book = try LedgerEngine.record(entry, in: book) }
        try store.saveBook(book)
        try body(store, book, original, children, path)
    }

    @Test func pagesMatchCoreAcrossPeriodsAccountsAndCombinedFiltersAfterReopen() throws {
        try fixture { store, book, original, _, path in
            let filters = [EntryFilter(), EntryFilter(recoveryLinkMode: .linked), EntryFilter(recoveryLinkMode: .unlinked),
                EntryFilter(kind: .expense, recoveryLinkMode: .linked),
                EntryFilter(accountID: original.accountID, from: original.occurredAt,
                    to: original.occurredAt.addingTimeInterval(86_400), recoveryLinkMode: .linked),
                EntryFilter(keyword: "plain", recoveryLinkMode: .linked),
                EntryFilter(importSourceMode: .unlinked, recoveryLinkMode: .linked),
                EntryFilter(importSourceMode: .linked, recoveryLinkMode: .linked)]
            let reopened = try SQLiteLedgerStore(path: path)
            for activeStore in [store, reopened] {
                for filter in filters {
                    let expected = try EntryQuery.entries(in: book, matching: filter)
                    var page = try activeStore.entryPage(matching: filter, limit: 1)
                    var entries = page.entries
                    #expect(page.totalCount == expected.count)
                    while let cursor = page.nextCursor {
                        page = try activeStore.entryPage(matching: filter, after: cursor, limit: 1)
                        #expect(page.totalCount == expected.count)
                        entries += page.entries
                    }
                    #expect(entries == expected)
                }
            }
        }
    }

    @Test func deletingRecoveriesInvalidatesCursorAndReclassifiesOriginal() throws {
        try fixture { store, book, original, children, _ in
            let filter = EntryFilter(recoveryLinkMode: .linked)
            let first = try store.entryPage(matching: filter, limit: 1)
            let cursor = try #require(first.nextCursor)
            #expect(throws: LedgerStoreError.staleHistoryCursor) {
                try store.entryPage(matching: EntryFilter(recoveryLinkMode: .unlinked), after: cursor)
            }
            var updated = try LedgerEngine.delete(entryID: children[0].id, in: book)
            try store.saveBook(updated)
            #expect(try store.entryPage(matching: filter).totalCount == 2)
            #expect(throws: LedgerStoreError.staleHistoryCursor) { try store.entryPage(matching: filter, after: cursor) }
            updated = try LedgerEngine.delete(entryID: children[1].id, in: updated)
            try store.saveBook(updated)
            #expect(try store.entryPage(matching: filter).totalCount == 0)
            #expect(try store.entryPage(matching: EntryFilter(recoveryLinkMode: .unlinked)).entries.contains(original))
        }
    }
}
