import Foundation
import GRDB
import LedgerCore

public enum LedgerStoreError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case unrecognizedDatabase
    case corruptData(String)
    case invalidPageSize, staleHistoryCursor
}

/// Opaque continuation, valid only for the same store, filter and database state.
public struct EntryPageCursor: Equatable, Sendable {
    fileprivate let storeID: UUID
    fileprivate let dataVersion: Int
    fileprivate let changes: Int
    fileprivate let filter: EntryFilter
    fileprivate let occurredAt: Date
    fileprivate let createdAt: Date
    fileprivate let id: UUID
    fileprivate let totalCount: Int
    fileprivate let trailingDaySummary: EntryDaySummary?
}

public struct EntryPage: Sendable {
    public let entries: [LedgerEntry]
    public let daySummaries: [EntryDaySummary]
    public let totalCount: Int
    public let nextCursor: EntryPageCursor?
}

/// Whether an ordinary new-entry command keeps or replaces the current draft.
/// Editing a saved entry always preserves the unrelated new-entry draft.
public enum EntryDraftUpdate: Sendable {
    case preserve
    case replace(EntryDraft?)
}

/// Consistent book, draft and settings from one database transaction.
public struct SQLiteLedgerSnapshot: Sendable {
    public let book: LedgerBook
    public let draft: EntryDraft?
    public let settings: LedgerSettings
}

/// SQLite persistence with incremental ordinary entry inserts and edits.
///
/// Each collection has its own table, exact integer money columns, foreign keys,
/// and a Codable payload for the complete model. Whole-book saves/restores still
/// replace collections in one transaction. Reads and validation remain full-book;
/// this does not yet claim the planned 100,000-entry performance target.
///
/// The queue serializes database access. No mutable encoder or decoder is shared.
/// Callers must coordinate read-modify-save operations; serialization of writes
/// alone does not make two independently edited book snapshots merge safely.
public final class SQLiteLedgerStore: Sendable {
    public static let schemaVersion = 10
    private static let applicationID = 0x4C444752 // "LDGR"
    private let database: DatabaseQueue
    private let historyStoreID = UUID()

    public init(path: String) throws {
        database = try Self.openDatabase(path: path).database
    }

    /// Opens and validates the database and returns its initial state from the
    /// same transaction. Later reads always fetch a fresh database snapshot.
    public static func open(path: String) throws -> (store: SQLiteLedgerStore, snapshot: SQLiteLedgerSnapshot) {
        let opened = try openDatabase(path: path)
        return (SQLiteLedgerStore(database: opened.database), opened.snapshot)
    }

    private init(database: DatabaseQueue) {
        self.database = database
    }

    private static func openDatabase(path: String) throws -> (database: DatabaseQueue, snapshot: SQLiteLedgerSnapshot) {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            db.add(function: DatabaseFunction("ledger_history_contains", argumentCount: 2, pure: true) { values in
                guard let data = Data.fromDatabaseValue(values[0]),
                      let keywordData = Data.fromDatabaseValue(values[1]) else {
                    throw LedgerStoreError.corruptData("entries")
                }
                // Preserve embedded NULs as well as Unicode; the SQL TEXT bridge
                // may use null-terminated strings when invoking custom functions.
                let keyword = String(decoding: keywordData, as: UTF8.self)
                // Decode only searchable text. Full entry decoding is limited to the returned page.
                let text = try Self.decode(HistoryText.self, payload: data, table: "entries")
                return EntryQuery.containsKeyword(keyword, title: text.title, note: text.note)
            })
        }
        let database = try DatabaseQueue(path: path, configuration: configuration)
        let snapshot = try database.write { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            guard (0...Self.schemaVersion).contains(version) else {
                throw LedgerStoreError.unsupportedSchemaVersion(version)
            }
            if version == 0 {
                let tables = try String.fetchAll(db, sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                    """)
                let identifier = try Int.fetchOne(db, sql: "PRAGMA application_id") ?? 0
                guard tables.isEmpty, identifier == 0 else {
                    throw LedgerStoreError.unrecognizedDatabase
                }
                try db.execute(sql: Self.ruleSchema)
                try db.execute(sql: Self.importSchema)
                try db.execute(sql: Self.initialSchema)
                try db.execute(sql: Self.labelSchema)
                let seed = LedgerBook()
                try LedgerEngine.validate(seed)
                try Self.writeBook(seed, in: db)
                try Self.writeSettings(LedgerSettings(), in: db)
                try db.execute(sql: "PRAGMA application_id = \(Self.applicationID)")
                try db.execute(sql: "PRAGMA user_version = \(Self.schemaVersion)")
            } else if version == 1 {
                guard try Int.fetchOne(db, sql: "PRAGMA application_id") == Self.applicationID else {
                    throw LedgerStoreError.unrecognizedDatabase
                }
                let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(accounts)")
                let columnNames = Set(try columns.map { row -> String in try row.decode(forColumn: "name") })
                for column in ["institution_id", "template_id", "icon_id"] where !columnNames.contains(column) {
                    try db.execute(sql: "ALTER TABLE accounts ADD COLUMN \(column) TEXT")
                }
                // Keep every payload byte intact. Missing optional IDs decode as nil,
                // matching the new NULL projections; validation below shares this transaction.
                try db.execute(sql: "PRAGMA user_version = \(Self.schemaVersion)")
            }
            if version == 1 || version == 2 {
                guard try Int.fetchOne(db, sql: "PRAGMA application_id") == Self.applicationID else {
                    throw LedgerStoreError.unrecognizedDatabase
                }
                try db.execute(sql: "ALTER TABLE entries ADD COLUMN original_entry_id TEXT REFERENCES entries(id) DEFERRABLE INITIALLY DEFERRED")
                try db.execute(sql: "ALTER TABLE entries ADD COLUMN allows_net_recovery INTEGER CHECK (allows_net_recovery IS NULL OR allows_net_recovery IN (0, 1))")
                try db.execute(sql: "PRAGMA user_version = \(Self.schemaVersion)")
            }
            if (1...3).contains(version) {
                guard try Int.fetchOne(db, sql: "PRAGMA application_id") == Self.applicationID else {
                    throw LedgerStoreError.unrecognizedDatabase
                }
                try db.execute(sql: Self.labelSchema)
                try db.execute(sql: "ALTER TABLE entries ADD COLUMN project_id TEXT REFERENCES projects(id)")
                try db.execute(sql: "PRAGMA user_version = \(Self.schemaVersion)")
            }
            if (1...4).contains(version) {
                try db.execute(sql: Self.importSchema)
                try db.execute(sql: "PRAGMA user_version = \(Self.schemaVersion)")
            }
            if version == 5 || version == 6 {
                // Import labels and reversal status live in the batch payload. Missing fields default without rewriting old bytes.
                try db.execute(sql: "PRAGMA user_version = \(Self.schemaVersion)")
            }
            if (1...7).contains(version) {
                try db.execute(sql: Self.ruleSchema)
                try db.execute(sql: "PRAGMA user_version = \(Self.schemaVersion)")
            }
            if version == 8 || version == 9 {
                // Expanded rule actions and source associations use existing payloads. Keep old bytes intact.
                try db.execute(sql: "PRAGMA user_version = \(Self.schemaVersion)")
            }
            let snapshot = try Self.readSnapshot(in: db)
            // Derived access path only: no business data, payload or backup contract changes.
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS entries_history_order ON entries(occurred_at DESC, created_at DESC, id ASC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS entries_project ON entries(project_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS entries_original ON entries(original_entry_id)")
            return snapshot
        }
        return (database, snapshot)
    }

    /// Reads all persisted state in one isolated read transaction, including
    /// changes committed by other connections since the store was opened.
    public func loadSnapshot() throws -> SQLiteLedgerSnapshot {
        try database.read { db in
            try Self.readSnapshot(in: db)
        }
    }

    public func loadBook() throws -> LedgerBook {
        try database.read { db in
            try Self.checkDatabase(db)
            return try Self.readBook(in: db, checkingRelationships: false)
        }
    }

    private struct HistoryText: Decodable { let title: String; let note: String }

    /// A consistent count and bounded page, without loading/validating the entire book.
    /// Opening and all write paths retain full validation. Each returned row still
    /// checks its payload against authoritative projected columns.
    public func entryPage(matching filter: EntryFilter = EntryFilter(),
                          after cursor: EntryPageCursor? = nil, limit: Int = 50) throws -> EntryPage {
        try EntryQuery.validate(filter)
        guard (1...200).contains(limit) else { throw LedgerStoreError.invalidPageSize }
        return try database.read { db in
            try Self.checkSchema(db)
            let dataVersion = try Int.fetchOne(db, sql: "PRAGMA data_version") ?? 0
            let changes = db.totalChangesCount
            if let cursor {
                guard cursor.storeID == historyStoreID, cursor.filter == filter,
                      cursor.dataVersion == dataVersion, cursor.changes == changes else {
                    throw LedgerStoreError.staleHistoryCursor
                }
            }
            var clauses: [String] = []
            var arguments: [DatabaseValue] = []
            func add(_ sql: String, _ values: [DatabaseValue]) {
                clauses.append(sql); arguments.append(contentsOf: values)
            }
            if filter.importSourceMode == .unlinked && filter.importNamespace != nil {
                add("0", [])
            } else if filter.importSourceMode != .all || filter.importNamespace != nil {
                // Decode provenance once in this same read transaction, never all entry payloads.
                let batches = try Self.readRows(ImportBatch.self, table: "import_batches", in: db) { Self.columns(for: $0) }
                let ids = EntryQuery.importSourceEntryIDs(in: batches, namespace: filter.importNamespace)
                    .map(\.uuidString).sorted()
                if ids.isEmpty {
                    if filter.importSourceMode != .unlinked { add("0", []) }
                } else {
                    // One JSON parameter avoids SQLite's variable limit for large source sets.
                    let json = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
                    let operation = filter.importSourceMode == .unlinked ? "NOT IN" : "IN"
                    add("id \(operation) (SELECT value FROM json_each(?))", [json.databaseValue])
                }
            }
            if let kind = filter.kind { add("kind = ?", [kind.rawValue.databaseValue]) }
            if filter.recoveryLinkMode != .all {
                // Membership keeps one row per entry even for multiple partial recoveries.
                // The subquery intentionally ignores the outer date/account/source filters.
                let linked = """
                    ((kind IN ('refund', 'recovery') AND original_entry_id IS NOT NULL)
                     OR id IN (SELECT original_entry_id FROM entries
                       WHERE kind IN ('refund', 'recovery') AND original_entry_id IS NOT NULL))
                    """
                add(filter.recoveryLinkMode == .linked ? linked : "NOT \(linked)", [])
            }
            if let id = filter.accountID {
                add("(account_id = ? OR (kind = 'transfer' AND destination_account_id = ?))",
                    [id.uuidString.databaseValue, id.uuidString.databaseValue])
            }
            if let id = filter.categoryID {
                add("""
                    category_id IN (SELECT id FROM categories WHERE
                      (id = ? AND parent_id IS NOT NULL) OR
                      (parent_id = ? AND EXISTS (SELECT 1 FROM categories WHERE id = ? AND parent_id IS NULL)))
                    """, Array(repeating: id.uuidString.databaseValue, count: 3))
            }
            if let id = filter.subjectID { add("subject_id = ?", [id.uuidString.databaseValue]) }
            if let id = filter.projectID { add("project_id = ?", [id.uuidString.databaseValue]) }
            if !filter.tagIDs.isEmpty {
                let ids = filter.tagIDs.sorted { $0.uuidString < $1.uuidString }
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
                let predicate = "SELECT COUNT(*) FROM entry_tags WHERE entry_id = entries.id AND tag_id IN (\(placeholders))"
                if filter.tagMatch == .all {
                    add("(\(predicate)) = ?", ids.map { $0.uuidString.databaseValue } + [ids.count.databaseValue])
                } else { add("(\(predicate)) > 0", ids.map { $0.uuidString.databaseValue }) }
            }
            if let currency = filter.currency { add("currency = ?", [currency.rawValue.databaseValue]) }
            if let minimum = filter.minimumMinor { add("amount_minor >= ?", [minimum.databaseValue]) }
            if let maximum = filter.maximumMinor { add("amount_minor <= ?", [maximum.databaseValue]) }
            if let from = filter.from { add("occurred_at >= ?", [from.timeIntervalSinceReferenceDate.databaseValue]) }
            if let to = filter.to { add("occurred_at < ?", [to.timeIntervalSinceReferenceDate.databaseValue]) }
            let keyword = filter.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            if !keyword.isEmpty { add("ledger_history_contains(payload, ?)", [Data(keyword.utf8).databaseValue]) }
            let condition = clauses.isEmpty ? "1" : clauses.joined(separator: " AND ")
            let filterArguments = arguments
            let total: Int
            if let cursor { total = cursor.totalCount }
            else { total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entries WHERE \(condition)",
                                          arguments: StatementArguments(arguments)) ?? 0 }
            var pageCondition = condition
            if let cursor {
                pageCondition += " AND (occurred_at < ? OR (occurred_at = ? AND created_at < ?) OR (occurred_at = ? AND created_at = ? AND id > ?))"
                let occurred = cursor.occurredAt.timeIntervalSinceReferenceDate.databaseValue
                let created = cursor.createdAt.timeIntervalSinceReferenceDate.databaseValue
                arguments += [occurred, occurred, created, occurred, created, cursor.id.uuidString.databaseValue]
            }
            arguments.append((limit + 1).databaseValue)
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM entries WHERE \(pageCondition)
                ORDER BY occurred_at DESC, created_at DESC, id ASC LIMIT ?
                """, arguments: StatementArguments(arguments))
            let entries = try rows.prefix(limit).map { row -> LedgerEntry in
                let payload: Data = try row.decode(forColumn: "payload")
                let entry = try Self.decode(LedgerEntry.self, payload: payload, table: "entries")
                for (column, expected) in Self.columns(for: entry) {
                    let stored: DatabaseValue = try row.decode(forColumn: column)
                    guard stored == expected else { throw LedgerStoreError.corruptData("entries") }
                }
                try Self.checkTagLinks(entry, in: db)
                return entry
            }
            let next: EntryPageCursor?
            var daySummaries: [EntryDaySummary] = []
            if let first = entries.first, let last = entries.last {
                let firstDay = EntryDaySummary.day(containing: first.occurredAt)
                let lastDay = EntryDaySummary.day(containing: last.occurredAt)
                guard let dayEnd = EntryDaySummary.calendar.date(byAdding: .day, value: 1, to: firstDay) else {
                    throw LedgerStoreError.corruptData("entry_summary_date")
                }
                let cached = cursor?.trailingDaySummary
                let reusesDay = cached?.day == firstDay
                if reusesDay, let cached { daySummaries.append(cached) }
                let end = reusesDay ? firstDay : dayEnd
                if lastDay < end {
                    // Same filter and transaction as the page, without LIMIT/keyset restriction.
                    // A day crossing pages reuses its complete summary from the validated cursor.
                    let summaryRows = try Row.fetchCursor(db, sql: """
                        SELECT kind, currency, amount_minor, occurred_at FROM entries
                        WHERE \(condition) AND occurred_at >= ? AND occurred_at < ?
                        """, arguments: StatementArguments(filterArguments + [
                            lastDay.timeIntervalSinceReferenceDate.databaseValue,
                            end.timeIntervalSinceReferenceDate.databaseValue]))
                    var accumulator = EntryDailyAccumulator()
                    while let row = try summaryRows.next() {
                        let kindValue: String = try row.decode(forColumn: "kind")
                        let currencyValue: String = try row.decode(forColumn: "currency")
                        let amount: Int64 = try row.decode(forColumn: "amount_minor")
                        let occurred: Double = try row.decode(forColumn: "occurred_at")
                        guard let kind = EntryKind(rawValue: kindValue), let currency = Currency(rawValue: currencyValue) else {
                            throw LedgerStoreError.corruptData("entry_summary")
                        }
                        do {
                            try accumulator.add(kind: kind, amount: Money(minorUnits: amount, currency: currency),
                                occurredAt: Date(timeIntervalSinceReferenceDate: occurred))
                        } catch { throw LedgerStoreError.corruptData("entry_summary") }
                    }
                    daySummaries += accumulator.summaries
                }
            }
            if rows.count > limit, let last = entries.last {
                next = EntryPageCursor(storeID: historyStoreID, dataVersion: dataVersion, changes: changes,
                                       filter: filter, occurredAt: last.occurredAt, createdAt: last.createdAt,
                                       id: last.id, totalCount: total, trailingDaySummary: daySummaries.last)
            } else { next = nil }
            return EntryPage(entries: entries, daySummaries: daySummaries, totalCount: total, nextCursor: next)
        }
    }

    /// Saves the book without changing the current unfinished entry.
    public func saveBook(_ book: LedgerBook) throws {
        try LedgerEngine.validate(book)
        try database.write { db in
            try Self.checkDatabase(db)
            try Self.writeBook(book, in: db)
            try Self.checkRelationships(db)
        }
    }

    public func loadDraft() throws -> EntryDraft? {
        try database.read { db in
            try Self.checkSchema(db)
            return try Self.readDraft(in: db)
        }
    }

    /// An unfinished draft is allowed to refer to an account that has since been
    /// removed. Reopening it is a UI validation step, not a reason to lose input.
    public func saveDraft(_ draft: EntryDraft?) throws {
        try database.write { db in
            try Self.checkSchema(db)
            try Self.writeDraft(draft, in: db)
        }
    }

    public func loadSettings() throws -> LedgerSettings {
        try database.read { db in
            try Self.checkSchema(db)
            return try Self.readSettings(in: db)
        }
    }

    public func saveSettings(_ settings: LedgerSettings) throws {
        try database.write { db in
            try Self.checkSchema(db)
            try Self.writeSettings(settings, in: db)
        }
    }

    /// Atomically saves the book and the next draft (nil after a completed entry).
    /// Any validation, encoding, SQL, or commit error leaves both stored values
    /// unchanged, including the previous recoverable draft.
    public func commit(_ book: LedgerBook, draft: EntryDraft?, settings: LedgerSettings? = nil) throws {
        try LedgerEngine.validate(book)
        try database.write { db in
            try Self.checkDatabase(db)
            try Self.writeBook(book, in: db)
            try Self.writeDraft(draft, in: db)
            if let settings { try Self.writeSettings(settings, in: db) }
            try Self.checkRelationships(db)
        }
    }

    /// Applies the command against the current persisted book in the same write
    /// transaction as its draft change. Unrelated rows and entry positions are
    /// never rewritten. Full validation is retained while read paths are migrated.
    public func saveEntry(_ entry: LedgerEntry, expectedVersion: Int? = nil,
                          draftUpdate: EntryDraftUpdate = .preserve) throws -> SQLiteLedgerSnapshot {
        try database.write { db in
            try Self.checkDatabase(db)
            let current = try Self.readBook(in: db)
            // Validate existing ancillary data before replacing anything.
            let currentDraft = try Self.readDraft(in: db)
            let settings = try Self.readSettings(in: db)
            let expectedBook: LedgerBook
            var expectedDraft = currentDraft
            if let expectedVersion {
                let updated = try LedgerEngine.replace(entry, expectedVersion: expectedVersion, in: current)
                expectedBook = updated
                guard let index = current.entries.firstIndex(where: { $0.id == entry.id }) else {
                    throw LedgerError.entryNotFound
                }
                let previous = current.entries[index]
                let replacement = updated.entries[index]
                if replacement != previous {
                    // The unique registry record ID and immediate composite FK
                    // need a temporary, transaction-local deferral when changing
                    // operation IDs. Never disable foreign_keys or reset this
                    // pragma early: COMMIT/ROLLBACK restores immediate checking.
                    try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
                    try db.execute(sql: """
                        UPDATE operation_registry SET record_id = NULL, record_kind = 'retired'
                        WHERE operation_id = ?
                        """, arguments: [previous.operationID.uuidString])
                    try Self.register(replacement.operationID, recordID: replacement.id, kind: "entry", in: db)
                    try Self.updateEntry(replacement, in: db)
                }
            } else {
                let updated = try LedgerEngine.record(entry, in: current)
                expectedBook = updated
                // A successful retry can have a different input ID/createdAt;
                // only the canonical domain result determines whether to insert.
                if updated.entries.count > current.entries.count, let inserted = updated.entries.last {
                    try Self.register(inserted.operationID, recordID: inserted.id, kind: "entry", in: db)
                    try Self.insertRow(inserted, position: current.entries.count, table: "entries",
                                       fields: Self.columns(for: inserted), in: db)
                    try Self.writeTagLinks(inserted, in: db)
                }
                // A no-op entry retry still obeys the caller's draft policy.
                if case .replace(let nextDraft) = draftUpdate {
                    expectedDraft = nextDraft
                    // Persist the exact submitted text even when Swift String
                    // equality considers two Unicode representations equivalent.
                    try Self.writeDraft(nextDraft, in: db)
                }
            }
            // Verify actual stored payloads, projections and relationships before
            // COMMIT. No fallible read occurs after the transaction has committed.
            let saved = SQLiteLedgerSnapshot(book: try Self.readBook(in: db),
                                            draft: try Self.readDraft(in: db), settings: try Self.readSettings(in: db))
            guard saved.book == expectedBook, saved.draft == expectedDraft, saved.settings == settings else {
                throw LedgerStoreError.corruptData("entry_commit")
            }
            return saved
        }
    }

    private static func readSnapshot(in db: Database) throws -> SQLiteLedgerSnapshot {
        try checkDatabase(db)
        return SQLiteLedgerSnapshot(book: try readBook(in: db, checkingRelationships: false),
                                    draft: try readDraft(in: db), settings: try readSettings(in: db))
    }

    public func saveImport(_ batch: ImportBatch, expectedVersion: Int? = nil) throws -> SQLiteLedgerSnapshot {
        try database.write { db in
            let current = try Self.readSnapshot(in: db)
            let updated = try ImportEngine.save(batch, in: current.book, expectedVersion: expectedVersion)
            try Self.writeBook(updated, in: db)
            return try Self.readSnapshot(in: db)
        }
    }

    public func saveImportRule(_ rule: ImportRule, expectedVersion: Int? = nil) throws -> SQLiteLedgerSnapshot {
        try database.write { db in
            let current = try Self.readSnapshot(in: db)
            let updated = try ImportRuleEngine.save(rule, expectedVersion: expectedVersion, in: current.book)
            try Self.writeBook(updated, in: db)
            let saved = try Self.readSnapshot(in: db)
            guard saved.book == updated, saved.draft == current.draft, saved.settings == current.settings else { throw LedgerStoreError.corruptData("import_rule_save") }
            return saved
        }
    }
    public func mergeImport(_ plan: ImportMergePlan) throws -> SQLiteLedgerSnapshot {
        try database.write { db in
            let current = try Self.readSnapshot(in: db)
            let updated = try ImportEngine.merge(plan, in: current.book)
            if updated != current.book { try Self.writeBook(updated, in: db) }
            let saved = try Self.readSnapshot(in: db)
            guard saved.book == updated, saved.draft == current.draft, saved.settings == current.settings else { throw LedgerStoreError.corruptData("import_merge") }
            return saved
        }
    }
    public func unlinkImport(_ plan: ImportUnlinkPlan) throws -> SQLiteLedgerSnapshot {
        try database.write { db in
            let current = try Self.readSnapshot(in: db)
            let updated = try ImportEngine.unlink(plan, in: current.book)
            if updated != current.book { try Self.writeBook(updated, in: db) }
            let saved = try Self.readSnapshot(in: db)
            guard saved.book == updated, saved.draft == current.draft, saved.settings == current.settings else { throw LedgerStoreError.corruptData("import_unlink") }
            return saved
        }
    }

    public func applyImportRule(_ plan: ImportRuleApplyPlan) throws -> SQLiteLedgerSnapshot {
        try database.write { db in
            let current = try Self.readSnapshot(in: db)
            let updated = try ImportRuleEngine.apply(plan, in: current.book)
            try Self.writeBook(updated, in: db)
            let saved = try Self.readSnapshot(in: db)
            guard saved.book == updated, saved.draft == current.draft, saved.settings == current.settings else { throw LedgerStoreError.corruptData("import_rule_apply") }
            return saved
        }
    }

    public func applyImportBatchRules(_ plan: ImportRuleBatchPlan) throws -> SQLiteLedgerSnapshot {
        try database.write { db in
            let current = try Self.readSnapshot(in: db)
            let updated = try ImportRuleEngine.applyBatch(plan, in: current.book)
            try Self.writeBook(updated, in: db)
            let saved = try Self.readSnapshot(in: db)
            guard saved.book == updated, saved.draft == current.draft, saved.settings == current.settings else { throw LedgerStoreError.corruptData("import_batch_rules") }
            return saved
        }
    }

    public func undoImport(_ plan: ImportUndoPlan) throws -> SQLiteLedgerSnapshot {
        try database.write { db in
            let current = try Self.readSnapshot(in: db)
            let updated = try ImportEngine.undo(plan, in: current.book)
            if updated != current.book { try Self.writeBook(updated, in: db) }
            let saved = try Self.readSnapshot(in: db)
            guard saved.book == updated, saved.draft == current.draft, saved.settings == current.settings else {
                throw LedgerStoreError.corruptData("import_undo")
            }
            return saved
        }
    }

    public func commitImportLabels(_ plan: ImportLabelsPlan) throws -> SQLiteLedgerSnapshot {
        try database.write { db in
            let current = try Self.readSnapshot(in: db)
            let updated = try ImportEngine.commitLabels(plan, in: current.book)
            try Self.writeBook(updated, in: db)
            let saved = try Self.readSnapshot(in: db)
            guard saved.book == updated, saved.draft == current.draft, saved.settings == current.settings else {
                throw LedgerStoreError.corruptData("import_labels")
            }
            return saved
        }
    }

    public func commitImport(_ plan: ImportPlan, now: Date = Date()) throws -> SQLiteLedgerSnapshot {
        try database.write { db in
            let current = try Self.readSnapshot(in: db)
            let updated = try ImportEngine.commit(plan, in: current.book, now: now)
            if updated != current.book { try Self.writeBook(updated, in: db) }
            let saved = try Self.readSnapshot(in: db)
            guard saved.book == updated, saved.draft == current.draft, saved.settings == current.settings else {
                throw LedgerStoreError.corruptData("import_commit")
            }
            return saved
        }
    }

    public func deleteEntries(_ plan: EntryDeletionPlan) throws -> SQLiteLedgerSnapshot {
        try database.write { db in
            let current = try Self.readSnapshot(in: db)
            let updated = try LedgerEngine.delete(plan, in: current.book)
            try Self.writeBook(updated, in: db)
            let saved = try Self.readSnapshot(in: db)
            guard saved.book == updated, saved.draft == current.draft, saved.settings == current.settings else {
                throw LedgerStoreError.corruptData("delete_commit")
            }
            return saved
        }
    }

    private static func readDraft(in db: Database) throws -> EntryDraft? {
        guard let payload = try Data.fetchOne(db, sql: "SELECT payload FROM entry_draft WHERE singleton = 1") else {
            return nil
        }
        return try decode(EntryDraft.self, payload: payload, table: "entry_draft")
    }

    private static func readSettings(in db: Database) throws -> LedgerSettings {
        guard let payload = try Data.fetchOne(db, sql: "SELECT payload FROM ledger_settings WHERE singleton = 1") else {
            throw LedgerStoreError.corruptData("ledger_settings")
        }
        return try decode(LedgerSettings.self, payload: payload, table: "ledger_settings")
    }

    private static func updateEntry(_ entry: LedgerEntry, in db: Database) throws {
        var fields = columns(for: entry)
        fields.removeValue(forKey: "id")
        fields["payload"] = try encode(entry).databaseValue
        let names = fields.keys.sorted()
        let assignments = names.map { "\($0) = ?" }.joined(separator: ", ")
        let values = names.compactMap { fields[$0] } + [entry.id.uuidString.databaseValue]
        try db.execute(sql: "UPDATE entries SET \(assignments) WHERE id = ?", arguments: StatementArguments(values))
        try db.execute(sql: "DELETE FROM entry_tags WHERE entry_id = ?", arguments: [entry.id.uuidString])
        try writeTagLinks(entry, in: db)
    }

    private static func writeSettings(_ settings: LedgerSettings, in db: Database) throws {
        let payload = try encode(settings)
        try db.execute(sql: """
            INSERT INTO ledger_settings (singleton, payload) VALUES (1, ?)
            ON CONFLICT(singleton) DO UPDATE SET payload = excluded.payload
            """, arguments: [payload])
    }

    private static func writeDraft(_ draft: EntryDraft?, in db: Database) throws {
        if let draft {
            let payload = try encode(draft)
            try db.execute(sql: """
                INSERT INTO entry_draft (singleton, payload) VALUES (1, ?)
                ON CONFLICT(singleton) DO UPDATE SET payload = excluded.payload
                """, arguments: [payload])
        } else {
            try db.execute(sql: "DELETE FROM entry_draft")
        }
    }

    private static func writeBook(_ book: LedgerBook, in db: Database) throws {
        // Children precede parents. LedgerCore.Category self-references are deferred so
        // arbitrary display order, including children before parents, is valid.
        try db.execute(sql: """
            DELETE FROM import_rules;
            DELETE FROM import_batches;
            DELETE FROM entry_tags;
            DELETE FROM entries;
            DELETE FROM tags;
            DELETE FROM projects;
            DELETE FROM adjustments;
            DELETE FROM operation_registry;
            DELETE FROM categories;
            DELETE FROM subjects;
            DELETE FROM accounts;
            """)
        try writeRows(book.importRules, table: "import_rules", in: db) { columns(for: $0) }
        try writeRows(book.importBatches, table: "import_batches", in: db) { columns(for: $0) }
        try writeRows(book.tags, table: "tags", in: db) { columns(for: $0) }
        try writeRows(book.projects, table: "projects", in: db) { columns(for: $0) }
        try writeRows(book.accounts, table: "accounts", in: db) { columns(for: $0) }
        try writeRows(book.subjects, table: "subjects", in: db) { columns(for: $0) }
        try writeRows(book.categories, table: "categories", in: db) { columns(for: $0) }
        for entry in book.entries {
            try register(entry.operationID, recordID: entry.id, kind: "entry", in: db)
        }
        for adjustment in book.adjustments {
            try register(adjustment.operationID, recordID: adjustment.id, kind: "adjustment", in: db)
        }
        for operationID in book.retiredOperationIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            // Only the consumed operation ID survives deletion, never deleted
            // titles, amounts, account references, or other event contents.
            try db.execute(sql: """
                INSERT INTO operation_registry (operation_id, record_id, record_kind) VALUES (?, NULL, 'retired')
                """, arguments: [operationID.uuidString])
        }
        try writeRows(book.entries, table: "entries", in: db) { columns(for: $0) }
        for entry in book.entries { try writeTagLinks(entry, in: db) }
        try writeRows(book.adjustments, table: "adjustments", in: db) { columns(for: $0) }
    }

    private static func register(_ operationID: UUID, recordID: UUID, kind: String, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO operation_registry (operation_id, record_id, record_kind) VALUES (?, ?, ?)
            """, arguments: [operationID.uuidString, recordID.uuidString, kind])
    }

    private static func writeRows<Value: Encodable>(
        _ values: [Value], table: String, in db: Database,
        projection: (Value) -> [String: DatabaseValue]
    ) throws {
        for (position, value) in values.enumerated() {
            try insertRow(value, position: position, table: table, fields: projection(value), in: db)
        }
    }

    private static func insertRow<Value: Encodable>(
        _ value: Value, position: Int, table: String, fields projection: [String: DatabaseValue], in db: Database
    ) throws {
        var fields = projection
        fields["position"] = position.databaseValue
        fields["payload"] = try encode(value).databaseValue
        let names = fields.keys.sorted()
        // Table/column names only originate in this file, never user input.
        let placeholders = Array(repeating: "?", count: names.count).joined(separator: ", ")
        let arguments = StatementArguments(names.compactMap { fields[$0] })
        try db.execute(sql: "INSERT INTO \(table) (\(names.joined(separator: ", "))) VALUES (\(placeholders))",
                       arguments: arguments)
    }

    private static func readBook(in db: Database, checkingRelationships: Bool = true) throws -> LedgerBook {
        let retiredStrings = try String.fetchAll(db, sql: """
            SELECT operation_id FROM operation_registry WHERE record_kind = 'retired'
            """)
        let retiredIDs = try Set(retiredStrings.map { value -> UUID in
            guard let id = UUID(uuidString: value), id.uuidString == value else {
                throw LedgerStoreError.corruptData("operation_registry")
            }
            return id
        })
        let book = LedgerBook(
            accounts: try readRows(Account.self, table: "accounts", in: db) { columns(for: $0) },
            entries: try readRows(LedgerEntry.self, table: "entries", in: db) { columns(for: $0) },
            adjustments: try readRows(BalanceAdjustment.self, table: "adjustments", in: db) { columns(for: $0) },
            subjects: try readRows(LedgerCore.Subject.self, table: "subjects", in: db) { columns(for: $0) },
            categories: try readRows(LedgerCore.Category.self, table: "categories", in: db) { columns(for: $0) },
            retiredOperationIDs: retiredIDs,
            tags: try readRows(EntryTag.self, table: "tags", in: db) { columns(for: $0) },
            projects: try readRows(EntryProject.self, table: "projects", in: db) { columns(for: $0) },
            importBatches: try readRows(ImportBatch.self, table: "import_batches", in: db) { columns(for: $0) },
            importRules: try readRows(ImportRule.self, table: "import_rules", in: db) { columns(for: $0) })
        // Validate all links in one query; full-book reads must not add one SQL read per entry.
        var storedLinks: [String: [String]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT entry_id, tag_id, position FROM entry_tags ORDER BY entry_id, position") {
            let entryID: String = try row.decode(forColumn: "entry_id")
            let tagID: String = try row.decode(forColumn: "tag_id")
            let position: Int = try row.decode(forColumn: "position")
            guard position == storedLinks[entryID, default: []].count else { throw LedgerStoreError.corruptData("entry_tags") }
            storedLinks[entryID, default: []].append(tagID)
        }
        for entry in book.entries {
            guard (storedLinks.removeValue(forKey: entry.id.uuidString) ?? []) == entry.tagIDs.map(\.uuidString) else {
                throw LedgerStoreError.corruptData("entry_tags")
            }
        }
        guard storedLinks.isEmpty else { throw LedgerStoreError.corruptData("entry_tags") }
        try LedgerEngine.validate(book)
        if checkingRelationships { try checkRelationships(db) }
        return book
    }

    private static func readRows<Value: Decodable>(
        _ type: Value.Type, table: String, in db: Database,
        projection: (Value) -> [String: DatabaseValue]
    ) throws -> [Value] {
        try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY position").enumerated().map { index, row in
            let position: Int = try row.decode(forColumn: "position")
            guard position == index else { throw LedgerStoreError.corruptData(table) }
            let payload: Data = try row.decode(forColumn: "payload")
            let value = try decode(type, payload: payload, table: table)
            for (column, expected) in projection(value) {
                let stored: DatabaseValue = try row.decode(forColumn: column)
                guard stored == expected else { throw LedgerStoreError.corruptData(table) }
            }
            return value
        }
    }

    private static func checkSchema(_ db: Database) throws {
        let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        guard version == schemaVersion else { throw LedgerStoreError.unsupportedSchemaVersion(version) }
        guard try Int.fetchOne(db, sql: "PRAGMA application_id") == applicationID else {
            throw LedgerStoreError.unrecognizedDatabase
        }
    }

    private static func checkDatabase(_ db: Database) throws {
        try checkSchema(db)
        guard try String.fetchAll(db, sql: "PRAGMA quick_check") == ["ok"] else {
            throw LedgerStoreError.corruptData("integrity")
        }
        try checkRelationships(db)
    }

    private static func checkRelationships(_ db: Database) throws {
        guard try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
            throw LedgerStoreError.corruptData("relationships")
        }
        let orphanCount = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM operation_registry AS operation
            WHERE (record_kind = 'entry' AND NOT EXISTS (
                SELECT 1 FROM entries WHERE entries.id = operation.record_id
                    AND entries.operation_id = operation.operation_id))
               OR (record_kind = 'adjustment' AND NOT EXISTS (
                SELECT 1 FROM adjustments WHERE adjustments.id = operation.record_id
                    AND adjustments.operation_id = operation.operation_id))
            """) ?? 0
        guard orphanCount == 0 else { throw LedgerStoreError.corruptData("operation_registry") }
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Foundation's reference-date Double round-trips subsecond Date values;
        // ISO8601's default formatter would discard fractional seconds.
        encoder.dateEncodingStrategy = .deferredToDate
        return try encoder.encode(value)
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, payload: Data, table: String) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        do { return try decoder.decode(type, from: payload) }
        catch { throw LedgerStoreError.corruptData(table) }
    }

    private static func columns(for account: Account) -> [String: DatabaseValue] {
        ["id": account.id.uuidString.databaseValue, "name": account.name.databaseValue,
         "kind": account.kind.rawValue.databaseValue, "nature": account.nature.rawValue.databaseValue,
         "currency": account.currency.rawValue.databaseValue, "opening_minor": account.openingMinor.databaseValue,
         "opening_date": account.openingDate.timeIntervalSinceReferenceDate.databaseValue,
         "included_in_summary": account.includedInSummary.databaseValue, "is_active": account.isActive.databaseValue,
         "institution_id": account.institutionID?.databaseValue ?? .null,
         "template_id": account.templateID?.databaseValue ?? .null,
         "icon_id": account.iconID?.databaseValue ?? .null]
    }

    private static func columns(for subject: LedgerCore.Subject) -> [String: DatabaseValue] {
        ["id": subject.id.uuidString.databaseValue, "name": subject.name.databaseValue,
         "is_active": subject.isActive.databaseValue]
    }

    private static func columns(for category: LedgerCore.Category) -> [String: DatabaseValue] {
        ["id": category.id.uuidString.databaseValue, "parent_id": category.parentID?.uuidString.databaseValue ?? .null,
         "name": category.name.databaseValue, "direction": category.direction.rawValue.databaseValue,
         "symbol": category.symbol.databaseValue, "is_active": category.isActive.databaseValue]
    }

    private static func writeTagLinks(_ entry: LedgerEntry, in db: Database) throws {
        for (position, id) in entry.tagIDs.enumerated() {
            try db.execute(sql: "INSERT INTO entry_tags(entry_id, tag_id, position) VALUES (?, ?, ?)",
                           arguments: [entry.id.uuidString, id.uuidString, position])
        }
    }

    private static func checkTagLinks(_ entry: LedgerEntry, in db: Database) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT tag_id, position FROM entry_tags WHERE entry_id = ? ORDER BY position",
                                   arguments: [entry.id.uuidString])
        guard rows.count == entry.tagIDs.count else { throw LedgerStoreError.corruptData("entry_tags") }
        for (index, row) in rows.enumerated() {
            let id: String = try row.decode(forColumn: "tag_id")
            let position: Int = try row.decode(forColumn: "position")
            guard position == index, id == entry.tagIDs[index].uuidString else { throw LedgerStoreError.corruptData("entry_tags") }
        }
    }

    private static func columns(for rule: ImportRule) -> [String: DatabaseValue] {
        ["id": rule.id.uuidString.databaseValue, "name": rule.name.databaseValue, "priority": rule.priority.databaseValue,
         "version": rule.version.databaseValue, "is_enabled": rule.isEnabled.databaseValue]
    }

    private static func columns(for batch: ImportBatch) -> [String: DatabaseValue] {
        ["id": batch.id.uuidString.databaseValue, "name": batch.name.databaseValue,
         "namespace": batch.namespace.databaseValue, "version": batch.version.databaseValue,
         "created_at": batch.createdAt.timeIntervalSinceReferenceDate.databaseValue]
    }

    private static func columns(for tag: EntryTag) -> [String: DatabaseValue] {
        ["id": tag.id.uuidString.databaseValue, "name": tag.name.databaseValue, "is_active": tag.isActive.databaseValue]
    }

    private static func columns(for project: EntryProject) -> [String: DatabaseValue] {
        ["id": project.id.uuidString.databaseValue, "name": project.name.databaseValue, "is_archived": project.isArchived.databaseValue]
    }

    private static func columns(for entry: LedgerEntry) -> [String: DatabaseValue] {
        ["id": entry.id.uuidString.databaseValue, "operation_id": entry.operationID.uuidString.databaseValue,
         "record_kind": "entry".databaseValue, "kind": entry.kind.rawValue.databaseValue,
         "account_id": entry.accountID.uuidString.databaseValue,
         "destination_account_id": entry.destinationAccountID?.uuidString.databaseValue ?? .null,
         "category_id": entry.categoryID?.uuidString.databaseValue ?? .null,
         "subject_id": entry.subjectID.uuidString.databaseValue,
         "amount_minor": entry.amount.minorUnits.databaseValue, "currency": entry.amount.currency.rawValue.databaseValue,
         "occurred_at": entry.occurredAt.timeIntervalSinceReferenceDate.databaseValue,
         "created_at": entry.createdAt.timeIntervalSinceReferenceDate.databaseValue, "version": entry.version.databaseValue,
         "project_id": entry.projectID?.uuidString.databaseValue ?? .null,
         "original_entry_id": entry.originalEntryID?.uuidString.databaseValue ?? .null,
         "allows_net_recovery": entry.allowsNetRecovery?.databaseValue ?? .null]
    }

    private static func columns(for adjustment: BalanceAdjustment) -> [String: DatabaseValue] {
        ["id": adjustment.id.uuidString.databaseValue, "operation_id": adjustment.operationID.uuidString.databaseValue,
         "record_kind": "adjustment".databaseValue, "account_id": adjustment.accountID.uuidString.databaseValue,
         "difference_minor": adjustment.difference.minorUnits.databaseValue,
         "currency": adjustment.difference.currency.rawValue.databaseValue,
         "target_minor": adjustment.target.minorUnits.databaseValue,
         "target_currency": adjustment.target.currency.rawValue.databaseValue,
         "occurred_at": adjustment.occurredAt.timeIntervalSinceReferenceDate.databaseValue]
    }

    private static let ruleSchema = """
        CREATE TABLE import_rules (
            id TEXT PRIMARY KEY NOT NULL,
            position INTEGER NOT NULL UNIQUE CHECK (position >= 0),
            name TEXT NOT NULL, priority INTEGER NOT NULL CHECK (priority BETWEEN 0 AND 10000),
            version INTEGER NOT NULL CHECK (version > 0), is_enabled INTEGER NOT NULL CHECK (is_enabled IN (0, 1)),
            payload BLOB NOT NULL CHECK (typeof(payload) = 'blob')
        );
        """

    private static let importSchema = """
        CREATE TABLE import_batches (
            id TEXT PRIMARY KEY NOT NULL,
            position INTEGER NOT NULL UNIQUE CHECK (position >= 0),
            name TEXT NOT NULL, namespace TEXT NOT NULL, version INTEGER NOT NULL CHECK (version > 0),
            created_at REAL NOT NULL, payload BLOB NOT NULL CHECK (typeof(payload) = 'blob')
        );
        """

    private static let labelSchema = """
        CREATE TABLE tags (
            id TEXT PRIMARY KEY NOT NULL,
            position INTEGER NOT NULL UNIQUE CHECK (position >= 0),
            name TEXT NOT NULL, is_active INTEGER NOT NULL CHECK (is_active IN (0, 1)),
            payload BLOB NOT NULL CHECK (typeof(payload) = 'blob')
        );
        CREATE TABLE projects (
            id TEXT PRIMARY KEY NOT NULL,
            position INTEGER NOT NULL UNIQUE CHECK (position >= 0),
            name TEXT NOT NULL, is_archived INTEGER NOT NULL CHECK (is_archived IN (0, 1)),
            payload BLOB NOT NULL CHECK (typeof(payload) = 'blob')
        );
        CREATE TABLE entry_tags (
            entry_id TEXT NOT NULL REFERENCES entries(id),
            tag_id TEXT NOT NULL REFERENCES tags(id),
            position INTEGER NOT NULL CHECK (position >= 0),
            PRIMARY KEY (entry_id, tag_id), UNIQUE (entry_id, position)
        );
        CREATE INDEX entry_tags_tag ON entry_tags(tag_id, entry_id);
        """

    private static let initialSchema = """
        CREATE TABLE accounts (
            id TEXT PRIMARY KEY NOT NULL,
            position INTEGER NOT NULL UNIQUE CHECK (position >= 0),
            name TEXT NOT NULL, kind TEXT NOT NULL, nature TEXT NOT NULL, currency TEXT NOT NULL,
            opening_minor INTEGER NOT NULL CHECK (typeof(opening_minor) = 'integer'),
            opening_date REAL NOT NULL,
            included_in_summary INTEGER NOT NULL CHECK (included_in_summary IN (0, 1)),
            is_active INTEGER NOT NULL CHECK (is_active IN (0, 1)),
            institution_id TEXT, template_id TEXT, icon_id TEXT,
            payload BLOB NOT NULL CHECK (typeof(payload) = 'blob')
        );
        CREATE TABLE subjects (
            id TEXT PRIMARY KEY NOT NULL,
            position INTEGER NOT NULL UNIQUE CHECK (position >= 0),
            name TEXT NOT NULL, is_active INTEGER NOT NULL CHECK (is_active IN (0, 1)),
            payload BLOB NOT NULL CHECK (typeof(payload) = 'blob')
        );
        CREATE TABLE categories (
            id TEXT PRIMARY KEY NOT NULL,
            position INTEGER NOT NULL UNIQUE CHECK (position >= 0),
            parent_id TEXT REFERENCES categories(id) DEFERRABLE INITIALLY DEFERRED,
            name TEXT NOT NULL, direction TEXT NOT NULL, symbol TEXT NOT NULL,
            is_active INTEGER NOT NULL CHECK (is_active IN (0, 1)),
            payload BLOB NOT NULL CHECK (typeof(payload) = 'blob')
        );
        CREATE INDEX categories_parent ON categories(parent_id);
        CREATE TABLE operation_registry (
            operation_id TEXT PRIMARY KEY NOT NULL,
            record_id TEXT,
            record_kind TEXT NOT NULL CHECK (record_kind IN ('entry', 'adjustment', 'retired')),
            CHECK ((record_kind = 'retired' AND record_id IS NULL)
                OR (record_kind != 'retired' AND record_id IS NOT NULL)),
            UNIQUE (record_id, record_kind),
            UNIQUE (operation_id, record_id, record_kind)
        );
        CREATE TABLE entries (
            id TEXT PRIMARY KEY NOT NULL,
            position INTEGER NOT NULL UNIQUE CHECK (position >= 0),
            operation_id TEXT NOT NULL UNIQUE,
            record_kind TEXT NOT NULL CHECK (record_kind = 'entry'),
            kind TEXT NOT NULL,
            account_id TEXT NOT NULL REFERENCES accounts(id),
            destination_account_id TEXT REFERENCES accounts(id),
            category_id TEXT REFERENCES categories(id),
            subject_id TEXT NOT NULL REFERENCES subjects(id),
            amount_minor INTEGER NOT NULL CHECK (typeof(amount_minor) = 'integer' AND amount_minor > 0),
            currency TEXT NOT NULL, occurred_at REAL NOT NULL, created_at REAL NOT NULL,
            version INTEGER NOT NULL CHECK (version > 0),
            project_id TEXT REFERENCES projects(id),
            original_entry_id TEXT REFERENCES entries(id) DEFERRABLE INITIALLY DEFERRED,
            allows_net_recovery INTEGER CHECK (allows_net_recovery IS NULL OR allows_net_recovery IN (0, 1)),
            payload BLOB NOT NULL CHECK (typeof(payload) = 'blob'),
            FOREIGN KEY (operation_id, id, record_kind)
                REFERENCES operation_registry(operation_id, record_id, record_kind)
        );
        CREATE INDEX entries_account_date ON entries(account_id, occurred_at);
        CREATE INDEX entries_destination ON entries(destination_account_id);
        CREATE INDEX entries_category ON entries(category_id);
        CREATE INDEX entries_subject ON entries(subject_id);
        CREATE TABLE adjustments (
            id TEXT PRIMARY KEY NOT NULL,
            position INTEGER NOT NULL UNIQUE CHECK (position >= 0),
            operation_id TEXT NOT NULL UNIQUE,
            record_kind TEXT NOT NULL CHECK (record_kind = 'adjustment'),
            account_id TEXT NOT NULL REFERENCES accounts(id),
            difference_minor INTEGER NOT NULL CHECK (typeof(difference_minor) = 'integer'),
            currency TEXT NOT NULL,
            target_minor INTEGER NOT NULL CHECK (typeof(target_minor) = 'integer'),
            target_currency TEXT NOT NULL, occurred_at REAL NOT NULL,
            payload BLOB NOT NULL CHECK (typeof(payload) = 'blob'),
            FOREIGN KEY (operation_id, id, record_kind)
                REFERENCES operation_registry(operation_id, record_id, record_kind)
        );
        CREATE INDEX adjustments_account_date ON adjustments(account_id, occurred_at);
        CREATE TABLE entry_draft (
            singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
            payload BLOB NOT NULL CHECK (typeof(payload) = 'blob')
        );
        CREATE TABLE ledger_settings (
            singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
            payload BLOB NOT NULL CHECK (typeof(payload) = 'blob')
        );
        """
}
