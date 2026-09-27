import Foundation
import Testing
@testable import LedgerCore

@Suite("Batch rule review and atomic explicit mapping")
struct ImportBatchRuleTests {
    private func fixture(count: Int = 3) throws -> (LedgerBook, ImportBatch, Account) {
        let account = Account(name: "账户", openingMinor: 10_000)
        var batch = try ImportCSV.parse(ImportCSV.template, name: "batch", namespace: "bank")
        let raw = batch.rows[0].raw
        batch.rows = (0..<count).map { index in
            var values = raw; values[0] = "source-\(index)"
            return ImportRow(raw: values)
        }
        let rule = ImportRule(name: "支出", conditions: [.init(field: .kind, comparison: .equals, value: "expense")],
                              actions: [.init(field: .account, targetID: account.id), .init(field: .category, targetID: SeedData.mealsID), .init(field: .subject, targetID: SeedData.mpcID)])
        let book = try ImportEngine.save(batch, in: LedgerBook(accounts: [account], importRules: [rule]))
        return (book, batch, account)
    }
    private func review(_ book: LedgerBook, _ batch: ImportBatch) throws -> ImportRuleBatchReview {
        try ImportRuleEngine.reviewBatch(batchID: batch.id, rowIDs: Set(batch.rows.map(\.id)), in: book)
    }

    @Test func fillEmptyNeverOverridesManualMappingsOrDefaultSubject() throws {
        var (book, batch, account) = try fixture()
        book.importBatches[0].rows[0].categoryID = SeedData.otherExpenseID
        book.importBatches[0].rows[1].accountID = account.id
        let value = try review(book, batch)
        let picks = ImportRuleEngine.unambiguousEmptySelections(value)
        #expect(picks[batch.rows[0].id] == [.account: account.id])
        #expect(picks[batch.rows[1].id] == [.category: SeedData.mealsID])
        #expect(picks.values.allSatisfy { $0[.subject] == nil })
        #expect(value.rows.map(\.rowID) == batch.rows.map(\.id))
        let plan = try ImportRuleEngine.prepareBatch(value, selections: picks)
        #expect(plan.changes.count == 3)
        #expect(plan.batch.rows[0].categoryID == SeedData.otherExpenseID)
    }

    @Test func evenLowerPriorityConflictRequiresExplicitChoiceWhileOtherFieldsCanFill() throws {
        var (book, batch, _) = try fixture()
        var conflicting = book.importRules[0]; conflicting.id = UUID(); conflicting.priority = 200
        conflicting.actions = [.init(field: .category, targetID: SeedData.otherExpenseID)]
        book.importRules.append(conflicting)
        let value = try review(book, batch)
        var picks = ImportRuleEngine.unambiguousEmptySelections(value)
        #expect(picks.values.allSatisfy { $0[.category] == nil })
        picks[batch.rows[1].id, default: [:]][.category] = SeedData.otherExpenseID
        let plan = try ImportRuleEngine.prepareBatch(value, selections: picks)
        #expect(plan.batch.rows[0].categoryID == nil && plan.batch.rows[1].categoryID == SeedData.otherExpenseID)
        book.importRules[1].priority = 100
        #expect(try review(book, batch).rows.allSatisfy { $0.suggestions.first { $0.id == .category }?.preferredID == nil })
    }

    @Test func oneBatchVersionChangesOnlyChosenRowsAndBackupKeepsLabelsAndRaw() throws {
        var (book, batch, account) = try fixture()
        let tag = EntryTag(name: "保留"), project = EntryProject(name: "项目")
        book.tags = [tag]; book.projects = [project]
        book.importBatches[0].rows[0].tagIDs = [tag.id]; book.importBatches[0].rows[0].projectID = project.id
        let inspected = try ImportRuleEngine.reviewBatch(batchID: batch.id, rowIDs: [batch.rows[0].id, batch.rows[2].id], in: book)
        let plan = try ImportRuleEngine.prepareBatch(inspected, selections: [batch.rows[2].id: [.account: account.id], batch.rows[0].id: [.category: SeedData.mealsID]])
        #expect(plan.changes.map(\.id) == [batch.rows[0].id, batch.rows[2].id])
        let saved = try ImportRuleEngine.applyBatch(plan, in: book)
        #expect(saved.importBatches[0].version == 2)
        #expect(saved.accounts == book.accounts && saved.entries == book.entries && saved.importRules == book.importRules)
        #expect(saved.importBatches[0].rows[1] == book.importBatches[0].rows[1])
        #expect(saved.importBatches[0].rows[0].tagIDs == [tag.id] && saved.importBatches[0].rows[0].projectID == project.id)
        #expect(saved.importBatches[0].rows.map(\.raw) == batch.rows.map(\.raw))
        let snapshot = LedgerBackupSnapshot(book: saved, draft: EntryDraft(amountText: "12+("), settings: LedgerSettings())
        #expect(try BackupCodec.decode(BackupCodec.encode(snapshot)) == snapshot)
    }

    @Test func noChangesUnknownRowsAndUnreviewedTargetsAreRejectedWithoutMutation() throws {
        let (book, batch, _) = try fixture()
        let value = try review(book, batch)
        #expect(throws: ImportError.self) { try ImportRuleEngine.prepareBatch(value, selections: [:]) }
        #expect(throws: ImportError.self) { try ImportRuleEngine.prepareBatch(value, selections: [batch.rows[0].id: [.subject: SeedData.mpcID]]) }
        #expect(throws: ImportError.unavailableRow) { try ImportRuleEngine.prepareBatch(value, selections: [UUID(): [:]]) }
        #expect(throws: ImportError.invalidState) { try ImportRuleEngine.prepareBatch(value, selections: [batch.rows[0].id: [.account: UUID()]]) }
        let subset = try ImportRuleEngine.reviewBatch(batchID: batch.id, rowIDs: [batch.rows[0].id], in: book)
        #expect(throws: ImportError.unavailableRow) { try ImportRuleEngine.prepareBatch(subset, selections: [batch.rows[1].id: [.category: SeedData.mealsID]]) }
        #expect(book.importBatches[0] == batch)
    }

    @Test func changedRulesCatalogOrDraftMappingInvalidateEntirePlan() throws {
        let (book, batch, _) = try fixture()
        let value = try review(book, batch)
        let plan = try ImportRuleEngine.prepareBatch(value, selections: ImportRuleEngine.unambiguousEmptySelections(value))
        var newer = book; newer.importRules[0].version += 1
        #expect(throws: ImportError.stalePreview) { try ImportRuleEngine.applyBatch(plan, in: newer) }
        newer = book; newer.accounts[0].isActive = false
        #expect(throws: ImportError.stalePreview) { try ImportRuleEngine.applyBatch(plan, in: newer) }
        newer = book; newer.importBatches[0].rows[2].categoryID = SeedData.otherExpenseID
        #expect(throws: ImportError.stalePreview) { try ImportRuleEngine.applyBatch(plan, in: newer) }
        let saved = try ImportRuleEngine.applyBatch(plan, in: book)
        #expect(throws: ImportError.stalePreview) { try ImportRuleEngine.applyBatch(plan, in: saved) }
    }

    @Test func selectionLimitAndProcessedOrClosedRowsAreEnforced() throws {
        let (large, batch, _) = try fixture(count: 201)
        #expect(throws: ImportError.tooManySelected) { try review(large, batch) }
        let allowed = try ImportRuleEngine.reviewBatch(batchID: batch.id, rowIDs: Set(batch.rows.prefix(200).map(\.id)), in: large)
        #expect(allowed.rows.count == 200)
        #expect(throws: ImportError.unavailableRow) { try ImportRuleEngine.reviewBatch(batchID: batch.id, rowIDs: [], in: large) }
        #expect(throws: ImportError.unavailableRow) { try ImportRuleEngine.reviewBatch(batchID: batch.id, rowIDs: [UUID()], in: large) }
        var (book, small, account) = try fixture()
        book.importBatches[0].rows[0].accountID = account.id; book.importBatches[0].rows[0].categoryID = SeedData.mealsID
        let posting = try ImportEngine.prepare(batchID: small.id, importIDs: [small.rows[0].id], skipIDs: [small.rows[1].id], in: book)
        let posted = try ImportEngine.commit(posting, in: book)
        #expect(throws: ImportError.unavailableRow) { try review(posted, small) }
        let undo = try #require(ImportEngine.reviewUndo(batchID: small.id, in: posted).plan)
        let reverted = try ImportEngine.undo(undo, in: posted)
        #expect(throws: ImportError.unavailableRow) { try ImportRuleEngine.reviewBatch(batchID: small.id, rowIDs: [small.rows[2].id], in: reverted) }
    }

    @Test func disabledOrUnmatchedRulesStayUntouchedAndBadRowsDoNotBlockOtherSuggestions() throws {
        var (book, batch, _) = try fixture()
        book.importBatches[0].rows[0].raw[2] = "income"
        book.importBatches[0].rows[1].raw[4] = "USD"
        let value = try review(book, batch)
        #expect(value.rows[0].suggestions.isEmpty)
        #expect(value.rows[1].warnings.count == 1)
        #expect(value.rows[2].suggestions.count == 3)
        book.importRules[0].isEnabled = false
        let disabled = try review(book, batch)
        #expect(ImportRuleEngine.unambiguousEmptySelections(disabled).isEmpty)
        #expect(throws: ImportError.self) { try ImportRuleEngine.prepareBatch(disabled, selections: [:]) }
    }
}
