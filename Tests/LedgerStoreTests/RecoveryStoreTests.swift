import Foundation
import GRDB
import LedgerCore
import LedgerStore
import Testing

@Suite("Recovery storage and migration")
struct RecoveryStoreTests {
    private func withStore(_ body: (SQLiteLedgerStore, DatabaseQueue, String, LedgerEntry, LedgerEntry) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.sqlite").path
        let store = try SQLiteLedgerStore(path: path)
        let account = Account(name: "退款测试", openingMinor: 200_000)
        let original = LedgerEntry(kind: .expense, amount: Money(minorUnits: 100_000), accountID: account.id,
                                   categoryID: SeedData.mealsID, occurredAt: Date(timeIntervalSince1970: 1_700_000_000))
        let refund = LedgerEntry(kind: .refund, amount: Money(minorUnits: 20_000), accountID: account.id,
                                 originalEntryID: original.id)
        try store.commit(LedgerEngine.record(original, in: LedgerBook(accounts: [account])),
                         draft: EntryDraft(amountText: "12+", originalEntryID: UUID()))
        try body(store, DatabaseQueue(path: path), path, original, refund)
    }

    @Test func recoverySurvivesReopenQueryBackupAndAtomicGroupDeletion() throws {
        try withStore { store, inspection, path, original, refund in
            let saved = try store.saveEntry(refund)
            #expect(try SQLiteLedgerStore(path: path).loadBook() == saved.book)
            #expect(try store.entryPage(matching: EntryFilter(kind: .refund)).entries == [refund])
            var reordered = saved.book
            reordered.entries.reverse() // Deferred self-reference must allow child-before-parent restore.
            let snapshot = LedgerBackupSnapshot(book: reordered, draft: saved.draft, settings: saved.settings)
            let restored = try BackupCodec.decode(BackupArchive.decode(BackupArchive.encode(BackupCodec.encode(snapshot))))
            try store.commit(restored.book, draft: restored.draft, settings: restored.settings)
            let plan = try LedgerEngine.deletionPlan(entryID: original.id, includingRecoveries: true, in: saved.book)
            let deleted = try store.deleteEntries(plan)
            #expect(deleted.book.entries.isEmpty && deleted.draft == saved.draft)
            #expect(deleted.book.retiredOperationIDs.isSuperset(of: [original.operationID, refund.operationID]))
            #expect(try LedgerEngine.balance(of: original.accountID, in: deleted.book).minorUnits == 200_000)
            try inspection.read { (db: Database) throws -> Void in
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }
    }

    @Test func staleGroupAndFailedDeleteLeaveEveryRecordAndDraftIntact() throws {
        try withStore { store, inspection, path, original, refund in
            let saved = try store.saveEntry(refund)
            let plan = try LedgerEngine.deletionPlan(entryID: original.id, includingRecoveries: true, in: saved.book)
            var next = refund; next.id = UUID(); next.operationID = UUID()
            let external = try SQLiteLedgerStore(path: path)
            let changed = try external.saveEntry(next)
            #expect(throws: LedgerError.staleVersion) { try store.deleteEntries(plan) }
            #expect(try store.loadSnapshot().book == changed.book)
            let fresh = try LedgerEngine.deletionPlan(entryID: original.id, includingRecoveries: true, in: changed.book)
            try inspection.write { db in
                try db.execute(sql: "CREATE TRIGGER reject_delete BEFORE DELETE ON entries BEGIN SELECT RAISE(ABORT, 'test rollback'); END")
            }
            #expect(throws: (any Error).self) { try store.deleteEntries(fresh) }
            let after = try store.loadSnapshot()
            #expect(after.book == changed.book && after.draft == changed.draft && after.settings == changed.settings)
        }
    }

    @Test func schemaTwoMigratesWithoutRewritingPayloadAndFailureRollsBack() throws {
        try withStore { _, inspection, path, original, _ in
            try inspection.write { db in
                try db.execute(sql: "DROP TABLE import_batches")
                try db.execute(sql: "DROP INDEX entries_project")
                try db.execute(sql: "DROP TABLE entry_tags")
                try db.execute(sql: "ALTER TABLE entries DROP COLUMN project_id")
                try db.execute(sql: "DROP TABLE tags")
                try db.execute(sql: "DROP TABLE projects")
                try db.execute(sql: "DROP INDEX entries_original")
                try db.execute(sql: "ALTER TABLE entries DROP COLUMN original_entry_id")
                try db.execute(sql: "ALTER TABLE entries DROP COLUMN allows_net_recovery")
                try db.execute(sql: "DROP TABLE IF EXISTS import_rules; PRAGMA user_version = 2")
            }
            let payload = try inspection.read { try Data.fetchOne($0, sql: "SELECT payload FROM entries") }
            // A corrupt old projection must abort the whole migration, not just the opening read.
            try inspection.write { try $0.execute(sql: "UPDATE entries SET amount_minor = amount_minor + 1") }
            #expect(throws: (any Error).self) { try SQLiteLedgerStore(path: path) }
            try inspection.read { (db: Database) throws -> Void in
                #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 2)
                let names = try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('entries')")
                #expect(!names.contains("original_entry_id"))
            }
            try inspection.write { try $0.execute(sql: "UPDATE entries SET amount_minor = amount_minor - 1") }
            let opened = try SQLiteLedgerStore(path: path)
            #expect(try opened.loadBook().entries == [original])
            try inspection.read { (db: Database) throws -> Void in
                #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == SQLiteLedgerStore.schemaVersion)
                #expect(try Data.fetchOne(db, sql: "SELECT payload FROM entries") == payload)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }
    }

    @Test func linkedProjectionTamperingIsRejected() throws {
        try withStore { store, inspection, _, _, refund in
            _ = try store.saveEntry(refund)
            try inspection.write { db in
                try db.execute(sql: "UPDATE entries SET original_entry_id = NULL WHERE id = ?", arguments: [refund.id.uuidString])
            }
            #expect(throws: LedgerStoreError.corruptData("entries")) { try store.loadSnapshot() }
        }
    }
}
