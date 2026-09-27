import Foundation
import GRDB
import LedgerCore
import LedgerStore
import Testing

@Suite("Import persistence and transactions")
struct ImportStoreTests {
    @Test func labelPreviewIsAtomicPreservesManualDraftAndPostsOrderedLinks() throws {
        try withStore { store, inspection, path in
            let a = EntryTag(name: "旅行"), b = EntryTag(name: "工作"), project = EntryProject(name: "出行")
            let manual = EntryDraft(amountText: "12+(")
            try store.commit(LedgerBook(tags: [a, b], projects: [project]), draft: manual)
            let batch = try stagedBatch()
            let staged = try store.saveImport(batch)
            let plan = try ImportEngine.prepareLabels(batchID: batch.id, rowIDs: [batch.rows[0].id], tags: .replace([b.id, a.id]), project: .set(project.id), in: staged.book)
            try inspection.write { try $0.execute(sql: "CREATE TRIGGER reject_labels BEFORE INSERT ON import_batches BEGIN SELECT RAISE(ABORT, 'injected'); END") }
            #expect(throws: (any Error).self) { try store.commitImportLabels(plan) }
            #expect(try store.loadSnapshot().book == staged.book)
            #expect(try store.loadSnapshot().draft == manual)
            try inspection.write { try $0.execute(sql: "DROP TRIGGER reject_labels") }
            let mapped = try store.commitImportLabels(plan)
            #expect(mapped.book.importBatches[0].rows[0].tagIDs == [b.id, a.id])
            #expect(mapped.book.entries.isEmpty && mapped.book.accounts.isEmpty && mapped.draft == manual)
            #expect(try SQLiteLedgerStore(path: path).loadBook() == mapped.book)
            #expect(throws: ImportError.stalePreview) { try store.commitImportLabels(plan) }
            let posting = try ImportEngine.prepare(batchID: batch.id, importIDs: [batch.rows[0].id], skipIDs: [], in: mapped.book)
            let posted = try store.commitImport(posting)
            #expect(posted.book.entries[0].tagIDs == [b.id, a.id] && posted.book.entries[0].projectID == project.id)
            try inspection.read { (db: Database) throws -> Void in
                #expect(try String.fetchAll(db, sql: "SELECT tag_id FROM entry_tags ORDER BY position") == [b.id.uuidString, a.id.uuidString])
            }
        }
    }

    @Test func schemaFiveDecodesAbsentLabelsWithoutRewritingPayloadAndRollsBackFailure() throws {
        try withStore { store, inspection, path in
            let batch = try stagedBatch()
            let saved = try store.saveImport(batch)
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(batch)) as? [String: Any])
            var rows = try #require(object["rows"] as? [[String: Any]])
            for index in rows.indices { rows[index].removeValue(forKey: "tagIDs"); rows[index].removeValue(forKey: "projectID") }
            object["rows"] = rows
            let oldPayload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try inspection.write { try $0.execute(sql: "UPDATE import_batches SET payload = ?; PRAGMA user_version = 5", arguments: [Data("invalid JSON".utf8)]) }
            #expect(throws: LedgerStoreError.corruptData("import_batches")) { try SQLiteLedgerStore(path: path) }
            try inspection.read { (db: Database) throws -> Void in
                #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 5)
            }
            try inspection.write { try $0.execute(sql: "UPDATE import_batches SET payload = ?", arguments: [oldPayload]) }
            let reopened = try SQLiteLedgerStore(path: path).loadSnapshot()
            #expect(reopened.book == saved.book)
            #expect(reopened.book.importBatches[0].rows[0].tagIDs.isEmpty)
            try inspection.read { (db: Database) throws -> Void in
                #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == SQLiteLedgerStore.schemaVersion)
                #expect(try Data.fetchOne(db, sql: "SELECT payload FROM import_batches") == oldPayload)
            }
        }
    }

    private func withStore(_ body: (SQLiteLedgerStore, DatabaseQueue, String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.sqlite").path
        try body(SQLiteLedgerStore(path: path), DatabaseQueue(path: path), path)
    }
    private func stagedBatch() throws -> ImportBatch {
        var batch = try ImportCSV.parse(ImportCSV.template, name: "sample.csv", namespace: "样本银行卡")
        let account = Account(name: "新银行卡", openingMinor: 10_000)
        batch.proposedAccounts = [account]
        batch.rows[0].accountID = account.id; batch.rows[0].categoryID = SeedData.mealsID
        return batch
    }

    @Test func draftReopensAndFailedCommitRollsBackAccountsEventsAndStatus() throws {
        try withStore { store, inspection, path in
            let manual = EntryDraft(amountText: "12+(", note: "手动草稿")
            try store.saveDraft(manual)
            let batch = try stagedBatch()
            let staged = try store.saveImport(batch)
            #expect(staged.book.accounts.isEmpty && staged.book.entries.isEmpty && staged.draft == manual)
            #expect(try SQLiteLedgerStore(path: path).loadBook().importBatches == [batch])
            let plan = try ImportEngine.prepare(batchID: batch.id, importIDs: [batch.rows[0].id], skipIDs: [], in: staged.book)
            try inspection.write { try $0.execute(sql: "CREATE TRIGGER reject_import BEFORE INSERT ON entries BEGIN SELECT RAISE(ABORT, 'injected'); END") }
            #expect(throws: (any Error).self) { try store.commitImport(plan) }
            let failed = try store.loadSnapshot()
            #expect(failed.book == staged.book && failed.draft == manual)
            try inspection.read { (db: Database) throws -> Void in
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM operation_registry") == 0)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM accounts") == 0)
            }
            try inspection.write { try $0.execute(sql: "DROP TRIGGER reject_import") }
            let saved = try store.commitImport(plan)
            #expect(saved.book.importBatches[0].rows[0].state == .imported && saved.draft == manual)
            #expect(try LedgerEngine.balance(of: batch.proposedAccounts[0].id, in: saved.book).minorUnits == 7_990)
            #expect(try store.commitImport(plan).book == saved.book)
            let reopened = try SQLiteLedgerStore(path: path).loadSnapshot()
            #expect(reopened.book == saved.book && reopened.draft == manual)
        }
    }

    @Test func concurrentBusinessEditRejectsPreviewAndBackupIncludesUnfinishedBatch() throws {
        try withStore { store, _, _ in
            let batch = try stagedBatch()
            let staged = try store.saveImport(batch)
            let plan = try ImportEngine.prepare(batchID: batch.id, importIDs: [batch.rows[0].id], skipIDs: [], in: staged.book)
            var changed = batch; changed.rows[0].categoryID = SeedData.otherExpenseID
            let current = try store.saveImport(changed, expectedVersion: 1)
            #expect(throws: ImportError.stalePreview) { try store.commitImport(plan) }
            #expect(try store.loadBook() == current.book)
            let backup = LedgerBackupSnapshot(book: current.book, draft: current.draft, settings: current.settings)
            let decoded = try BackupCodec.decode(BackupArchive.decode(BackupArchive.encode(BackupCodec.encode(backup))))
            try store.commit(LedgerBook(), draft: nil)
            try store.commit(decoded.book, draft: decoded.draft, settings: decoded.settings)
            #expect(try store.loadBook() == current.book)
        }
    }

    @Test func importedSourceSurvivesEntryDeletionAndProjectionTamperingFails() throws {
        try withStore { store, inspection, _ in
            let batch = try stagedBatch()
            let staged = try store.saveImport(batch)
            let plan = try ImportEngine.prepare(batchID: batch.id, importIDs: [batch.rows[0].id], skipIDs: [], in: staged.book)
            let saved = try store.commitImport(plan)
            let deletion = try LedgerEngine.deletionPlan(entryID: batch.rows[0].id, in: saved.book)
            let deleted = try store.deleteEntries(deletion)
            let again = try ImportCSV.parse(ImportCSV.template, name: "again", namespace: batch.namespace)
            #expect(ImportEngine.review(again.rows[0], batch: again, in: deleted.book) == .duplicate)
            try inspection.write { try $0.execute(sql: "UPDATE import_batches SET version = version + 1") }
            #expect(throws: LedgerStoreError.corruptData("import_batches")) { try store.loadSnapshot() }
        }
    }

    @Test func schemaFourMigrationIsAtomicAndPreservesPayloads() throws {
        try withStore { store, inspection, path in
            let account = Account(name: "旧账户")
            let entry = LedgerEntry(kind: .expense, amount: Money(minorUnits: 100), accountID: account.id, categoryID: SeedData.mealsID)
            let book = LedgerBook(accounts: [account], entries: [entry])
            let draft = EntryDraft(amountText: "12+")
            try store.commit(book, draft: draft)
            try inspection.write { try $0.execute(sql: "DROP TABLE import_batches; PRAGMA user_version = 4") }
            let payloads = try inspection.read { db in
                (try Data.fetchOne(db, sql: "SELECT payload FROM entries"), try Data.fetchOne(db, sql: "SELECT payload FROM entry_draft"))
            }
            try inspection.write { try $0.execute(sql: "UPDATE entry_draft SET payload = ?", arguments: [Data("bad JSON".utf8)]) }
            #expect(throws: LedgerStoreError.corruptData("entry_draft")) { try SQLiteLedgerStore(path: path) }
            try inspection.read { (db: Database) throws -> Void in
                #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 4)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name='import_batches'") == 0)
            }
            try inspection.write { try $0.execute(sql: "UPDATE entry_draft SET payload = ?", arguments: [payloads.1]) }
            let opened = try SQLiteLedgerStore(path: path).loadSnapshot()
            #expect(opened.book == book && opened.draft == draft)
            try inspection.read { (db: Database) throws -> Void in
                #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == SQLiteLedgerStore.schemaVersion)
                #expect(try Data.fetchOne(db, sql: "SELECT payload FROM entries") == payloads.0)
                #expect(try Data.fetchOne(db, sql: "SELECT payload FROM entry_draft") == payloads.1)
            }
        }
    }
}
