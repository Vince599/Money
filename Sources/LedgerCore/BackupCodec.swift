import Foundation

public struct LedgerBackupSnapshot: Equatable, Sendable {
    public var book: LedgerBook
    public var draft: EntryDraft?
    public var settings: LedgerSettings

    public init(book: LedgerBook, draft: EntryDraft?, settings: LedgerSettings) {
        self.book = book; self.draft = draft; self.settings = settings
    }
}

/// Complete, lossless backup of the currently implemented LedgerCore model.
/// This profile does not claim to contain the unimplemented entities in the product roadmap.
/// The result is a fixed set of CSV bytes; archive transport and atomic restore are separate layers.
public enum BackupCodec {
    public static func encode(_ snapshot: LedgerBackupSnapshot, createdAt: Date = Date()) throws -> [String: Data] {
        try validate(snapshot)
        guard BackupDates.isSupported(createdAt) else { throw BackupError.invalidSnapshot(reason: "Invalid backup creation date") }
        let book = snapshot.book
        var rows: [String: [[String?]]] = [:]
        rows[BackupSchema.accounts.name] = try book.accounts.enumerated().map { index, account in
            [String(index), id(account.id), account.name, account.kind.rawValue, account.nature.rawValue,
             account.currency.rawValue, String(account.openingMinor)] + (try BackupDates.values(account.openingDate))
                + [String(account.includedInSummary), String(account.isActive), account.institutionID, account.templateID, account.iconID]
        }
        rows[BackupSchema.subjects.name] = book.subjects.enumerated().map { index, subject in
            [String(index), id(subject.id), subject.name, String(subject.isActive)]
        }
        rows[BackupSchema.categories.name] = book.categories.enumerated().map { index, category in
            [String(index), id(category.id), category.name, id(category.parentID), category.direction.rawValue, category.symbol, String(category.isActive)]
        }
        rows[BackupSchema.entries.name] = try book.entries.enumerated().map { index, entry in
            [String(index), id(entry.id), id(entry.operationID), entry.kind.rawValue, String(entry.amount.minorUnits),
             entry.amount.currency.rawValue, id(entry.accountID), id(entry.destinationAccountID), id(entry.categoryID), id(entry.subjectID)]
                + (try BackupDates.values(entry.occurredAt)) + (try BackupDates.values(entry.createdAt))
                + [entry.title, entry.note, String(entry.version)]
        }
        rows[BackupSchema.adjustments.name] = try book.adjustments.enumerated().map { index, adjustment in
            [String(index), id(adjustment.id), id(adjustment.operationID), id(adjustment.accountID), String(adjustment.difference.minorUnits),
             adjustment.difference.currency.rawValue, String(adjustment.target.minorUnits), adjustment.target.currency.rawValue]
                + (try BackupDates.values(adjustment.occurredAt)) + [adjustment.note]
        }
        rows[BackupSchema.retired.name] = book.retiredOperationIDs.map { $0.uuidString.lowercased() }.sorted().map { [$0] }
        if let draft = snapshot.draft {
            rows[BackupSchema.draft.name] = [[id(draft.entryID), id(draft.operationID), draft.kind.rawValue, draft.amountText,
                id(draft.accountID), id(draft.destinationAccountID), id(draft.subjectID), id(draft.expenseCategoryID), id(draft.incomeCategoryID)]
                + (try BackupDates.values(draft.occurredAt)) + [draft.title, draft.note]]
        } else { rows[BackupSchema.draft.name] = [] }
        rows[BackupSchema.settings.name] = [[id(snapshot.settings.defaultAccountID), id(snapshot.settings.defaultSubjectID)]]
        let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unbundled"
        rows[BackupSchema.manifest.name] = [[BackupSchema.profile, BackupSchema.version, BackupSchema.dbVersion, appVersion, "true"]
            + (try BackupDates.values(createdAt)) + [String(BackupSchema.all.count)]]
        rows[BackupSchema.dictionary.name] = BackupSchema.dictionaryRecords
        // counts includes itself and checksums; neither needs its own byte hash/size to compute its row count.
        rows[BackupSchema.counts.name] = BackupSchema.all.map { table in
            let count = table.name == BackupSchema.counts.name ? BackupSchema.all.count
                : table.name == BackupSchema.checksums.name ? BackupSchema.all.count - 1 : rows[table.name, default: []].count
            return [table.name, String(count)]
        }
        var files: [String: Data] = [:]
        for table in BackupSchema.all where table.name != BackupSchema.checksums.name {
            let records = [table.header] + rows[table.name, default: []]
            guard records.count <= BackupCSV.maxRecords,
                  records.allSatisfy({ $0.count <= BackupCSV.maxColumns && $0.allSatisfy({
                      // The parser counts the backslash-escaped field before text unescaping.
                      ($0?.utf8.reduce(0, { $0 + ($1 == 92 ? 2 : 1) }) ?? 2) <= BackupCSV.maxCellBytes
                  }) }) else { throw BackupError.invalidSnapshot(reason: "CSV record, column or cell limit exceeded") }
            let data = BackupCSV.encode(records)
            guard data.count <= BackupCSV.maxFileBytes else { throw BackupError.invalidSnapshot(reason: "CSV file too large") }
            files[table.name] = data
        }
        let checksumRows: [[String?]] = files.keys.sorted().map { [$0, BackupSHA256.hex(files[$0]!)] }
        files[BackupSchema.checksums.name] = BackupCSV.encode([BackupSchema.checksums.header] + checksumRows)
        guard files.values.reduce(0, { $0 + $1.count }) <= BackupCSV.maxTotalBytes else {
            throw BackupError.invalidSnapshot(reason: "Backup exceeds total size limit")
        }
        return files
    }

    public static func decode(_ files: [String: Data]) throws -> LedgerBackupSnapshot {
        guard Set(files.keys) == BackupSchema.fileNames else {
            throw BackupError.invalidArchive(reason: "Missing or unknown backup files")
        }
        guard files.values.allSatisfy({ $0.count <= BackupCSV.maxFileBytes }),
              files.values.reduce(0, { $0 + $1.count }) <= BackupCSV.maxTotalBytes else {
            throw BackupError.invalidArchive(reason: "Backup size limit exceeded")
        }
        // Verify the exact raw bytes before CSV decoding any of the protected files.
        let checksums = try BackupSchema.checksums.read(files[BackupSchema.checksums.name]!)
        var checked = Set<String>()
        for row in checksums {
            let file = try row.string("file")
            guard file != BackupSchema.checksums.name, let data = files[file], checked.insert(file).inserted,
                  try row.string("sha256") == BackupSHA256.hex(data) else {
                throw BackupError.invalidArchive(reason: "Duplicate, unknown or mismatched checksum: \(file)")
            }
        }
        guard checked == BackupSchema.fileNames.subtracting([BackupSchema.checksums.name]) else {
            throw BackupError.invalidArchive(reason: "Incomplete checksum list")
        }
        let manifests = try BackupSchema.manifest.read(files[BackupSchema.manifest.name]!)
        guard manifests.count == 1 else { throw BackupError.invalidArchive(reason: "Expected one manifest") }
        let manifest = manifests[0]
        let profile = try manifest.string("profile")
        let version = try manifest.string("backup_format_version")
        let dbVersion = try manifest.string("db_schema_version")
        let contractTables: [BackupTable]
        let accountTable: BackupTable
        switch (profile, version, dbVersion) {
        case (BackupSchema.profile, BackupSchema.version, BackupSchema.dbVersion):
            contractTables = BackupSchema.all
            accountTable = BackupSchema.accounts
        case (BackupSchema.legacyProfile, BackupSchema.legacyVersion, BackupSchema.legacyDBVersion):
            contractTables = BackupSchema.legacyAll
            accountTable = BackupSchema.legacyAccounts
        default:
            let reportedVersion = (profile == BackupSchema.profile && version == BackupSchema.version)
                || (profile == BackupSchema.legacyProfile && version == BackupSchema.legacyVersion)
                ? version + ";db=" + dbVersion : version
            throw BackupError.unsupportedFormat(profile: profile, version: reportedVersion)
        }
        guard try manifest.bool("complete"), try manifest.int("file_count") == contractTables.count,
              try !manifest.string("app_version").isEmpty else { throw BackupError.invalidArchive(reason: "Incomplete manifest") }
        _ = try manifest.date("created_at")
        guard files[BackupSchema.dictionary.name] == BackupSchema.dictionaryData(for: contractTables) else {
            throw BackupError.invalidArchive(reason: "Schema dictionary differs from the supported contract")
        }
        var tables: [String: [BackupRow]] = [:]
        for table in contractTables { tables[table.name] = try table.read(files[table.name]!) }
        var counted = Set<String>()
        for row in tables[BackupSchema.counts.name]! {
            let name = try row.string("file")
            guard let records = tables[name], counted.insert(name).inserted, try row.int("row_count") == records.count else {
                throw BackupError.invalidArchive(reason: "Duplicate, unknown or incorrect row count: \(name)")
            }
        }
        guard counted == BackupSchema.fileNames else { throw BackupError.invalidArchive(reason: "Incomplete row counts") }
        func ordered(_ table: BackupTable) throws -> [BackupRow] {
            let records = tables[table.name]!
            for (position, row) in records.enumerated() {
                guard try row.int("position") == position else { throw BackupError.invalidArchive(reason: "Invalid row order: \(table.name)") }
            }
            return records
        }
        let accounts = try ordered(accountTable).map { row in
            Account(id: try row.uuid("id"), name: try row.string("name"), kind: try row.enumeration("kind"), nature: try row.enumeration("nature"),
                    currency: try row.enumeration("currency"), openingMinor: try row.int64("opening_minor"), openingDate: try row.date("opening_at"),
                    includedInSummary: try row.bool("included_in_summary"), isActive: try row.bool("is_active"),
                    institutionID: row.optionalString("institution_id"), templateID: row.optionalString("template_id"),
                    iconID: row.optionalString("icon_id"))
        }
        let subjects = try ordered(BackupSchema.subjects).map { row in
            Subject(id: try row.uuid("id"), name: try row.string("name"), isActive: try row.bool("is_active"))
        }
        let categories = try ordered(BackupSchema.categories).map { row in
            Category(id: try row.uuid("id"), name: try row.string("name"), parentID: try row.optionalUUID("parent_id"),
                     direction: try row.enumeration("direction"), symbol: try row.string("symbol"), isActive: try row.bool("is_active"))
        }
        let entries = try ordered(BackupSchema.entries).map { row in
            LedgerEntry(id: try row.uuid("id"), operationID: try row.uuid("operation_id"), kind: try row.enumeration("kind"),
                        amount: Money(minorUnits: try row.int64("amount_minor"), currency: try row.enumeration("currency")),
                        accountID: try row.uuid("account_id"), destinationAccountID: try row.optionalUUID("destination_account_id"),
                        categoryID: try row.optionalUUID("category_id"), subjectID: try row.uuid("subject_id"),
                        occurredAt: try row.date("occurred_at"), createdAt: try row.date("created_at"),
                        title: try row.string("title"), note: try row.string("note"), version: try row.int("version"))
        }
        let adjustments = try ordered(BackupSchema.adjustments).map { row in
            BalanceAdjustment(id: try row.uuid("id"), operationID: try row.uuid("operation_id"), accountID: try row.uuid("account_id"),
                              difference: Money(minorUnits: try row.int64("difference_minor"), currency: try row.enumeration("difference_currency")),
                              target: Money(minorUnits: try row.int64("target_minor"), currency: try row.enumeration("target_currency")),
                              occurredAt: try row.date("occurred_at"), note: try row.string("note"))
        }
        let retired = try tables[BackupSchema.retired.name]!.map { try $0.uuid("operation_id") }
        guard Set(retired).count == retired.count else { throw BackupError.invalidArchive(reason: "Duplicate retired operation ID") }
        let draftRows = tables[BackupSchema.draft.name]!, settingRows = tables[BackupSchema.settings.name]!
        guard draftRows.count <= 1, settingRows.count == 1 else { throw BackupError.invalidArchive(reason: "Invalid draft or settings row count") }
        let draft = try draftRows.first.map { row in
            EntryDraft(entryID: try row.uuid("entry_id"), operationID: try row.uuid("operation_id"), kind: try row.enumeration("kind"),
                       amountText: try row.string("amount_text"), accountID: try row.optionalUUID("account_id"),
                       destinationAccountID: try row.optionalUUID("destination_account_id"), subjectID: try row.uuid("subject_id"),
                       expenseCategoryID: try row.optionalUUID("expense_category_id"), incomeCategoryID: try row.optionalUUID("income_category_id"),
                       occurredAt: try row.date("occurred_at"), title: try row.string("title"), note: try row.string("note"))
        }
        let settings = LedgerSettings(defaultAccountID: try settingRows[0].optionalUUID("default_account_id"),
                                      defaultSubjectID: try settingRows[0].uuid("default_subject_id"))
        let book = LedgerBook(accounts: accounts, entries: entries, adjustments: adjustments, subjects: subjects,
                              categories: categories, retiredOperationIDs: Set(retired))
        let snapshot = LedgerBackupSnapshot(book: book, draft: draft, settings: settings)
        do { try validate(snapshot) }
        catch { throw BackupError.invalidArchive(reason: "Invalid restored snapshot: \(error)") }
        return snapshot
    }

    private static func id(_ value: UUID?) -> String? { value?.uuidString.lowercased() }

    private static func validate(_ snapshot: LedgerBackupSnapshot) throws {
        let book = snapshot.book
        do { try LedgerEngine.validate(book) }
        catch { throw BackupError.invalidSnapshot(reason: "Ledger validation failed: \(error)") }
        let dates = book.accounts.map(\.openingDate) + book.entries.flatMap { [$0.occurredAt, $0.createdAt] }
            + book.adjustments.map(\.occurredAt) + (snapshot.draft.map { [$0.occurredAt] } ?? [])
        guard dates.allSatisfy(BackupDates.isSupported) else { throw BackupError.invalidSnapshot(reason: "Invalid or unsupported date") }
        let accounts = Dictionary(uniqueKeysWithValues: book.accounts.map { ($0.id, $0) })
        let subjects = Dictionary(uniqueKeysWithValues: book.subjects.map { ($0.id, $0) })
        if let id = snapshot.settings.defaultAccountID, accounts[id]?.isActive != true {
            throw BackupError.invalidSnapshot(reason: "Default account is missing or inactive")
        }
        guard subjects[snapshot.settings.defaultSubjectID]?.isActive == true else {
            throw BackupError.invalidSnapshot(reason: "Default subject is missing or inactive")
        }
        // An unfinished draft is not a posted event. Preserve missing/disabled selections
        // and invalid amount text for UI repair, consistently with SQLiteLedgerStore.
        // Its Date is checked above; UUID and enum syntax are checked during CSV parsing.
    }
}
