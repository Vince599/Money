import Foundation
import GRDB
import LedgerCore
import LedgerStore
import Testing

@Suite("SQLite provenance pages")
struct EntrySourcePageTests {
    private func fixture(_ body: (SQLiteLedgerStore, LedgerBook, [ImportBatch], String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("sources.sqlite").path
        let store = try SQLiteLedgerStore(path: path)
        let account = Account(name: "Bank", openingMinor: 100_000)
        try store.saveBook(LedgerBook(accounts: [account]))
        var original = try ImportCSV.parse(ImportCSV.template, name: "original.csv", namespace: "Bank '_%")
        original.rows[0].accountID = account.id; original.rows[0].categoryID = SeedData.mealsID
        let initial = try store.saveImport(original)
        var book = try store.commitImport(ImportEngine.prepare(batchID: original.id, importIDs: [original.rows[0].id], skipIDs: [], in: initial.book)).book
        let target = LedgerEntry(kind: .expense, amount: Money(minorUnits: 2010), accountID: account.id,
                                 categoryID: SeedData.mealsID, occurredAt: try Date.ISO8601FormatStyle().parse(original.rows[0].raw[1]), title: "Manual lunch")
        let plain = LedgerEntry(kind: .income, amount: Money(minorUnits: 500), accountID: account.id,
                                categoryID: SeedData.salaryIncomeID, title: "Unrelated income")
        book.entries += [target, plain]; try store.saveBook(book)
        var merged: [ImportBatch] = []
        for namespace in ["Wallet", "Other"] {
            var batch = try ImportCSV.parse(ImportCSV.template, name: "merged.csv", namespace: namespace)
            batch.rows[0].accountID = account.id; batch.rows[0].categoryID = SeedData.mealsID
            book = try store.saveImport(batch).book
            let review = try ImportEngine.reviewMerge(batchID: batch.id, rowID: batch.rows[0].id, entryID: target.id, in: book)
            book = try store.mergeImport(ImportEngine.prepareMerge(review, keepExisting: Set(review.differences))).book
            merged.append(batch)
        }
        try body(store, book, merged, path)
    }
    private func pages(_ store: SQLiteLedgerStore, _ filter: EntryFilter, size: Int = 1) throws -> [LedgerEntry] {
        var cursor: EntryPageCursor?, result: [LedgerEntry] = []
        repeat {
            let page = try store.entryPage(matching: filter, after: cursor, limit: size)
            result += page.entries; cursor = page.nextCursor
            #expect(result.count <= page.totalCount)
            if cursor == nil { #expect(result.count == page.totalCount) }
        } while cursor != nil
        #expect(Set(result.map(\.id)).count == result.count)
        return result
    }

    @Test func sourcePagesMatchCoreWithExactNamespacesAndCombinedConditions() throws {
        try fixture { store, book, _, path in
            let filters = [EntryFilter(), EntryFilter(importSourceMode: .linked), EntryFilter(importSourceMode: .unlinked),
                           EntryFilter(importNamespace: "Bank '_%"), EntryFilter(importNamespace: "Wallet"),
                           EntryFilter(importNamespace: "wallet"), EntryFilter(importNamespace: "%"),
                           EntryFilter(importSourceMode: .unlinked, importNamespace: "Wallet"),
                           EntryFilter(keyword: "manual", kind: .expense, currency: .cny, minimumMinor: 2010,
                                       maximumMinor: 2010, importSourceMode: .linked, importNamespace: "Other")]
            let reopened = try SQLiteLedgerStore(path: path)
            for filter in filters {
                let expected = try EntryQuery.entries(in: book, matching: filter)
                #expect(try pages(store, filter) == expected)
                #expect(try pages(reopened, filter, size: 2) == expected)
            }
        }
    }

    @Test func unlinkInvalidatesCursorEvenWhenEntriesAndCountDoNotChange() throws {
        try fixture { store, book, merged, _ in
            let filter = EntryFilter(importSourceMode: .linked)
            let first = try store.entryPage(matching: filter, limit: 1)
            let cursor = try #require(first.nextCursor)
            #expect(throws: LedgerStoreError.staleHistoryCursor) {
                try store.entryPage(matching: EntryFilter(importSourceMode: .unlinked), after: cursor)
            }
            let changed = try store.unlinkImport(ImportEngine.prepareUnlink(batchID: merged[0].id, rowID: merged[0].rows[0].id, in: book)).book
            #expect(changed.entries == book.entries)
            #expect(try store.entryPage(matching: filter).totalCount == first.totalCount)
            #expect(throws: LedgerStoreError.staleHistoryCursor) { try store.entryPage(matching: filter, after: cursor) }
            #expect(try pages(store, EntryFilter(importNamespace: "Wallet")).isEmpty)
            #expect(try pages(store, filter) == EntryQuery.entries(in: changed, matching: filter))
            let undo = try #require(ImportEngine.reviewUndo(batchID: merged[1].id, in: changed).plan)
            let undone = try store.undoImport(undo).book
            #expect(try pages(store, filter).count == 1)
            #expect(try pages(store, EntryFilter(importSourceMode: .unlinked)) == EntryQuery.entries(in: undone, matching: EntryFilter(importSourceMode: .unlinked)))
        }
    }

    @Test func largeSourceSetUsesBoundedPagesAndCorruptProvenanceFailsClosed() throws {
        try fixture { store, initial, _, path in
            var book = initial
            let account = book.accounts[0]
            var batch = try ImportCSV.parse(ImportCSV.template, name: "large.csv", namespace: "Large")
            let sample = batch.rows[0].raw
            batch.rows = []
            for index in 0..<1005 {
                var raw = sample; raw[0] = "large-\(index)"
                var row = ImportRow(raw: raw)
                row.accountID = account.id; row.categoryID = SeedData.mealsID; row.state = .imported
                batch.rows.append(row)
                book.entries.append(LedgerEntry(id: row.id, operationID: row.operationID, kind: .expense,
                    amount: Money(minorUnits: 2010), accountID: account.id, categoryID: SeedData.mealsID,
                    occurredAt: try Date.ISO8601FormatStyle().parse(raw[1]), title: raw[8]))
            }
            book.importBatches.append(batch); try store.saveBook(book)
            let filter = EntryFilter(importNamespace: "Large")
            let actual = try pages(store, filter, size: 200)
            #expect(actual.count == 1005)
            #expect(actual == (try EntryQuery.entries(in: book, matching: filter)))
            let inspection = try DatabaseQueue(path: path)
            try inspection.write { db in
                try db.execute(sql: "UPDATE import_batches SET payload = ? WHERE id = ?", arguments: [Data("bad".utf8), batch.id.uuidString])
            }
            #expect(try store.entryPage(limit: 1).entries.count == 1)
            #expect(throws: (any Error).self) { try store.entryPage(matching: filter) }
        }
    }
}
