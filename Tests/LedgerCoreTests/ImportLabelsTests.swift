import Foundation
import Testing
@testable import LedgerCore

@Suite("Import labels and reviewed changes")
struct ImportLabelsTests {
    private func fixture() throws -> (LedgerBook, ImportBatch, EntryTag, EntryTag, EntryProject) {
        let a = EntryTag(name: "旅行"), b = EntryTag(name: "工作"), project = EntryProject(name: "出行")
        let account = Account(name: "银行卡", openingMinor: 10_000)
        var batch = try ImportCSV.parse(ImportCSV.template, name: "example", namespace: "bank")
        batch.rows[0].accountID = account.id; batch.rows[0].categoryID = SeedData.mealsID
        var raw = batch.rows[0].raw; raw[0] = "example-2"; raw[3] = "30.00"
        var second = ImportRow(raw: raw); second.accountID = account.id; second.categoryID = SeedData.mealsID
        batch.rows.append(second)
        batch.rows[0].tagIDs = [a.id]; batch.rows[0].projectID = project.id
        let book = try ImportEngine.save(batch, in: LedgerBook(accounts: [account], tags: [a, b], projects: [project]))
        return (book, batch, a, b, project)
    }

    @Test func previewOnlyChangesSelectedDraftAndCommitPreservesCashAndRaw() throws {
        let (book, batch, a, b, project) = try fixture()
        let plan = try ImportEngine.prepareLabels(batchID: batch.id, rowIDs: [batch.rows[0].id], tags: .add([a.id, b.id]), project: .keep, in: book)
        #expect(plan.batch.rows[0].tagIDs == [a.id, b.id])
        #expect(plan.batch.rows[0].projectID == project.id)
        #expect(plan.batch.rows[1] == batch.rows[1] && book.importBatches[0] == batch)
        let saved = try ImportEngine.commitLabels(plan, in: book)
        #expect(saved.entries.isEmpty && saved.accounts == book.accounts)
        #expect(saved.importBatches[0].version == 2)
        #expect(saved.importBatches[0].rows.map(\.raw) == batch.rows.map(\.raw))
        #expect(saved.importBatches[0].rows.map(\.operationID) == batch.rows.map(\.operationID))
        #expect(throws: ImportError.stalePreview) { try ImportEngine.commitLabels(plan, in: saved) }
    }

    @Test func replaceRemoveClearAndProjectActionsHaveDifferentMeanings() throws {
        let (book, batch, a, b, project) = try fixture()
        let ids: Set<UUID> = [batch.rows[0].id]
        let replace = try ImportEngine.changingLabels(in: batch, rowIDs: ids, tags: .replace([b.id]), project: .clear, book: book)
        #expect(replace.rows[0].tagIDs == [b.id] && replace.rows[0].projectID == nil)
        let remove = try ImportEngine.changingLabels(in: batch, rowIDs: ids, tags: .remove([a.id]), project: .keep, book: book)
        #expect(remove.rows[0].tagIDs.isEmpty && remove.rows[0].projectID == project.id)
        let clear = try ImportEngine.changingLabels(in: batch, rowIDs: ids, tags: .clear, project: .clear, book: book)
        #expect(clear.rows[0].tagIDs.isEmpty && clear.rows[0].projectID == nil)
        let set = try ImportEngine.changingLabels(in: batch, rowIDs: [batch.rows[1].id], tags: .keep, project: .set(project.id), book: book)
        #expect(set.rows[1].tagIDs.isEmpty && set.rows[1].projectID == project.id)
        #expect(set.rows[0] == batch.rows[0])
    }

    @Test func missingAndInactiveDraftReferencesSurviveBackupButMustBeRepairedBeforePosting() throws {
        var (book, batch, a, _, _) = try fixture()
        book.tags[0].isActive = false; book.projects[0].isArchived = true
        let missing = UUID(); batch.rows[0].tagIDs.append(missing)
        book = try ImportEngine.save(batch, in: book, expectedVersion: 1)
        batch = book.importBatches[0]
        let snapshot = LedgerBackupSnapshot(book: book, draft: nil, settings: LedgerSettings())
        #expect(try BackupCodec.decode(BackupCodec.encode(snapshot)) == snapshot)
        #expect(ImportEngine.review(batch.rows[0], batch: batch, in: book) != .ready)
        #expect(throws: ImportError.self) { try ImportEngine.changingLabels(in: batch, rowIDs: [batch.rows[0].id], tags: .add([a.id]), project: .keep, book: book) }
        let repaired = try ImportEngine.changingLabels(in: batch, rowIDs: [batch.rows[0].id], tags: .remove([a.id, missing]), project: .clear, book: book)
        #expect(ImportEngine.review(repaired.rows[0], batch: repaired, in: book) == .ready)
    }

    @Test func staleCatalogOrBatchRejectsConfirmedPreviewWithoutLosingNewerState() throws {
        let (book, batch, _, b, project) = try fixture()
        let plan = try ImportEngine.prepareLabels(batchID: batch.id, rowIDs: [batch.rows[1].id], tags: .add([b.id]), project: .set(project.id), in: book)
        var changed = book; changed.tags[1].isActive = false
        #expect(throws: ImportError.stalePreview) { try ImportEngine.commitLabels(plan, in: changed) }
        var edited = batch; edited.rows[1].categoryID = SeedData.otherExpenseID
        let newer = try ImportEngine.save(edited, in: book, expectedVersion: 1)
        #expect(throws: ImportError.stalePreview) { try ImportEngine.commitLabels(plan, in: newer) }
        #expect(throws: ImportError.stalePreview) { try ImportEngine.changingLabels(in: batch, rowIDs: [batch.rows[0].id], tags: .clear, project: .clear, book: newer) }
    }

    @Test func invalidTargetsSelectionsAndCompletedRowsAreRejected() throws {
        let (book, batch, a, _, _) = try fixture()
        #expect(throws: ImportError.self) { try ImportEngine.prepareLabels(batchID: batch.id, rowIDs: [], tags: .clear, project: .keep, in: book) }
        #expect(throws: ImportError.self) { try ImportEngine.prepareLabels(batchID: batch.id, rowIDs: [UUID()], tags: .clear, project: .keep, in: book) }
        #expect(throws: ImportError.self) { try ImportEngine.prepareLabels(batchID: batch.id, rowIDs: [batch.rows[0].id], tags: .add([a.id, a.id]), project: .keep, in: book) }
        #expect(throws: ImportError.self) { try ImportEngine.prepareLabels(batchID: batch.id, rowIDs: [batch.rows[0].id], tags: .keep, project: .set(UUID()), in: book) }
        let posted = try ImportEngine.commit(ImportEngine.prepare(batchID: batch.id, importIDs: [batch.rows[0].id], skipIDs: [batch.rows[1].id], in: book), in: book)
        for row in batch.rows {
            #expect(throws: ImportError.unavailableRow) { try ImportEngine.prepareLabels(batchID: batch.id, rowIDs: [row.id], tags: .clear, project: .clear, in: posted) }
        }
        var tooMany = batch
        tooMany.rows = (0..<201).map { number in
            var raw = batch.rows[0].raw; raw[0] = String(number); return ImportRow(raw: raw)
        }
        var largeBook = book; largeBook.importBatches = [tooMany]
        #expect(throws: ImportError.tooManySelected) { try ImportEngine.prepareLabels(batchID: tooMany.id, rowIDs: Set(tooMany.rows.map(\.id)), tags: .clear, project: .keep, in: largeBook) }
    }

    @Test func importedLabelsKeepOrderAndDoNotChangeBalances() throws {
        let (book, batch, a, b, project) = try fixture()
        let labelPlan = try ImportEngine.prepareLabels(batchID: batch.id, rowIDs: [batch.rows[0].id], tags: .replace([b.id, a.id]), project: .set(project.id), in: book)
        let mapped = try ImportEngine.commitLabels(labelPlan, in: book)
        let plan = try ImportEngine.prepare(batchID: batch.id, importIDs: [batch.rows[0].id], skipIDs: [], in: mapped)
        let posted = try ImportEngine.commit(plan, in: mapped)
        #expect(posted.entries[0].tagIDs == [b.id, a.id] && posted.entries[0].projectID == project.id)
        #expect(try LedgerEngine.balance(of: book.accounts[0].id, in: posted).minorUnits == 7_990)
        #expect(try ImportEngine.commit(plan, in: posted) == posted)
        let snapshot = LedgerBackupSnapshot(book: posted, draft: EntryDraft(amountText: "12+"), settings: LedgerSettings())
        let files = try BackupCodec.encode(snapshot)
        #expect(files.count == 20 && files["import_row_tags.csv"] != nil)
        #expect(try BackupCodec.decode(BackupArchive.decode(BackupArchive.encode(files))) == snapshot)
    }

    @Test func changingLabelsInvalidatesPreviousDuplicateReview() throws {
        var (book, batch, _, b, _) = try fixture()
        var original = try ImportEngine.candidate(batch.rows[0], batch: batch, in: book, now: Date())
        original.id = UUID(); original.operationID = UUID()
        book = try LedgerEngine.record(original, in: book)
        guard case .similar(let token, _) = ImportEngine.review(batch.rows[0], batch: batch, in: book) else { Issue.record("Expected duplicate review"); return }
        batch.rows[0].duplicateReviewToken = token
        book = try ImportEngine.save(batch, in: book, expectedVersion: batch.version)
        batch = book.importBatches[0]
        #expect(ImportEngine.review(batch.rows[0], batch: batch, in: book) == .ready)
        let changed = try ImportEngine.changingLabels(in: batch, rowIDs: [batch.rows[0].id], tags: .add([b.id]), project: .keep, book: book)
        guard case .similar = ImportEngine.review(changed.rows[0], batch: changed, in: book) else { Issue.record("Must review changed labels again"); return }
    }

    @Test func legacyRowJSONAndExactProfileFivePreserveImportStateWithEmptyLabels() throws {
        var (book, batch, _, _, _) = try fixture()
        batch.rows[0].tagIDs = []; batch.rows[0].projectID = nil; book.importBatches = [batch]
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(batch.rows[0])) as? [String: Any])
        json.removeValue(forKey: "tagIDs"); json.removeValue(forKey: "projectID")
        let row = try JSONDecoder().decode(ImportRow.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(row == batch.rows[0])
        let snapshot = LedgerBackupSnapshot(book: book, draft: nil, settings: LedgerSettings())
        var files = try BackupCodec.encode(snapshot).filter { Set(BackupSchema.v5All.map(\.name)).contains($0.key) }
        let oldBatches = try BackupSchema.importBatches.read(files["import_batches.csv"]!).map { record in BackupSchema.v6ImportBatches.columns.map { record.values[$0.name] } }
        files["import_batches.csv"] = BackupCSV.encode([BackupSchema.v6ImportBatches.header] + oldBatches)
        let oldRows = try BackupSchema.importRows.read(files["import_rows.csv"]!).map { record in BackupSchema.v5ImportRows.columns.map { record.values[$0.name] } }
        files["import_rows.csv"] = BackupCSV.encode([BackupSchema.v5ImportRows.header] + oldRows)
        var manifest = try BackupSchema.manifest.read(files["manifest.csv"]!)[0].values
        manifest["profile"] = "ledger-core-v5"; manifest["backup_format_version"] = "5.0"; manifest["db_schema_version"] = "5"; manifest["file_count"] = "19"
        files["manifest.csv"] = BackupCSV.encode([BackupSchema.v5Manifest.header, BackupSchema.v5Manifest.columns.map { manifest[$0.name] }])
        files["schema_dictionary.csv"] = BackupSchema.dictionaryData(for: BackupSchema.v5All)
        try rehash(&files)
        #expect(try BackupCodec.decode(files) == snapshot)
    }

    @Test func orphanAndDuplicateDraftTagLinksRejectEvenAfterRehashing() throws {
        let (book, _, _, _, _) = try fixture()
        let files = try BackupCodec.encode(LedgerBackupSnapshot(book: book, draft: nil, settings: LedgerSettings()))
        for orphan in [true, false] {
            var changed = files
            var records = try BackupCSV.decode(files["import_row_tags.csv"]!, file: "import_row_tags.csv")
            if orphan { records[1][1] = UUID().uuidString.lowercased() }
            else { var duplicate = records[1]; duplicate[0] = "1"; records.append(duplicate) }
            changed["import_row_tags.csv"] = BackupCSV.encode(records.map { $0.map(Optional.some) })
            try rehash(&changed)
            #expect(throws: BackupError.self) { try BackupCodec.decode(changed) }
        }
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
