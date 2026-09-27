import Foundation
import GRDB
import LedgerCore
import LedgerStore
import Testing

@Suite("SQLite history pages")
struct HistoryPageTests {
    @Test func pagesMatchReferenceOrderIncludingIdenticalTimestamps() throws {
        try withFixture { store, book, _ in
            let expected = try EntryQuery.entries(in: book)
            for size in [1, 2, 17, 50, 200] {
                let actual = try allPages(store, filter: EntryFilter(), size: size)
                #expect(actual == expected, "Filter: \(filter)")
                #expect(Set(actual.map(\.id)).count == book.entries.count)
            }
        }
    }

    @Test func filtersMatchCoreForUnicodeLiteralTextAndCombinedConditions() throws {
        try withFixture { store, book, _ in
            let bank = book.accounts[0].id
            let destination = book.accounts[1].id
            let moment = book.entries[0].occurredAt
            var filters = [EntryFilter(), EntryFilter(kind: .expense), EntryFilter(kind: .income),
                           EntryFilter(kind: .transfer), EntryFilter(accountID: bank),
                           EntryFilter(accountID: destination), EntryFilter(categoryID: SeedData.foodID),
                           EntryFilter(categoryID: SeedData.mealsID), EntryFilter(categoryID: UUID()),
                           EntryFilter(subjectID: UUID()), EntryFilter(currency: .usd),
                           EntryFilter(currency: .cny, minimumMinor: 102, maximumMinor: 102),
                           EntryFilter(from: moment, to: moment.addingTimeInterval(1)),
                           EntryFilter(to: moment)]
            for word in [" lunch ", "午餐", "%", "_", "' OR 1=1 --", "\\", "\n", "CAFÉ", "cafe\u{0301}", "🧾", "\u{0}"] {
                filters.append(EntryFilter(keyword: word))
            }
            filters.append(EntryFilter(keyword: "lunch", kind: .expense, accountID: bank,
                                       categoryID: SeedData.foodID, subjectID: SeedData.mpcID,
                                       currency: .cny, minimumMinor: 100, maximumMinor: 200,
                                       from: moment.addingTimeInterval(-1), to: moment.addingTimeInterval(2)))
            for filter in filters {
                let actual = try allPages(store, filter: filter, size: 7)
                let expected = try EntryQuery.entries(in: book, matching: filter)
                #expect(actual == expected)
            }
        }
    }

    @Test func invalidConditionsAreRejectedAndEmptyBooksHaveNoContinuation() throws {
        let store = try SQLiteLedgerStore(path: ":memory:")
        let page = try store.entryPage()
        #expect(page.entries.isEmpty && page.totalCount == 0 && page.nextCursor == nil)
        for size in [0, -1, 201, Int.max] {
            #expect(throws: LedgerStoreError.invalidPageSize) { try store.entryPage(limit: size) }
        }
        #expect(throws: EntryQueryError.amountCurrencyRequired) {
            try store.entryPage(matching: EntryFilter(minimumMinor: 1))
        }
        #expect(throws: EntryQueryError.invalidDateRange) {
            try store.entryPage(matching: EntryFilter(from: Date(timeIntervalSinceReferenceDate: .nan)))
        }
    }

    @Test func cursorsRejectDifferentFiltersStoresAndOwnWrites() throws {
        try withFixture { store, book, path in
            let first = try store.entryPage(limit: 2)
            let cursor = try #require(first.nextCursor)
            #expect(throws: LedgerStoreError.staleHistoryCursor) {
                try store.entryPage(matching: EntryFilter(kind: .expense), after: cursor)
            }
            let other = try SQLiteLedgerStore(path: path)
            #expect(throws: LedgerStoreError.staleHistoryCursor) { try other.entryPage(after: cursor) }
            var changed = book
            changed.entries.removeLast()
            try store.saveBook(changed)
            #expect(throws: LedgerStoreError.staleHistoryCursor) { try store.entryPage(after: cursor) }
            #expect(try allPages(store, filter: EntryFilter(), size: 9) == EntryQuery.entries(in: changed))
        }
    }

    @Test func anotherConnectionEditWithUnchangedCountInvalidatesContinuation() throws {
        try withFixture { store, book, path in
            let first = try store.entryPage(limit: 2)
            let cursor = try #require(first.nextCursor)
            let writer = try SQLiteLedgerStore(path: path)
            var changed = book
            changed.entries[0].occurredAt = changed.entries[0].occurredAt.addingTimeInterval(-10_000)
            changed.entries[0].title = "已修改"
            try writer.saveBook(changed)
            #expect(throws: LedgerStoreError.staleHistoryCursor) { try store.entryPage(after: cursor) }
            #expect(try allPages(store, filter: EntryFilter(), size: 11) == EntryQuery.entries(in: changed))
        }
    }

    @Test func pagingChecksReturnedPayloadButDoesNotDecodeUnrelatedEntriesOrDrafts() throws {
        try withFixture { store, book, path in
            let ordered = try EntryQuery.entries(in: book)
            let first = try #require(ordered.first)
            let last = try #require(ordered.last)
            let inspection = try DatabaseQueue(path: path)
            try inspection.write { db in
                try db.execute(sql: "UPDATE entries SET payload = ? WHERE id = ?",
                               arguments: [Data("bad".utf8), last.id.uuidString])
                try db.execute(sql: "INSERT INTO entry_draft(singleton, payload) VALUES(1, ?)", arguments: [Data("bad".utf8)])
            }
            let page = try store.entryPage(limit: 1)
            #expect(page.entries == [first] && page.totalCount == book.entries.count)
            // A returned row must still fail if its projected amount and payload disagree.
            try inspection.write { db in
                try db.execute(sql: "UPDATE entries SET amount_minor = amount_minor + 1 WHERE id = ?",
                               arguments: [first.id.uuidString])
            }
            #expect(throws: LedgerStoreError.corruptData("entries")) { try store.entryPage(limit: 1) }
            #expect(throws: LedgerStoreError.corruptData("entries")) { try store.loadSnapshot() }
        }
    }

    @Test func reopeningOldSchemaTwoAddsOnlyIndexAndQueriesUseIt() throws {
        try withFixture { store, book, path in
            let inspection = try DatabaseQueue(path: path)
            try inspection.write { db in
                try db.execute(sql: "DROP INDEX entries_history_order")
                for table in ["accounts", "categories", "subjects", "entries", "adjustments", "operation_registry", "entry_draft", "ledger_settings"] {
                    for action in ["INSERT", "UPDATE", "DELETE"] {
                        try db.execute(sql: "CREATE TRIGGER no_\(table)_\(action) BEFORE \(action) ON \(table) BEGIN SELECT RAISE(ABORT, 'unexpected write'); END")
                    }
                }
            }
            let reopened = try SQLiteLedgerStore(path: path)
            #expect(try reopened.loadBook() == book)
            #expect(try reopened.entryPage(limit: 5).entries.count == 5)
            // A fresh connection observes the new schema before preparing EXPLAIN.
            let planInspection = try DatabaseQueue(path: path)
            try planInspection.read { db in
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'entries_history_order'") == 1)
                let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT * FROM entries ORDER BY occurred_at DESC, created_at DESC, id ASC LIMIT 51")
                let details = try plan.map { try $0.decode(String.self, forColumn: "detail") }.joined(separator: "\n")
                #expect(details.contains("entries_history_order"))
                #expect(!details.contains("TEMP B-TREE"))
                #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 2)
            }
            _ = store
        }
    }

    private func allPages(_ store: SQLiteLedgerStore, filter: EntryFilter, size: Int) throws -> [LedgerEntry] {
        var entries: [LedgerEntry] = []
        var cursor: EntryPageCursor?
        repeat {
            let page = try store.entryPage(matching: filter, after: cursor, limit: size)
            #expect(page.entries.count <= size)
            entries.append(contentsOf: page.entries)
            cursor = page.nextCursor
            #expect(entries.count <= page.totalCount)
            if cursor == nil { #expect(entries.count == page.totalCount) }
        } while cursor != nil
        return entries
    }

    private func withFixture(_ body: (SQLiteLedgerStore, LedgerBook, String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("history.sqlite").path
        let store = try SQLiteLedgerStore(path: path)
        let bank = Account(name: "历史银行卡", openingMinor: 100_000)
        let wallet = Account(name: "钱包")
        let usd = Account(name: "美元", currency: .usd, openingMinor: 100_000)
        var book = LedgerBook(accounts: [bank, wallet, usd])
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for index in 0..<123 {
            let kind: EntryKind = index % 5 == 0 ? .transfer : index % 7 == 0 ? .income : .expense
            let account = index % 11 == 0 && kind != .transfer ? usd : bank
            let category: UUID? = kind == .expense ? SeedData.mealsID : kind == .income ? SeedData.salaryIncomeID : nil
            let entry = LedgerEntry(kind: kind, amount: Money(minorUnits: Int64(100 + index), currency: account.currency),
                                    accountID: account.id, destinationAccountID: kind == .transfer ? wallet.id : nil,
                                    categoryID: category, occurredAt: date.addingTimeInterval(Double(index / 8)),
                                    createdAt: date.addingTimeInterval(Double(index / 3)),
                                    title: index % 2 == 0 ? "Lunch 午餐 CAFÉ" : "Cafe\u{0301} 🧾",
                                    note: index % 3 == 0 ? "100%_ ' OR 1=1 -- \\ \n零\u{0}尾" : "普通备注")
            book.entries.append(entry)
        }
        // Inactive references remain searchable after being used historically.
        book.accounts[0].isActive = false
        book.categories[book.categories.firstIndex(where: { $0.id == SeedData.mealsID })!].isActive = false
        try store.saveBook(book)
        try body(store, book, path)
    }
}
