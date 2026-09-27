import Foundation
import Testing
@testable import LedgerCore

@Suite("Lossless CSV backup")
struct BackupCodecTests {
    private let timestamp = Date(timeIntervalSinceReferenceDate: 812_345_678.1234567)

    private func snapshot() -> LedgerBackupSnapshot {
        let a = Account(name: "  银行,\"A\"\r\n\\N ", openingMinor: 1_000_000, openingDate: timestamp,
                        institutionID: "bank.icbc", templateID: "bank.icbc.debit", iconID: "icon.bank.icbc")
        let b = Account(name: "信用卡", kind: .creditCard, nature: .liability, openingMinor: 500, openingDate: timestamp,
                        includedInSummary: false, isActive: false)
        let max = Account(name: "Max USD", kind: .brokerage, currency: .usd, openingMinor: .max, openingDate: timestamp)
        let min = Account(name: "Min HKD", kind: .storedValue, currency: .hkd, openingMinor: .min, openingDate: timestamp)
        let subject = Subject(name: "  Other 主体  ")
        var book = LedgerBook(accounts: [b, a, max, min], subjects: [subject] + SeedData.subjects,
                              categories: Array(SeedData.categories.reversed()), retiredOperationIDs: [UUID(), UUID()])
        book.entries = [
            LedgerEntry(kind: .expense, amount: Money(minorUnits: 12345), accountID: a.id,
                        categoryID: SeedData.mealsID, subjectID: subject.id, occurredAt: timestamp, createdAt: timestamp,
                        title: "=SUM(A1:A2)", note: "e\u{301} 😀\t\r\n\"quotes\",comma\\N\\path\\\u{301}", version: 9),
            LedgerEntry(kind: .income, amount: Money(minorUnits: 120), accountID: a.id,
                        categoryID: SeedData.salaryIncomeID, occurredAt: timestamp, createdAt: timestamp, title: "", note: ""),
            LedgerEntry(kind: .transfer, amount: Money(minorUnits: 200), accountID: a.id,
                        destinationAccountID: b.id, occurredAt: timestamp, createdAt: timestamp)
        ]
        book.adjustments = [BalanceAdjustment(accountID: a.id, difference: Money(minorUnits: -30),
                                              target: Money(minorUnits: 987_545), occurredAt: timestamp, note: "manual\\correction")]
        let draft = EntryDraft(kind: .transfer, amountText: "000.未完成", accountID: a.id, destinationAccountID: b.id,
                               subjectID: subject.id, expenseCategoryID: SeedData.mealsID, incomeCategoryID: SeedData.salaryIncomeID,
                               occurredAt: timestamp, title: "\"\"", note: "\\N")
        return LedgerBackupSnapshot(book: book, draft: draft,
                                    settings: LedgerSettings(defaultAccountID: a.id, defaultSubjectID: subject.id))
    }

    private func blank(draft: EntryDraft? = nil) -> LedgerBackupSnapshot {
        LedgerBackupSnapshot(book: LedgerBook(), draft: draft, settings: LedgerSettings())
    }

    private func rehash(_ files: inout [String: Data]) {
        let rows: [[String?]] = files.keys.filter { $0 != "checksums.csv" }.sorted().map { [$0, BackupSHA256.hex(files[$0]!)] }
        files["checksums.csv"] = BackupCSV.encode([BackupSchema.checksums.header] + rows)
    }

    private func edit(_ files: inout [String: Data], table: BackupTable, row: Int = 0, column: String, value: String?) throws {
        var rows = try table.read(files[table.name]!).map { record in table.columns.map { record.values[$0.name] } }
        let index = try #require(table.columns.firstIndex(where: { $0.name == column }))
        rows[row][index] = value
        files[table.name] = BackupCSV.encode([table.header] + rows)
        rehash(&files)
    }

    private func removeLabelTables(_ files: inout [String: Data]) throws {
        for table in [BackupSchema.tags, BackupSchema.projects, BackupSchema.entryTags, BackupSchema.draftTags, BackupSchema.importBatches, BackupSchema.importRows, BackupSchema.importAccounts, BackupSchema.importRowTags, BackupSchema.importRules, BackupSchema.importRuleConditions, BackupSchema.importRuleActions] {
            files.removeValue(forKey: table.name)
        }
        try edit(&files, table: BackupSchema.manifest, column: "file_count", value: "12")
        let counts: [[String?]] = try files.keys.sorted().map { name in
            let count = name == "counts.csv" ? 12 : name == "checksums.csv" ? 11 : try BackupCSV.decode(files[name]!, file: name).count - 1
            return [name, String(count)]
        }
        files[BackupSchema.counts.name] = BackupCSV.encode([BackupSchema.counts.header] + counts)
        rehash(&files)
    }

    private func legacyFiles(from snapshot: LedgerBackupSnapshot) throws -> [String: Data] {
        var files = try BackupCodec.encode(snapshot, createdAt: timestamp)
        for (current, legacy) in [(BackupSchema.entries, BackupSchema.v2Entries), (BackupSchema.draft, BackupSchema.v2Draft)] {
            let rows = try current.read(files[current.name]!).map { row in legacy.columns.map { row.values[$0.name] } }
            files[legacy.name] = BackupCSV.encode([legacy.header] + rows)
        }
        let rows = try BackupSchema.accounts.read(files[BackupSchema.accounts.name]!).map { row in
            BackupSchema.legacyAccounts.columns.map { row.values[$0.name] }
        }
        files[BackupSchema.legacyAccounts.name] = BackupCSV.encode([BackupSchema.legacyAccounts.header] + rows)
        try edit(&files, table: BackupSchema.manifest, column: "profile", value: BackupSchema.legacyProfile)
        try edit(&files, table: BackupSchema.manifest, column: "backup_format_version", value: BackupSchema.legacyVersion)
        try edit(&files, table: BackupSchema.manifest, column: "db_schema_version", value: BackupSchema.legacyDBVersion)
        files[BackupSchema.dictionary.name] = BackupSchema.legacyDictionaryData
        var countRows = try BackupSchema.counts.read(files[BackupSchema.counts.name]!).map { row in
            BackupSchema.counts.columns.map { row.values[$0.name] }
        }
        let dictionaryIndex = try #require(countRows.firstIndex { $0[0] == BackupSchema.dictionary.name })
        countRows[dictionaryIndex][1] = String(BackupSchema.legacyDictionaryRecords.count)
        files[BackupSchema.counts.name] = BackupCSV.encode([BackupSchema.counts.header] + countRows)
        rehash(&files)
        try removeLabelTables(&files)
        return files
    }

    @Test func allImplementedFieldsRoundTripAndAreDeterministic() throws {
        let original = snapshot()
        let files = try BackupCodec.encode(original, createdAt: timestamp)
        #expect(files == (try BackupCodec.encode(original, createdAt: timestamp)))
        #expect(Set(files.keys) == BackupSchema.fileNames)
        #expect(try BackupCodec.decode(files) == original)
        #expect(files["schema_dictionary.csv"] == BackupSchema.dictionaryData)
        for data in files.values {
            #expect(data.last == 10)
            #expect(!data.starts(with: [0xef, 0xbb, 0xbf]))
            #expect(String(data: data, encoding: .utf8) != nil)
        }
        let restored = try BackupCodec.decode(files)
        #expect(Array(restored.book.entries[0].note.utf8) == Array(original.book.entries[0].note.utf8))
        #expect(restored.book.accounts[2].openingMinor == Int64.max)
        #expect(restored.book.accounts[3].openingMinor == Int64.min)
        #expect(restored.book.entries[0].occurredAt.timeIntervalSinceReferenceDate.bitPattern == timestamp.timeIntervalSinceReferenceDate.bitPattern)
        #expect(restored.book.categories.map(\.id) == original.book.categories.map(\.id))
        #expect(restored.book.accounts[1].institutionID == "bank.icbc")
        #expect(restored.book.accounts[1].templateID == "bank.icbc.debit")
        #expect(restored.book.accounts[1].iconID == "icon.bank.icbc")
    }

    @Test func legacyVersionOneBackupRestoresWithNilPresentationMetadata() throws {
        #expect(BackupSHA256.hex(BackupSchema.legacyDictionaryData)
            == "28baf3dba73ce0824f666176c8a88f7169520cf7686404314a999b8d37ba16ea")
        #expect(String(decoding: BackupCSV.encode([BackupSchema.legacyAccounts.header]), as: UTF8.self)
            == "position,id,name,kind,nature,currency,opening_minor,opening_at_utc,opening_at_bits,included_in_summary,is_active\n")
        let original = snapshot()
        let restored = try BackupCodec.decode(legacyFiles(from: original))
        var expected = original
        for index in expected.book.accounts.indices {
            expected.book.accounts[index].institutionID = nil
            expected.book.accounts[index].templateID = nil
            expected.book.accounts[index].iconID = nil
        }
        #expect(restored == expected)
    }

    @Test func rejectsManifestTableAndDictionaryFromMixedBackupContracts() throws {
        var currentTablesWithLegacyManifest = try BackupCodec.encode(snapshot(), createdAt: timestamp)
        try edit(&currentTablesWithLegacyManifest, table: BackupSchema.manifest,
                 column: "profile", value: BackupSchema.legacyProfile)
        try edit(&currentTablesWithLegacyManifest, table: BackupSchema.manifest,
                 column: "backup_format_version", value: BackupSchema.legacyVersion)
        try edit(&currentTablesWithLegacyManifest, table: BackupSchema.manifest,
                 column: "db_schema_version", value: BackupSchema.legacyDBVersion)
        #expect(throws: BackupError.self) { try BackupCodec.decode(currentTablesWithLegacyManifest) }

        var legacyTablesWithCurrentManifest = try legacyFiles(from: snapshot())
        try edit(&legacyTablesWithCurrentManifest, table: BackupSchema.manifest,
                 column: "profile", value: BackupSchema.profile)
        try edit(&legacyTablesWithCurrentManifest, table: BackupSchema.manifest,
                 column: "backup_format_version", value: BackupSchema.version)
        try edit(&legacyTablesWithCurrentManifest, table: BackupSchema.manifest,
                 column: "db_schema_version", value: BackupSchema.dbVersion)
        #expect(throws: BackupError.self) { try BackupCodec.decode(legacyTablesWithCurrentManifest) }
    }

    @Test func noDraftAndEmptyDraftRemainDistinctWithNoAccountsOrTransactions() throws {
        let noDraft = blank()
        let emptyDraft = blank(draft: EntryDraft(occurredAt: timestamp))
        #expect(try BackupCodec.decode(BackupCodec.encode(noDraft)) == noDraft)
        #expect(try BackupCodec.decode(BackupCodec.encode(emptyDraft)) == emptyDraft)
        #expect(try BackupCodec.decode(BackupCodec.encode(noDraft)).book.accounts.isEmpty)
    }

    @Test func unresolvedDraftSelectionsAndInvalidAmountTextArePreservedForRepair() throws {
        let original = blank(draft: EntryDraft(amountText: "-..", accountID: UUID(), destinationAccountID: UUID(),
                                               subjectID: UUID(), expenseCategoryID: UUID(), incomeCategoryID: UUID(),
                                               occurredAt: timestamp))
        #expect(try BackupCodec.decode(BackupCodec.encode(original)) == original)
    }

    @Test func csvPreservesNullLiteralBackslashEmptyAndCRLF() throws {
        let values: [String?] = [nil, "\\N", "", " leading ", "a,b", "a\"b", "a\r\nb", "\\\u{301}", "e\u{301}", "😀"]
        let data = BackupCSV.encode([values])
        let raw = try BackupCSV.decode(data, file: "test.csv")[0]
        let restored = try raw.map { $0 == "\\N" ? nil : try BackupCSV.text($0, file: "test.csv") }
        #expect(restored == values)
        #expect(String(decoding: data, as: UTF8.self).hasPrefix("\\N,\\\\N,\"\","))
        #expect(String(decoding: data, as: UTF8.self).contains("\"a\r\nb\""))
    }

    @Test(arguments: ["a,b", "a,b\r\n", "a,\n", "a,\"unterminated\n", "a,un\"quoted\n", "a,\"b\"junk\n", "\n"])
    func rejectsMalformedCSV(_ text: String) {
        #expect(throws: BackupError.self) { try BackupCSV.decode(Data(text.utf8), file: "test.csv") }
    }

    @Test func rejectsBOMInvalidUTF8AndUnpairedBackslash() throws {
        #expect(throws: BackupError.self) { try BackupCSV.decode(Data([0xef, 0xbb, 0xbf, 97, 10]), file: "bad.csv") }
        #expect(throws: BackupError.self) { try BackupCSV.decode(Data([0xff, 10]), file: "bad.csv") }
        #expect(throws: BackupError.self) { try BackupCSV.text("hello\\world", file: "bad.csv") }
        #expect(throws: BackupError.self) { try BackupCSV.text("\\\u{301}", file: "bad.csv") }
        var files = try BackupCodec.encode(snapshot())
        let text = String(decoding: files["entries.csv"]!, as: UTF8.self).replacingOccurrences(of: "=SUM(A1:A2)", with: "bad\\text")
        files["entries.csv"] = Data(text.utf8); rehash(&files)
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
    }

    @Test func hashesProtectOriginalBytesIncludingTrailingLF() throws {
        var files = try BackupCodec.encode(snapshot())
        files["accounts.csv"]!.append(10)
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
        files = try BackupCodec.encode(snapshot())
        files["entries.csv"]!.removeLast()
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
        rehash(&files)
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
    }

    @Test(arguments: [("profile", "future-core"), ("backup_format_version", "9.0"), ("backup_format_version", "3.1"), ("db_schema_version", "9")])
    func rejectsUnsupportedVersionsDistinctly(_ field: String, _ value: String) throws {
        var files = try BackupCodec.encode(blank())
        try edit(&files, table: BackupSchema.manifest, column: field, value: value)
        do {
            _ = try BackupCodec.decode(files)
            Issue.record("Expected unsupported backup format")
        } catch BackupError.unsupportedFormat {} catch { Issue.record("Wrong error: \(error)") }
    }

    @Test func versionTwoBackupRetainsAccountAppearanceAndRestoresWithoutLinks() throws {
        let source = snapshot()
        var files = try BackupCodec.encode(source)
        for (current, old) in [(BackupSchema.entries, BackupSchema.v2Entries), (BackupSchema.draft, BackupSchema.v2Draft)] {
            let rows = try current.read(files[current.name]!).map { row in old.columns.map { row.values[$0.name] } }
            files[old.name] = BackupCSV.encode([old.header] + rows)
        }
        try edit(&files, table: BackupSchema.manifest, column: "profile", value: BackupSchema.v2Profile)
        try edit(&files, table: BackupSchema.manifest, column: "backup_format_version", value: BackupSchema.v2Version)
        try edit(&files, table: BackupSchema.manifest, column: "db_schema_version", value: BackupSchema.v2DBVersion)
        files[BackupSchema.dictionary.name] = BackupSchema.dictionaryData(for: BackupSchema.v2All)
        let countRows = try BackupSchema.counts.read(files[BackupSchema.counts.name]!).map { row -> [String?] in
            let name = try row.string("file")
            return [name, name == BackupSchema.dictionary.name ? String(BackupSchema.dictionaryRecords(for: BackupSchema.v2All).count) : try row.string("row_count")]
        }
        files[BackupSchema.counts.name] = BackupCSV.encode([BackupSchema.counts.header] + countRows)
        rehash(&files)
        try removeLabelTables(&files)
        #expect(try BackupCodec.decode(files) == source)
        // A current header hidden behind an old manifest must still fail.
        files[BackupSchema.entries.name] = try BackupCodec.encode(source)[BackupSchema.entries.name]
        rehash(&files)
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
    }

    @Test func rejectsMissingUnknownFilesAndHeadersAndSchemaEvenWithNewHashes() throws {
        let original = try BackupCodec.encode(snapshot())
        var files = original; files.removeValue(forKey: "draft.csv")
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
        files = original; files["../accounts.csv"] = Data()
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
        files = original
        files["accounts.csv"] = Data(String(decoding: files["accounts.csv"]!, as: UTF8.self).replacingOccurrences(of: "position,id,", with: "position,new_id,").utf8)
        rehash(&files)
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
        files = original; files["schema_dictionary.csv"]!.append(10); rehash(&files)
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
    }

    @Test(arguments: ["9223372036854775808", "1e2", "1.0", "+1", "01", "-0", "１２", " 1", "0", "-1"])
    func rejectsInvalidAmountsEvenWithValidHashes(_ value: String) throws {
        var files = try BackupCodec.encode(snapshot())
        try edit(&files, table: BackupSchema.entries, column: "amount_minor", value: value)
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
    }

    @Test func rejectsDuplicateIDsOperationsForeignKeysAndInvalidSettings() throws {
        let source = snapshot(), original = try BackupCodec.encode(source)
        for (table, row, field, value) in [
            (BackupSchema.entries, 1, "id", source.book.entries[0].id.uuidString.lowercased()),
            (BackupSchema.adjustments, 0, "operation_id", source.book.entries[0].operationID.uuidString.lowercased()),
            (BackupSchema.entries, 0, "account_id", UUID().uuidString.lowercased()),
            (BackupSchema.entries, 0, "category_id", UUID().uuidString.lowercased()),
            (BackupSchema.categories, 0, "parent_id", UUID().uuidString.lowercased()),
            (BackupSchema.settings, 0, "default_subject_id", UUID().uuidString.lowercased()),
            (BackupSchema.settings, 0, "default_account_id", source.book.accounts[0].id.uuidString.lowercased()),
            (BackupSchema.retired, 0, "operation_id", source.book.entries[0].operationID.uuidString.lowercased()),
            (BackupSchema.retired, 1, "operation_id", try BackupSchema.retired.read(original["retired_operations.csv"]!)[0].string("operation_id")),
            (BackupSchema.accounts, 0, "position", "1"),
            (BackupSchema.entries, 0, "kind", "refund"),
            (BackupSchema.accounts, 0, "is_active", "TRUE"),
            (BackupSchema.entries, 0, "currency", "USD"),
            (BackupSchema.entries, 0, "version", "0")
        ] {
            var files = original
            try edit(&files, table: table, row: row, column: field, value: value)
            #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
        }
    }

    @Test func rejectsInvalidUUIDAndUnexpectedNull() throws {
        let original = try BackupCodec.encode(snapshot())
        var files = original
        try edit(&files, table: BackupSchema.entries, column: "id", value: "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF")
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
        files = original; try edit(&files, table: BackupSchema.entries, column: "note", value: nil)
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
    }

    @Test func rejectsCountTamperingIncompleteManifestAndChecksumCoverage() throws {
        let original = try BackupCodec.encode(snapshot())
        var files = original
        try edit(&files, table: BackupSchema.counts, column: "row_count", value: "999")
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
        files = original; try edit(&files, table: BackupSchema.manifest, column: "complete", value: "false")
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
        files = original
        var checksumRows = try BackupSchema.checksums.read(files["checksums.csv"]!).map { row in BackupSchema.checksums.columns.map { row.values[$0.name] } }
        checksumRows[1] = checksumRows[0]
        files["checksums.csv"] = BackupCSV.encode([BackupSchema.checksums.header] + checksumRows)
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
        checksumRows.removeLast()
        files["checksums.csv"] = BackupCSV.encode([BackupSchema.checksums.header] + checksumRows)
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -63_113_904_001, 252_423_993_600])
    func rejectsUnsupportedDatesBeforeFormatting(_ value: Double) throws {
        let date = Date(timeIntervalSinceReferenceDate: value)
        #expect(throws: BackupError.self) { try BackupCodec.encode(blank(draft: EntryDraft(occurredAt: date))) }
        #expect(throws: BackupError.self) { try BackupCodec.encode(blank(), createdAt: date) }
        var files = try BackupCodec.encode(snapshot())
        let bits = String(value.bitPattern, radix: 16)
        try edit(&files, table: BackupSchema.entries, column: "occurred_at_bits", value: String(repeating: "0", count: 16 - bits.count) + bits)
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
    }

    @Test func allSupportedDateBitsRoundTripWithoutInventingInputPrecision() throws {
        for value in [-63_113_904_000, -0.25, -0.0, Double.leastNonzeroMagnitude, 0, 812_345_678.1234567, 252_423_993_599.9] {
            let date = Date(timeIntervalSinceReferenceDate: value)
            let original = blank(draft: EntryDraft(occurredAt: date))
            let restored = try BackupCodec.decode(BackupCodec.encode(original, createdAt: date))
            #expect(restored.draft?.occurredAt.timeIntervalSinceReferenceDate.bitPattern == date.timeIntervalSinceReferenceDate.bitPattern)
        }
        #expect(try BackupDates.utc(Date(timeIntervalSinceReferenceDate: -63_113_904_000)) == "0001-01-01T00:00:00Z")
        #expect(try BackupDates.utc(Date(timeIntervalSinceReferenceDate: 252_423_993_599)) == "9999-12-31T23:59:59Z")
        #expect(try BackupDates.utc(Date(timeIntervalSinceReferenceDate: -0.25)) == "2000-12-31T23:59:59Z")
        var files = try BackupCodec.encode(snapshot())
        try edit(&files, table: BackupSchema.entries, column: "occurred_at_utc", value: "2026-02-30T25:00:00Z")
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
    }

    @Test func parserResourceLimitsRejectExcessColumnsAndCells() {
        let columns = Array(repeating: "x", count: BackupCSV.maxColumns + 1).joined(separator: ",") + "\n"
        #expect(throws: BackupError.self) { try BackupCSV.decode(Data(columns.utf8), file: "wide.csv") }
        let cell = String(repeating: "x", count: BackupCSV.maxCellBytes + 1) + "\n"
        #expect(throws: BackupError.self) { try BackupCSV.decode(Data(cell.utf8), file: "long.csv") }
    }

    @Test func exporterRefusesInvalidDefaultAndLedger() throws {
        var original = snapshot()
        original.settings.defaultAccountID = original.book.accounts[0].id
        #expect(throws: BackupError.self) { try BackupCodec.encode(original) }
        original = snapshot(); original.book.entries[0].accountID = UUID()
        #expect(throws: BackupError.self) { try BackupCodec.encode(original) }
    }
}
