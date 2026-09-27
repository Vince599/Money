import Foundation
import GRDB
import LedgerCore
import LedgerStore
import Testing

@Suite("Tag and project storage")
struct EntryLabelsStoreTests {
    private func withStore(_ body: (SQLiteLedgerStore, DatabaseQueue, String, LedgerBook) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.sqlite").path
        let store = try SQLiteLedgerStore(path: path)
        let book = LedgerBook(accounts: [Account(name: "银行卡", openingMinor: 10_000)],
                              tags: [EntryTag(name: "旅行"), EntryTag(name: "两人")], projects: [EntryProject(name: "上海")])
        try store.commit(book, draft: EntryDraft(amountText: "12+(", tagIDs: [UUID()], projectID: UUID()))
        try body(store, DatabaseQueue(path: path), path, book)
    }

    private func entry(_ book: LedgerBook, tags: [UUID], project: UUID? = nil) -> LedgerEntry {
        LedgerEntry(kind: .expense, amount: Money(minorUnits: 100), accountID: book.accounts[0].id,
                    categoryID: SeedData.mealsID, tagIDs: tags, projectID: project)
    }

    @Test func filtersPaginateWithoutDuplicatesAndKeepStableCursorIdentity() throws {
        try withStore { store, _, path, book in
            var expected = book
            for index in 0..<7 {
                expected = try store.saveEntry(entry(book, tags: index % 2 == 0 ? book.tags.map(\.id) : [book.tags[0].id],
                                                     project: index < 5 ? book.projects[0].id : nil)).book
            }
            let queries = [EntryFilter(tagIDs: Set(book.tags.map(\.id))),
                           EntryFilter(tagIDs: Set(book.tags.map(\.id)), tagMatch: .any),
                           EntryFilter(tagIDs: [book.tags[1].id], projectID: book.projects[0].id),
                           EntryFilter(tagIDs: [UUID()]), EntryFilter(projectID: UUID()), EntryFilter(tagMatch: .any)]
            for query in queries {
                var page = try store.entryPage(matching: query, limit: 2)
                var found = page.entries
                while let cursor = page.nextCursor {
                    page = try store.entryPage(matching: query, after: cursor, limit: 2)
                    found += page.entries
                }
                #expect(found == (try EntryQuery.entries(in: expected, matching: query)))
                #expect(page.totalCount == found.count)
            }
            let filter = EntryFilter(tagIDs: [book.tags[0].id])
            let page = try store.entryPage(matching: filter, limit: 1)
            #expect(throws: LedgerStoreError.staleHistoryCursor) {
                try store.entryPage(matching: EntryFilter(tagIDs: filter.tagIDs, tagMatch: .any), after: page.nextCursor, limit: 1)
            }
            #expect(try SQLiteLedgerStore(path: path).loadBook() == expected)
        }
    }

    @Test func incrementalEditWritesLinksAtomicallyAndDeletionRemovesOnlyEventLinks() throws {
        try withStore { store, inspection, _, book in
            let first = entry(book, tags: book.tags.map(\.id), project: book.projects[0].id)
            let saved = try store.saveEntry(first)
            var changed = first; changed.operationID = UUID(); changed.tagIDs = [book.tags[1].id]; changed.projectID = nil
            try inspection.write { try $0.execute(sql: "CREATE TRIGGER reject_link BEFORE INSERT ON entry_tags BEGIN SELECT RAISE(ABORT, 'injected'); END") }
            #expect(throws: (any Error).self) { try store.saveEntry(changed, expectedVersion: 1) }
            let failed = try store.loadSnapshot()
            #expect(failed.book == saved.book && failed.draft == saved.draft)
            try inspection.write { try $0.execute(sql: "DROP TRIGGER reject_link") }
            let edited = try store.saveEntry(changed, expectedVersion: 1)
            #expect(edited.book.entries[0].tagIDs == changed.tagIDs && edited.book.entries[0].projectID == nil)
            #expect(try store.saveEntry(changed, expectedVersion: 1).book == edited.book)
            let plan = try LedgerEngine.deletionPlan(entryID: first.id, in: edited.book)
            let deleted = try store.deleteEntries(plan)
            #expect(deleted.book.entries.isEmpty && deleted.book.tags == book.tags && deleted.book.projects == book.projects)
            #expect(deleted.draft == saved.draft)
            try inspection.read { (db: Database) throws -> Void in
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry_tags") == 0)
            }
        }
    }

    @Test func linkAndProjectProjectionCorruptionAreRejected() throws {
        try withStore { store, inspection, _, book in
            let first = entry(book, tags: [book.tags[0].id], project: book.projects[0].id)
            _ = try store.saveEntry(first)
            try inspection.write { try $0.execute(sql: "DELETE FROM entry_tags") }
            #expect(throws: LedgerStoreError.corruptData("entry_tags")) { try store.loadSnapshot() }
            #expect(throws: LedgerStoreError.corruptData("entry_tags")) { try store.entryPage() }
            try inspection.write { db in
                try db.execute(sql: "INSERT INTO entry_tags VALUES (?, ?, 0)", arguments: [first.id.uuidString, book.tags[0].id.uuidString])
                try db.execute(sql: "UPDATE entries SET project_id = NULL")
            }
            #expect(throws: LedgerStoreError.corruptData("entries")) { try store.loadSnapshot() }
        }
    }

    @Test func archiveBackupRestoreAndWholeBookFailurePreserveDraft() throws {
        try withStore { store, inspection, path, book in
            var saved = try store.saveEntry(entry(book, tags: book.tags.map(\.id), project: book.projects[0].id))
            var archived = saved.book; archived.projects[0].isArchived = true; archived.tags[0].isActive = false
            try store.commit(archived, draft: saved.draft)
            saved = try SQLiteLedgerStore(path: path).loadSnapshot()
            let backup = LedgerBackupSnapshot(book: saved.book, draft: saved.draft, settings: saved.settings)
            let decoded = try BackupCodec.decode(BackupArchive.decode(BackupArchive.encode(BackupCodec.encode(backup))))
            try store.commit(LedgerBook(), draft: nil)
            try store.commit(decoded.book, draft: decoded.draft, settings: decoded.settings)
            #expect(try store.loadBook() == archived)
            #expect(try store.entryPage(matching: EntryFilter(projectID: book.projects[0].id)).totalCount == 1)
            try inspection.write { try $0.execute(sql: "CREATE TRIGGER reject_project BEFORE INSERT ON projects BEGIN SELECT RAISE(ABORT, 'injected'); END") }
            #expect(throws: (any Error).self) { try store.commit(decoded.book, draft: nil) }
            let current = try store.loadSnapshot()
            #expect(current.book == decoded.book && current.draft == decoded.draft)
        }
    }

    @Test func schemaThreeMigrationPreservesPayloadsAndRollsBackOnInvalidDraft() throws {
        try withStore { store, inspection, path, book in
            let posted = entry(book, tags: [])
            let legacyBook = LedgerBook(accounts: book.accounts, entries: [posted])
            try store.commit(legacyBook, draft: EntryDraft(amountText: "12+"))
            try inspection.write { db in
                try db.execute(sql: "DROP TABLE import_batches; DROP INDEX entries_project; DROP TABLE entry_tags; ALTER TABLE entries DROP COLUMN project_id; DROP TABLE tags; DROP TABLE projects; DROP TABLE IF EXISTS import_rules; PRAGMA user_version = 3")
                for table in ["entries", "entry_draft"] {
                    let payload = try #require(Data.fetchOne(db, sql: "SELECT payload FROM \(table)"))
                    var object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
                    object.removeValue(forKey: "tagIDs"); object.removeValue(forKey: "projectID")
                    try db.execute(sql: "UPDATE \(table) SET payload = ?", arguments: [try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])])
                }
            }
            let payloads = try inspection.read { db in
                (try Data.fetchOne(db, sql: "SELECT payload FROM entries"), try Data.fetchOne(db, sql: "SELECT payload FROM entry_draft"))
            }
            try inspection.write { try $0.execute(sql: "UPDATE entry_draft SET payload = ?", arguments: [Data("bad JSON".utf8)]) }
            #expect(throws: LedgerStoreError.corruptData("entry_draft")) { try SQLiteLedgerStore(path: path) }
            try inspection.read { (db: Database) throws -> Void in
                #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 3)
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name = 'tags'") == 0)
            }
            try inspection.write { try $0.execute(sql: "UPDATE entry_draft SET payload = ?", arguments: [payloads.1]) }
            let migrated = try SQLiteLedgerStore(path: path).loadSnapshot()
            #expect(migrated.book == legacyBook && migrated.draft?.tagIDs == [])
            try inspection.read { (db: Database) throws -> Void in
                #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == SQLiteLedgerStore.schemaVersion)
                #expect(try Data.fetchOne(db, sql: "SELECT payload FROM entries") == payloads.0)
                #expect(try Data.fetchOne(db, sql: "SELECT payload FROM entry_draft") == payloads.1)
                #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
            }
        }
    }
}
