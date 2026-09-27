import Foundation
import XCTest
import LedgerCore
@testable import Ledger

@MainActor
final class ImportRepositoryTests: XCTestCase {
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
