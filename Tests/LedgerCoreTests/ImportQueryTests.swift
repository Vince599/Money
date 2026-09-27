import Foundation
import Testing
@testable import LedgerCore

@Suite("Import history inspection")
struct ImportQueryTests {
    private func row(_ source: String, title: String = "午餐", note: String = "", state: ImportRowState = .pending) -> ImportRow {
        var value = ImportRow(raw: [source, "2026-08-15T12:30:00+08:00", "expense", "20.00", "CNY", "银行", "", "餐饮/正餐", title, note, "success"])
        value.state = state
        return value
    }
    private func batch(_ rows: [ImportRow], namespace: String = "银行1234") -> ImportBatch {
        ImportBatch(name: "bill.csv", namespace: namespace, rows: rows)
    }
    @Test func combinesConditionsOnSameRowAndPreservesFileOrderWithoutMutating() {
        let first = row("001", title: "Alice", state: .merged)
        let second = row("002", title: "Alice", state: .pending)
        let third = row("003", title: "Bob", state: .merged)
        let fourth = row("004", note: "ALICE", state: .merged)
        let value = batch([first, second, third, fourth]); let before = value
        let filter = ImportFilter(namespace: value.namespace, scope: .open, state: .merged, keyword: " alice ")
        #expect(ImportQuery.rows(in: value, matching: filter) == [first, fourth])
        #expect(ImportQuery.rows(in: value, matching: ImportFilter(namespace: "银行123" )).isEmpty)
        #expect(value == before)
    }
    @Test func matchesOnlySourceIDDisplayedTitleAndNoteWithLiteralSemantics() {
        let first = row("000001", title: "[A].* 100%_", note: "two  spaces")
        let second = row("100001", title: "ordinary", note: "two spaces")
        let fallback = row("003", title: "")
        let value = batch([first, second, fallback])
        for word in ["000001", "[A].*", "%_", "two  spaces"] {
            #expect(ImportQuery.rows(in: value, matching: ImportFilter(keyword: word)) == [first])
        }
        #expect(ImportQuery.rows(in: value, matching: ImportFilter(keyword: "餐饮/正餐")) == [fallback])
        for word in ["bill.csv", "银行1234", "2026-08", "success", "CNY"] {
            #expect(ImportQuery.rows(in: value, matching: ImportFilter(keyword: word)).isEmpty)
        }
        #expect(ImportQuery.rows(in: value, matching: ImportFilter(keyword: " \n\t")) == value.rows)
    }
    @Test func unicodeLiteralSearchAndRequestIdentityRemainConsistent() {
        let first = row("1", title: "café"), second = row("2", title: "cafe\u{0301}")
        let one = ImportFilter(keyword: first.title), two = ImportFilter(keyword: second.title)
        #expect(one != two)
        #expect(ImportQuery.rows(in: batch([first, second]), matching: one) == [first])
        #expect(ImportQuery.rows(in: batch([first, second]), matching: two) == [second])
        #expect(ImportFilter(state: .merged) != ImportFilter(state: .unlinked))
        #expect(ImportFilter(scope: .open) != ImportFilter(scope: .reverted))
        #expect(ImportFilter(namespace: "bank") != ImportFilter(namespace: "Bank"))
    }
    @Test func pendingRowsInClosedBatchAreHistoricalAndNeverSelectable() {
        let pending = row("001"), reverted = row("002", state: .reverted)
        var closed = batch([pending, reverted]); closed.revertedAt = Date()
        #expect(ImportQuery.rows(in: closed, matching: ImportFilter(scope: .reverted, state: .pending)) == [pending])
        #expect(ImportQuery.rows(in: closed, matching: ImportFilter(scope: .open)).isEmpty)
        #expect(ImportQuery.selectableIDs(in: closed, matching: ImportFilter(), limit: 50).isEmpty)
        #expect(ImportQuery.rows(in: batch([pending]), matching: ImportFilter(scope: .reverted)).isEmpty)
    }
    @Test func everyFinalStateCanBeLocatedButNotSelected() {
        for state in [ImportRowState.imported, .merged, .unlinked, .skipped, .reverted] {
            let record = row("001", state: state); let value = batch([record, row("002")])
            let filter = ImportFilter(state: state)
            #expect(ImportQuery.rows(in: value, matching: filter) == [record])
            #expect(ImportQuery.selectableIDs(in: value, matching: filter, limit: 50).isEmpty)
        }
    }
    @Test func historyUsesReverseBatchOrderAndCountsOnlyMatchingRows() {
        let older = batch([row("1"), row("2", state: .merged)])
        let other = batch([row("3", state: .merged)], namespace: "other")
        let newest = batch([row("4", state: .merged), row("5", state: .merged)])
        let book = LedgerBook(importBatches: [older, other, newest]); let before = book
        let results = ImportQuery.batches(in: book, matching: ImportFilter(namespace: older.namespace, state: .merged))
        #expect(results.map(\.id) == [newest.id, older.id])
        #expect(results.map(\.matchingRowCount) == [2, 1])
        #expect(ImportQuery.batches(in: book, matching: ImportFilter(keyword: "missing")).isEmpty)
        #expect(book == before)
    }
    @Test func selectionUsesFilteredVisiblePageAndNeverHiddenRowsOrOverTwoHundred() {
        let values = (0..<260).map { row(String($0), title: $0.isMultiple(of: 2) ? "match" : "hidden") }
        let value = batch(values), filter = ImportFilter(keyword: "match")
        let visible = ImportQuery.rows(in: value, matching: filter)
        #expect(ImportQuery.selectableIDs(in: value, matching: filter, limit: 50) == Set(visible.prefix(50).map(\.id)))
        #expect(ImportQuery.selectableIDs(in: value, matching: ImportFilter(), limit: 1000).count == 200)
        #expect(ImportQuery.selectableIDs(in: value, matching: filter, limit: 0).isEmpty)
        #expect(ImportQuery.selectableIDs(in: value, matching: filter, limit: -1).isEmpty)
        var changed = value; changed.rows[0].state = .merged
        #expect(!ImportQuery.selectableIDs(in: changed, matching: filter, limit: 50).contains(values[0].id))
    }
    @Test func finalizedSelectionDoesNotPullHiddenPendingRowsIntoPage() {
        let first = row("1", state: .merged), second = row("2"), third = row("3")
        #expect(ImportQuery.selectableIDs(in: batch([first, second, third]), matching: ImportFilter(), limit: 2) == [second.id])
        #expect(ImportQuery.rows(in: batch([])).isEmpty)
    }
    @Test func realMergeUnlinkAndReversalHistorySurvivesBackupAndRemainsReadOnly() throws {
        let account = Account(name: "银行", openingMinor: 10_000)
        var source = batch([row("source-1")])
        source.rows[0].accountID = account.id; source.rows[0].categoryID = SeedData.mealsID
        var entry = try ImportEngine.originalEntry(source.rows[0], batch: source)
        entry.id = UUID(); entry.operationID = UUID()
        var book = try ImportEngine.save(source, in: LedgerBook(accounts: [account], entries: [entry]))
        let review = try ImportEngine.reviewMerge(batchID: source.id, rowID: source.rows[0].id, entryID: entry.id, in: book)
        book = try ImportEngine.merge(ImportEngine.prepareMerge(review, keepExisting: Set(review.differences)), in: book)
        #expect(ImportQuery.batches(in: book, matching: ImportFilter(state: .merged)).map(\.id) == [source.id])
        book = try ImportEngine.unlink(ImportEngine.prepareUnlink(batchID: source.id, rowID: source.rows[0].id, in: book), in: book)
        #expect(ImportQuery.batches(in: book, matching: ImportFilter(state: .merged)).isEmpty)
        #expect(ImportQuery.batches(in: book, matching: ImportFilter(state: .unlinked)).map(\.id) == [source.id])
        var newer = source; newer.id = UUID(); newer.rows[0].id = UUID(); newer.rows[0].operationID = UUID()
        book = try ImportEngine.save(newer, in: book)
        let nextReview = try ImportEngine.reviewMerge(batchID: newer.id, rowID: newer.rows[0].id, entryID: entry.id, in: book)
        book = try ImportEngine.merge(ImportEngine.prepareMerge(nextReview, keepExisting: Set(nextReview.differences)), in: book)
        let undo = try #require(ImportEngine.reviewUndo(batchID: newer.id, in: book).plan)
        book = try ImportEngine.undo(undo, in: book)
        let restored = try BackupCodec.decode(BackupCodec.encode(LedgerBackupSnapshot(book: book, draft: nil, settings: LedgerSettings()))).book
        #expect(ImportQuery.batches(in: restored, matching: ImportFilter(scope: .reverted, state: .reverted, keyword: "source-1")).map(\.id) == [newer.id])
        #expect(ImportQuery.batches(in: restored, matching: ImportFilter(scope: .open, state: .unlinked)).map(\.id) == [source.id])
        #expect(restored.entries == [entry])
        for item in ImportQuery.batches(in: restored) {
            #expect(ImportQuery.selectableIDs(in: item.batch, matching: ImportFilter(), limit: 50).isEmpty)
        }
    }

}
