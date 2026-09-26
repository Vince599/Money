import XCTest
import LedgerCore
import LedgerStore
@testable import Ledger

@MainActor
final class LedgerAppTests: XCTestCase {
    func testExpressionDraftAndCopySurvivePersistenceAndBackup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("test.sqlite").path
        let repo = try LedgerRepository(path: path)
        let account = Account(name: "计算器", openingMinor: 100_00)
        let initial = try await repo.addAccount(account, makeDefault: true)
        var draft = EntryDraft(amountText: "10+(", accountID: account.id, expenseCategoryID: SeedData.mealsID)
        try await repo.saveDraft(draft, revision: 1)
        let archive = try await repo.exportBackup()
        let backup = try BackupCodec.decode(BackupArchive.decode(archive))
        XCTAssertEqual(backup.draft, draft) // An incomplete expression remains an editable draft.
        draft.amountText = "10+5.05*2"
        try await repo.saveDraft(draft, revision: 2)
        let reopened = try LedgerRepository(path: path)
        let persisted = try await reopened.snapshot()
        XCTAssertEqual(persisted.draft, draft)
        let entry = try draft.entry(in: persisted.book)
        XCTAssertEqual(entry.amount.minorUnits, 2010)
        let saved = try await repo.saveEntry(entry, expectedVersion: nil, nextDraft: nil, revision: 3)
        let copy = try EntryDraft.copying(entry, in: saved.book, settings: initial.settings)
        try await repo.saveDraft(copy, revision: 4)
        let copyArchive = try await repo.exportBackup()
        let copiedBackup = try BackupCodec.decode(BackupArchive.decode(copyArchive))
        XCTAssertEqual(copiedBackup.draft, copy)
        XCTAssertNotEqual(copy.entryID, entry.id)
        XCTAssertEqual(copiedBackup.book.entries.count, 1)
        XCTAssertEqual(try LedgerEngine.balance(of: account.id, in: copiedBackup.book).minorUnits, 7990)
    }

    func testRepositorySavesEntryAndClearsDraftTogether() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("test.sqlite").path
        let repo = try LedgerRepository(path: path)
        let account = Account(name: "微信", kind: .wallet, openingMinor: 100_00)
        let initial = try await repo.addAccount(account, makeDefault: true)
        XCTAssertEqual(initial.settings.defaultAccountID, account.id)
        let draft = EntryDraft(amountText: "28", accountID: account.id, expenseCategoryID: SeedData.mealsID)
        try await repo.saveDraft(draft, revision: 1)
        let entry = try draft.entry(in: initial.book)
        let result = try await repo.saveEntry(entry, expectedVersion: nil, nextDraft: nil, revision: 3)
        XCTAssertNil(result.draft)
        XCTAssertEqual(try LedgerEngine.balance(of: account.id, in: result.book).minorUnits, 72_00)
        // A delayed autosave must not resurrect the draft after the entry has been committed.
        try await repo.saveDraft(draft, revision: 2)
        let reopened = try LedgerRepository(path: path)
        let persisted = try await reopened.snapshot()
        XCTAssertNil(persisted.draft)
        XCTAssertEqual(persisted.book.entries.count, 1)
    }

    func testOlderEntryCommitPreservesNewerDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try LedgerRepository(path: directory.appendingPathComponent("test.sqlite").path)
        let account = Account(name: "微信", kind: .wallet, openingMinor: 100_00)
        let initial = try await repo.addAccount(account, makeDefault: true)
        let earlier = EntryDraft(amountText: "28", accountID: account.id, expenseCategoryID: SeedData.mealsID)
        let newer = EntryDraft(amountText: "36", accountID: account.id, expenseCategoryID: SeedData.taxiID)
        try await repo.saveDraft(newer, revision: 12)
        let result = try await repo.saveEntry(earlier.entry(in: initial.book), expectedVersion: nil,
                                              nextDraft: nil, revision: 11)
        XCTAssertEqual(result.draft, newer)
        XCTAssertEqual(result.draftRevision, 12)
        XCTAssertEqual(result.book.entries.count, 1)
        XCTAssertEqual(try LedgerEngine.balance(of: account.id, in: result.book).minorUnits, 72_00)
    }

    func testBalanceAdjustmentRetryAfterReopeningDoesNotRepeat() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("test.sqlite").path
        let repo = try LedgerRepository(path: path)
        let account = Account(name: "银行卡", openingMinor: 10_000_00)
        _ = try await repo.addAccount(account, makeDefault: true)
        let operationID = UUID()
        let target = Money(minorUnits: 8_000_00, currency: .cny)
        let first = try await repo.adjustAccount(account.id, target: target, note: "核对余额", operationID: operationID)
        let reopened = try LedgerRepository(path: path)
        let retried = try await reopened.adjustAccount(account.id, target: target, note: "核对余额", operationID: operationID)
        XCTAssertEqual(retried.book, first.book)
        XCTAssertEqual(retried.book.adjustments.count, 1)
        XCTAssertEqual(try LedgerEngine.balance(of: account.id, in: retried.book), target)
    }
}
