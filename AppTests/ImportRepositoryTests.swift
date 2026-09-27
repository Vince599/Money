import Foundation
import XCTest
import LedgerCore
@testable import Ledger

@MainActor
final class ImportRepositoryTests: XCTestCase {
    func testExtendedRuleMappingAndBackupPreserveOrderedTagsProjectAndTransferTarget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try LedgerRepository(path: directory.appendingPathComponent("ledger.sqlite").path)
        let tag = EntryTag(name: "标签"), project = EntryProject(name: "项目")
        _ = try await repo.saveTag(tag); _ = try await repo.saveProject(project)
        // A formal account is needed for a persistent target; use the ordinary account creation path.
        let account = Account(name: "目标账户")
        _ = try await repo.addAccount(account, makeDefault: false)
        var batch = try ImportCSV.parse(ImportCSV.template, name: "rules", namespace: "bank")
        batch.rows[0].raw[2] = "transfer"
        _ = try await repo.saveImport(batch)
        let rule = ImportRule(name: "转账", conditions: [.init(field: .kind, comparison: .equals, value: "transfer")], actions: [.init(field: .destinationAccount, targetID: account.id), .init(field: .tag, targetID: tag.id), .init(field: .project, targetID: project.id)])
        _ = try await repo.saveImportRule(rule)
        let review = try await repo.reviewImportRules(batchID: batch.id, rowID: batch.rows[0].id)
        let draft = EntryDraft(amountText: "8+(")
        try await repo.saveDraft(draft, revision: 7)
        let mapped = try await repo.applyImportRule(ImportRuleEngine.prepare(review, selections: [.destinationAccount: account.id, .tag: tag.id, .project: project.id]))
        XCTAssertEqual(mapped.draft, draft); XCTAssertEqual(mapped.draftRevision, 7)
        XCTAssertEqual(mapped.book.importBatches[0].rows[0].tagIDs, [tag.id])
        let bytes = try await repo.exportBackup()
        let preview = try await repo.prepareRestore(bytes)
        let restored = try await repo.restore(previewID: preview.id, revision: 8)
        XCTAssertEqual(restored.book, mapped.book)
        XCTAssertEqual(restored.book.importBatches[0].rows[0].destinationAccountID, account.id)
        XCTAssertEqual(restored.book.importBatches[0].rows[0].projectID, project.id)
    }

    func testBatchRulePreviewRejectsNewerRulesAndCommitsAllRowsWithDraftAndBackup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try LedgerRepository(path: directory.appendingPathComponent("ledger.sqlite").path)
        var batch = try ImportCSV.parse(ImportCSV.template, name: "batch", namespace: "bank")
        var raw = batch.rows[0].raw; raw[0] = "second"
        batch.rows.append(ImportRow(raw: raw))
        _ = try await repo.saveImport(batch)
        var rule = ImportRule(name: "餐饮", conditions: [.init(field: .kind, comparison: .equals, value: "expense")], actions: [.init(field: .category, targetID: SeedData.mealsID)])
        _ = try await repo.saveImportRule(rule)
        let review = try await repo.reviewImportBatchRules(batchID: batch.id, rowIDs: Set(batch.rows.map(\.id)))
        let picks = ImportRuleEngine.unambiguousEmptySelections(review)
        let oldPlan = try await repo.prepareImportBatchRules(review, selections: picks)
        rule.name = "新名称"; _ = try await repo.saveImportRule(rule, expectedVersion: 1)
        do { _ = try await repo.prepareImportBatchRules(review, selections: picks); XCTFail("Old review must fail") }
        catch { XCTAssertEqual(error as? ImportError, .stalePreview) }
        do { _ = try await repo.applyImportBatchRules(oldPlan); XCTFail("Old plan must fail") }
        catch { XCTAssertEqual(error as? ImportError, .stalePreview) }
        let fresh = try await repo.reviewImportBatchRules(batchID: batch.id, rowIDs: Set(batch.rows.map(\.id)))
        let plan = try await repo.prepareImportBatchRules(fresh, selections: ImportRuleEngine.unambiguousEmptySelections(fresh))
        let draft = EntryDraft(amountText: "12+(")
        try await repo.saveDraft(draft, revision: 5)
        let saved = try await repo.applyImportBatchRules(plan)
        XCTAssertTrue(saved.book.importBatches[0].rows.allSatisfy { $0.categoryID == SeedData.mealsID })
        XCTAssertEqual(saved.book.importBatches[0].version, 2)
        XCTAssertEqual(saved.draft, draft); XCTAssertEqual(saved.draftRevision, 5)
        XCTAssertTrue(saved.book.entries.isEmpty)
        let backup = try await repo.exportBackup()
        let restore = try await repo.prepareRestore(backup)
        let restored = try await repo.restore(previewID: restore.id, revision: 6)
        XCTAssertEqual(restored.book, saved.book); XCTAssertEqual(restored.draft, draft)
    }

    func testRuleVersionInvalidatesSuggestionAndBackupPreservesRulesAndManualDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try LedgerRepository(path: directory.appendingPathComponent("ledger.sqlite").path)
        let batch = try ImportCSV.parse(ImportCSV.template, name: "rules", namespace: "bank")
        _ = try await repo.saveImport(batch)
        var rule = ImportRule(name: "餐饮", conditions: [.init(field: .kind, comparison: .equals, value: "expense")], actions: [.init(field: .category, targetID: SeedData.mealsID)])
        _ = try await repo.saveImportRule(rule)
        let inspected = try await repo.reviewImportRules(batchID: batch.id, rowID: batch.rows[0].id)
        let plan = try ImportRuleEngine.prepare(inspected, selections: [.category: SeedData.mealsID])
        rule.name = "新的规则名称"
        _ = try await repo.saveImportRule(rule, expectedVersion: 1)
        do { _ = try await repo.applyImportRule(plan); XCTFail("Old rule preview must not commit") }
        catch { XCTAssertEqual(error as? ImportError, .stalePreview) }
        let fresh = try await repo.reviewImportRules(batchID: batch.id, rowID: batch.rows[0].id)
        let draft = EntryDraft(amountText: "12+(")
        try await repo.saveDraft(draft, revision: 11)
        let mapped = try await repo.applyImportRule(ImportRuleEngine.prepare(fresh, selections: [.category: SeedData.mealsID]))
        XCTAssertEqual(mapped.draft, draft); XCTAssertEqual(mapped.draftRevision, 11)
        XCTAssertEqual(mapped.book.importRules[0].version, 2)
        XCTAssertTrue(mapped.book.entries.isEmpty)
        let backup = try await repo.exportBackup()
        let preview = try await repo.prepareRestore(backup)
        XCTAssertEqual(preview.importRuleCount, 1)
        let restored = try await repo.restore(previewID: preview.id, revision: 12)
        XCTAssertEqual(restored.book, mapped.book); XCTAssertEqual(restored.draft, draft)
    }

    func testUndoPreservesLatestDraftAndBackupRestoresClosedBatchWithoutCashReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try LedgerRepository(path: directory.appendingPathComponent("ledger.sqlite").path)
        var batch = try ImportCSV.parse(ImportCSV.template, name: "undo", namespace: "bank")
        let account = Account(name: "银行卡", openingMinor: 10_000)
        batch.proposedAccounts = [account]; batch.rows[0].accountID = account.id; batch.rows[0].categoryID = SeedData.mealsID
        _ = try await repo.saveImport(batch)
        let posting = try await repo.prepareImport(batchID: batch.id, importIDs: [batch.rows[0].id], skipIDs: [])
        _ = try await repo.commitImport(posting.plan)
        let review = try await repo.reviewImportUndo(batchID: batch.id)
        let plan = try XCTUnwrap(review.plan)
        let draft = EntryDraft(amountText: "12+(")
        try await repo.saveDraft(draft, revision: 9)
        let undone = try await repo.undoImport(plan)
        XCTAssertTrue(undone.book.entries.isEmpty)
        XCTAssertEqual(undone.draft, draft); XCTAssertEqual(undone.draftRevision, 9)
        let retry = try await repo.undoImport(plan)
        XCTAssertEqual(retry.book, undone.book)
        let bytes = try await repo.exportBackup()
        let preview = try await repo.prepareRestore(bytes)
        let restored = try await repo.restore(previewID: preview.id, revision: 10)
        XCTAssertEqual(restored.book, undone.book)
        XCTAssertEqual(restored.book.importBatches[0].rows[0].state, .reverted)
        XCTAssertEqual(try LedgerEngine.balance(of: account.id, in: restored.book).minorUnits, 10_000)
        do { _ = try await repo.commitImport(posting.plan); XCTFail("Old posting must not replay") }
        catch { XCTAssertEqual(error as? ImportError, .stalePreview) }
    }

    func testLabelsPreviewRejectsCatalogChangesAndRestoresDraftWithLabels() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try LedgerRepository(path: directory.appendingPathComponent("ledger.sqlite").path)
        var tag = EntryTag(name: "旅行")
        let project = EntryProject(name: "出行")
        _ = try await repo.saveTag(tag); _ = try await repo.saveProject(project)
        let batch = try ImportCSV.parse(ImportCSV.template, name: "example", namespace: "bank")
        _ = try await repo.saveImport(batch)
        let plan = try await repo.prepareImportLabels(batchID: batch.id, rowIDs: [batch.rows[0].id], tags: .add([tag.id]), project: .set(project.id))
        tag.isActive = false; _ = try await repo.saveTag(tag)
        do { _ = try await repo.commitImportLabels(plan); XCTFail("Expected stale preview") }
        catch { XCTAssertEqual(error as? ImportError, .stalePreview) }
        tag.isActive = true; _ = try await repo.saveTag(tag)
        let refreshed = try await repo.prepareImportLabels(batchID: batch.id, rowIDs: [batch.rows[0].id], tags: .add([tag.id]), project: .set(project.id))
        let draft = EntryDraft(amountText: "9+(")
        try await repo.saveDraft(draft, revision: 8)
        let mapped = try await repo.commitImportLabels(refreshed)
        XCTAssertEqual(mapped.draft, draft); XCTAssertEqual(mapped.draftRevision, 8)
        XCTAssertTrue(mapped.book.entries.isEmpty)
        XCTAssertEqual(mapped.book.importBatches[0].rows[0].tagIDs, [tag.id])
        let backup = try await repo.exportBackup()
        let restore = try await repo.prepareRestore(backup)
        let restored = try await repo.restore(previewID: restore.id, revision: 9)
        XCTAssertEqual(restored.book, mapped.book)
        XCTAssertEqual(restored.draft, draft)
    }

    func testSequentialReviewSavesPreservePreviousRowAndRejectOldEditor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try LedgerRepository(path: directory.appendingPathComponent("ledger.sqlite").path)
        let tag = EntryTag(name: "单行核对")
        _ = try await repo.saveTag(tag)
        var batch = try ImportCSV.parse(ImportCSV.template, name: "example", namespace: "bank")
        var raw = batch.rows[0].raw; raw[0] = "example-2"
        batch.rows.append(ImportRow(raw: raw))
        _ = try await repo.saveImport(batch)
        let oldEditor = batch
        batch.rows[0].tagIDs = [tag.id]
        let firstSaved = try await repo.saveImport(batch, expectedVersion: 1)
        var nextEditor = try XCTUnwrap(firstSaved.book.importBatches.first)
        nextEditor.rows[1].categoryID = SeedData.mealsID
        let secondSaved = try await repo.saveImport(nextEditor, expectedVersion: nextEditor.version)
        XCTAssertEqual(secondSaved.book.importBatches[0].rows[0].tagIDs, [tag.id])
        XCTAssertEqual(secondSaved.book.importBatches[0].rows[1].categoryID, SeedData.mealsID)
        do { _ = try await repo.saveImport(oldEditor, expectedVersion: 1); XCTFail("Expected stale editor") }
        catch { XCTAssertEqual(error as? ImportError, .stalePreview) }
        let reopened = try LedgerRepository(path: directory.appendingPathComponent("ledger.sqlite").path)
        let actual = try await reopened.snapshot()
        XCTAssertEqual(actual.book, secondSaved.book)
    }

    func testCSVFileDraftMappingPreviewCommitAndFullRestore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try LedgerRepository(path: directory.appendingPathComponent("ledger.sqlite").path)
        let csv = directory.appendingPathComponent("sample.csv")
        try ImportCSV.template.write(to: csv)
        let draft = EntryDraft(amountText: "12+(")
        try await repo.saveDraft(draft, revision: 7)
        let parsed = try await repo.importCSV(from: csv, namespace: "测试银行卡")
        XCTAssertTrue(parsed.book.entries.isEmpty && parsed.book.accounts.isEmpty)
        var batch = try XCTUnwrap(parsed.book.importBatches.first)
        let account = Account(name: "导入账户", openingMinor: 10_000)
        batch.proposedAccounts = [account]; batch.rows[0].accountID = account.id; batch.rows[0].categoryID = SeedData.mealsID
        let mapped = try await repo.saveImport(batch, expectedVersion: batch.version)
        let backup = try await repo.exportBackup()
        let preview = try await repo.prepareImport(batchID: batch.id, importIDs: [batch.rows[0].id], skipIDs: [])
        XCTAssertEqual(preview.effects.first?.before.minorUnits, 10_000)
        XCTAssertEqual(preview.effects.first?.after.minorUnits, 7_990)
        XCTAssertTrue(preview.effects.first?.isNew == true)
        let saved = try await repo.commitImport(preview.plan)
        XCTAssertEqual(saved.draft, draft)
        XCTAssertEqual(saved.draftRevision, 7)
        let retried = try await repo.commitImport(preview.plan)
        XCTAssertEqual(retried.book.entries.count, 1)
        try await repo.saveDraft(nil, revision: 6)
        let beforeRestore = try await repo.snapshot()
        XCTAssertEqual(beforeRestore.draft, draft)
        let restore = try await repo.prepareRestore(backup)
        XCTAssertEqual(restore.importBatchCount, 1)
        let restored = try await repo.restore(previewID: restore.id, revision: 9)
        XCTAssertEqual(restored.book, mapped.book)
        XCTAssertEqual(restored.draft, draft)
        XCTAssertTrue(restored.book.accounts.isEmpty)
    }

    func testInvalidFileDoesNotReplaceExistingDraftAndExpiredPreviewCannotCommit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try LedgerRepository(path: directory.appendingPathComponent("ledger.sqlite").path)
        var batch = try ImportCSV.parse(ImportCSV.template, name: "test", namespace: "bank")
        let account = Account(name: "bank", openingMinor: 10_000)
        batch.proposedAccounts = [account]; batch.rows[0].accountID = account.id; batch.rows[0].categoryID = SeedData.mealsID
        let saved = try await repo.saveImport(batch)
        let bad = directory.appendingPathComponent("bad.csv")
        try Data("wrong,header\n".utf8).write(to: bad)
        do { _ = try await repo.importCSV(from: bad, namespace: "bank"); XCTFail("Expected CSV failure") }
        catch { XCTAssertNotNil(error as? ImportError) }
        let unchanged = try await repo.snapshot()
        XCTAssertEqual(unchanged.book, saved.book)
        let preview = try await repo.prepareImport(batchID: batch.id, importIDs: [batch.rows[0].id], skipIDs: [])
        _ = try await repo.saveTag(EntryTag(name: "并行改动"))
        do { _ = try await repo.commitImport(preview.plan); XCTFail("Expected stale preview") }
        catch { XCTAssertEqual(error as? ImportError, .stalePreview) }
        let current = try await repo.snapshot()
        XCTAssertTrue(current.book.entries.isEmpty && current.book.accounts.isEmpty)
    }
}
