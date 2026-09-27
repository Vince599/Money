import Foundation
import Testing
@testable import LedgerCore

@Suite("Safe import batch reversal")
struct ImportUndoTests {
    private let date = Date(timeIntervalSince1970: 1_790_467_200)
    private func fixture(partial: Bool = false) throws -> (LedgerBook, ImportBatch, ImportPlan) {
        let account = Account(name: "银行卡", openingMinor: 10_000)
        var batch = try ImportCSV.parse(ImportCSV.template, name: "test", namespace: "bank", at: date)
        batch.rows[0].accountID = account.id; batch.rows[0].categoryID = SeedData.mealsID
        if partial {
            var raw = batch.rows[0].raw; raw[0] = "second"; raw[3] = "10.00"
            var row = ImportRow(raw: raw); row.accountID = account.id; row.categoryID = SeedData.mealsID
            batch.rows.append(row)
        }
        batch.proposedAccounts = [account]
        let book = try ImportEngine.save(batch, in: LedgerBook())
        let plan = try ImportEngine.prepare(batchID: batch.id, importIDs: [batch.rows[0].id], skipIDs: [], in: book, now: date)
        let posted = try ImportEngine.commit(plan, in: book, now: date)
        return (posted, posted.importBatches[0], plan)
    }

    @Test func reversalRestoresCashKeepsAccountAndSourceClosesBatchAndRetriesOnce() throws {
        let (book, batch, posting) = try fixture(partial: true)
        let plan = try #require(ImportEngine.reviewUndo(batchID: batch.id, in: book, at: date).plan)
        #expect(plan.entries.count == 1 && plan.accounts[0].before.minorUnits == 7_990 && plan.accounts[0].after.minorUnits == 10_000)
        let after = try ImportEngine.undo(plan, in: book)
        #expect(after.entries.isEmpty && after.accounts == book.accounts)
        #expect(after.importBatches[0].rows[0].state == .reverted)
        #expect(after.importBatches[0].rows[1] == batch.rows[1])
        #expect(after.importBatches[0].rows.map(\.raw) == batch.rows.map(\.raw))
        #expect(after.importBatches[0].revertedAt == date)
        #expect(after.retiredOperationIDs.contains(batch.rows[0].operationID))
        #expect(try ImportEngine.undo(plan, in: after) == after)
        #expect(throws: ImportError.stalePreview) { try ImportEngine.commit(posting, in: after, now: date) }
        #expect(throws: ImportError.self) { try ImportEngine.prepare(batchID: batch.id, importIDs: [batch.rows[1].id], skipIDs: [], in: after, now: date) }
        #expect(throws: ImportError.self) { try ImportEngine.save(after.importBatches[0], in: after, expectedVersion: after.importBatches[0].version) }
        #expect(throws: ImportError.self) { try ImportEngine.reviewUndo(batchID: batch.id, in: after, at: date) }
        #expect(ImportEngine.review(batch.rows[1], batch: after.importBatches[0], in: after, now: date) != .ready)
    }

    @Test func changedAndDeletedEntriesBlockWithoutTouchingUnrelatedWork() throws {
        let (book, batch, _) = try fixture()
        var entry = book.entries[0]; entry.operationID = UUID(); entry.note = "用户补充"
        let edited = try LedgerEngine.replace(entry, expectedVersion: 1, in: book)
        let report = try ImportEngine.reviewUndo(batchID: batch.id, in: edited, at: date)
        #expect(report.plan == nil && report.blockers.count == 1 && report.blockers[0].entryID == entry.id)
        let deleted = try LedgerEngine.delete(entryID: entry.id, in: edited)
        let missing = try ImportEngine.reviewUndo(batchID: batch.id, in: deleted, at: date)
        #expect(missing.plan == nil && missing.blockers.count == 1 && missing.blockers[0].entryID == nil)
    }

    @Test func refundDependencyMustBeHandledExplicitlyEvenAfterOldPreview() throws {
        let (book, batch, _) = try fixture()
        let plan = try #require(ImportEngine.reviewUndo(batchID: batch.id, in: book, at: date).plan)
        let refund = LedgerEntry(kind: .refund, amount: Money(minorUnits: 100), accountID: book.accounts[0].id,
                                 occurredAt: date, originalEntryID: book.entries[0].id)
        let linked = try LedgerEngine.record(refund, in: book)
        let review = try ImportEngine.reviewUndo(batchID: batch.id, in: linked, at: date)
        #expect(review.plan == nil && review.blockers.contains { $0.entryID == refund.id })
        #expect(throws: ImportError.stalePreview) { try ImportEngine.undo(plan, in: linked) }
        let resolved = try LedgerEngine.delete(entryID: refund.id, in: linked)
        let refreshed = try #require(ImportEngine.reviewUndo(batchID: batch.id, in: resolved, at: date).plan)
        #expect(try ImportEngine.undo(refreshed, in: resolved).entries.isEmpty)
    }

    @Test func unrelatedWorkSurvivesAndAnyStaleBusinessSnapshotRequiresNewPreview() throws {
        let (book, batch, _) = try fixture()
        let plan = try #require(ImportEngine.reviewUndo(batchID: batch.id, in: book, at: date).plan)
        let extra = LedgerEntry(kind: .expense, amount: Money(minorUnits: 500), accountID: book.accounts[0].id, categoryID: SeedData.mealsID)
        let changed = try LedgerEngine.record(extra, in: book)
        #expect(throws: ImportError.stalePreview) { try ImportEngine.undo(plan, in: changed) }
        let refreshed = try #require(ImportEngine.reviewUndo(batchID: batch.id, in: changed, at: date).plan)
        let after = try ImportEngine.undo(refreshed, in: changed)
        #expect(after.entries == [extra])
        #expect(try LedgerEngine.balance(of: book.accounts[0].id, in: after).minorUnits == 9_500)
        #expect(throws: ImportError.stalePreview) { try ImportEngine.undo(plan, in: after) }
    }

    @Test func reimportUsesNewIDsAndOnlyReversedSourceIdentityIsReleased() throws {
        let (book, batch, _) = try fixture()
        let plan = try #require(ImportEngine.reviewUndo(batchID: batch.id, in: book, at: date).plan)
        let after = try ImportEngine.undo(plan, in: book)
        var fresh = try ImportCSV.parse(ImportCSV.template, name: "again", namespace: batch.namespace, at: date)
        fresh.rows[0].accountID = book.accounts[0].id; fresh.rows[0].categoryID = SeedData.mealsID
        #expect(ImportEngine.review(fresh.rows[0], batch: fresh, in: book, now: date) == .duplicate)
        #expect(ImportEngine.review(fresh.rows[0], batch: fresh, in: after, now: date) == .ready)
        let staged = try ImportEngine.save(fresh, in: after)
        let posted = try ImportEngine.commit(ImportEngine.prepare(batchID: fresh.id, importIDs: [fresh.rows[0].id], skipIDs: [], in: staged, now: date), in: staged, now: date)
        #expect(posted.entries.count == 1 && posted.entries[0].id != batch.rows[0].id)
        #expect(try LedgerEngine.balance(of: book.accounts[0].id, in: posted).minorUnits == 7_990)
        let again = try ImportCSV.parse(ImportCSV.template, name: "third", namespace: batch.namespace, at: date)
        #expect(ImportEngine.review(again.rows[0], batch: again, in: posted, now: date) == .duplicate)
    }

    @Test func fullBackupRetainsReversalAndRejectsIncompleteDateOrForgedState() throws {
        let (book, batch, _) = try fixture()
        let plan = try #require(ImportEngine.reviewUndo(batchID: batch.id, in: book, at: date).plan)
        let after = try ImportEngine.undo(plan, in: book)
        let snapshot = LedgerBackupSnapshot(book: after, draft: EntryDraft(amountText: "12+("), settings: LedgerSettings(defaultAccountID: book.accounts[0].id))
        let files = try BackupCodec.encode(snapshot)
        #expect(try BackupCodec.decode(BackupArchive.decode(BackupArchive.encode(files))) == snapshot)
        var invalid = after
        invalid.importBatches[0].revertedAt = nil
        #expect(throws: ImportError.invalidState) { try LedgerEngine.validate(invalid) }
        invalid = after; invalid.retiredOperationIDs = []
        #expect(throws: ImportError.invalidState) { try LedgerEngine.validate(invalid) }
        invalid = book; invalid.importBatches[0].revertedAt = date
        #expect(throws: ImportError.invalidState) { try LedgerEngine.validate(invalid) }
        var tampered = files
        var records = try BackupSchema.importBatches.read(files["import_batches.csv"]!).map { row in BackupSchema.importBatches.columns.map { row.values[$0.name] } }
        records[0][7] = nil
        tampered["import_batches.csv"] = BackupCSV.encode([BackupSchema.importBatches.header] + records)
        try rehash(&tampered)
        #expect(throws: BackupError.self) { try BackupCodec.decode(tampered) }
    }

    @Test func exactProfileSixKeepsOldReceiptsAndCanSafelyReverseAfterRestore() throws {
        let (book, batch, _) = try fixture()
        let snapshot = LedgerBackupSnapshot(book: book, draft: nil, settings: LedgerSettings())
        var files = try BackupCodec.encode(snapshot)
        let batches = try BackupSchema.importBatches.read(files["import_batches.csv"]!).map { row in BackupSchema.v6ImportBatches.columns.map { row.values[$0.name] } }
        files["import_batches.csv"] = BackupCSV.encode([BackupSchema.v6ImportBatches.header] + batches)
        var manifest = try BackupSchema.manifest.read(files["manifest.csv"]!)[0].values
        manifest["profile"] = "ledger-core-v6"; manifest["backup_format_version"] = "6.0"; manifest["db_schema_version"] = "6"
        files["manifest.csv"] = BackupCSV.encode([BackupSchema.manifest.header, BackupSchema.manifest.columns.map { manifest[$0.name] }])
        files["schema_dictionary.csv"] = BackupSchema.dictionaryData(for: BackupSchema.v6All)
        try rehash(&files)
        let restored = try BackupCodec.decode(files)
        #expect(restored == snapshot && restored.book.importBatches[0].revertedAt == nil)
        let plan = try #require(ImportEngine.reviewUndo(batchID: batch.id, in: restored.book, at: date).plan)
        #expect(try ImportEngine.undo(plan, in: restored.book).entries.isEmpty)
    }

    @Test func archivedCatalogDoesNotMasqueradeAsAnEditedEventAndEmptyBatchCannotReverse() throws {
        var (book, batch, _) = try fixture()
        book.accounts[0].isActive = false
        book.categories[book.categories.firstIndex { $0.id == SeedData.mealsID }!].isActive = false
        let review = try ImportEngine.reviewUndo(batchID: batch.id, in: book, at: date)
        #expect(review.plan != nil && review.blockers.isEmpty)
        let empty = try ImportCSV.parse(ImportCSV.template, name: "draft", namespace: "other", at: date)
        let added = try ImportEngine.save(empty, in: book)
        #expect(throws: ImportError.self) { try ImportEngine.reviewUndo(batchID: empty.id, in: added, at: date) }
    }

    @Test func reversesAllPartialSubmissionsIncludingIncomeAndBothTransferSides() throws {
        let a = Account(name: "银行卡", openingMinor: 10_000), b = Account(name: "零钱", openingMinor: 5_000)
        var batch = try ImportCSV.parse(ImportCSV.template, name: "mixed", namespace: "bank", at: date)
        batch.rows[0].raw[2] = "transfer"; batch.rows[0].raw[3] = "20.00"
        batch.rows[0].accountID = a.id; batch.rows[0].destinationAccountID = b.id
        var raw = batch.rows[0].raw; raw[0] = "income"; raw[2] = "income"; raw[3] = "5.00"
        var income = ImportRow(raw: raw); income.accountID = b.id; income.categoryID = SeedData.salaryIncomeID
        batch.rows.append(income)
        var book = try ImportEngine.save(batch, in: LedgerBook(accounts: [a, b]))
        for row in batch.rows {
            let plan = try ImportEngine.prepare(batchID: batch.id, importIDs: [row.id], skipIDs: [], in: book, now: date)
            book = try ImportEngine.commit(plan, in: book, now: date)
        }
        let plan = try #require(ImportEngine.reviewUndo(batchID: batch.id, in: book, at: date).plan)
        #expect(plan.entries.count == 2 && plan.accounts.count == 2)
        #expect(plan.accounts[0].before.minorUnits == 8_000 && plan.accounts[1].before.minorUnits == 7_500)
        let after = try ImportEngine.undo(plan, in: book)
        #expect(after.entries.isEmpty && after.importBatches[0].rows.allSatisfy { $0.state == .reverted })
        #expect(try LedgerEngine.balance(of: a.id, in: after).minorUnits == 10_000)
        #expect(try LedgerEngine.balance(of: b.id, in: after).minorUnits == 5_000)
    }

    private func rehash(_ files: inout [String: Data]) throws {
        let count = files.count
        let counts: [[String?]] = try files.keys.sorted().map { name in
            [name, String(name == "counts.csv" ? count : name == "checksums.csv" ? count - 1 : try BackupCSV.decode(files[name]!, file: name).count - 1)]
        }
        files["counts.csv"] = BackupCSV.encode([BackupSchema.counts.header] + counts)
        files["checksums.csv"] = BackupCSV.encode([BackupSchema.checksums.header] + files.keys.filter { $0 != "checksums.csv" }.sorted().map { [$0, BackupSHA256.hex(files[$0]!)] })
    }
}
