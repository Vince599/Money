import Foundation
import Testing
@testable import LedgerCore

@Suite("Explicit source-only import merge")
struct ImportMergeTests {
    private func fixture() throws -> (LedgerBook, ImportBatch, LedgerEntry) {
        let account = Account(name: "银行卡", openingMinor: 100_00), tag = EntryTag(name: "手写标签")
        var batch = try ImportCSV.parse(ImportCSV.template, name: "来源", namespace: "bank")
        batch.rows[0].accountID = account.id; batch.rows[0].categoryID = SeedData.mealsID
        var entry = try ImportEngine.originalEntry(batch.rows[0], batch: batch)
        entry.id = UUID(); entry.operationID = UUID(); entry.title = "手写标题"; entry.note = "手写备注"; entry.tagIDs = [tag.id]
        let book = try ImportEngine.save(batch, in: LedgerBook(accounts: [account], entries: [entry], tags: [tag]))
        return (book, batch, entry)
    }
    private func plan(_ book: LedgerBook, _ batch: ImportBatch, _ target: LedgerEntry) throws -> ImportMergePlan {
        let review = try ImportEngine.reviewMerge(batchID: batch.id, rowID: batch.rows[0].id, entryID: target.id, in: book)
        return try ImportEngine.prepareMerge(review, keepExisting: Set(review.differences))
    }

    @Test func suggestionsRequireExplicitDifferencesAndMergeLeavesCashAndEventExactlyUnchanged() throws {
        let (book, batch, target) = try fixture()
        #expect(try ImportEngine.mergeCandidates(batchID: batch.id, rowID: batch.rows[0].id, in: book) == [target])
        let review = try ImportEngine.reviewMerge(batchID: batch.id, rowID: batch.rows[0].id, entryID: target.id, in: book)
        #expect(review.differences.contains(.note) && review.differences.contains(.tags))
        #expect(throws: ImportError.self) { try ImportEngine.prepareMerge(review, keepExisting: []) }
        let value = try ImportEngine.prepareMerge(review, keepExisting: Set(review.differences))
        let merged = try ImportEngine.merge(value, in: book)
        #expect(merged.entries == book.entries && merged.accounts == book.accounts)
        #expect(merged.importBatches[0].rows[0].state == .merged && merged.importBatches[0].rows[0].mergedEntryID == target.id)
        #expect(merged.retiredOperationIDs.contains(batch.rows[0].operationID))
        #expect(try LedgerEngine.balance(of: target.accountID, in: merged) == LedgerEngine.balance(of: target.accountID, in: book))
        #expect(try ImportEngine.merge(value, in: merged) == merged)
    }

    @Test func cashMismatchDifferentDayAndSpecialKindsCannotMerge() throws {
        let (book, batch, target) = try fixture()
        var changed = book; changed.entries[0].amount = Money(minorUnits: target.amount.minorUnits + 1)
        #expect(try ImportEngine.mergeCandidates(batchID: batch.id, rowID: batch.rows[0].id, in: changed).isEmpty)
        #expect(throws: ImportError.self) { try plan(changed, batch, target) }
        changed = book; changed.entries[0].occurredAt += 86400
        #expect(throws: ImportError.self) { try plan(changed, batch, target) }
        changed = book; changed.entries[0].kind = .income; changed.entries[0].categoryID = SeedData.salaryIncomeID
        #expect(throws: ImportError.self) { try plan(changed, batch, target) }
        changed = book; changed.importBatches[0].rows[0].raw[10] = "failed"
        #expect(throws: ImportError.self) { try plan(changed, batch, target) }
    }

    @Test func processedIdentityCannotPostOrRelinkAndRawEvidenceRemainsFrozen() throws {
        let (book, batch, target) = try fixture()
        let merged = try ImportEngine.merge(plan(book, batch, target), in: book)
        #expect(throws: ImportError.self) { try plan(merged, batch, target) }
        #expect(throws: ImportError.self) { try ImportEngine.prepare(batchID: batch.id, importIDs: [batch.rows[0].id], skipIDs: [], in: merged) }
        var again = try ImportCSV.parse(ImportCSV.template, name: "重导入", namespace: batch.namespace)
        again.rows[0].accountID = target.accountID; again.rows[0].categoryID = target.categoryID
        #expect(ImportEngine.review(again.rows[0], batch: again, in: merged) == .duplicate)
        let second = try ImportEngine.save(again, in: merged)
        #expect(throws: ImportError.self) { try plan(second, again, target) }
        var edited = merged.importBatches[0]; edited.rows[0].raw[8] = "篡改"
        #expect(throws: ImportError.self) { try ImportEngine.save(edited, in: merged, expectedVersion: edited.version) }
        var pending = batch; pending.rows[0].mergedEntryID = target.id
        #expect(throws: ImportError.self) { try ImportEngine.save(pending, in: book, expectedVersion: 1) }
    }

    @Test func staleMergeAndOldDeletePreviewCannotOverwriteNewState() throws {
        let (book, batch, target) = try fixture()
        let merge = try plan(book, batch, target)
        let deletion = try LedgerEngine.deletionPlan(entryID: target.id, in: book)
        var newer = book; newer.entries[0].note += "新编辑"; newer.entries[0].version += 1
        #expect(throws: ImportError.stalePreview) { try ImportEngine.merge(merge, in: newer) }
        let merged = try ImportEngine.merge(merge, in: book)
        #expect(throws: ImportError.self) { try LedgerEngine.delete(deletion, in: merged) }
        #expect(throws: ImportError.self) { try LedgerEngine.deletionPlan(entryID: target.id, in: merged) }
    }

    @Test func undoOnlyDetachesThisSourceAndKeepsLaterEditsAndOtherSources() throws {
        let (book, batch, target) = try fixture()
        let merge = try plan(book, batch, target)
        var merged = try ImportEngine.merge(merge, in: book)
        var other = try ImportCSV.parse(ImportCSV.template, name: "其他来源", namespace: "other")
        other.rows[0].accountID = target.accountID; other.rows[0].categoryID = target.categoryID
        merged = try ImportEngine.save(other, in: merged)
        merged = try ImportEngine.merge(plan(merged, other, target), in: merged)
        merged.entries[0].note = "后来编辑"; merged.entries[0].version += 1
        let undo = try #require(ImportEngine.reviewUndo(batchID: batch.id, in: merged).plan)
        #expect(undo.entries.isEmpty && undo.accounts.isEmpty && undo.mergedRows.count == 1)
        let undone = try ImportEngine.undo(undo, in: merged)
        #expect(undone.entries == merged.entries && undone.importBatches[1] == merged.importBatches[1])
        #expect(undone.importBatches[0].rows[0].state == .reverted && undone.importBatches[0].rows[0].mergedEntryID == target.id)
        #expect(try ImportEngine.undo(undo, in: undone) == undone)
        #expect(throws: ImportError.stalePreview) { try ImportEngine.merge(merge, in: undone) }
        #expect(throws: ImportError.self) { try LedgerEngine.deletionPlan(entryID: target.id, in: undone) }
        let undoOther = try #require(ImportEngine.reviewUndo(batchID: other.id, in: undone).plan)
        let released = try ImportEngine.undo(undoOther, in: undone)
        #expect(try LedgerEngine.delete(LedgerEngine.deletionPlan(entryID: target.id, in: released), in: released).entries.isEmpty)
    }

    @Test func originalImportUndoWaitsForOtherMergedSources() throws {
        var (book, batch, _) = try fixture()
        var original = try ImportCSV.parse(ImportCSV.template, name: "原导入", namespace: "original")
        original.rows[0].accountID = book.accounts[0].id; original.rows[0].categoryID = SeedData.mealsID
        let target = try ImportEngine.originalEntry(original.rows[0], batch: original)
        original.rows[0].state = .imported
        book.entries = [target]; book.importBatches.append(original)
        let merged = try ImportEngine.merge(plan(book, batch, target), in: book)
        #expect(try ImportEngine.reviewUndo(batchID: original.id, in: merged).plan == nil)
        let unlink = try #require(ImportEngine.reviewUndo(batchID: batch.id, in: merged).plan)
        let released = try ImportEngine.undo(unlink, in: merged)
        let undo = try #require(ImportEngine.reviewUndo(batchID: original.id, in: released).plan)
        #expect(try ImportEngine.undo(undo, in: released).entries.isEmpty)
    }

    @Test func mixedBatchUndoRemovesOnlyNewCashEventsAndDetachesEvidence() throws {
        var (book, batch, target) = try fixture()
        var raw = batch.rows[0].raw; raw[0] = "separate"; raw[3] = "5.00"
        var extra = ImportRow(raw: raw); extra.accountID = target.accountID; extra.categoryID = SeedData.mealsID
        batch.rows.append(extra); book.importBatches[0] = batch
        var merged = try ImportEngine.merge(plan(book, batch, target), in: book)
        merged = try ImportEngine.commit(ImportEngine.prepare(batchID: batch.id, importIDs: [extra.id], skipIDs: [], in: merged), in: merged)
        let undo = try #require(ImportEngine.reviewUndo(batchID: batch.id, in: merged).plan)
        #expect(undo.entries.count == 1 && undo.mergedRows.count == 1)
        let undone = try ImportEngine.undo(undo, in: merged)
        #expect(undone.entries == [target] && undone.importBatches[0].rows.allSatisfy { $0.state == .reverted })
    }

    @Test func completeBackupPreservesMergedAndRevertedSourcesAndRejectsDanglingTargets() throws {
        let (book, batch, target) = try fixture()
        let merged = try ImportEngine.merge(plan(book, batch, target), in: book)
        let undo = try #require(ImportEngine.reviewUndo(batchID: batch.id, in: merged).plan)
        for state in [merged, try ImportEngine.undo(undo, in: merged)] {
            let snapshot = LedgerBackupSnapshot(book: state, draft: EntryDraft(amountText: "12+("), settings: LedgerSettings())
            #expect(try BackupCodec.decode(BackupCodec.encode(snapshot)) == snapshot)
        }
        var files = try BackupCodec.encode(LedgerBackupSnapshot(book: merged, draft: nil, settings: LedgerSettings()))
        var rows = try BackupCSV.decode(files["import_rows.csv"]!, file: "import_rows.csv")
        rows[1][rows[1].count - 1] = UUID().uuidString.lowercased()
        files["import_rows.csv"] = BackupCSV.encode(rows); try rehash(&files)
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
    }

    @Test func exactProfileNineRestoresWithoutAssociationAndOldJSONDefaultsToNil() throws {
        let (book, batch, _) = try fixture()
        let snapshot = LedgerBackupSnapshot(book: book, draft: nil, settings: LedgerSettings())
        var files = try BackupCodec.encode(snapshot)
        let legacy = try BackupSchema.importRows.read(files["import_rows.csv"]!).map { row in BackupSchema.v9ImportRows.columns.map { row.values[$0.name] } }
        files["import_rows.csv"] = BackupCSV.encode([BackupSchema.v9ImportRows.header] + legacy)
        var manifest = try BackupSchema.manifest.read(files["manifest.csv"]!)[0].values
        manifest["profile"] = "ledger-core-v9"; manifest["backup_format_version"] = "9.0"; manifest["db_schema_version"] = "9"
        files["manifest.csv"] = BackupCSV.encode([BackupSchema.manifest.header, BackupSchema.manifest.columns.map { manifest[$0.name] }])
        files["schema_dictionary.csv"] = BackupSchema.dictionaryData(for: BackupSchema.v9All); try rehash(&files)
        #expect(try BackupCodec.decode(files) == snapshot)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(batch.rows[0])) as? [String: Any])
        json.removeValue(forKey: "mergedEntryID")
        #expect(try JSONDecoder().decode(ImportRow.self, from: JSONSerialization.data(withJSONObject: json)).mergedEntryID == nil)
    }
    @Test func singleUnlinkCanReleaseEvidenceWhenMixedBatchUndoIsBlockedByEditedCash() throws {
        var (book, batch, target) = try fixture()
        var raw = batch.rows[0].raw; raw[0] = "extra"; raw[3] = "3.00"
        var extra = ImportRow(raw: raw); extra.accountID = target.accountID; extra.categoryID = SeedData.mealsID
        batch.rows.append(extra); book.importBatches[0] = batch
        var merged = try ImportEngine.merge(plan(book, batch, target), in: book)
        merged = try ImportEngine.commit(ImportEngine.prepare(batchID: batch.id, importIDs: [extra.id], skipIDs: [], in: merged), in: merged)
        let index = try #require(merged.entries.firstIndex { $0.id == extra.id })
        merged.entries[index].note = "后来修改"; merged.entries[index].version += 1
        #expect(try ImportEngine.reviewUndo(batchID: batch.id, in: merged).plan == nil)
        let unlink = try ImportEngine.prepareUnlink(batchID: batch.id, rowID: batch.rows[0].id, in: merged)
        let released = try ImportEngine.unlink(unlink, in: merged)
        #expect(released.entries == merged.entries && released.importBatches[0].rows[1] == merged.importBatches[0].rows[1])
        #expect(released.importBatches[0].rows[0].state == .unlinked && released.importBatches[0].revertedAt == nil)
        #expect(try ImportEngine.unlink(unlink, in: released) == released)
        let deleted = try LedgerEngine.delete(LedgerEngine.deletionPlan(entryID: target.id, in: released), in: released)
        #expect(deleted.entries.count == 1 && deleted.entries[0].id == extra.id)
        let snapshot = LedgerBackupSnapshot(book: deleted, draft: nil, settings: LedgerSettings())
        #expect(try BackupCodec.decode(BackupCodec.encode(snapshot)) == snapshot)
    }
    @Test func oldUnlinkPreviewCannotDropNewerSourceStateAndUnlinkedRowsCannotPostAgain() throws {
        let (book, batch, target) = try fixture()
        let merged = try ImportEngine.merge(plan(book, batch, target), in: book)
        let unlink = try ImportEngine.prepareUnlink(batchID: batch.id, rowID: batch.rows[0].id, in: merged)
        var changed = merged; changed.entries[0].version += 1; changed.entries[0].note += "new"
        #expect(throws: ImportError.stalePreview) { try ImportEngine.unlink(unlink, in: changed) }
        let released = try ImportEngine.unlink(unlink, in: merged)
        #expect(throws: ImportError.self) { try ImportEngine.prepare(batchID: batch.id, importIDs: [batch.rows[0].id], skipIDs: [], in: released) }
        #expect(throws: ImportError.self) { try ImportEngine.prepareUnlink(batchID: batch.id, rowID: batch.rows[0].id, in: released) }
    }
    private func rehash(_ files: inout [String: Data]) throws {
        let count = files.count
        let rows: [[String?]] = try files.keys.sorted().map { name in
            [name, String(name == "counts.csv" ? count : name == "checksums.csv" ? count - 1 : try BackupCSV.decode(files[name]!, file: name).count - 1)]
        }
        files["counts.csv"] = BackupCSV.encode([BackupSchema.counts.header] + rows)
        files["checksums.csv"] = BackupCSV.encode([BackupSchema.checksums.header] + files.keys.filter { $0 != "checksums.csv" }.sorted().map { [$0, BackupSHA256.hex(files[$0]!)] })
    }
}
