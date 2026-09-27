import Foundation
import Testing
@testable import LedgerCore

@Suite("Extended import rule actions")
struct ImportRuleActionTests {
    private func fixture() throws -> (LedgerBook, ImportBatch, Account, EntryTag, EntryTag, EntryProject) {
        let account = Account(name: "银行卡", openingMinor: 10_000), destination = Account(name: "零钱")
        let old = EntryTag(name: "原标签"), new = EntryTag(name: "追加"), project = EntryProject(name: "项目")
        var batch = try ImportCSV.parse(ImportCSV.template, name: "rules", namespace: "bank")
        batch.rows[0].raw[2] = "transfer"; batch.rows[0].accountID = account.id; batch.rows[0].tagIDs = [old.id]
        let rule = ImportRule(name: "转账资料", conditions: [.init(field: .kind, comparison: .equals, value: "transfer")], actions: [
            .init(field: .destinationAccount, targetID: destination.id), .init(field: .tag, targetID: new.id), .init(field: .project, targetID: project.id)])
        let book = try ImportEngine.save(batch, in: LedgerBook(accounts: [account, destination], tags: [old, new], projects: [project], importRules: [rule]))
        return (book, batch, destination, old, new, project)
    }
    private func review(_ book: LedgerBook, _ batch: ImportBatch) throws -> ImportRuleReview {
        try ImportRuleEngine.review(batchID: batch.id, rowID: batch.rows[0].id, in: book)
    }

    @Test func singleRowAppendsTagAndSetsProjectAndTransferDestinationWithoutPosting() throws {
        let (book, batch, destination, old, new, project) = try fixture()
        let plan = try ImportRuleEngine.prepare(review(book, batch), selections: [.tag: new.id, .project: project.id, .destinationAccount: destination.id])
        let saved = try ImportRuleEngine.apply(plan, in: book)
        let row = saved.importBatches[0].rows[0]
        #expect(row.tagIDs == [old.id, new.id] && row.projectID == project.id && row.destinationAccountID == destination.id)
        #expect(saved.entries.isEmpty && saved.accounts == book.accounts && row.raw == batch.rows[0].raw)
        let again = try ImportRuleEngine.prepare(review(saved, batch), selections: [.tag: new.id])
        #expect(again.batch.rows[0].tagIDs == [old.id, new.id])
        let posting = try ImportEngine.prepare(batchID: batch.id, importIDs: [row.id], skipIDs: [], in: saved)
        let posted = try ImportEngine.commit(posting, in: saved)
        #expect(posted.entries[0].tagIDs == [old.id, new.id] && posted.entries[0].projectID == project.id)
        #expect(posted.entries[0].destinationAccountID == destination.id)
    }

    @Test func bulkFillExcludesAppendTagsAndExistingProjectsWhileExplicitAppendCountsAsChange() throws {
        var (book, batch, destination, old, new, project) = try fixture()
        book.importBatches[0].rows[0].projectID = project.id
        let reviewed = try ImportRuleEngine.reviewBatch(batchID: batch.id, rowIDs: [batch.rows[0].id], in: book)
        #expect(ImportRuleEngine.unambiguousEmptySelections(reviewed)[batch.rows[0].id] == [.destinationAccount: destination.id])
        let plan = try ImportRuleEngine.prepareBatch(reviewed, selections: [batch.rows[0].id: [.tag: new.id]])
        #expect(plan.changes[0].fields == [.tag] && plan.changes[0].after.tagIDs == [old.id, new.id])
        let saved = try ImportRuleEngine.applyBatch(plan, in: book)
        let second = try ImportRuleEngine.reviewBatch(batchID: batch.id, rowIDs: [batch.rows[0].id], in: saved)
        #expect(throws: ImportError.self) { try ImportRuleEngine.prepareBatch(second, selections: [batch.rows[0].id: [.tag: new.id]]) }
    }

    @Test func differentTagAndProjectSuggestionsRequireChoicesAndNeverUnionAutomatically() throws {
        var (book, batch, _, old, new, project) = try fixture()
        let other = EntryProject(name: "另一个项目"); book.projects.append(other)
        var rule = book.importRules[0]; rule.id = UUID()
        rule.actions = [.init(field: .tag, targetID: old.id), .init(field: .project, targetID: other.id)]
        book.importRules.append(rule)
        let inspected = try review(book, batch)
        #expect(inspected.suggestions.first { $0.id == .tag }?.hasConflict == true)
        #expect(inspected.suggestions.first { $0.id == .project }?.preferredID == nil)
        let plan = try ImportRuleEngine.prepare(inspected, selections: [.tag: new.id, .project: project.id])
        #expect(plan.batch.rows[0].tagIDs == [old.id, new.id] && plan.batch.rows[0].projectID == project.id)
    }

    @Test func archivedOrInactiveReferencesPauseAndAccountEditorIncludesDestinationRules() throws {
        let (book, batch, destination, _, _, project) = try fixture()
        #expect(ImportRuleEngine.affectedRules(field: .account, id: destination.id, in: book).count == 1)
        #expect(ImportRuleEngine.affectedRules(field: .project, id: project.id, in: book).count == 1)
        var changed = book; changed.tags[1].isActive = false
        #expect(try review(changed, batch).suggestions.isEmpty)
        changed = book; changed.projects[0].isArchived = true
        #expect(try review(changed, batch).suggestions.isEmpty)
        changed = book; changed.accounts[1].isActive = false
        #expect(try review(changed, batch).suggestions.isEmpty)
        let snapshot = LedgerBackupSnapshot(book: changed, draft: nil, settings: LedgerSettings())
        #expect(try BackupCodec.decode(BackupCodec.encode(snapshot)) == snapshot)
    }

    @Test func destinationRequiresTransferMatchingCurrencyAndDistinctFinalAccounts() throws {
        var (book, batch, destination, _, _, _) = try fixture()
        book.importRules[0].conditions = [.init(field: .account, comparison: .equals, value: batch.rows[0].raw[5])]
        book.importBatches[0].rows[0].raw[2] = "expense"
        let expense = try review(book, batch)
        #expect(!expense.suggestions.contains { $0.id == .destinationAccount } && expense.warnings.count == 1)
        book.importBatches[0].rows[0].raw[2] = "transfer"
        book.accounts[1].currency = .usd
        #expect(try review(book, batch).warnings.count == 1)
        book.accounts[1].currency = .cny
        book.importRules[0].actions.append(.init(field: .account, targetID: destination.id))
        let inspected = try review(book, batch)
        #expect(throws: ImportError.self) { try ImportRuleEngine.prepare(inspected, selections: [.account: destination.id, .destinationAccount: destination.id]) }
        book.importBatches[0].rows[0].destinationAccountID = destination.id
        #expect(throws: ImportError.self) { try ImportRuleEngine.prepare(review(book, batch), selections: [.account: destination.id]) }
    }

    @Test func profileNinePreservesNewActionsAndSoftMissingReferences() throws {
        var (book, _, _, _, _, _) = try fixture()
        book.importRules[0].actions[1].targetID = UUID()
        let snapshot = LedgerBackupSnapshot(book: book, draft: EntryDraft(amountText: "12+("), settings: LedgerSettings())
        let files = try BackupCodec.encode(snapshot)
        #expect(files.count == 23 && BackupSchema.profile == "ledger-core-v9")
        #expect(try BackupCodec.decode(files) == snapshot)
    }

    @Test func exactProfileEightKeepsOldRuleActionsAndRejectsNewEnumsInLegacyContract() throws {
        var (book, _, _, _, _, _) = try fixture()
        book.importRules[0].actions = [.init(field: .account, targetID: book.accounts[0].id)]
        let snapshot = LedgerBackupSnapshot(book: book, draft: nil, settings: LedgerSettings())
        var files = try BackupCodec.encode(snapshot)
        var manifest = try BackupSchema.manifest.read(files["manifest.csv"]!)[0].values
        manifest["profile"] = "ledger-core-v8"; manifest["backup_format_version"] = "8.0"; manifest["db_schema_version"] = "8"
        files["manifest.csv"] = BackupCSV.encode([BackupSchema.manifest.header, BackupSchema.manifest.columns.map { manifest[$0.name] }])
        files["schema_dictionary.csv"] = BackupSchema.dictionaryData(for: BackupSchema.v8All)
        rehash(&files)
        #expect(try BackupCodec.decode(files) == snapshot)
        var rows = try BackupCSV.decode(files["import_rule_actions.csv"]!, file: "import_rule_actions.csv")
        rows[1][2] = "tag"
        files["import_rule_actions.csv"] = BackupCSV.encode(rows)
        rehash(&files)
        #expect(throws: BackupError.self) { try BackupCodec.decode(files) }
    }
    private func rehash(_ files: inout [String: Data]) {
        files["checksums.csv"] = BackupCSV.encode([BackupSchema.checksums.header] + files.keys.filter { $0 != "checksums.csv" }.sorted().map { [$0, BackupSHA256.hex(files[$0]!)] })
    }
}
