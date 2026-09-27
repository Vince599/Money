import Foundation
import GRDB
import LedgerCore
import LedgerStore
import Testing

/// Apple-only persistence tests. Separate connections change state deterministically;
/// these do not use timing-dependent concurrency or claim a performance threshold.
@Suite("Atomic SQLite snapshots")
struct SnapshotTests {
    @Test func openingNewDatabaseReturnsCompleteSeedAndUsableStore() throws {
        try withDatabase { path in
            let opened = try SQLiteLedgerStore.open(path: path)
            expect(opened.snapshot, book: LedgerBook(), draft: nil, settings: LedgerSettings())
            expect(try opened.store.loadSnapshot(), book: LedgerBook(), draft: nil, settings: LedgerSettings())
            let draft = EntryDraft(amountText: "12+(", title: "尚未完成")
            try opened.store.saveDraft(draft)
            expect(try opened.store.loadSnapshot(), book: LedgerBook(), draft: draft, settings: LedgerSettings())
            // The returned initial value is an immutable snapshot, not a live view.
            #expect(opened.snapshot.draft == nil)
        }
    }

    @Test func schemaTwoWholeBookAPIReopensWithoutRewritingAnyTable() throws {
        try withDatabase { path in
            // Current-schema reopening must not rewrite editable order, adjustments,
            // retired operations or presentation metadata. Migration has separate tests.
            var book = try fixture()
            book.accounts[0].institutionID = "future.institution"
            book.accounts[0].templateID = "future.template"
            book.accounts[0].iconID = "future.icon"
            book.subjects[0].name = "自定义主体"
            book.categories.reverse()
            let draft = EntryDraft(amountText: "28.", accountID: book.accounts[0].id, note: "保留草稿")
            let settings = LedgerSettings(defaultAccountID: book.accounts[0].id)
            try SQLiteLedgerStore(path: path).commit(book, draft: draft, settings: settings)
            let inspection = try DatabaseQueue(path: path)
            try prohibitAllWrites(inspection)

            let opened = try SQLiteLedgerStore.open(path: path)
            expect(opened.snapshot, book: book, draft: draft, settings: settings)
            expect(try opened.store.loadSnapshot(), book: book, draft: draft, settings: settings)
            #expect(try opened.store.loadBook() == book)
            let legacy = try SQLiteLedgerStore(path: path)
            expect(try legacy.loadSnapshot(), book: book, draft: draft, settings: settings)
            try inspection.read { (db: Database) throws -> Void in
                #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 2)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM adjustments") == 1)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM operation_registry WHERE record_kind = 'retired'") == 1)
            }
        }
    }

    @Test func snapshotsObserveOtherConnectionsAndOwnWritesWithoutCaching() throws {
        try withDatabase { path in
            let opened = try SQLiteLedgerStore.open(path: path)
            let writer = try SQLiteLedgerStore(path: path)
            let book = try fixture()
            let draft = EntryDraft(amountText: "88", accountID: book.accounts[0].id, title: "另一连接")
            let settings = LedgerSettings(defaultAccountID: book.accounts[0].id)
            try writer.commit(book, draft: draft, settings: settings)
            expect(try opened.store.loadSnapshot(), book: book, draft: draft, settings: settings)
            let nextDraft = EntryDraft(amountText: "99+", note: "仅草稿变化")
            try writer.saveDraft(nextDraft)
            expect(try opened.store.loadSnapshot(), book: book, draft: nextDraft, settings: settings)
            let nextSettings = LedgerSettings()
            try writer.saveSettings(nextSettings)
            expect(try opened.store.loadSnapshot(), book: book, draft: nextDraft, settings: nextSettings)

            var changed = book
            changed.accounts[0].name = "同连接写入"
            try opened.store.saveBook(changed)
            expect(try opened.store.loadSnapshot(), book: changed, draft: nextDraft, settings: nextSettings)
            try writer.saveDraft(nil)
            expect(try opened.store.loadSnapshot(), book: changed, draft: nil, settings: nextSettings)
            expect(opened.snapshot, book: LedgerBook(), draft: nil, settings: LedgerSettings())
        }
    }

    @Test func incompleteDraftWithStaleReferencesAndExactTextSurvivesOpen() throws {
        try withDatabase { path in
            let store = try SQLiteLedgerStore(path: path)
            let draft = EntryDraft(kind: .transfer, amountText: "1+(", accountID: UUID(),
                                   destinationAccountID: UUID(), subjectID: UUID(),
                                   expenseCategoryID: UUID(), incomeCategoryID: UUID(),
                                   title: "Cafe\u{0301}", note: "未完成\npre\u{0301}compose\u{0301}")
            try store.saveDraft(draft)
            let opened = try SQLiteLedgerStore.open(path: path)
            expect(opened.snapshot, book: LedgerBook(), draft: draft, settings: LedgerSettings())
            let recovered = try #require(opened.snapshot.draft)
            #expect(Array(recovered.title.utf8) == Array(draft.title.utf8))
            #expect(Array(recovered.note.utf8) == Array(draft.note.utf8))
            let legacy = try SQLiteLedgerStore(path: path)
            expect(try legacy.loadSnapshot(), book: LedgerBook(), draft: draft, settings: LedgerSettings())
        }
    }

    @Test(arguments: ["payload", "projection", "position"])
    func corruptedEntryPayloadProjectionOrOrderIsRejected(corruption: String) throws {
        try withDatabase { path in
            let store = try SQLiteLedgerStore(path: path)
            try store.saveBook(fixture())
            let inspection = try DatabaseQueue(path: path)
            try inspection.write { db in
                switch corruption {
                case "payload":
                    try db.execute(sql: "UPDATE entries SET payload = ?", arguments: [Data("not JSON".utf8)])
                case "projection":
                    try db.execute(sql: "UPDATE entries SET amount_minor = amount_minor + 1")
                default:
                    try db.execute(sql: "UPDATE entries SET position = 5")
                }
            }
            try prohibitAllWrites(inspection)
            expectRejected(.corruptData("entries"), store: store, path: path)
        }
    }

    @Test func selfConsistentSQLProjectionStillRequiresFullDomainValidation() throws {
        try withDatabase { path in
            let store = try SQLiteLedgerStore(path: path)
            let book = try fixture()
            try store.saveBook(book)
            var invalid = book.entries[0]
            invalid.amount = Money(minorUnits: invalid.amount.minorUnits, currency: .hkd)
            let payload = try JSONEncoder().encode(invalid)
            let inspection = try DatabaseQueue(path: path)
            try inspection.write { db in
                // FK, SQL types and payload/projection all agree; the account's
                // CNY currency makes this an invalid domain event.
                try db.execute(sql: "UPDATE entries SET currency = 'HKD', payload = ?", arguments: [payload])
            }
            try prohibitAllWrites(inspection)
            #expect(throws: LedgerError.currencyMismatch) { try store.loadSnapshot() }
            #expect(throws: LedgerError.currencyMismatch) { try SQLiteLedgerStore.open(path: path) }
            #expect(throws: LedgerError.currencyMismatch) { try SQLiteLedgerStore(path: path) }
            #expect(throws: LedgerError.currencyMismatch) { try store.loadBook() }
        }
    }

    @Test(arguments: [false, true])
    func brokenForeignKeyOrOrphanRegistryIsRejected(orphanRegistry: Bool) throws {
        try withDatabase { path in
            let store = try SQLiteLedgerStore(path: path)
            try store.saveBook(fixture())
            var configuration = Configuration()
            configuration.foreignKeysEnabled = false
            let inspection = try DatabaseQueue(path: path, configuration: configuration)
            try inspection.write { db in
                if orphanRegistry {
                    try db.execute(sql: """
                        INSERT INTO operation_registry (operation_id, record_id, record_kind)
                        VALUES (?, ?, 'entry')
                        """, arguments: [UUID().uuidString, UUID().uuidString])
                } else {
                    try db.execute(sql: "UPDATE entries SET account_id = ?", arguments: [UUID().uuidString])
                }
            }
            try prohibitAllWrites(inspection)
            let error = LedgerStoreError.corruptData(orphanRegistry ? "operation_registry" : "relationships")
            expectRejected(error, store: store, path: path)
            #expect(throws: error) { try store.loadBook() }
        }
    }

    @Test(arguments: ["not JSON", "{}"])
    func corruptedDraftIsRejectedWithoutClearingUserInput(payloadText: String) throws {
        try withDatabase { path in
            let store = try SQLiteLedgerStore(path: path)
            try store.saveDraft(EntryDraft(amountText: "56"))
            let payload = Data(payloadText.utf8)
            let inspection = try DatabaseQueue(path: path)
            try inspection.write { db in
                try db.execute(sql: "UPDATE entry_draft SET payload = ?", arguments: [payload])
            }
            try prohibitAllWrites(inspection)
            expectRejected(.corruptData("entry_draft"), store: store, path: path)
            try inspection.read { (db: Database) throws -> Void in
                #expect(try Data.fetchOne(db, sql: "SELECT payload FROM entry_draft") == payload)
            }
        }
    }

    @Test(arguments: ["missing", "not JSON", "{}"])
    func missingOrCorruptedSettingsAreRejectedWithoutResettingDefaults(corruption: String) throws {
        try withDatabase { path in
            let store = try SQLiteLedgerStore(path: path)
            let inspection = try DatabaseQueue(path: path)
            try inspection.write { db in
                if corruption == "missing" {
                    try db.execute(sql: "DELETE FROM ledger_settings")
                } else {
                    try db.execute(sql: "UPDATE ledger_settings SET payload = ?", arguments: [Data(corruption.utf8)])
                }
            }
            try prohibitAllWrites(inspection)
            expectRejected(.corruptData("ledger_settings"), store: store, path: path)
            try inspection.read { (db: Database) throws -> Void in
                let payload = try Data.fetchOne(db, sql: "SELECT payload FROM ledger_settings")
                #expect(payload == (corruption == "missing" ? nil : Data(corruption.utf8)))
            }
        }
    }

    @Test func unknownSchemaAndForeignDatabaseAreNeverResetByFactory() throws {
        try withDatabase { path in
            let opened = try SQLiteLedgerStore.open(path: path)
            let inspection = try DatabaseQueue(path: path)
            try inspection.write { db in try db.execute(sql: "PRAGMA user_version = 99") }
            expectRejected(.unsupportedSchemaVersion(99), store: opened.store, path: path)
            try inspection.read { (db: Database) throws -> Void in
                #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 99)
            }
        }
        try withDatabase { path in
            let inspection = try DatabaseQueue(path: path)
            try inspection.write { db in
                try db.execute(sql: "CREATE TABLE unrelated (value TEXT); INSERT INTO unrelated VALUES ('keep')")
            }
            #expect(throws: LedgerStoreError.unrecognizedDatabase) { try SQLiteLedgerStore.open(path: path) }
            #expect(throws: LedgerStoreError.unrecognizedDatabase) { try SQLiteLedgerStore(path: path) }
            try inspection.read { (db: Database) throws -> Void in
                #expect(try String.fetchOne(db, sql: "SELECT value FROM unrelated") == "keep")
                #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 0)
            }
        }
    }

    private func expect(_ snapshot: SQLiteLedgerSnapshot, book: LedgerBook,
                        draft: EntryDraft?, settings: LedgerSettings) {
        #expect(snapshot.book == book)
        #expect(snapshot.draft == draft)
        #expect(snapshot.settings == settings)
    }

    private func expectRejected(_ error: LedgerStoreError, store: SQLiteLedgerStore, path: String) {
        #expect(throws: error) { try store.loadSnapshot() }
        #expect(throws: error) { try SQLiteLedgerStore.open(path: path) }
        #expect(throws: error) { try SQLiteLedgerStore(path: path) }
    }

    private func fixture() throws -> LedgerBook {
        let date = Date(timeIntervalSinceReferenceDate: 812_300_000.25)
        let account = Account(name: "合成账户", openingMinor: 100_000, openingDate: date)
        let entry = LedgerEntry(kind: .expense, amount: Money(minorUnits: 2_800), accountID: account.id,
                                categoryID: SeedData.mealsID, occurredAt: date, createdAt: date,
                                title: "午餐", note: "合成快照数据")
        let book = try LedgerEngine.record(entry, in: LedgerBook(accounts: [account], retiredOperationIDs: [UUID()]))
        return try LedgerEngine.adjustBalance(accountID: account.id, to: Money(minorUnits: 98_000),
                                              operationID: UUID(), at: date.addingTimeInterval(1),
                                              note: "余额更正", in: book)
    }

    private func prohibitAllWrites(_ inspection: DatabaseQueue) throws {
        try inspection.write { db in
            for table in ["accounts", "subjects", "categories", "entries", "adjustments",
                          "operation_registry", "entry_draft", "ledger_settings"] {
                for action in ["INSERT", "UPDATE", "DELETE"] {
                    try db.execute(sql: """
                        CREATE TRIGGER snapshot_protect_\(table)_\(action) BEFORE \(action) ON \(table)
                        BEGIN SELECT RAISE(ABORT, 'snapshot must not rewrite persisted state'); END;
                        """)
                }
            }
        }
    }

    private func withDatabase(_ body: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("ledger.sqlite").path)
    }
}
