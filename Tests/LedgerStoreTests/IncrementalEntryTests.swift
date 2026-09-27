import Foundation
import GRDB
import LedgerCore
import LedgerStore
import Testing

/// SQL guards prove that a successful save did not rewrite unrelated rows. These
/// Apple-only tests supplement, rather than replace, repository draft-revision tests.
@Suite("Incremental entry persistence")
struct IncrementalEntryTests {
    @Test func insertionOnlyAppendsItsEntryAndOperationAndAtomicallyClearsDraft() throws {
        try withFixture { store, inspection, fixture, path in
            let entry = newEntry(in: fixture)
            let before = try entryRows(inspection)
            try protectCatalog(inspection)
            try permitEntryInsert(entry.id, inspection)
            try permitOperations([entry.operationID], inspection)

            let saved = try store.saveEntry(entry, draftUpdate: .replace(nil))
            let expected = try LedgerEngine.record(entry, in: fixture.book)
            #expect(saved.book == expected)
            #expect(saved.draft == nil && saved.settings == fixture.settings)
            let after = try entryRows(inspection)
            #expect(after.count == before.count + 1)
            for (id, row) in before { #expect(after[id] == row) }
            #expect(after[entry.id.uuidString]?.position == fixture.book.entries.count)
            #expect(try operation(entry.operationID, inspection) == RegistryRow(recordID: entry.id.uuidString, kind: "entry"))
            try expectReopened(path, book: expected, draft: nil, settings: fixture.settings)
        }
    }

    @Test func editingUpdatesTargetInPlaceAndPreservesUnrelatedRowsAndDraft() throws {
        try withFixture { store, inspection, fixture, path in
            let old = fixture.book.entries[0]
            var edit = replacement(of: old)
            edit.accountID = fixture.book.accounts[1].id
            edit.categoryID = SeedData.taxiID
            edit.occurredAt = old.occurredAt.addingTimeInterval(-86_400)
            edit.createdAt = old.createdAt.addingTimeInterval(999) // The original creation time wins.
            let expected = try LedgerEngine.replace(edit, expectedVersion: old.version, in: fixture.book)
            let before = try entryRows(inspection)
            try protectCatalog(inspection)
            try denyWrites(["entry_draft"], inspection)
            try permitEntryUpdate(old.id, inspection)
            try permitOperations([old.operationID, edit.operationID], inspection)

            let saved = try store.saveEntry(edit, expectedVersion: old.version,
                                           draftUpdate: .replace(EntryDraft(amountText: "must not replace")))
            #expect(saved.book == expected && saved.draft == fixture.draft && saved.settings == fixture.settings)
            let after = try entryRows(inspection)
            #expect(after.count == before.count)
            for (id, row) in before where id != old.id.uuidString { #expect(after[id] == row) }
            let oldRow = try #require(before[old.id.uuidString])
            let newRow = try #require(after[old.id.uuidString])
            #expect(newRow.rowID == oldRow.rowID && newRow.position == oldRow.position)
            #expect(newRow.createdAt == oldRow.createdAt && newRow.version == oldRow.version + 1)
            #expect(newRow.payload != oldRow.payload)
            #expect(try operation(old.operationID, inspection) == RegistryRow(recordID: nil, kind: "retired"))
            #expect(try operation(edit.operationID, inspection) == RegistryRow(recordID: old.id.uuidString, kind: "entry"))
            try expectReopened(path, book: expected, draft: fixture.draft, settings: fixture.settings)
        }
    }

    @Test func insertionRetryAfterReopenDoesNotRewriteBusinessRowsButStillAppliesDraftPolicy() throws {
        try withFixture { store, inspection, fixture, path in
            let entry = newEntry(in: fixture)
            let first = try store.saveEntry(entry, draftUpdate: .replace(nil))
            let reopened = try SQLiteLedgerStore(path: path)
            let newer = EntryDraft(amountText: "36+(", accountID: fixture.book.accounts[0].id, note: "较新草稿")
            try reopened.saveDraft(newer)
            try protectCatalog(inspection)
            try denyWrites(["entries", "operation_registry"], inspection)
            var retry = entry
            retry.id = UUID()
            retry.createdAt = entry.createdAt.addingTimeInterval(100)
            // The engine canonicalizes identity/creation time for an otherwise identical operation retry.
            let preserved = try reopened.saveEntry(retry)
            #expect(preserved.book == first.book && preserved.draft == newer)
            let next = EntryDraft(amountText: "44", accountID: fixture.book.accounts[1].id)
            let replaced = try reopened.saveEntry(retry, draftUpdate: .replace(next))
            #expect(replaced.book == first.book && replaced.draft == next)
            let composed = EntryDraft(amountText: "45", accountID: fixture.book.accounts[0].id,
                                      title: "Caf\u{00e9}", note: "pr\u{00e9}compos\u{00e9}")
            var decomposed = composed
            decomposed.title = "Cafe\u{0301}"
            decomposed.note = "pre\u{0301}compose\u{0301}"
            #expect(composed == decomposed)
            #expect(Array(composed.title.utf8) != Array(decomposed.title.utf8))
            _ = try reopened.saveEntry(retry, draftUpdate: .replace(composed))
            let exact = try reopened.saveEntry(retry, draftUpdate: .replace(decomposed))
            let exactDraft = try #require(exact.draft)
            #expect(Array(exactDraft.title.utf8) == Array(decomposed.title.utf8))
            #expect(Array(exactDraft.note.utf8) == Array(decomposed.note.utf8))
            let verificationStore = try SQLiteLedgerStore(path: path)
            let persistedOptional = try verificationStore.loadDraft()
            let persisted = try #require(persistedOptional)
            #expect(Array(persisted.title.utf8) == Array(decomposed.title.utf8))
            #expect(Array(persisted.note.utf8) == Array(decomposed.note.utf8))
            let cleared = try reopened.saveEntry(retry, draftUpdate: .replace(nil))
            #expect(cleared.book == first.book && cleared.draft == nil && cleared.settings == fixture.settings)
            try expectReopened(path, book: first.book, draft: nil, settings: fixture.settings)
        }
    }

    @Test func editRetryAfterReopenDoesNotWriteOrIncrementVersionAndAlwaysPreservesDraft() throws {
        try withFixture { store, inspection, fixture, path in
            let old = fixture.book.entries[0]
            let edit = replacement(of: old)
            let first = try store.saveEntry(edit, expectedVersion: old.version)
            let reopened = try SQLiteLedgerStore(path: path)
            try denyWrites(allTables, inspection)
            let retried = try reopened.saveEntry(edit, expectedVersion: old.version, draftUpdate: .replace(nil))
            #expect(retried.book == first.book)
            #expect(retried.book.entries[0].version == old.version + 1)
            #expect(retried.draft == fixture.draft && retried.settings == fixture.settings)
            try expectReopened(path, book: first.book, draft: fixture.draft, settings: fixture.settings)
        }
    }

    @Test func conflictingCommandsFailBeforeAnyWriteAndPreserveAllState() throws {
        try withFixture { store, inspection, fixture, path in
            let old = fixture.book.entries[0]
            let edited = replacement(of: old)
            let current = try store.saveEntry(edited, expectedVersion: old.version)
            try denyWrites(allTables, inspection)

            var stale = replacement(of: old)
            stale.amount = Money(minorUnits: 4_400)
            #expect(throws: LedgerError.staleVersion) {
                try store.saveEntry(stale, expectedVersion: old.version, draftUpdate: .replace(nil))
            }
            var duplicate = newEntry(in: fixture)
            duplicate.id = old.id
            #expect(throws: LedgerError.duplicateID) { try store.saveEntry(duplicate, draftUpdate: .replace(nil)) }
            var retired = newEntry(in: fixture)
            retired.operationID = old.operationID
            #expect(throws: LedgerError.operationConflict) { try store.saveEntry(retired, draftUpdate: .replace(nil)) }
            var adjustmentOperation = newEntry(in: fixture)
            adjustmentOperation.operationID = fixture.book.adjustments[0].operationID
            #expect(throws: LedgerError.operationConflict) { try store.saveEntry(adjustmentOperation) }
            var changedReplay = newEntry(in: fixture)
            changedReplay.operationID = edited.operationID
            #expect(throws: LedgerError.operationConflict) { try store.saveEntry(changedReplay) }
            var invalidNewVersion = newEntry(in: fixture)
            invalidNewVersion.version = 2
            #expect(throws: LedgerError.staleVersion) { try store.saveEntry(invalidNewVersion) }

            #expect(try store.loadBook() == current.book)
            #expect(try store.loadDraft() == fixture.draft)
            #expect(try store.loadSettings() == fixture.settings)
            try expectReopened(path, book: current.book, draft: fixture.draft, settings: fixture.settings)
        }
    }

    @Test func inactiveReferencesAreRejectedForNewEntriesButRetainedWhenEditingHistory() throws {
        try withFixture { store, inspection, fixture, path in
            var historical = fixture.book
            historical.accounts[0].isActive = false
            historical.categories[historical.categories.firstIndex(where: { $0.id == SeedData.mealsID })!].isActive = false
            historical.categories[historical.categories.firstIndex(where: { $0.id == SeedData.foodID })!].isActive = false
            try store.saveBook(historical)
            let old = historical.entries[0]
            let edit = replacement(of: old)
            try protectCatalog(inspection)
            try denyWrites(["entry_draft"], inspection)
            try permitEntryUpdate(old.id, inspection)
            try permitOperations([old.operationID, edit.operationID], inspection)
            let rejected = newEntry(in: fixture)
            #expect(throws: LedgerError.inactiveAccount) { try store.saveEntry(rejected) }
            var inactiveCategory = rejected
            inactiveCategory.accountID = historical.accounts[1].id
            #expect(throws: LedgerError.invalidCategory) { try store.saveEntry(inactiveCategory) }

            let saved = try store.saveEntry(edit, expectedVersion: old.version, draftUpdate: .replace(nil))
            let expected = try LedgerEngine.replace(edit, expectedVersion: old.version, in: historical)
            #expect(saved.book == expected && saved.draft == fixture.draft && saved.settings == fixture.settings)
            try expectReopened(path, book: expected, draft: fixture.draft, settings: fixture.settings)
        }
    }

    @Test func draftDeletionFailureRollsBackInsertedEntryAndOperationThenSameCommandCanRetry() throws {
        try withFixture { store, inspection, fixture, path in
            let entry = newEntry(in: fixture)
            let before = try entryRows(inspection)
            try protectCatalog(inspection)
            try permitEntryInsert(entry.id, inspection)
            try permitOperations([entry.operationID], inspection)
            try inspection.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER reject_clear_draft BEFORE DELETE ON entry_draft
                    BEGIN SELECT RAISE(ABORT, 'injected draft delete failure'); END;
                    """)
            }
            #expect(throws: DatabaseError.self) { try store.saveEntry(entry, draftUpdate: .replace(nil)) }
            #expect(try entryRows(inspection) == before)
            #expect(try operation(entry.operationID, inspection) == nil)
            try expectReopened(path, book: fixture.book, draft: fixture.draft, settings: fixture.settings)

            try inspection.write { db in try db.execute(sql: "DROP TRIGGER reject_clear_draft") }
            let saved = try store.saveEntry(entry, draftUpdate: .replace(nil))
            let expected = try LedgerEngine.record(entry, in: fixture.book)
            #expect(saved.book == expected)
            #expect(saved.draft == nil)
        }
    }

    @Test(arguments: [false, true])
    func editingFailureBeforeOrAfterRowUpdateRollsBackOperationTransition(afterUpdate: Bool) throws {
        try withFixture { store, inspection, fixture, path in
            let old = fixture.book.entries[0]
            let edit = replacement(of: old)
            let before = try entryRows(inspection)
            try protectCatalog(inspection)
            try denyWrites(["entry_draft"], inspection)
            try permitEntryUpdate(old.id, inspection)
            try permitOperations([old.operationID, edit.operationID], inspection)
            try inspection.write { db in
                let timing = afterUpdate ? "AFTER" : "BEFORE"
                try db.execute(sql: """
                    CREATE TRIGGER reject_target_update \(timing) UPDATE ON entries
                    WHEN OLD.id = '\(old.id.uuidString)'
                    BEGIN SELECT RAISE(ABORT, 'injected entry update failure'); END;
                    """)
            }
            #expect(throws: DatabaseError.self) {
                try store.saveEntry(edit, expectedVersion: old.version, draftUpdate: .replace(nil))
            }
            #expect(try entryRows(inspection) == before)
            #expect(try operation(old.operationID, inspection) == RegistryRow(recordID: old.id.uuidString, kind: "entry"))
            #expect(try operation(edit.operationID, inspection) == nil)
            try expectReopened(path, book: fixture.book, draft: fixture.draft, settings: fixture.settings)

            try inspection.write { db in try db.execute(sql: "DROP TRIGGER reject_target_update") }
            let saved = try store.saveEntry(edit, expectedVersion: old.version)
            let expected = try LedgerEngine.replace(edit, expectedVersion: old.version, in: fixture.book)
            #expect(saved.book == expected)
        }
    }

    @Test func internallyConsistentSilentTriggerMutationIsRejectedAndRolledBack() throws {
        try withFixture { store, inspection, fixture, path in
            let old = fixture.book.entries[0]
            let edit = replacement(of: old)
            let expected = try LedgerEngine.replace(edit, expectedVersion: old.version, in: fixture.book)
            var tampered = expected.entries[0]
            tampered.amount = Money(minorUnits: 9_999, currency: edit.amount.currency)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let tamperedPayload = try encoder.encode(tampered).map { String(format: "%02x", $0) }.joined()
            let before = try entryRows(inspection)
            try protectCatalog(inspection)
            try denyWrites(["entry_draft"], inspection)
            try permitEntryUpdate(old.id, inspection)
            try permitOperations([old.operationID, edit.operationID], inspection)
            try inspection.write { db in
                // Both the projected amount and Codable payload agree. Ordinary row/FK
                // checks pass; comparison with the commanded domain result must reject it.
                try db.execute(sql: """
                    CREATE TRIGGER silently_change_target AFTER UPDATE OF amount_minor ON entries
                    WHEN NEW.id = '\(old.id.uuidString)' AND NEW.amount_minor = \(edit.amount.minorUnits)
                    BEGIN
                        UPDATE entries SET amount_minor = 9999, payload = X'\(tamperedPayload)'
                        WHERE id = '\(old.id.uuidString)';
                    END;
                    """)
            }
            #expect(throws: LedgerStoreError.corruptData("entry_commit")) {
                try store.saveEntry(edit, expectedVersion: old.version)
            }
            #expect(try entryRows(inspection) == before)
            #expect(try operation(old.operationID, inspection) == RegistryRow(recordID: old.id.uuidString, kind: "entry"))
            #expect(try operation(edit.operationID, inspection) == nil)
            try expectReopened(path, book: fixture.book, draft: fixture.draft, settings: fixture.settings)
        }
    }

    @Test func preserveDraftDoesNotEvenRewriteTheExistingDraftOrSettings() throws {
        try withFixture { store, inspection, fixture, path in
            let entry = newEntry(in: fixture)
            try protectCatalog(inspection)
            try denyWrites(["entry_draft"], inspection)
            try permitEntryInsert(entry.id, inspection)
            try permitOperations([entry.operationID], inspection)
            let saved = try store.saveEntry(entry)
            let expected = try LedgerEngine.record(entry, in: fixture.book)
            #expect(saved.book == expected)
            #expect(saved.draft == fixture.draft && saved.settings == fixture.settings)
            try expectReopened(path, book: saved.book, draft: fixture.draft, settings: fixture.settings)
        }
    }

    @Test func wholeBookSchemaTwoSnapshotSupportsIncrementalSavesAndBackup() throws {
        try withFixture { store, inspection, fixture, path in
            // This covers the retained whole-book API on the current schema.
            // Genuine schema-1 migration is covered by SQLiteLedgerStoreTests.
            var legacy = fixture.book
            legacy.categories.reverse()
            try store.commit(legacy, draft: fixture.draft, settings: fixture.settings)
            let reopened = try SQLiteLedgerStore(path: path)
            try inspection.read { (db: Database) throws -> Void in
                #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 2)
                #expect(try Int.fetchOne(db, sql: "PRAGMA application_id") == 0x4C444752)
            }
            let entry = newEntry(in: fixture)
            let nextDraft = EntryDraft(amountText: "8/(", accountID: legacy.accounts[0].id, title: "继续记账")
            try protectCatalog(inspection)
            try permitEntryInsert(entry.id, inspection)
            try permitOperations([entry.operationID], inspection)
            let saved = try reopened.saveEntry(entry, draftUpdate: .replace(nextDraft))
            let expected = try LedgerEngine.record(entry, in: legacy)
            #expect(saved.book == expected)
            #expect(saved.draft == nextDraft && saved.settings == fixture.settings)
            let backup = LedgerBackupSnapshot(book: saved.book, draft: saved.draft, settings: saved.settings)
            #expect(try BackupCodec.decode(BackupCodec.encode(backup)) == backup)
            try expectReopened(path, book: saved.book, draft: nextDraft, settings: fixture.settings)
            try inspection.read { (db: Database) throws -> Void in
                #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 2)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }
    }

    private struct Fixture {
        let book: LedgerBook
        let draft: EntryDraft
        let settings: LedgerSettings
    }

    private func fixture() throws -> Fixture {
        let date = Date(timeIntervalSinceReferenceDate: 812_300_000.25)
        let cash = Account(name: "合成钱包", kind: .wallet, openingMinor: 100_000, openingDate: date)
        let bank = Account(name: "合成银行卡", openingMinor: 100_000, openingDate: date)
        let card = Account(name: "合成信用卡", kind: .creditCard, nature: .liability,
                           openingMinor: 3_000, openingDate: date)
        let target = LedgerEntry(kind: .expense, amount: Money(minorUnits: 2_800), accountID: cash.id,
                                 categoryID: SeedData.mealsID, occurredAt: date, createdAt: date,
                                 title: "午餐", note: "原始备注")
        let transfer = LedgerEntry(kind: .transfer, amount: Money(minorUnits: 5_000), accountID: bank.id,
                                   destinationAccountID: card.id, occurredAt: date, createdAt: date)
        let deleted = LedgerEntry(kind: .income, amount: Money(minorUnits: 4_000), accountID: cash.id,
                                  categoryID: SeedData.salaryIncomeID, occurredAt: date, createdAt: date)
        var book = LedgerBook(accounts: [cash, bank, card])
        for entry in [target, transfer, deleted] { book = try LedgerEngine.record(entry, in: book) }
        book = try LedgerEngine.delete(entryID: deleted.id, in: book)
        book = try LedgerEngine.adjustBalance(accountID: bank.id, to: Money(minorUnits: 92_000),
                                              operationID: UUID(), at: date, note: "必须保留的更正", in: book)
        let draft = EntryDraft(amountText: "18+(", accountID: cash.id, expenseCategoryID: SeedData.mealsID,
                               occurredAt: date, title: "未完成草稿", note: "必须保留")
        return Fixture(book: book, draft: draft, settings: LedgerSettings(defaultAccountID: cash.id))
    }

    private func newEntry(in fixture: Fixture) -> LedgerEntry {
        let date = fixture.book.accounts[0].openingDate.addingTimeInterval(86_400)
        return LedgerEntry(kind: .expense, amount: Money(minorUnits: 2_010), accountID: fixture.book.accounts[0].id,
                           categoryID: SeedData.mealsID, occurredAt: date, createdAt: date,
                           title: "新记录", note: "中文，\"引号\"\n第二行")
    }

    private func replacement(of original: LedgerEntry) -> LedgerEntry {
        var edit = original
        edit.operationID = UUID()
        edit.amount = Money(minorUnits: 3_300, currency: original.amount.currency)
        edit.title = "更正后的标题"
        return edit
    }

    private let catalogTables = ["accounts", "subjects", "categories", "adjustments", "ledger_settings"]
    private var allTables: [String] { catalogTables + ["entries", "operation_registry", "entry_draft"] }

    private func protectCatalog(_ inspection: DatabaseQueue) throws { try denyWrites(catalogTables, inspection) }

    private func denyWrites(_ tables: [String], _ inspection: DatabaseQueue) throws {
        try inspection.write { db in
            for table in tables {
                for action in ["INSERT", "UPDATE", "DELETE"] {
                    try db.execute(sql: """
                        CREATE TRIGGER deny_\(table)_\(action.lowercased()) BEFORE \(action) ON \(table)
                        BEGIN SELECT RAISE(ABORT, 'unexpected write to protected table'); END;
                        """)
                }
            }
        }
    }

    private func permitEntryInsert(_ id: UUID, _ inspection: DatabaseQueue) throws {
        try inspection.write { db in
            try db.execute(sql: """
                CREATE TRIGGER guard_entry_insert BEFORE INSERT ON entries WHEN NEW.id != '\(id.uuidString)'
                BEGIN SELECT RAISE(ABORT, 'unexpected entry insertion'); END;
                CREATE TRIGGER guard_entry_update BEFORE UPDATE ON entries
                BEGIN SELECT RAISE(ABORT, 'unexpected entry update'); END;
                CREATE TRIGGER guard_entry_delete BEFORE DELETE ON entries
                BEGIN SELECT RAISE(ABORT, 'unexpected entry deletion'); END;
                """)
        }
    }

    private func permitEntryUpdate(_ id: UUID, _ inspection: DatabaseQueue) throws {
        try inspection.write { db in
            try db.execute(sql: """
                CREATE TRIGGER guard_entry_insert BEFORE INSERT ON entries
                BEGIN SELECT RAISE(ABORT, 'edit must not insert or replace entries'); END;
                CREATE TRIGGER guard_entry_delete BEFORE DELETE ON entries
                BEGIN SELECT RAISE(ABORT, 'edit must not delete entries'); END;
                CREATE TRIGGER guard_entry_update BEFORE UPDATE ON entries
                WHEN OLD.id != '\(id.uuidString)' OR NEW.id != '\(id.uuidString)'
                BEGIN SELECT RAISE(ABORT, 'edit touched an unrelated entry'); END;
                """)
        }
    }

    private func permitOperations(_ ids: [UUID], _ inspection: DatabaseQueue) throws {
        let allowed = ids.map { "'\($0.uuidString)'" }.joined(separator: ",")
        try inspection.write { db in
            try db.execute(sql: """
                CREATE TRIGGER guard_operation_insert BEFORE INSERT ON operation_registry
                WHEN NEW.operation_id NOT IN (\(allowed))
                BEGIN SELECT RAISE(ABORT, 'unrelated operation insert'); END;
                CREATE TRIGGER guard_operation_update BEFORE UPDATE ON operation_registry
                WHEN OLD.operation_id NOT IN (\(allowed)) OR NEW.operation_id NOT IN (\(allowed))
                BEGIN SELECT RAISE(ABORT, 'unrelated operation update'); END;
                CREATE TRIGGER guard_operation_delete BEFORE DELETE ON operation_registry
                WHEN OLD.operation_id NOT IN (\(allowed))
                BEGIN SELECT RAISE(ABORT, 'unrelated operation delete'); END;
                """)
        }
    }

    private struct StoredEntry: Equatable, Sendable {
        let rowID: Int64
        let position: Int
        let createdAt: Double
        let version: Int
        let payload: Data
    }

    private func entryRows(_ inspection: DatabaseQueue) throws -> [String: StoredEntry] {
        try inspection.read { (db: Database) throws -> [String: StoredEntry] in
            var result: [String: StoredEntry] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, rowid AS stored_rowid, position, created_at, version, payload FROM entries") {
                let id: String = row["id"]
                result[id] = StoredEntry(rowID: row["stored_rowid"], position: row["position"],
                                         createdAt: row["created_at"], version: row["version"], payload: row["payload"])
            }
            return result
        }
    }

    private struct RegistryRow: Equatable, Sendable {
        let recordID: String?
        let kind: String
    }

    private func operation(_ id: UUID, _ inspection: DatabaseQueue) throws -> RegistryRow? {
        try inspection.read { (db: Database) throws -> RegistryRow? in
            guard let row = try Row.fetchOne(db, sql: "SELECT record_id, record_kind FROM operation_registry WHERE operation_id = ?",
                                            arguments: [id.uuidString]) else { return nil }
            return RegistryRow(recordID: row["record_id"], kind: row["record_kind"])
        }
    }

    private func expectReopened(_ path: String, book: LedgerBook, draft: EntryDraft?, settings: LedgerSettings) throws {
        let reopened = try SQLiteLedgerStore(path: path)
        #expect(try reopened.loadBook() == book)
        #expect(try reopened.loadDraft() == draft)
        #expect(try reopened.loadSettings() == settings)
        let inspection = try DatabaseQueue(path: path)
        try inspection.read { (db: Database) throws -> Void in
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    private func withFixture(_ body: (SQLiteLedgerStore, DatabaseQueue, Fixture, String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IncrementalEntryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.sqlite").path
        let fixture = try fixture()
        let store = try SQLiteLedgerStore(path: path)
        try store.commit(fixture.book, draft: fixture.draft, settings: fixture.settings)
        let inspection = try DatabaseQueue(path: path)
        try body(store, inspection, fixture, path)
    }
}
