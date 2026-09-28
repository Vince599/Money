import Foundation
import Testing
@testable import LedgerCore

@Suite("Entry provenance filters")
struct EntrySourceQueryTests {
    private func fixture() throws -> (LedgerBook, ImportBatch, [ImportBatch], LedgerEntry, LedgerEntry) {
        let account = Account(name: "账户", openingMinor: 10_000)
        var original = try ImportCSV.parse(ImportCSV.template, name: "original.csv", namespace: "Bank '_%")
        original.rows[0].accountID = account.id; original.rows[0].categoryID = SeedData.mealsID
        var book = try ImportEngine.save(original, in: LedgerBook(accounts: [account]))
        book = try ImportEngine.commit(ImportEngine.prepare(batchID: original.id, importIDs: [original.rows[0].id], skipIDs: [], in: book), in: book)
        var target = try ImportEngine.originalEntry(original.rows[0], batch: original)
        target.id = UUID(); target.operationID = UUID(); target.title = "Manual lunch"
        let plain = LedgerEntry(kind: .income, amount: Money(minorUnits: 500), accountID: account.id,
                                categoryID: SeedData.salaryIncomeID, title: "Plain income")
        book.entries += [target, plain]
        var merged: [ImportBatch] = []
        for namespace in ["Wallet", "Second Wallet"] {
            var batch = try ImportCSV.parse(ImportCSV.template, name: "source.csv", namespace: namespace)
            batch.rows[0].accountID = account.id; batch.rows[0].categoryID = SeedData.mealsID
            book = try ImportEngine.save(batch, in: book)
            let review = try ImportEngine.reviewMerge(batchID: batch.id, rowID: batch.rows[0].id, entryID: target.id, in: book)
            book = try ImportEngine.merge(ImportEngine.prepareMerge(review, keepExisting: Set(review.differences)), in: book)
            merged.append(batch)
        }
        return (book, original, merged, target, plain)
    }
    private func ids(_ book: LedgerBook, _ filter: EntryFilter) throws -> Set<UUID> {
        Set(try EntryQuery.entries(in: book, matching: filter).map(\.id))
    }

    @Test func activeSourcesIncludeOriginalAndMergedTargetsWithoutDuplicates() throws {
        let (book, original, _, target, plain) = try fixture()
        let before = book
        let linked = try EntryQuery.entries(in: book, matching: EntryFilter(importSourceMode: .linked))
        #expect(linked.count == 2)
        #expect(Set(linked.map(\.id)) == [original.rows[0].id, target.id])
        #expect(try ids(book, EntryFilter(importSourceMode: .unlinked)) == [plain.id])
        #expect(book == before)
    }

    @Test func namespaceMatchesExactlyAndAllConditionsIntersect() throws {
        let (book, original, _, target, _) = try fixture()
        #expect(try ids(book, EntryFilter(importNamespace: original.namespace)) == [original.rows[0].id])
        #expect(try ids(book, EntryFilter(keyword: "manual", kind: .expense, currency: .cny, minimumMinor: 2010,
                                          maximumMinor: 2010, importSourceMode: .linked, importNamespace: "Wallet")) == [target.id])
        for filter in [EntryFilter(importNamespace: "wallet"), EntryFilter(importNamespace: "%"),
                       EntryFilter(kind: .income, importSourceMode: .linked),
                       EntryFilter(importSourceMode: .unlinked, importNamespace: "Wallet")] {
            #expect(try ids(book, filter).isEmpty)
        }
        #expect(EntryFilter(importSourceMode: .linked) != EntryFilter(importSourceMode: .unlinked))
        #expect(EntryFilter(importNamespace: "Wallet") != EntryFilter(importNamespace: "Second Wallet"))
    }

    @Test func unlinkOnlyRemovesOneSourceUntilLastLiveLinkIsRemoved() throws {
        var (book, _, merged, target, plain) = try fixture()
        book = try ImportEngine.unlink(ImportEngine.prepareUnlink(batchID: merged[0].id, rowID: merged[0].rows[0].id, in: book), in: book)
        #expect(try ids(book, EntryFilter(importNamespace: "Wallet")).isEmpty)
        #expect(try ids(book, EntryFilter(importNamespace: "Second Wallet")) == [target.id])
        #expect(try ids(book, EntryFilter(importSourceMode: .unlinked)) == [plain.id])
        book = try ImportEngine.unlink(ImportEngine.prepareUnlink(batchID: merged[1].id, rowID: merged[1].rows[0].id, in: book), in: book)
        #expect(try ids(book, EntryFilter(importSourceMode: .unlinked)) == [target.id, plain.id])
    }

    @Test func undoAndPendingOrSkippedRowsDoNotCountAsLiveSources() throws {
        var (book, original, merged, target, _) = try fixture()
        let undo = try #require(ImportEngine.reviewUndo(batchID: original.id, in: book).plan)
        book = try ImportEngine.undo(undo, in: book)
        #expect(try ids(book, EntryFilter(importNamespace: original.namespace)).isEmpty)
        for batch in merged {
            let plan = try #require(ImportEngine.reviewUndo(batchID: batch.id, in: book).plan)
            book = try ImportEngine.undo(plan, in: book)
        }
        var pending = try ImportCSV.parse(ImportCSV.template, name: "pending", namespace: "Pending")
        book = try ImportEngine.save(pending, in: book)
        #expect(try ids(book, EntryFilter(importSourceMode: .linked)).isEmpty)
        book = try ImportEngine.commit(ImportEngine.prepare(batchID: pending.id, importIDs: [], skipIDs: [pending.rows[0].id], in: book), in: book)
        #expect(try ids(book, EntryFilter(importSourceMode: .linked)).isEmpty)
        #expect(book.entries.contains(target))
        pending = book.importBatches.last!
        #expect(pending.rows[0].state == .skipped)
    }

    @Test func backupRestoreRetainsSourceFilterResults() throws {
        var (book, _, merged, _, _) = try fixture()
        book = try ImportEngine.unlink(ImportEngine.prepareUnlink(batchID: merged[0].id, rowID: merged[0].rows[0].id, in: book), in: book)
        let snapshot = LedgerBackupSnapshot(book: book, draft: nil, settings: LedgerSettings())
        let restored = try BackupCodec.decode(BackupCodec.encode(snapshot))
        for filter in [EntryFilter(), EntryFilter(importSourceMode: .linked), EntryFilter(importSourceMode: .unlinked),
                       EntryFilter(importNamespace: "Wallet"), EntryFilter(importNamespace: "Second Wallet")] {
            #expect(try EntryQuery.entries(in: restored.book, matching: filter) == EntryQuery.entries(in: book, matching: filter))
        }
    }
}
