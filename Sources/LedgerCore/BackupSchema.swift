import Foundation

struct BackupColumn: Sendable {
    let name: String
    let type: String
    var nullable = false
    var unit = ""
    var precision = ""
    var values = ""
    var reference = ""
    var meaning = ""
}

struct BackupTable: Sendable {
    let name: String
    let columns: [BackupColumn]
    var header: [String?] { columns.map(\.name) }

    func read(_ data: Data) throws -> [BackupRow] {
        let records = try BackupCSV.decode(data, file: name)
        guard records[0] == columns.map(\.name) else {
            throw BackupError.invalidArchive(reason: "Unknown, missing or reordered columns: \(name)")
        }
        return try records.dropFirst().map { record in
            guard record.count == columns.count else {
                throw BackupError.invalidArchive(reason: "Column count mismatch: \(name)")
            }
            var result: [String: String] = [:]
            for (column, raw) in zip(columns, record) {
                if raw == "\\N" {
                    guard column.nullable else { throw BackupError.invalidArchive(reason: "Unexpected null: \(name).\(column.name)") }
                    continue
                }
                let value = column.type == "text" ? try BackupCSV.text(raw, file: name) : raw
                let valid: Bool
                switch column.type {
                case "text": valid = true
                case "uuid": valid = UUID(uuidString: value)?.uuidString.lowercased() == value
                case "int64": valid = Int64(value).map { String($0) == value } ?? false
                case "uint": valid = Int(value).map { $0 >= 0 && String($0) == value } ?? false
                case "bool": valid = value == "true" || value == "false"
                case "enum": valid = column.values.split(separator: "|").contains(Substring(value))
                case "date_bits": valid = Self.isHex(value, count: 16)
                case "sha256": valid = Self.isHex(value, count: 64)
                case "utc":
                    // Full date validity is checked together with its exact-bit companion.
                    let bytes = Array(value.utf8)
                    valid = bytes.count == 20 && bytes[4] == 45 && bytes[7] == 45 && bytes[10] == 84
                        && bytes[13] == 58 && bytes[16] == 58 && bytes[19] == 90
                        && bytes.enumerated().allSatisfy { [4, 7, 10, 13, 16, 19].contains($0.offset) || (48...57).contains($0.element) }
                default: valid = false
                }
                guard valid else { throw BackupError.invalidArchive(reason: "Invalid \(column.type): \(name).\(column.name)") }
                result[column.name] = value
            }
            return BackupRow(file: name, values: result)
        }
    }

    static func isHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct BackupRow {
    let file: String
    let values: [String: String]
    func string(_ name: String) throws -> String {
        guard let value = values[name] else { throw BackupError.invalidArchive(reason: "Missing value: \(file).\(name)") }
        return value
    }
    func optionalString(_ name: String) -> String? { values[name] }
    func uuid(_ name: String) throws -> UUID {
        guard let value = UUID(uuidString: try string(name)) else { throw BackupError.invalidArchive(reason: "Invalid UUID: \(file).\(name)") }
        return value
    }
    func optionalUUID(_ name: String) throws -> UUID? { try values[name].map { _ in try uuid(name) } }
    func int64(_ name: String) throws -> Int64 {
        guard let value = Int64(try string(name)) else { throw BackupError.invalidArchive(reason: "Invalid Int64: \(file).\(name)") }
        return value
    }
    func int(_ name: String) throws -> Int {
        guard let value = Int(exactly: try int64(name)) else { throw BackupError.invalidArchive(reason: "Integer overflow: \(file).\(name)") }
        return value
    }
    func bool(_ name: String) throws -> Bool { try string(name) == "true" }
    func enumeration<T: RawRepresentable>(_ name: String, as: T.Type = T.self) throws -> T where T.RawValue == String {
        guard let value = T(rawValue: try string(name)) else { throw BackupError.invalidArchive(reason: "Invalid enum: \(file).\(name)") }
        return value
    }
    func date(_ prefix: String) throws -> Date {
        let raw = try string(prefix + "_bits")
        guard let bits = UInt64(raw, radix: 16) else { throw BackupError.invalidArchive(reason: "Invalid date bits: \(file).\(prefix)") }
        let date = Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits))
        guard BackupDates.isSupported(date), try BackupDates.utc(date) == string(prefix + "_utc") else {
            throw BackupError.invalidArchive(reason: "Invalid or inconsistent date: \(file).\(prefix)")
        }
        return date
    }
}

enum BackupDates {
    // Numeric guards run before using any Foundation date formatting/calendar API.
    static func isSupported(_ date: Date) -> Bool {
        let value = date.timeIntervalSinceReferenceDate
        return value.isFinite && value >= -63_113_904_000 && value < 252_423_993_600
    }
    static func values(_ date: Date) throws -> [String?] {
        guard isSupported(date) else { throw BackupError.invalidSnapshot(reason: "Date outside 0001...9999 UTC") }
        let bits = String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
        return [try utc(date), String(repeating: "0", count: 16 - bits.count) + bits]
    }
    static func utc(_ date: Date) throws -> String {
        guard isSupported(date) else { throw BackupError.invalidArchive(reason: "Date outside 0001...9999 UTC") }
        // Gregorian civil date conversion avoids locale, calendar cutover and OS formatter variations.
        // The range guard makes every conversion below fit comfortably in Int64.
        let seconds = Int64(floor(date.timeIntervalSinceReferenceDate)) + 978_307_200
        let days = seconds >= 0 ? seconds / 86_400 : (seconds - 86_399) / 86_400
        let daytime = seconds - days * 86_400
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        var year = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp + (mp < 10 ? 3 : -9)
        year += month <= 2 ? 1 : 0
        func pad(_ value: Int64, _ digits: Int = 2) -> String {
            let value = String(value)
            return String(repeating: "0", count: max(0, digits - value.count)) + value
        }
        return "\(pad(year, 4))-\(pad(month))-\(pad(day))T\(pad(daytime / 3600)):\(pad(daytime % 3600 / 60)):\(pad(daytime % 60))Z"
    }
}

enum BackupSchema {
    static let profile = "ledger-core-v5"
    static let version = "5.0"
    static let dbVersion = "5"
    static let v4Profile = "ledger-core-v4"
    static let v4Version = "4.0"
    static let v4DBVersion = "4"
    static let v3Profile = "ledger-core-v3"
    static let v3Version = "3.0"
    static let v3DBVersion = "3"
    static let v2Profile = "ledger-core-v2"
    static let v2Version = "2.0"
    static let v2DBVersion = "2"
    static let legacyProfile = "ledger-core-v1"
    static let legacyVersion = "1.0"
    static let legacyDBVersion = "1"

    private static func text(_ name: String, _ meaning: String = "", nullable: Bool = false) -> BackupColumn {
        .init(name: name, type: "text", nullable: nullable, meaning: meaning)
    }
    private static func uuid(_ name: String, nullable: Bool = false, reference: String = "") -> BackupColumn {
        .init(name: name, type: "uuid", nullable: nullable, precision: "lowercase-hyphenated-36", reference: reference)
    }
    private static func choice(_ name: String, _ values: String) -> BackupColumn { .init(name: name, type: "enum", values: values) }
    private static func bool(_ name: String) -> BackupColumn { .init(name: name, type: "bool", values: "true|false") }
    private static func integer(_ name: String, unit: String = "", precision: String = "-9223372036854775808...9223372036854775807") -> BackupColumn {
        .init(name: name, type: "int64", unit: unit, precision: precision)
    }
    private static let position = BackupColumn(name: "position", type: "uint", precision: "contiguous-zero-based-row-order", meaning: "Original model array order")
    private static func date(_ prefix: String) -> [BackupColumn] {
        [.init(name: prefix + "_utc", type: "utc", unit: "UTC", precision: "YYYY-MM-DDTHH:mm:ssZ; floor-second; years 0001...9999",
               meaning: "Readable companion; does not assert original input precision"),
         .init(name: prefix + "_bits", type: "date_bits", unit: "seconds-since-2001-01-01T00:00:00Z", precision: "IEEE754-binary64; 16 lowercase hex digits; finite",
               meaning: "Exact Foundation Date reference-seconds bit pattern; authoritative together with matching UTC column")]
    }
    static let legacyAccounts = BackupTable(name: "accounts.csv", columns: [position, uuid("id"), text("name"),
        choice("kind", "bank|wallet|cash|storedValue|creditCard|brokerage|loan"), choice("nature", "asset|liability"),
        choice("currency", "CNY|HKD|USD"), integer("opening_minor", unit: "currency minor units; 1/100")]
        + date("opening_at") + [bool("included_in_summary"), bool("is_active")])
    static let accounts = BackupTable(name: "accounts.csv", columns: legacyAccounts.columns + [
        text("institution_id", "Stable account institution catalog identifier", nullable: true),
        text("template_id", "Stable account template catalog identifier", nullable: true),
        text("icon_id", "Stable account icon catalog identifier", nullable: true)
    ])
    static let subjects = BackupTable(name: "subjects.csv", columns: [position, uuid("id"), text("name"), bool("is_active")])
    static let categories = BackupTable(name: "categories.csv", columns: [position, uuid("id"), text("name"),
        uuid("parent_id", nullable: true, reference: "categories.csv.id"), choice("direction", "expense|income"), text("symbol"), bool("is_active")])
    static let v2Entries = BackupTable(name: "entries.csv", columns: [position, uuid("id"), uuid("operation_id"), choice("kind", "expense|income|transfer"),
        integer("amount_minor", unit: "currency minor units; 1/100", precision: "1...9223372036854775807"), choice("currency", "CNY|HKD|USD"),
        uuid("account_id", reference: "accounts.csv.id"), uuid("destination_account_id", nullable: true, reference: "accounts.csv.id"),
        uuid("category_id", nullable: true, reference: "categories.csv.id"), uuid("subject_id", reference: "subjects.csv.id")]
        + date("occurred_at") + date("created_at") + [text("title"), text("note"), integer("version", precision: "1...9223372036854775807")])
    static let adjustments = BackupTable(name: "adjustments.csv", columns: [position, uuid("id"), uuid("operation_id"),
        uuid("account_id", reference: "accounts.csv.id"), integer("difference_minor", unit: "difference_currency minor units; 1/100"),
        choice("difference_currency", "CNY|HKD|USD"), integer("target_minor", unit: "target_currency minor units; 1/100"),
        choice("target_currency", "CNY|HKD|USD")] + date("occurred_at") + [text("note")])
    static let retired = BackupTable(name: "retired_operations.csv", columns: [uuid("operation_id")])
    static let v2Draft = BackupTable(name: "draft.csv", columns: [uuid("entry_id"), uuid("operation_id"), choice("kind", "expense|income|transfer"),
        text("amount_text", "Unfinished input preserved verbatim; not parsed as a posted amount"),
        uuid("account_id", nullable: true, reference: "soft:accounts.csv.id"), uuid("destination_account_id", nullable: true, reference: "soft:accounts.csv.id"),
        uuid("subject_id", reference: "soft:subjects.csv.id"), uuid("expense_category_id", nullable: true, reference: "soft:categories.csv.id"),
        uuid("income_category_id", nullable: true, reference: "soft:categories.csv.id")]
        + date("occurred_at") + [text("title"), text("note")])
    static let settings = BackupTable(name: "settings.csv", columns: [uuid("default_account_id", nullable: true, reference: "accounts.csv.id"),
        uuid("default_subject_id", reference: "subjects.csv.id")])
    static let legacyManifest = BackupTable(name: "manifest.csv", columns: [text("profile"), text("backup_format_version"),
        text("db_schema_version"), text("app_version"), bool("complete")] + date("created_at")
        + [.init(name: "file_count", type: "uint", precision: "12")])
    static let dictionary = BackupTable(name: "schema_dictionary.csv", columns: [text("file"), text("column"), position,
        text("type"), bool("required"), bool("nullable"), text("unit"), text("precision"), text("allowed_values"), text("foreign_key"), text("meaning")])
    static let counts = BackupTable(name: "counts.csv", columns: [text("file"), .init(name: "row_count", type: "uint", precision: "0...9223372036854775807; excludes header")])
    static let checksums = BackupTable(name: "checksums.csv", columns: [text("file"), .init(name: "sha256", type: "sha256", precision: "64 lowercase hex digits; raw uncompressed bytes")])

    private static func recoveryColumns(_ table: BackupTable, soft: Bool = false) -> [BackupColumn] {
        table.columns.map { $0.name == "kind" ? choice("kind", "expense|income|transfer|refund|recovery") : $0 } + [
            uuid("original_entry_id", nullable: true, reference: (soft ? "soft:" : "") + "entries.csv.id"),
            .init(name: "allows_net_recovery", type: "bool", nullable: true, values: "true|false",
                  meaning: "Purchase opt-in for total recovery above original cost; null means disabled")
        ]
    }
    static let v3Entries = BackupTable(name: "entries.csv", columns: recoveryColumns(v2Entries))
    static let entries = BackupTable(name: "entries.csv", columns: v3Entries.columns + [uuid("project_id", nullable: true, reference: "projects.csv.id")])
    static let v3Draft = BackupTable(name: "draft.csv", columns: recoveryColumns(v2Draft, soft: true))
    static let draft = BackupTable(name: "draft.csv", columns: v3Draft.columns + [uuid("project_id", nullable: true, reference: "soft:projects.csv.id")])
    static let tags = BackupTable(name: "tags.csv", columns: [position, uuid("id"), text("name"), bool("is_active")])
    static let projects = BackupTable(name: "projects.csv", columns: [position, uuid("id"), text("name"), bool("is_archived")])
    static let entryTags = BackupTable(name: "entry_tags.csv", columns: [position, uuid("entry_id", reference: "entries.csv.id"), uuid("tag_id", reference: "tags.csv.id")])
    static let draftTags = BackupTable(name: "draft_tags.csv", columns: [position, uuid("entry_id", reference: "draft.csv.entry_id"), uuid("tag_id", reference: "soft:tags.csv.id")])
    static let v4Manifest = BackupTable(name: "manifest.csv", columns: legacyManifest.columns.map {
        $0.name == "file_count" ? BackupColumn(name: "file_count", type: "uint", precision: "16") : $0
    })
    static let manifest = BackupTable(name: "manifest.csv", columns: legacyManifest.columns.map {
        $0.name == "file_count" ? BackupColumn(name: "file_count", type: "uint", precision: "19") : $0
    })
    static let importBatches = BackupTable(name: "import_batches.csv", columns: [position, uuid("id"), text("name"), text("namespace"), integer("version", precision: "1...9223372036854775807")] + date("created_at"))
    static let importRows = BackupTable(name: "import_rows.csv", columns: [position, uuid("batch_id", reference: "import_batches.csv.id"), uuid("id"), uuid("operation_id"),
        uuid("account_id", nullable: true, reference: "soft:accounts.csv.id|import_accounts.csv.id"),
        uuid("destination_account_id", nullable: true, reference: "soft:accounts.csv.id|import_accounts.csv.id"),
        uuid("category_id", nullable: true, reference: "soft:categories.csv.id"), uuid("subject_id", reference: "soft:subjects.csv.id"),
        choice("state", "pending|imported|skipped"), text("duplicate_review_token", nullable: true)]
        + ImportCSV.header.map { text("raw_" + $0, "Original UTF-8 source field; preserved without trimming or interpretation") })
    static let importAccounts = BackupTable(name: "import_accounts.csv", columns: [uuid("batch_id", reference: "import_batches.csv.id")] + accounts.columns)
    static let all = [accounts, subjects, categories, entries, adjustments, retired, draft, settings, manifest, dictionary, counts, checksums, tags, projects, entryTags, draftTags, importBatches, importRows, importAccounts]
    static let v4All = [accounts, subjects, categories, entries, adjustments, retired, draft, settings, v4Manifest, dictionary, counts, checksums, tags, projects, entryTags, draftTags]
    static let v3All = [accounts, subjects, categories, v3Entries, adjustments, retired, v3Draft, settings, legacyManifest, dictionary, counts, checksums]
    static let v2All = [accounts, subjects, categories, v2Entries, adjustments, retired, v2Draft, settings, legacyManifest, dictionary, counts, checksums]
    static let legacyAll = [legacyAccounts, subjects, categories, v2Entries, adjustments, retired, v2Draft, settings, legacyManifest, dictionary, counts, checksums]
    static var fileNames: Set<String> { Set(all.map(\.name)) }
    static func dictionaryRecords(for tables: [BackupTable]) -> [[String?]] {
        tables.flatMap { table in
            table.columns.enumerated().map { index, column in
                [table.name, column.name, String(index), column.type, "true", String(column.nullable),
                 column.unit, column.precision, column.values, column.reference, column.meaning]
            }
        }
    }
    static var dictionaryRecords: [[String?]] { dictionaryRecords(for: all) }
    static var legacyDictionaryRecords: [[String?]] { dictionaryRecords(for: legacyAll) }
    static func dictionaryData(for tables: [BackupTable]) -> Data {
        BackupCSV.encode([dictionary.header] + dictionaryRecords(for: tables))
    }
    static var dictionaryData: Data { dictionaryData(for: all) }
    static var legacyDictionaryData: Data { dictionaryData(for: legacyAll) }
}
