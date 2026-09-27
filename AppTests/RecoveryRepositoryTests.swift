import Foundation
import XCTest
import LedgerCore
@testable import Ledger

@MainActor
final class RecoveryRepositoryTests: XCTestCase {
    func testModelPublishesRecoverySummaryAndGroupDeletePreservesUnrelatedDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.sqlite").path
        let repo = try LedgerRepository(path: path)
        let account = Account(name: "回收验证", openingMinor: 200_000)
        _ = try await repo.addAccount(account, makeDefault: true)
        let model = LedgerAppModel(repository: repo)
        await model.start()
        let original = LedgerEntry(kind: .expense, amount: Money(minorUnits: 100_000), accountID: account.id,
                                   categoryID: SeedData.mealsID, occurredAt: Date().addingTimeInterval(-60), note: "保留的备注")
        let savedOriginal = await model.save(original)
        XCTAssertTrue(savedOriginal)
        let refund = LedgerEntry(kind: .refund, amount: Money(minorUnits: 20_000), accountID: account.id,
                                 originalEntryID: original.id)
        let savedRefund = await model.save(refund)
        XCTAssertTrue(savedRefund)
        XCTAssertEqual(model.recoveries[original.id]?.netCost.minorUnits, 80_000)
        XCTAssertEqual(model.displayTitle(refund), "退款")
        XCTAssertEqual(model.book.entries.first?.note, "保留的备注")
        let unsafeDelete = await model.delete(original.id)
        XCTAssertFalse(unsafeDelete)
        XCTAssertEqual(model.book.entries.count, 2)
        let draft = EntryDraft(amountText: "尚未填写", originalEntryID: original.id)
        await model.updateDraft(draft).value
        let exported = try await model.exportBackup()
        let restored = try BackupCodec.decode(BackupArchive.decode(exported))
        XCTAssertEqual(restored.book, model.book)
        XCTAssertEqual(restored.draft, draft)
        let plan = try await model.deletionPreview(original.id)
        let deleted = await model.delete(plan)
        XCTAssertTrue(deleted)
        XCTAssertTrue(model.recoveries.isEmpty)
        XCTAssertTrue(model.book.entries.isEmpty)
        XCTAssertEqual(model.draft, draft)
        let reopened = try await LedgerRepository(path: path).snapshot()
        XCTAssertEqual(reopened.book, model.book)
        XCTAssertEqual(reopened.draft, draft)
        XCTAssertTrue(reopened.recoveries.isEmpty)
    }

    func testReclassificationUpdatesSummaryWithoutDuplicatingReceipt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try LedgerRepository(path: directory.appendingPathComponent("ledger.sqlite").path)
        let account = Account(name: "回收转换", openingMinor: 200_000)
        _ = try await repo.addAccount(account, makeDefault: true)
        let original = LedgerEntry(kind: .expense, amount: Money(minorUnits: 100_000), accountID: account.id,
                                   categoryID: SeedData.mealsID, occurredAt: Date().addingTimeInterval(-60))
        _ = try await repo.saveEntry(original, expectedVersion: nil, nextDraft: nil, revision: 1)
        var recovery = LedgerEntry(kind: .recovery, amount: Money(minorUnits: 20_000), accountID: account.id, originalEntryID: original.id)
        let before = try await repo.saveEntry(recovery, expectedVersion: nil, nextDraft: nil, revision: 2)
        recovery.kind = .income; recovery.originalEntryID = nil; recovery.categoryID = SeedData.salaryIncomeID; recovery.operationID = UUID()
        let after = try await repo.saveEntry(recovery, expectedVersion: 1, nextDraft: nil, revision: 3)
        XCTAssertTrue(after.recoveries.isEmpty)
        XCTAssertEqual(after.book.entries.count, 2)
        XCTAssertEqual(try LedgerEngine.balance(of: account.id, in: before.book), try LedgerEngine.balance(of: account.id, in: after.book))
    }
}
