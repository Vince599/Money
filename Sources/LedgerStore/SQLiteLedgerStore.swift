import Foundation
import GRDB
import LedgerCore

public enum LedgerStoreError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case unrecognizedDatabase
    case corruptData(String)
}

/// Whether an ordinary new-entry command keeps or replaces the current draft.
/// Editing a saved entry always preserves the unrelated new-entry draft.
public enum EntryDraftUpdate: Sendable {
    case preserve
    case replace(EntryDraft?)
}

/// Constructed inside the transaction and returned only after a successful commit.
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
    public static let schemaVersion = 1
    private static let applicationID = 0x4C444752 // "LDGR"
    private let database: DatabaseQueue

    public init(path: String) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        database = try DatabaseQueue(path: path, configuration: configuration)
        try database.write { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            guard version == 0 || version == Self.schemaVersion else {
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
                try db.execute(sql: Self.initialSchema)
                let seed = LedgerBook()
                try LedgerEngine.validate(seed)
                try Self.writeBook(seed, in: db)
                try Self.writeSettings(LedgerSettings(), in: db)
                try db.execute(sql: "PRAGMA application_id = \(Self.applicationID)")
                try db.execute(sql: "PRAGMA user_version = \(Self.schemaVersion)")
            }
            try Self.checkDatabase(db)
            _ = try Self.readBook(in: db)
        }
    }

    public func loadBook() throws -> LedgerBook {
        try database.read { db in
            try Self.checkDatabase(db)
            return try Self.readBook(in: db)
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
            DELETE FROM entries;
            DELETE FROM adjustments;
            DELETE FROM operation_registry;
            DELETE FROM categories;
            DELETE FROM subjects;
            DELETE FROM accounts;
            """)
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

    private static func readBook(in db: Database) throws -> LedgerBook {
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
            retiredOperationIDs: retiredIDs)
        try LedgerEngine.validate(book)
        try checkRelationships(db)
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
         "included_in_summary": account.includedInSummary.databaseValue, "is_active": account.isActive.databaseValue]
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

    private static func columns(for entry: LedgerEntry) -> [String: DatabaseValue] {
        ["id": entry.id.uuidString.databaseValue, "operation_id": entry.operationID.uuidString.databaseValue,
         "record_kind": "entry".databaseValue, "kind": entry.kind.rawValue.databaseValue,
         "account_id": entry.accountID.uuidString.databaseValue,
         "destination_account_id": entry.destinationAccountID?.uuidString.databaseValue ?? .null,
         "category_id": entry.categoryID?.uuidString.databaseValue ?? .null,
         "subject_id": entry.subjectID.uuidString.databaseValue,
         "amount_minor": entry.amount.minorUnits.databaseValue, "currency": entry.amount.currency.rawValue.databaseValue,
         "occurred_at": entry.occurredAt.timeIntervalSinceReferenceDate.databaseValue,
         "created_at": entry.createdAt.timeIntervalSinceReferenceDate.databaseValue, "version": entry.version.databaseValue]
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

    private static let initialSchema = """
        CREATE TABLE accounts (
            id TEXT PRIMARY KEY NOT NULL,
            position INTEGER NOT NULL UNIQUE CHECK (position >= 0),
            name TEXT NOT NULL, kind TEXT NOT NULL, nature TEXT NOT NULL, currency TEXT NOT NULL,
            opening_minor INTEGER NOT NULL CHECK (typeof(opening_minor) = 'integer'),
            opening_date REAL NOT NULL,
            included_in_summary INTEGER NOT NULL CHECK (included_in_summary IN (0, 1)),
            is_active INTEGER NOT NULL CHECK (is_active IN (0, 1)),
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
