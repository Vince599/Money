import Foundation
import XCTest
import LedgerCore
@testable import Ledger

@MainActor
final class IncrementalRepositoryTests: XCTestCase {
    func testEditingAndRetryPreserveUnrelatedDraftWithoutAdvancingRevision() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.sqlite").path
        let repo = try LedgerRepository(path: path)
        let account = Account(name: "编辑测试", openingMinor: 100_00)
        _ = try await repo.addAccount(account, makeDefault: true)
        let original = expense(accountID: account.id, minorUnits: 20_10)
        _ = try await repo.saveEntry(original, expectedVersion: nil, nextDraft: nil, revision: 1)

        let unrelated = EntryDraft(amountText: "36+(", accountID: account.id,
                                   expenseCategoryID: SeedData.taxiID, note: "另一笔未完成输入")
        try await repo.saveDraft(unrelated, revision: 10)
        var edit = original
        edit.operationID = UUID()
        edit.amount = Money(minorUnits: 25_00)
        edit.createdAt = original.createdAt.addingTimeInterval(60)
        edit.note = "修正已保存的流水"
        let edited = try await repo.saveEntry(edit, expectedVersion: 1, nextDraft: nil, revision: 20)
        XCTAssertEqual(edited.draft, unrelated)
        XCTAssertEqual(edited.draftRevision, 10)
        let editedEntry = try XCTUnwrap(edited.book.entries.first)
        XCTAssertEqual(editedEntry.id, original.id)
        XCTAssertEqual(editedEntry.createdAt, original.createdAt)
        XCTAssertEqual(editedEntry.version, 2)
        XCTAssertEqual(edited.book.retiredOperationIDs, [original.operationID])
        try await assertReopenedState(edited, at: path)

        // A later autosave below the edit's revision must still be accepted.
        var continued = unrelated
        continued.amountText = "36+(4"
        try await repo.saveDraft(continued, revision: 11)
        let unrelatedReplacement = EntryDraft(amountText: "999", note: "编辑不得覆盖当前草稿")
        let retried = try await repo.saveEntry(edit, expectedVersion: 1,
                                             nextDraft: unrelatedReplacement, revision: 21)
        XCTAssertEqual(retried.book, edited.book)
        XCTAssertEqual(retried.draft, continued)
        XCTAssertEqual(retried.settings, edited.settings)
        XCTAssertEqual(retried.draftRevision, 11)
        try await assertReopenedState(retried, at: path)
    }

    func testIdempotentCreationStillAppliesNextDraftAndClearPolicies() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.sqlite").path
        let repo = try LedgerRepository(path: path)
        let account = Account(name: "重试测试", openingMinor: 100_00)
        _ = try await repo.addAccount(account, makeDefault: true)
        let original = expense(accountID: account.id, minorUnits: 20_10)
        let first = try await repo.saveEntry(original, expectedVersion: nil, nextDraft: nil, revision: 1)
        let current = EntryDraft(amountText: "12+(", accountID: account.id, note: "当前草稿")
        try await repo.saveDraft(current, revision: 5)

        var retry = original
        retry.id = UUID()
        retry.createdAt = original.createdAt.addingTimeInterval(120)
        let next = EntryDraft(amountText: "18.", accountID: account.id, note: "保存并继续的下一笔")
        let replaced = try await repo.saveEntry(retry, expectedVersion: nil, nextDraft: next, revision: 6)
        XCTAssertEqual(replaced.book, first.book)
        XCTAssertEqual(replaced.book.entries.count, 1)
        XCTAssertEqual(replaced.draft, next)
        XCTAssertEqual(replaced.draftRevision, 6)
        XCTAssertEqual(try LedgerEngine.balance(of: account.id, in: replaced.book).minorUnits, 79_90)
        try await assertReopenedState(replaced, at: path)

        let cleared = try await repo.saveEntry(retry, expectedVersion: nil, nextDraft: nil, revision: 7)
        XCTAssertEqual(cleared.book, first.book)
        XCTAssertNil(cleared.draft)
        XCTAssertEqual(cleared.settings, first.settings)
        XCTAssertEqual(cleared.draftRevision, 7)
        try await assertReopenedState(cleared, at: path)
    }

    func testFailedCreationDoesNotAdvanceDraftRevisionFence() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.sqlite").path
        let repo = try LedgerRepository(path: path)
        let account = Account(name: "失败测试", openingMinor: 100_00)
        let initial = try await repo.addAccount(account, makeDefault: true)
        let previous = EntryDraft(amountText: "12+(", accountID: account.id, note: "失败时保留")
        try await repo.saveDraft(previous, revision: 7)
        let invalid = expense(accountID: account.id, minorUnits: 0)
        do {
            _ = try await repo.saveEntry(invalid, expectedVersion: nil, nextDraft: nil, revision: 40)
            XCTFail("Invalid entry must fail before changing the draft revision fence")
        } catch {
            XCTAssertEqual(error as? LedgerError, .invalidAmount)
        }
        let failed = try await repo.snapshot()
        XCTAssertEqual(failed.book, initial.book)
        XCTAssertEqual(failed.settings, initial.settings)
        XCTAssertEqual(failed.draft, previous)
        XCTAssertEqual(failed.draftRevision, 7)

        var continued = previous
        continued.amountText = "12+(3"
        try await repo.saveDraft(continued, revision: 8)
        let savedDraft = try await repo.snapshot()
        XCTAssertEqual(savedDraft.draft, continued)
        XCTAssertEqual(savedDraft.draftRevision, 8)
        XCTAssertEqual(savedDraft.book, initial.book)
        try await assertReopenedState(savedDraft, at: path)
    }

    func testTwoRepositoriesCreateAgainstLatestPersistedBook() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.sqlite").path
        let firstRepo = try LedgerRepository(path: path)
        let account = Account(name: "共享数据库测试", openingMinor: 100_00)
        let initial = try await firstRepo.addAccount(account, makeDefault: true)
        let secondRepo = try LedgerRepository(path: path)
        let earlierSnapshot = try await secondRepo.snapshot()
        XCTAssertTrue(earlierSnapshot.book.entries.isEmpty)

        let firstEntry = expense(accountID: account.id, minorUnits: 20_10)
        let first = try await firstRepo.saveEntry(firstEntry, expectedVersion: nil, nextDraft: nil, revision: 1)
        try await assertReopenedState(first, at: path)
        var secondEntry = expense(accountID: account.id, minorUnits: 5_00)
        secondEntry.kind = .income
        secondEntry.categoryID = SeedData.salaryIncomeID
        secondEntry.title = "第二个实例收入"
        let second = try await secondRepo.saveEntry(secondEntry, expectedVersion: nil, nextDraft: nil, revision: 1)
        XCTAssertEqual(second.book.entries, [firstEntry, secondEntry])
        XCTAssertEqual(second.settings, initial.settings)
        XCTAssertNil(second.draft)
        XCTAssertEqual(try LedgerEngine.balance(of: account.id, in: second.book).minorUnits, 84_90)
        let firstRefreshed = try await firstRepo.snapshot()
        XCTAssertEqual(firstRefreshed.book, second.book)
        XCTAssertEqual(firstRefreshed.settings, second.settings)
        XCTAssertEqual(firstRefreshed.draft, second.draft)
        try await assertReopenedState(second, at: path)
    }

    private func expense(accountID: UUID, minorUnits: Int64) -> LedgerEntry {
        let date = Date(timeIntervalSinceReferenceDate: 812_345_678.123456)
        return LedgerEntry(kind: .expense, amount: Money(minorUnits: minorUnits), accountID: accountID,
                           categoryID: SeedData.mealsID, occurredAt: date, createdAt: date,
                           title: "增量保存测试", note: "合成数据")
    }

    private func assertReopenedState(_ expected: LedgerSnapshot, at path: String,
                                     file: StaticString = #filePath, line: UInt = #line) async throws {
        let reopened = try LedgerRepository(path: path)
        let actual = try await reopened.snapshot()
        XCTAssertEqual(actual.book, expected.book, file: file, line: line)
        XCTAssertEqual(actual.draft, expected.draft, file: file, line: line)
        XCTAssertEqual(actual.settings, expected.settings, file: file, line: line)
        // draftRevision is an in-memory fence owned by each repository instance.
    }

    private func testDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncrementalRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
