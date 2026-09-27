import Foundation
import Testing
@testable import LedgerCore

@Suite("Generic CSV import")
struct ImportTests {
    private let now = Date(timeIntervalSince1970: 1_790_467_200)
    private func raw(_ id: String = "00001", amount: String = "2000.00", date: String = "2026-08-15T12:30:00+08:00", kind: String = "expense") -> [String] {
        [id, date, kind, amount, "CNY", "银行卡1234", "", "餐饮/正餐", "午餐", "保留原文", "success"]
    }
    private func fixture(_ rows: [[String]]? = nil, staged: Bool = false) throws -> (LedgerBook, ImportBatch, Account) {
        let account = Account(name: "银行卡", openingMinor: 1_000_000, openingDate: now)
        var batch = try ImportCSV.parse(ImportCSV.encode([ImportCSV.header] + (rows ?? [raw()])), name: "bill.csv", namespace: "银行1234", at: now)
        for index in batch.rows.indices {
            batch.rows[index].accountID = account.id
            batch.rows[index].categoryID = SeedData.mealsID
        }
        if staged { batch.proposedAccounts = [account] }
        let book = try ImportEngine.save(batch, in: LedgerBook(accounts: staged ? [] : [account]))
        return (book, batch, account)
    }
    private func commit(_ batch: ImportBatch, in book: LedgerBook, ids: Set<UUID>? = nil) throws -> LedgerBook {
        let plan = try ImportEngine.prepare(batchID: batch.id, importIDs: ids ?? Set(batch.rows.map(\.id)), skipIDs: [], in: book, now: now)
        return try ImportEngine.commit(plan, in: book, now: now)
    }

    @Test func encoderQuotesCSVBytesIndependentOfGraphemeClusters() throws {
        let samples = ["one\r\ntwo", "one\ntwo", "one\rtwo", ",\u{0301}", "\"\u{0301}"]
        let expected = ["\"one\r\ntwo\"\r\n", "\"one\ntwo\"\r\n", "\"one\rtwo\"\r\n", "\",\u{0301}\"\r\n", "\"\"\"\u{0301}\"\r\n"]
        for (sample, encoded) in zip(samples, expected) {
            #expect(ImportCSV.encode([[sample]]) == Data(encoded.utf8))
            #expect(try ImportCSV.decode(Data(encoded.utf8)) == [[sample]])
        }
    }

    @Test func parserPreservesSourceTextBOMCRLFMultilineAndMissingFinalNewline() throws {
        var source = raw(); source[8] = "含,逗号\"引号"; source[9] = "原样\r\n第二行\\N\\path😀"
        let bytes = ImportCSV.encode([ImportCSV.header, source])
        let bom = Data([239, 187, 191]) + bytes.dropLast(2)
        let batch = try ImportCSV.parse(bom, name: "测试.csv", namespace: " 身份 ", at: now)
        #expect(batch.namespace == "身份" && batch.rows[0].sourceID == "00001")
        #expect(batch.rows[0].raw == source)
        #expect(batch.rows[0].accountID == nil && batch.rows[0].categoryID == nil)
        #expect(try ImportCSV.parse(ImportCSV.template, name: "template", namespace: "sample").rows.count == 1)
    }

    @Test(arguments: [Data(), Data([255]), Data("a,b\n1,2".utf8), Data("\"not closed".utf8), Data("a,b\r1,2".utf8)])
    func malformedFilesDoNotCreateDrafts(_ data: Data) throws {
        #expect(throws: ImportError.self) { try ImportCSV.parse(data, name: "bad", namespace: "bank") }
    }

    @Test func structuralAndSizeLimitsRejectBeforePosting() throws {
        #expect(throws: ImportError.self) { try ImportCSV.parse(ImportCSV.encode([ImportCSV.header]), name: "empty", namespace: "bank") }
        #expect(throws: ImportError.self) { try ImportCSV.parse(ImportCSV.template, name: "empty", namespace: " ") }
        #expect(throws: ImportError.self) { try ImportCSV.parse(ImportCSV.encode([ImportCSV.header, ["short"]]), name: "bad", namespace: "bank") }
        #expect(throws: ImportError.self) { try ImportCSV.parse(Data(repeating: 97, count: ImportCSV.maximumBytes + 1), name: "large", namespace: "bank") }
        #expect(throws: ImportError.self) { try ImportCSV.parse(ImportCSV.encode([ImportCSV.header] + Array(repeating: raw(), count: 10_001)), name: "many", namespace: "bank") }
    }

    @Test(arguments: ["2026-02-30T10:00:00+08:00", "2026-01-01", "2026-01-01T10:00:00", "2026-01-01T25:00:00Z", "2026-01-01T10:00:60Z", "2026-01-01T10:00:00+14:01"])
    func invalidDatesStayPending(_ date: String) throws {
        let (book, batch, _) = try fixture([raw(date: date)])
        if case .blocked = ImportEngine.review(batch.rows[0], batch: batch, in: book, now: now) {} else { Issue.record("Expected blocked date") }
    }

    @Test func datesRequireExplicitZoneAndPreserveFractionalSeconds() throws {
        let first = try #require(ImportCSV.date("2024-02-29T12:30:00.123456+08:00"))
        let second = try #require(ImportCSV.date("2024-02-29T04:30:00.123456Z"))
        #expect(first == second)
        #expect(ImportCSV.date("2025-02-29T12:30:00Z") == nil)
    }

    @Test func sourceStatesSpecialKindsZeroFutureAndUnknownCurrencyAreHeld() throws {
        for (column, value) in [(10, "failed"), (10, "closed"), (2, "refund"), (2, "loanPayment"), (2, "stock"), (3, "0"), (3, "-1"), (3, "1+2"), (1, "2099-01-01T00:00:00Z"), (4, "JPY")] {
            var source = raw(); source[column] = value
            let (book, batch, _) = try fixture([source])
            #expect(ImportEngine.review(batch.rows[0], batch: batch, in: book, now: now) != .ready)
            #expect(throws: ImportError.self) { try commit(batch, in: book) }
        }
    }

    @Test func historicalImportPartialCommitRetryAndManualDraftStaySeparate() throws {
        let (book, batch, account) = try fixture([raw(), raw("00002", amount: "5.00")])
        #expect(book.entries.isEmpty)
        let plan = try ImportEngine.prepare(batchID: batch.id, importIDs: [batch.rows[0].id], skipIDs: [], in: book, now: now)
        let saved = try ImportEngine.commit(plan, in: book, now: now)
        #expect(try LedgerEngine.balance(of: account.id, in: saved).minorUnits == 800_000)
        #expect(saved.entries[0].occurredAt < account.openingDate)
        #expect(saved.importBatches[0].rows.map(\.state) == [.imported, .pending])
        #expect(try ImportEngine.commit(plan, in: saved, now: now) == saved)
        #expect(throws: ImportError.self) { try commit(batch, in: saved, ids: [batch.rows[0].id]) }
        let remainder = saved.importBatches[0]
        let finished = try commit(remainder, in: saved, ids: [remainder.rows[1].id])
        #expect(try LedgerEngine.balance(of: account.id, in: finished).minorUnits == 799_500)
    }

    @Test func sourceDuplicatesConflictAndDeletedEventsRemainConsumed() throws {
        let (book, batch, _) = try fixture()
        let saved = try commit(batch, in: book)
        var again = try ImportCSV.parse(ImportCSV.encode([ImportCSV.header, raw()]), name: "again", namespace: batch.namespace, at: now)
        #expect(ImportEngine.review(again.rows[0], batch: again, in: saved, now: now) == .duplicate)
        again.rows[0].raw[3] = "1.00"
        #expect(ImportEngine.review(again.rows[0], batch: again, in: saved, now: now) == .conflict)
        let deleted = try LedgerEngine.delete(entryID: saved.entries[0].id, in: saved)
        again.rows[0].raw = raw()
        #expect(ImportEngine.review(again.rows[0], batch: again, in: deleted, now: now) == .duplicate)
        var damaged = deleted; damaged.retiredOperationIDs = []
        #expect(throws: ImportError.invalidState) { try LedgerEngine.validate(damaged) }
    }

    @Test func inBatchDuplicatesRequireExplicitSkipAndSkippedRowsDoNotConsumeSource() throws {
        let (book, batch, _) = try fixture([raw(), raw()])
        #expect(ImportEngine.review(batch.rows[0], batch: batch, in: book, now: now) == .conflict)
        let skip = try ImportEngine.prepare(batchID: batch.id, importIDs: [], skipIDs: [batch.rows[1].id], in: book, now: now)
        let skipped = try ImportEngine.commit(skip, in: book, now: now)
        #expect(skipped.entries.isEmpty)
        let saved = try commit(skipped.importBatches[0], in: skipped, ids: [batch.rows[0].id])
        #expect(saved.entries.count == 1)
    }

    @Test func sameDayAmountRequiresReviewAndChangedCandidateInvalidatesConsent() throws {
        let (book, batch, _) = try fixture([raw(), raw("00002")])
        var reviewed = batch
        for index in reviewed.rows.indices {
            let review = ImportEngine.review(reviewed.rows[index], batch: batch, in: book, now: now)
            guard case .similar(let token, let count) = review else { Issue.record("Expected similar"); return }
            #expect(count == 1); reviewed.rows[index].duplicateReviewToken = token
        }
        let updated = try ImportEngine.save(reviewed, in: book, expectedVersion: 1)
        let saved = try commit(updated.importBatches[0], in: updated)
        #expect(saved.entries.count == 2)
        var next = try ImportCSV.parse(ImportCSV.encode([ImportCSV.header, raw("00003")]), name: "third", namespace: batch.namespace, at: now)
        next.rows[0].accountID = batch.rows[0].accountID; next.rows[0].categoryID = SeedData.mealsID
        guard case .similar(let token, _) = ImportEngine.review(next.rows[0], batch: next, in: saved, now: now) else { Issue.record("Expected similar"); return }
        next.rows[0].duplicateReviewToken = token
        #expect(ImportEngine.review(next.rows[0], batch: next, in: saved, now: now) == .ready)
        var changed = saved.entries[0]; changed.operationID = UUID(); changed.note = "edited"
        let edited = try LedgerEngine.replace(changed, expectedVersion: 1, in: saved)
        #expect(ImportEngine.review(next.rows[0], batch: next, in: edited, now: now) != .ready)
    }

    @Test func stagedAccountsAreCreatedOnlyWithSelectedEventsAndStalePlansFail() throws {
        var (book, batch, account) = try fixture(staged: true)
        let unused = Account(name: "未使用账户")
        batch.proposedAccounts.append(unused)
        book = try ImportEngine.save(batch, in: book, expectedVersion: 1); batch = book.importBatches[0]
        #expect(book.accounts.isEmpty)
        let plan = try ImportEngine.prepare(batchID: batch.id, importIDs: [batch.rows[0].id], skipIDs: [], in: book, now: now)
        #expect(plan.newAccountIDs == [account.id])
        var changed = batch; changed.rows[0].subjectID = UUID()
        let stale = try ImportEngine.save(changed, in: book, expectedVersion: batch.version)
        #expect(throws: ImportError.stalePreview) { try ImportEngine.commit(plan, in: stale, now: now) }
        let saved = try ImportEngine.commit(plan, in: book, now: now)
        #expect(saved.accounts == [account])
        #expect(saved.importBatches[0].proposedAccounts == [unused])
        #expect(try LedgerEngine.balance(of: account.id, in: saved).minorUnits == 800_000)
    }

    @Test func transferIsOneEventAndInactiveMappingsNeverGuessReplacement() throws {
        var (book, batch, account) = try fixture([raw(kind: "transfer")])
        let destination = Account(name: "零钱")
        book.accounts.append(destination)
        batch.rows[0].destinationAccountID = destination.id
        book = try ImportEngine.save(batch, in: book, expectedVersion: 1)
        let saved = try commit(book.importBatches[0], in: book)
        #expect(saved.entries.count == 1 && saved.entries[0].categoryID == nil)
        #expect(try LedgerEngine.balance(of: destination.id, in: saved).minorUnits == 200_000)
        account.isActive = false
        let inactive = try CatalogEditor.saveAccount(account, in: book)
        #expect(ImportEngine.review(batch.rows[0], batch: batch, in: inactive, now: now) != .ready)
    }

    @Test func completeBackupPreservesRawMappingCompletionAndUnpostedAccounts() throws {
        let (book, batch, _) = try fixture([raw(), raw("00002", amount: "1.00")], staged: true)
        let saved = try commit(batch, in: book, ids: [batch.rows[0].id])
        let snapshot = LedgerBackupSnapshot(book: saved, draft: EntryDraft(amountText: "12+("), settings: LedgerSettings())
        let files = try BackupCodec.encode(snapshot, createdAt: now)
        #expect(files.count == 23)
        #expect(try BackupCodec.decode(BackupArchive.decode(BackupArchive.encode(files))) == snapshot)
        let staged = LedgerBackupSnapshot(book: book, draft: nil, settings: LedgerSettings())
        #expect(try BackupCodec.decode(BackupCodec.encode(staged)) == staged)
    }

    @Test func oldBookAndProfileFourRestoreWithoutImportState() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(LedgerBook())) as? [String: Any])
        object.removeValue(forKey: "importBatches")
        #expect(try JSONDecoder().decode(LedgerBook.self, from: JSONSerialization.data(withJSONObject: object)).importBatches.isEmpty)
        let snapshot = LedgerBackupSnapshot(book: LedgerBook(tags: [EntryTag(name: "旅行")]), draft: EntryDraft(), settings: LedgerSettings())
        var files = try BackupCodec.encode(snapshot).filter { Set(BackupSchema.v4All.map(\.name)).contains($0.key) }
        var manifest = try BackupSchema.manifest.read(files["manifest.csv"]!)[0].values
        manifest["profile"] = "ledger-core-v4"; manifest["backup_format_version"] = "4.0"; manifest["db_schema_version"] = "4"; manifest["file_count"] = "16"
        files["manifest.csv"] = BackupCSV.encode([BackupSchema.v4Manifest.header, BackupSchema.v4Manifest.columns.map { manifest[$0.name] }])
        files["schema_dictionary.csv"] = BackupSchema.dictionaryData(for: BackupSchema.v4All)
        try rehash(&files)
        #expect(try BackupCodec.decode(files) == snapshot)
    }

    @Test func forgedCompletionOrOrphanImportRowsCannotRestore() throws {
        let (book, _, _) = try fixture()
        var files = try BackupCodec.encode(LedgerBackupSnapshot(book: book, draft: nil, settings: LedgerSettings()))
        var rows = try BackupSchema.importRows.read(files["import_rows.csv"]!).map { row in BackupSchema.importRows.columns.map { row.values[$0.name] } }
        rows[0][8] = "imported"
        files["import_rows.csv"] = BackupCSV.encode([BackupSchema.importRows.header] + rows)
        try rehash(&files)
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
        rows[0][8] = "pending"; rows[0][1] = UUID().uuidString.lowercased()
        files["import_rows.csv"] = BackupCSV.encode([BackupSchema.importRows.header] + rows)
        try rehash(&files)
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
    }

    @Test func importedReceiptCannotPointToUnrelatedLiveOperationAndCompletedRowsAreImmutable() throws {
        let (book, batch, _) = try fixture()
        let saved = try commit(batch, in: book)
        var broken = saved
        broken.importBatches[0].rows[0].id = UUID()
        #expect(throws: ImportError.invalidState) { try LedgerEngine.validate(broken) }
        var changed = saved.importBatches[0]
        changed.rows[0].categoryID = SeedData.otherExpenseID
        #expect(throws: ImportError.invalidState) { try ImportEngine.save(changed, in: saved, expectedVersion: changed.version) }
        var pending = batch; pending.rows[0].raw[3] = "1.00"
        #expect(throws: ImportError.invalidState) { try ImportEngine.save(pending, in: book, expectedVersion: 1) }
    }

    private func rehash(_ files: inout [String: Data]) throws {
        let counts: [[String?]] = try files.keys.sorted().map { name in
            let count = name == "counts.csv" ? files.count : name == "checksums.csv" ? files.count - 1 : try BackupCSV.decode(files[name]!, file: name).count - 1
            return [name, String(count)]
        }
        files["counts.csv"] = BackupCSV.encode([BackupSchema.counts.header] + counts)
        let hashes: [[String?]] = files.keys.filter { $0 != "checksums.csv" }.sorted().map { [$0, BackupSHA256.hex(files[$0]!)] }
        files["checksums.csv"] = BackupCSV.encode([BackupSchema.checksums.header] + hashes)
    }
}
