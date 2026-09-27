import Foundation
import XCTest
import LedgerCore
@testable import Ledger

@MainActor
final class ShortcutRepositoryTests: XCTestCase {
    func testShortcutExpenseIncomeAndTransferPreserveManualDraftAndBackup() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.sqlite").path
        let repo = try LedgerRepository(path: path)
        let source = Account(name: "银行卡", openingMinor: 1_000_00)
        let destination = Account(name: "现金", kind: .cash, openingMinor: 50_00)
        _ = try await repo.addAccount(source, makeDefault: true)
        _ = try await repo.addAccount(destination, makeDefault: false)
        let manualDraft = EntryDraft(amountText: "36+(", accountID: source.id,
                                     expenseCategoryID: SeedData.taxiID, title: "未完成",
                                     note: "保留手动输入,引号\"与换行\n")
        try await repo.saveDraft(manualDraft, revision: 10)
        let initial = try await repo.snapshot()

        let expense = entry(kind: .expense, accountID: source.id, minorUnits: 20_10,
                            categoryID: SeedData.mealsID)
        let income = entry(kind: .income, accountID: source.id, minorUnits: 300_00,
                           categoryID: SeedData.salaryIncomeID)
        let transfer = entry(kind: .transfer, accountID: source.id, minorUnits: 75_00,
                             destinationAccountID: destination.id)
        var saved = initial
        for command in [expense, income, transfer] {
            saved = try await repo.saveShortcutEntry(command)
            XCTAssertEqual(saved.draft, manualDraft)
            XCTAssertEqual(saved.draftRevision, 10)
            XCTAssertEqual(saved.settings, initial.settings)
        }
        XCTAssertEqual(saved.book.entries, [expense, income, transfer])
        XCTAssertTrue(saved.book.adjustments.isEmpty)
        XCTAssertEqual(try LedgerEngine.balance(of: source.id, in: saved.book).minorUnits, 1_204_90)
        XCTAssertEqual(try LedgerEngine.balance(of: destination.id, in: saved.book).minorUnits, 125_00)
        try await assertPersistedState(saved, repository: repo, at: path)

        // The next editor autosave still owns the revision immediately after 10.
        var continued = manualDraft
        continued.amountText = "36+(4"
        try await repo.saveDraft(continued, revision: 11)
        let afterAutosave = try await repo.snapshot()
        XCTAssertEqual(afterAutosave.draft, continued)
        XCTAssertEqual(afterAutosave.draftRevision, 11)
        XCTAssertEqual(afterAutosave.book, saved.book)
    }

    func testRetryUsesOneEventAndPreservesLatestManualDraft() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.sqlite").path
        let repo = try LedgerRepository(path: path)
        let account = Account(name: "微信", kind: .wallet, openingMinor: 100_00)
        _ = try await repo.addAccount(account, makeDefault: true)
        let command = entry(kind: .expense, accountID: account.id, minorUnits: 20_10,
                            categoryID: SeedData.mealsID)
        let first = try await repo.saveShortcutEntry(command)
        XCTAssertNil(first.draft)
        XCTAssertEqual(first.draftRevision, 0)

        let draft = EntryDraft(amountText: "12.", accountID: account.id, note: "重试时的手动草稿")
        try await repo.saveDraft(draft, revision: 5)
        var retry = command
        retry.id = UUID()
        retry.createdAt = command.createdAt.addingTimeInterval(60)
        let retried = try await repo.saveShortcutEntry(retry)
        XCTAssertEqual(retried.book, first.book)
        XCTAssertEqual(retried.book.entries, [command])
        XCTAssertEqual(retried.draft, draft)
        XCTAssertEqual(retried.draftRevision, 5)
        XCTAssertEqual(try LedgerEngine.balance(of: account.id, in: retried.book).minorUnits, 79_90)
        try await assertPersistedState(retried, repository: repo, at: path)

        retry.amount = Money(minorUnits: 30_00)
        do {
            _ = try await repo.saveShortcutEntry(retry)
            XCTFail("An operation ID cannot be reused for a different payment")
        } catch { XCTAssertEqual(error as? LedgerError, .operationConflict) }
        let afterConflict = try await repo.snapshot()
        XCTAssertEqual(afterConflict.book, retried.book)
        XCTAssertEqual(afterConflict.draft, draft)
        XCTAssertEqual(afterConflict.draftRevision, 5)
    }

    func testInvalidShortcutReferencesAndCrossCurrencyTransferLeaveDatabaseUnchanged() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.sqlite").path
        let repo = try LedgerRepository(path: path)
        let account = Account(name: "人民币账户", openingMinor: 100_00)
        let foreign = Account(name: "美元账户", currency: .usd, openingMinor: 50_00)
        let inactive = Account(name: "停用账户", isActive: false)
        _ = try await repo.addAccount(account, makeDefault: true)
        _ = try await repo.addAccount(foreign, makeDefault: false)
        _ = try await repo.addAccount(inactive, makeDefault: false)
        let manualDraft = EntryDraft(amountText: "12+(", accountID: account.id, note: "失败时保留")
        try await repo.saveDraft(manualDraft, revision: 7)
        let initial = try await repo.snapshot()

        let crossCurrency = entry(kind: .transfer, accountID: account.id, minorUnits: 10_00,
                                  destinationAccountID: foreign.id)
        let missingAccount = entry(kind: .expense, accountID: UUID(), minorUnits: 10_00,
                                   categoryID: SeedData.mealsID)
        let inactiveAccount = entry(kind: .expense, accountID: inactive.id, minorUnits: 10_00,
                                    categoryID: SeedData.mealsID)
        let wrongCategory = entry(kind: .expense, accountID: account.id, minorUnits: 10_00,
                                  categoryID: SeedData.salaryIncomeID)
        var missingSubject = entry(kind: .expense, accountID: account.id, minorUnits: 10_00,
                                   categoryID: SeedData.mealsID)
        missingSubject.subjectID = UUID()
        let cases: [(LedgerEntry, LedgerError)] = [
            (crossCurrency, .currencyMismatch), (missingAccount, .accountNotFound),
            (inactiveAccount, .inactiveAccount), (wrongCategory, .invalidCategory),
            (missingSubject, .invalidSubject)
        ]
        for (command, expectedError) in cases {
            do {
                _ = try await repo.saveShortcutEntry(command)
                XCTFail("Invalid shortcut input must fail before changing persisted state")
            } catch { XCTAssertEqual(error as? LedgerError, expectedError) }
            let after = try await repo.snapshot()
            XCTAssertEqual(after.book, initial.book)
            XCTAssertEqual(after.draft, manualDraft)
            XCTAssertEqual(after.settings, initial.settings)
            XCTAssertEqual(after.draftRevision, 7)
        }
        try await assertPersistedState(initial, repository: repo, at: path)
    }

    private func entry(kind: EntryKind, accountID: UUID, minorUnits: Int64,
                       categoryID: UUID? = nil, destinationAccountID: UUID? = nil) -> LedgerEntry {
        let date = Date(timeIntervalSinceReferenceDate: 812_345_678.123456)
        return LedgerEntry(kind: kind, amount: Money(minorUnits: minorUnits), accountID: accountID,
                           destinationAccountID: destinationAccountID, categoryID: categoryID,
                           occurredAt: date, createdAt: date, title: "快捷记账", note: "合成测试数据")
    }

    private func assertPersistedState(_ expected: LedgerSnapshot, repository: LedgerRepository, at path: String,
                                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let archive = try await repository.exportBackup()
        let backup = try BackupCodec.decode(BackupArchive.decode(archive))
        XCTAssertEqual(backup.book, expected.book, file: file, line: line)
        XCTAssertEqual(backup.draft, expected.draft, file: file, line: line)
        XCTAssertEqual(backup.settings, expected.settings, file: file, line: line)
        let reopened = try LedgerRepository(path: path)
        let persisted = try await reopened.snapshot()
        XCTAssertEqual(persisted.book, expected.book, file: file, line: line)
        XCTAssertEqual(persisted.draft, expected.draft, file: file, line: line)
        XCTAssertEqual(persisted.settings, expected.settings, file: file, line: line)
        // The draft revision fence belongs to the shared live repository, not the backup or database.
    }

    private func testDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShortcutRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
