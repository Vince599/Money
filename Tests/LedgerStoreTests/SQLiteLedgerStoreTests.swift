import Foundation
import GRDB
import LedgerCore
import LedgerStore
import Testing

/// These tests require the Apple-only LedgerStore target and GRDB. They are not
/// included in Windows core-test results; run `swift test` on macOS as well.
@Suite("SQLite ledger persistence")
struct SQLiteLedgerStoreTests {
    @Test func firstLaunchSeedsOnlyTheEditableDirectory() throws {
        try withDatabase { path in
            var saved = LedgerBook()
            do {
                let store = try SQLiteLedgerStore(path: path)
                let initial = try store.loadBook()
                #expect(initial.accounts.isEmpty)
                #expect(initial.entries.isEmpty)
                #expect(initial.adjustments.isEmpty)
                #expect(initial.retiredOperationIDs.isEmpty)
                #expect(initial.subjects == SeedData.subjects)
                #expect(initial.categories == SeedData.categories)
                #expect(try store.loadDraft() == nil)
                #expect(try store.loadSettings() == LedgerSettings())
                saved = initial
                saved.subjects[0].name = "我的主体"
                saved.categories[0].name = "自定义餐饮"
                saved.categories.reverse() // Display order need not be parent-first.
                try store.saveBook(saved)
            }
            let reopened = try SQLiteLedgerStore(path: path)
            #expect(try reopened.loadBook() == saved)
            let inspection = try DatabaseQueue(path: path)
            try inspection.read { (db: Database) throws -> Void in
                #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == SQLiteLedgerStore.schemaVersion)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM accounts") == 0)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entries") == 0)
            }
        }
    }

    @Test func exactIntegerAmountsDatesAndUnicodeSurviveReopening() throws {
        try withDatabase { path in
            let date = Date(timeIntervalSinceReferenceDate: 812_345_678.123456)
            let maximum = Account(name: "最大余额", openingMinor: .max, openingDate: date,
                                  institutionID: "icbc", templateID: "cn.icbc.debit", iconID: "brand.icbc")
            let minimum = Account(name: "最小余额", openingMinor: .min, openingDate: date,
                                  institutionID: "future.institution", templateID: "future.template", iconID: "future.icon")
            let largeMinor: Int64 = 9_007_199_254_740_993 // Cannot be represented exactly by Double.
            let entry = LedgerEntry(
                kind: .expense, amount: Money(minorUnits: largeMinor), accountID: maximum.id,
                categoryID: SeedData.mealsID, occurredAt: date, createdAt: date,
                title: "中文，逗号与\"引号\"", note: "第一行\n第二行 🍜")
            var expected = try LedgerEngine.record(entry, in: LedgerBook(accounts: [maximum, minimum]))
            expected = try LedgerEngine.adjustBalance(
                accountID: maximum.id, to: Money(minorUnits: 123_456_789_012_345),
                operationID: UUID(), at: date, note: "余额更正", in: expected)
            do {
                let store = try SQLiteLedgerStore(path: path)
                try store.saveBook(expected)
            }
            let reopened = try SQLiteLedgerStore(path: path)
            #expect(try reopened.loadBook() == expected)
            let inspection = try DatabaseQueue(path: path)
            try inspection.read { (db: Database) throws -> Void in
                #expect(try Int64.fetchOne(db, sql: "SELECT amount_minor FROM entries") == largeMinor)
                #expect(try String.fetchOne(db, sql: "SELECT typeof(amount_minor) FROM entries") == "integer")
                #expect(try Int64.fetchOne(db, sql: "SELECT MIN(opening_minor) FROM accounts") == Int64.min)
                #expect(try Int64.fetchOne(db, sql: "SELECT MAX(opening_minor) FROM accounts") == Int64.max)
                #expect(try String.fetchOne(db, sql: "SELECT institution_id FROM accounts WHERE id = ?",
                                            arguments: [maximum.id.uuidString]) == "icbc")
                #expect(try String.fetchOne(db, sql: "SELECT icon_id FROM accounts WHERE id = ?",
                                            arguments: [minimum.id.uuidString]) == "future.icon")
            }
        }
    }

    @Test func bookOnlySavesPreserveDraftAndSettings() throws {
        try withDatabase { path in
            let store = try SQLiteLedgerStore(path: path)
            let book = try fixture()
            let draft = EntryDraft(amountText: "28.", accountID: book.accounts[0].id, note: "输入未完成")
            let settings = LedgerSettings(defaultAccountID: book.accounts[0].id)
            try store.saveDraft(draft)
            try store.saveSettings(settings)
            try store.saveBook(book)
            #expect(try store.loadDraft() == draft)
            #expect(try store.loadSettings() == settings)
            let reopened = try SQLiteLedgerStore(path: path)
            #expect(try reopened.loadDraft() == draft)
            #expect(try reopened.loadSettings() == settings)
        }
    }

    @Test func commitSavesBookAndNextDraftAndOptionallySettings() throws {
        try withDatabase { path in
            let store = try SQLiteLedgerStore(path: path)
            let book = try fixture()
            let next = EntryDraft(accountID: book.accounts[0].id)
            let settings = LedgerSettings(defaultAccountID: book.accounts[0].id)
            try store.commit(book, draft: next, settings: settings)
            #expect(try store.loadBook() == book)
            #expect(try store.loadDraft() == next)
            #expect(try store.loadSettings() == settings)
            try store.commit(book, draft: nil)
            #expect(try store.loadDraft() == nil)
            #expect(try store.loadSettings() == settings)
        }
    }

    @Test func databaseFailureAfterBookWritesRollsBackBookAndDraft() throws {
        try withDatabase { path in
            let store = try SQLiteLedgerStore(path: path)
            let original = try fixture()
            let draft = EntryDraft(amountText: "99", note: "必须保留")
            try store.commit(original, draft: draft)
            let inspection = try DatabaseQueue(path: path)
            try inspection.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER reject_draft_delete BEFORE DELETE ON entry_draft
                    BEGIN SELECT RAISE(ABORT, 'injected disk-write failure'); END;
                    """)
            }
            var changed = original
            changed.accounts[0].name = "不会提交的改名"
            #expect(throws: DatabaseError.self) { try store.commit(changed, draft: nil) }
            #expect(try store.loadBook() == original)
            #expect(try store.loadDraft() == draft)
            let reopened = try SQLiteLedgerStore(path: path)
            #expect(try reopened.loadBook() == original)
            #expect(try reopened.loadDraft() == draft)
        }
    }

    @Test func settingsFailureRollsBackNewAccountAndClearedDraft() throws {
        try withDatabase { path in
            let store = try SQLiteLedgerStore(path: path)
            let original = try store.loadBook()
            let originalSettings = try store.loadSettings()
            let draft = EntryDraft(amountText: "12", title: "尚未保存")
            try store.saveDraft(draft)
            let inspection = try DatabaseQueue(path: path)
            try inspection.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER reject_settings_update BEFORE UPDATE ON ledger_settings
                    BEGIN SELECT RAISE(ABORT, 'injected settings failure'); END;
                    """)
            }
            var changed = original
            let account = Account(name: "微信", kind: .wallet)
            changed.accounts.append(account)
            #expect(throws: DatabaseError.self) {
                try store.commit(changed, draft: nil, settings: LedgerSettings(defaultAccountID: account.id))
            }
            #expect(try store.loadBook() == original)
            #expect(try store.loadDraft() == draft)
            #expect(try store.loadSettings() == originalSettings)
        }
    }

    @Test func invalidBookDoesNotClearDraftOrPartiallyReplaceCollections() throws {
        try withDatabase { path in
            let store = try SQLiteLedgerStore(path: path)
            let original = try fixture()
            let draft = EntryDraft(amountText: "24", accountID: original.accounts[0].id)
            try store.commit(original, draft: draft)
            var invalid = original
            invalid.accounts.removeAll()
            #expect(throws: LedgerError.accountNotFound) { try store.commit(invalid, draft: nil) }
            #expect(try store.loadBook() == original)
            #expect(try store.loadDraft() == draft)
        }
    }

    @Test func retiredOperationsPersistWithoutDeletedContentsAndRejectReplay() throws {
        try withDatabase { path in
            let store = try SQLiteLedgerStore(path: path)
            let original = try fixture()
            let entry = original.entries[0]
            let deleted = try LedgerEngine.delete(entryID: entry.id, in: original)
            try store.commit(deleted, draft: nil)
            let reopened = try SQLiteLedgerStore(path: path)
            let restored = try reopened.loadBook()
            #expect(restored == deleted)
            #expect(restored.retiredOperationIDs.contains(entry.operationID))
            #expect(throws: LedgerError.operationConflict) { try LedgerEngine.record(entry, in: restored) }
            let inspection = try DatabaseQueue(path: path)
            try inspection.read { (db: Database) throws -> Void in
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entries") == 0)
                #expect(try String.fetchOne(db, sql: "SELECT operation_id FROM operation_registry") == entry.operationID.uuidString)
                #expect(try String.fetchOne(db, sql: "SELECT record_kind FROM operation_registry") == "retired")
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM operation_registry WHERE record_id IS NOT NULL") == 0)
            }
        }
    }

    @Test func retryIsStillIdempotentAfterStoreReopens() throws {
        try withDatabase { path in
            let original = try fixture()
            try SQLiteLedgerStore(path: path).saveBook(original)
            let reopened = try SQLiteLedgerStore(path: path)
            let retry = try LedgerEngine.record(original.entries[0], in: reopened.loadBook())
            try reopened.commit(retry, draft: nil)
            #expect(try reopened.loadBook() == original)
            let inspection = try DatabaseQueue(path: path)
            #expect(throws: DatabaseError.self) {
                try inspection.write { db in
                    try db.execute(sql: """
                        INSERT INTO operation_registry (operation_id, record_id, record_kind)
                        VALUES (?, ?, 'adjustment')
                        """, arguments: [original.entries[0].operationID.uuidString, UUID().uuidString])
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func corruptedPayloadOrMismatchedMoneyIsRejected(corruptPayload: Bool) throws {
        try withDatabase { path in
            let store = try SQLiteLedgerStore(path: path)
            try store.saveBook(fixture())
            let inspection = try DatabaseQueue(path: path)
            try inspection.write { db in
                if corruptPayload {
                    try db.execute(sql: "UPDATE entries SET payload = ?", arguments: [Data("not JSON".utf8)])
                } else {
                    try db.execute(sql: "UPDATE entries SET amount_minor = amount_minor + 1")
                }
            }
            #expect(throws: LedgerStoreError.corruptData("entries")) { try store.loadBook() }
            #expect(throws: LedgerStoreError.corruptData("entries")) { try SQLiteLedgerStore(path: path) }
        }
    }

    @Test(arguments: ["institution_id", "template_id", "icon_id"])
    func mismatchedAccountPresentationProjectionIsRejected(column: String) throws {
        try withDatabase { path in
            let store = try SQLiteLedgerStore(path: path)
            var book = try fixture()
            book.accounts[0].institutionID = "future.institution"
            book.accounts[0].templateID = "future.template"
            book.accounts[0].iconID = "future.icon"
            try store.saveBook(book)
            let inspection = try DatabaseQueue(path: path)
            try inspection.write { db in
                try db.execute(sql: "UPDATE accounts SET \(column) = NULL")
            }
            #expect(throws: LedgerStoreError.corruptData("accounts")) { try store.loadSnapshot() }
            #expect(throws: LedgerStoreError.corruptData("accounts")) { try SQLiteLedgerStore.open(path: path) }
        }
    }

    @Test func schemaOneWithoutPresentationColumnsMigratesWithoutChangingExistingState() throws {
        try withDatabase { path in
            let expected = try createSchemaOneFixture(path: path)
            let inspection = try DatabaseQueue(path: path)
            let originalPayloads = try inspection.read { db in
                #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 1)
                #expect(try accountColumnNames(in: db).isDisjoint(with: ["institution_id", "template_id", "icon_id"]))
                return try Data.fetchAll(db, sql: "SELECT payload FROM accounts ORDER BY position")
            }

            let opened = try SQLiteLedgerStore.open(path: path)
            #expect(opened.snapshot.book == expected.book)
            #expect(opened.snapshot.draft == expected.draft)
            #expect(opened.snapshot.settings == expected.settings)
            #expect(opened.snapshot.book.accounts.allSatisfy {
                $0.institutionID == nil && $0.templateID == nil && $0.iconID == nil
            })
            #expect(try LedgerEngine.balance(of: expected.book.accounts[0].id, in: opened.snapshot.book).minorUnits == 97_200)
            try inspection.read { (db: Database) throws -> Void in
                #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == SQLiteLedgerStore.schemaVersion)
                #expect(try Data.fetchAll(db, sql: "SELECT payload FROM accounts ORDER BY position") == originalPayloads)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM accounts WHERE institution_id IS NOT NULL OR template_id IS NOT NULL OR icon_id IS NOT NULL") == 0)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }

            // A second open must not need another migration or invent a brand from the name.
            let reopened = try SQLiteLedgerStore(path: path).loadSnapshot()
            #expect(reopened.book == expected.book && reopened.draft == expected.draft)
            #expect(reopened.settings == expected.settings)
        }
    }

    @Test func failedSchemaOneMigrationRollsBackColumnsVersionAndAllStoredState() throws {
        try withDatabase { path in
            let expected = try createSchemaOneFixture(path: path)
            let inspection = try DatabaseQueue(path: path)
            let original = try inspection.read { db in
                let draft: Data? = try Data.fetchOne(db, sql: "SELECT payload FROM entry_draft")
                let settings: Data? = try Data.fetchOne(db, sql: "SELECT payload FROM ledger_settings")
                return (accounts: try Data.fetchAll(db, sql: "SELECT payload FROM accounts ORDER BY position"),
                        entries: try Data.fetchAll(db, sql: "SELECT payload FROM entries ORDER BY position"),
                        draft: try #require(draft), settings: try #require(settings))
            }
            let invalidDraft = Data("not JSON".utf8)
            try inspection.write { db in
                try db.execute(sql: "UPDATE entry_draft SET payload = ?", arguments: [invalidDraft])
            }

            #expect(throws: LedgerStoreError.corruptData("entry_draft")) { try SQLiteLedgerStore.open(path: path) }
            try inspection.read { (db: Database) throws -> Void in
                #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 1)
                #expect(try accountColumnNames(in: db).isDisjoint(with: ["institution_id", "template_id", "icon_id"]))
                #expect(try Data.fetchAll(db, sql: "SELECT payload FROM accounts ORDER BY position") == original.accounts)
                #expect(try Data.fetchAll(db, sql: "SELECT payload FROM entries ORDER BY position") == original.entries)
                #expect(try Data.fetchOne(db, sql: "SELECT payload FROM entry_draft") == invalidDraft)
                #expect(try Data.fetchOne(db, sql: "SELECT payload FROM ledger_settings") == original.settings)
            }
            // Repairing the injected fault leaves the same legacy database able to migrate.
            try inspection.write { db in
                try db.execute(sql: "UPDATE entry_draft SET payload = ?", arguments: [original.draft])
            }
            let recovered = try SQLiteLedgerStore.open(path: path).snapshot
            #expect(recovered.book == expected.book && recovered.draft == expected.draft)
            #expect(recovered.settings == expected.settings)
        }
    }

    @Test func brokenForeignKeysAreNotLoadedAsValidBook() throws {
        try withDatabase { path in
            let store = try SQLiteLedgerStore(path: path)
            try store.saveBook(fixture())
            var configuration = Configuration()
            configuration.foreignKeysEnabled = false
            let inspection = try DatabaseQueue(path: path, configuration: configuration)
            try inspection.write { db in
                try db.execute(sql: "UPDATE entries SET account_id = ?", arguments: [UUID().uuidString])
            }
            #expect(throws: LedgerStoreError.corruptData("relationships")) { try store.loadBook() }
        }
    }

    @Test func unknownSchemaAndForeignDatabaseAreNeverReset() throws {
        try withDatabase { path in
            let inspection = try DatabaseQueue(path: path)
            try inspection.write { db in
                try db.execute(sql: "PRAGMA user_version = 99")
            }
            #expect(throws: LedgerStoreError.unsupportedSchemaVersion(99)) { try SQLiteLedgerStore(path: path) }
            try inspection.read { (db: Database) throws -> Void in
                #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 99)
            }
        }
        try withDatabase { path in
            let inspection = try DatabaseQueue(path: path)
            try inspection.write { db in
                try db.execute(sql: "CREATE TABLE unrelated (value TEXT); INSERT INTO unrelated VALUES ('keep')")
            }
            #expect(throws: LedgerStoreError.unrecognizedDatabase) { try SQLiteLedgerStore(path: path) }
            try inspection.read { (db: Database) throws -> Void in
                #expect(try String.fetchOne(db, sql: "SELECT value FROM unrelated") == "keep")
            }
        }
    }

    private func createSchemaOneFixture(path: String) throws -> LedgerBackupSnapshot {
        var book = try fixture()
        book.retiredOperationIDs.insert(UUID())
        let draft = EntryDraft(amountText: "12+(", accountID: book.accounts[0].id, note: "旧草稿不能丢失")
        let settings = LedgerSettings(defaultAccountID: book.accounts[0].id)
        try SQLiteLedgerStore(path: path).commit(book, draft: draft, settings: settings)

        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        let legacy = try DatabaseQueue(path: path, configuration: configuration)
        try legacy.write { db in
            // Rebuild with the actual schema-1 columns, rather than relabeling a schema-2 DB.
            // Other tables have no schema-2 changes and retain their existing data and FKs.
            try db.execute(sql: """
                CREATE TABLE accounts_v1 (
                    id TEXT PRIMARY KEY NOT NULL,
                    position INTEGER NOT NULL UNIQUE CHECK (position >= 0),
                    name TEXT NOT NULL, kind TEXT NOT NULL, nature TEXT NOT NULL, currency TEXT NOT NULL,
                    opening_minor INTEGER NOT NULL CHECK (typeof(opening_minor) = 'integer'),
                    opening_date REAL NOT NULL,
                    included_in_summary INTEGER NOT NULL CHECK (included_in_summary IN (0, 1)),
                    is_active INTEGER NOT NULL CHECK (is_active IN (0, 1)),
                    payload BLOB NOT NULL CHECK (typeof(payload) = 'blob')
                );
                INSERT INTO accounts_v1 SELECT id, position, name, kind, nature, currency,
                    opening_minor, opening_date, included_in_summary, is_active, payload FROM accounts;
                DROP TABLE accounts;
                ALTER TABLE accounts_v1 RENAME TO accounts;
                DROP TABLE IF EXISTS import_rules; PRAGMA user_version = 1;
                """)
            try db.execute(sql: "DROP TABLE import_batches")
                try db.execute(sql: "DROP INDEX entries_project")
                try db.execute(sql: "DROP TABLE entry_tags")
                try db.execute(sql: "ALTER TABLE entries DROP COLUMN project_id")
                try db.execute(sql: "DROP TABLE tags")
                try db.execute(sql: "DROP TABLE projects")
                try db.execute(sql: "DROP INDEX entries_original")
            try db.execute(sql: "ALTER TABLE entries DROP COLUMN original_entry_id")
            try db.execute(sql: "ALTER TABLE entries DROP COLUMN allows_net_recovery")
            for row in try Row.fetchAll(db, sql: "SELECT id, payload FROM accounts") {
                let id: String = try row.decode(forColumn: "id")
                let payload: Data = try row.decode(forColumn: "payload")
                var object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
                for key in ["institutionID", "templateID", "iconID"] { object.removeValue(forKey: key) }
                let oldPayload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                try db.execute(sql: "UPDATE accounts SET payload = ? WHERE id = ?", arguments: [oldPayload, id])
            }
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
        return LedgerBackupSnapshot(book: book, draft: draft, settings: settings)
    }

    private func accountColumnNames(in db: Database) throws -> Set<String> {
        Set(try Row.fetchAll(db, sql: "PRAGMA table_info(accounts)").map { row -> String in
            try row.decode(forColumn: "name")
        })
    }

    private func fixture() throws -> LedgerBook {
        let date = Date(timeIntervalSinceReferenceDate: 812_300_000.25)
        let account = Account(name: "微信", kind: .wallet, openingMinor: 100_000, openingDate: date)
        let entry = LedgerEntry(kind: .expense, amount: Money(minorUnits: 2_800), accountID: account.id,
                                categoryID: SeedData.mealsID, occurredAt: date, createdAt: date,
                                title: "午餐", note: "合成测试数据")
        return try LedgerEngine.record(entry, in: LedgerBook(accounts: [account]))
    }

    private func withDatabase(_ body: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LedgerStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("ledger.sqlite").path)
    }
}
