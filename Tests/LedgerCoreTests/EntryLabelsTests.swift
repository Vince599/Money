import Foundation
import Testing
@testable import LedgerCore

@Suite("Entry tags and projects")
struct EntryLabelsTests {
    private func fixture() throws -> LedgerBook {
        let account = Account(name: "银行卡", openingMinor: 100_000)
        let tags = [EntryTag(name: "旅行"), EntryTag(name: "两人"), EntryTag(name: "工作")]
        let project = EntryProject(name: "上海旅行")
        var book = LedgerBook(accounts: [account], tags: tags, projects: [project])
        for index in 0..<3 {
            let entry = LedgerEntry(kind: .expense, amount: Money(minorUnits: 1_000), accountID: account.id,
                                    categoryID: SeedData.mealsID, tagIDs: index == 0 ? [tags[1].id, tags[0].id] : [tags[index].id],
                                    projectID: index < 2 ? project.id : nil)
            book = try LedgerEngine.record(entry, in: book)
        }
        return book
    }

    @Test func allAnyAndProjectFiltersKeepAccountingUnchanged() throws {
        let book = try fixture(), tags = Set(book.tags.prefix(2).map(\.id))
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(tagIDs: tags)).map(\.id) == [book.entries[0].id])
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(tagIDs: tags, tagMatch: .any)).count == 2)
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(tagMatch: .any)).count == 3)
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(tagIDs: [UUID()])).isEmpty)
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(projectID: book.projects[0].id)).count == 2)
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(tagIDs: [book.tags[2].id], projectID: book.projects[0].id)).isEmpty)
        #expect(try LedgerEngine.balance(of: book.accounts[0].id, in: book).minorUnits == 97_000)
        #expect(book.entries.allSatisfy { $0.categoryID == SeedData.mealsID })
        #expect(EntryFilter(tagIDs: tags) != EntryFilter(tagIDs: tags, tagMatch: .any))
    }

    @Test func associationsForEveryEntryKind() throws {
        var book = try fixture()
        let second = Account(name: "收款账户")
        book.accounts.append(second)
        for kind in [EntryKind.income, .transfer, .refund, .recovery] {
            let entry = LedgerEntry(kind: kind, amount: Money(minorUnits: 100), accountID: book.accounts[0].id,
                                    destinationAccountID: kind == .transfer ? second.id : nil,
                                    categoryID: kind == .income ? SeedData.salaryIncomeID : nil,
                                    originalEntryID: kind.isRecovery ? book.entries[0].id : nil,
                                    tagIDs: [book.tags[0].id], projectID: book.projects[0].id)
            book = try LedgerEngine.record(entry, in: book)
            #expect(try EntryQuery.entries(in: book, matching: EntryFilter(kind: kind, tagIDs: [book.tags[0].id], projectID: book.projects[0].id)) == [entry])
        }
        #expect(try LedgerEngine.balance(of: book.accounts[0].id, in: book).minorUnits == 97_200)
        #expect(try LedgerEngine.balance(of: second.id, in: book).minorUnits == 100)
    }

    @Test func archiveRenameAndDisableRetainHistoryButRejectNewSelection() throws {
        let original = try fixture()
        var tag = original.tags[0]; tag.isActive = false; tag.name = "旧旅行标签"
        var project = original.projects[0]; project.isArchived = true; project.name = "已完成上海旅行"
        let book = try CatalogEditor.saveProject(project, in: CatalogEditor.saveTag(tag, in: original))
        #expect(book.entries == original.entries)
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(tagIDs: [tag.id], projectID: project.id)).count == 1)
        var editing = book.entries[0]; editing.operationID = UUID(); editing.note = "补备注"
        let edited = try LedgerEngine.replace(editing, expectedVersion: 1, in: book)
        #expect(edited.entries[0].tagIDs == editing.tagIDs)
        var fresh = book.entries[0]; fresh.id = UUID(); fresh.operationID = UUID()
        #expect(throws: LedgerError.invalidTag) { try LedgerEngine.record(fresh, in: book) }
        fresh.tagIDs = []
        #expect(throws: LedgerError.invalidProject) { try LedgerEngine.record(fresh, in: book) }
        let copy = try EntryDraft.copying(book.entries[0], in: book)
        #expect(copy.tagIDs == [book.tags[1].id] && copy.projectID == nil)
        project.isArchived = false; tag.isActive = true
        let reopened = try CatalogEditor.saveProject(project, in: CatalogEditor.saveTag(tag, in: book))
        #expect(try LedgerEngine.record(fresh, in: reopened).entries.count == 4)
    }

    @Test func danglingDuplicateAndEmptyMetadataAreRejected() throws {
        let book = try fixture()
        var invalid = book; invalid.entries[0].tagIDs.append(invalid.entries[0].tagIDs[0])
        #expect(throws: LedgerError.invalidTag) { try LedgerEngine.validate(invalid) }
        invalid = book; invalid.tags.removeFirst()
        #expect(throws: LedgerError.invalidTag) { try LedgerEngine.validate(invalid) }
        invalid = book; invalid.projects = []
        #expect(throws: LedgerError.invalidProject) { try LedgerEngine.validate(invalid) }
        #expect(throws: LedgerError.invalidTag) { try CatalogEditor.saveTag(EntryTag(name: " \n"), in: book) }
        #expect(throws: LedgerError.invalidProject) { try CatalogEditor.saveProject(EntryProject(name: ""), in: book) }
        invalid = book; invalid.tags.append(invalid.tags[0])
        #expect(throws: LedgerError.duplicateID) { try LedgerEngine.validate(invalid) }
    }

    @Test func draftCopyAndRetryPreserveExplicitAssociations() throws {
        let book = try fixture(), entry = book.entries[0]
        let draft = try EntryDraft.copying(entry, in: book)
        #expect(draft.tagIDs == entry.tagIDs && draft.projectID == entry.projectID)
        let copied = try draft.entry(in: book)
        let result = try LedgerEngine.record(copied, in: book)
        #expect(try LedgerEngine.record(copied, in: result) == result)
        var conflict = copied; conflict.tagIDs = []
        #expect(throws: LedgerError.operationConflict) { try LedgerEngine.record(conflict, in: result) }
        #expect(draft.nextEntry().tagIDs.isEmpty && draft.nextEntry().projectID == nil)
    }

    @Test func backupContainsLinksAndSoftDraftReferencesWithoutLosingOrder() throws {
        var book = try fixture()
        book.tags[0].name = "逗号,引号\"换行\n\\N"; book.projects[0].isArchived = true
        let draft = EntryDraft(amountText: "12+(", tagIDs: [UUID(), book.tags[0].id], projectID: UUID())
        let snapshot = LedgerBackupSnapshot(book: book, draft: draft, settings: LedgerSettings())
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let files = try BackupCodec.encode(snapshot, createdAt: time)
        #expect(files.count == 20)
        #expect(files == (try BackupCodec.encode(snapshot, createdAt: time)))
        #expect(try BackupCodec.decode(BackupArchive.decode(BackupArchive.encode(files))) == snapshot)
        #expect(try BackupSchema.entryTags.read(files["entry_tags.csv"]!).count == 4)
    }

    @Test func oldJSONDefaultsNewFieldsButDoesNotAcceptMalformedArrays() throws {
        let book = try fixture()
        func removing(_ value: some Encodable, keys: [String]) throws -> Data {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
            keys.forEach { object.removeValue(forKey: $0) }
            return try JSONSerialization.data(withJSONObject: object)
        }
        let entryData = try removing(book.entries[0], keys: ["tagIDs", "projectID"])
        let entry = try JSONDecoder().decode(LedgerEntry.self, from: entryData)
        #expect(entry.tagIDs.isEmpty && entry.projectID == nil)
        let draft = try JSONDecoder().decode(EntryDraft.self, from: removing(EntryDraft(), keys: ["tagIDs", "projectID"]))
        #expect(draft.tagIDs.isEmpty && draft.projectID == nil)
        let oldBook = try JSONDecoder().decode(LedgerBook.self, from: removing(LedgerBook(), keys: ["tags", "projects"]))
        #expect(oldBook.tags.isEmpty && oldBook.projects.isEmpty)
        var object = try #require(JSONSerialization.jsonObject(with: entryData) as? [String: Any])
        object["tagIDs"] = "broken"
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LedgerEntry.self, from: JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func versionThreeBackupKeepsRecoveryAndRejectsMixedContracts() throws {
        let account = Account(name: "旧账本")
        let original = LedgerEntry(kind: .expense, amount: Money(minorUnits: 100_000), accountID: account.id, categoryID: SeedData.mealsID,
                                   occurredAt: Date(timeIntervalSince1970: 1_700_000_000), allowsNetRecovery: true)
        let refund = LedgerEntry(kind: .refund, amount: Money(minorUnits: 20_000), accountID: account.id, originalEntryID: original.id)
        let snapshot = LedgerBackupSnapshot(book: LedgerBook(accounts: [account], entries: [original, refund]),
                                            draft: EntryDraft(kind: .refund, originalEntryID: original.id), settings: LedgerSettings())
        let current = try BackupCodec.encode(snapshot)
        var files = current.filter { Set(BackupSchema.v3All.map(\.name)).contains($0.key) }
        for (new, old) in [(BackupSchema.entries, BackupSchema.v3Entries), (BackupSchema.draft, BackupSchema.v3Draft)] {
            let rows = try new.read(files[new.name]!).map { row in old.columns.map { row.values[$0.name] } }
            files[old.name] = BackupCSV.encode([old.header] + rows)
        }
        var manifest = try BackupSchema.manifest.read(files["manifest.csv"]!)[0].values
        manifest["profile"] = "ledger-core-v3"; manifest["backup_format_version"] = "3.0"
        manifest["db_schema_version"] = "3"; manifest["file_count"] = "12"
        files["manifest.csv"] = BackupCSV.encode([BackupSchema.legacyManifest.header, BackupSchema.legacyManifest.columns.map { manifest[$0.name] }])
        files["schema_dictionary.csv"] = BackupSchema.dictionaryData(for: BackupSchema.v3All)
        try rebuildIntegrity(&files)
        #expect(try BackupCodec.decode(files) == snapshot)
        files["tags.csv"] = current["tags.csv"]
        try rebuildIntegrity(&files)
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
    }

    @Test func rehashedOrphanDuplicateAndMissingLinksAreRejected() throws {
        let snapshot = LedgerBackupSnapshot(book: try fixture(), draft: EntryDraft(tagIDs: [UUID()]), settings: LedgerSettings())
        let original = try BackupCodec.encode(snapshot)
        for table in [BackupSchema.entryTags, BackupSchema.draftTags] {
            var files = original
            var rows = try table.read(files[table.name]!).map { row in table.columns.map { row.values[$0.name] } }
            rows[0][1] = UUID().uuidString.lowercased()
            files[table.name] = BackupCSV.encode([table.header] + rows)
            try rebuildIntegrity(&files)
            #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
        }
        var files = original
        var rows = try BackupSchema.entryTags.read(files["entry_tags.csv"]!).map { row in BackupSchema.entryTags.columns.map { row.values[$0.name] } }
        rows[1][2] = rows[0][2]
        files["entry_tags.csv"] = BackupCSV.encode([BackupSchema.entryTags.header] + rows)
        try rebuildIntegrity(&files)
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
        files = original; files.removeValue(forKey: "draft_tags.csv")
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
    }

    private func rebuildIntegrity(_ files: inout [String: Data]) throws {
        let countRows: [[String?]] = try files.keys.sorted().map { name in
            let count = name == "counts.csv" ? files.count : name == "checksums.csv" ? files.count - 1 : try BackupCSV.decode(files[name]!, file: name).count - 1
            return [name, String(count)]
        }
        files["counts.csv"] = BackupCSV.encode([BackupSchema.counts.header] + countRows)
        let hashes: [[String?]] = files.keys.filter { $0 != "checksums.csv" }.sorted().map { [$0, BackupSHA256.hex(files[$0]!)] }
        files["checksums.csv"] = BackupCSV.encode([BackupSchema.checksums.header] + hashes)
    }
}
