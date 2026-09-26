import Foundation
import XCTest
import LedgerCore
@testable import Ledger

@MainActor
final class SnapshotRepositoryTests: XCTestCase {
    func testFactoryOpensNewDatabaseOffMainActorWithInitialSnapshot() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.sqlite").path

        // Exercise the same actor boundary used by the app's disk startup.
        let opened = try await Task.detached { try LedgerRepository.open(path: path) }.value
        XCTAssertEqual(opened.snapshot.book, LedgerBook())
        XCTAssertNil(opened.snapshot.draft)
        XCTAssertEqual(opened.snapshot.settings, LedgerSettings())
        XCTAssertEqual(opened.snapshot.draftRevision, 0)

        let current = try await opened.repository.snapshot()
        assertPersistedState(current, equals: opened.snapshot)
        XCTAssertEqual(current.draftRevision, 0)
    }

    func testFactoryReturnsExistingBookDraftAndSettingsWithFreshRevisionFence() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.sqlite").path
        let original = try LedgerRepository(path: path)
        let account = Account(name: "已有账户", openingMinor: 100_00)
        _ = try await original.addAccount(account, makeDefault: true)
        let entry = expense(accountID: account.id)
        let draft = EntryDraft(amountText: "12+(", accountID: account.id,
                               expenseCategoryID: SeedData.taxiID, note: "重新打开后继续输入")
        let saved = try await original.saveEntry(entry, expectedVersion: nil,
                                                 nextDraft: draft, revision: 27)

        let opened = try LedgerRepository.open(path: path)
        assertPersistedState(opened.snapshot, equals: saved)
        XCTAssertEqual(saved.draftRevision, 27)
        XCTAssertEqual(opened.snapshot.draftRevision, 0)
        let current = try await opened.repository.snapshot()
        assertPersistedState(current, equals: saved)
        XCTAssertEqual(current.draftRevision, 0)

        // The persisted draft survives, but a new repository starts its own sequence at zero.
        var continued = draft
        continued.amountText = "12+(3"
        try await opened.repository.saveDraft(continued, revision: 1)
        let updated = try await opened.repository.snapshot()
        XCTAssertEqual(updated.draft, continued)
        XCTAssertEqual(updated.draftRevision, 1)
        XCTAssertEqual(updated.book, saved.book)
        XCTAssertEqual(updated.settings, saved.settings)
    }

    func testFactoryRepositoryAdvancesDraftSequenceAndSavesEntry() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.sqlite").path
        let opened = try LedgerRepository.open(path: path)
        let account = Account(name: "新建后记账", openingMinor: 100_00)
        let configured = try await opened.repository.addAccount(account, makeDefault: true)
        var draft = EntryDraft(amountText: "12+(", accountID: account.id,
                               expenseCategoryID: SeedData.mealsID, title: "午餐")
        try await opened.repository.saveDraft(draft, revision: 1)
        draft.amountText = "12+(3)"
        try await opened.repository.saveDraft(draft, revision: 2)
        let pending = try await opened.repository.snapshot()
        XCTAssertEqual(pending.draft, draft)
        XCTAssertEqual(pending.draftRevision, 2)
        XCTAssertEqual(pending.book, configured.book)

        let date = Date(timeIntervalSinceReferenceDate: 812_345_678.123456)
        let entry = try draft.entry(in: pending.book, createdAt: date)
        let saved = try await opened.repository.saveEntry(entry, expectedVersion: nil,
                                                          nextDraft: nil, revision: 3)
        XCTAssertEqual(saved.book.entries, [entry])
        XCTAssertNil(saved.draft)
        XCTAssertEqual(saved.settings, configured.settings)
        XCTAssertEqual(saved.draftRevision, 3)
        let current = try await opened.repository.snapshot()
        assertPersistedState(current, equals: saved)
        XCTAssertEqual(current.draftRevision, 3)

        let reopened = try LedgerRepository.open(path: path)
        assertPersistedState(reopened.snapshot, equals: saved)
        XCTAssertEqual(reopened.snapshot.draftRevision, 0)
    }

    func testSnapshotReloadsExternalWriterChangesInsteadOfCachingOpeningState() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.sqlite").path
        let reader = try LedgerRepository.open(path: path)
        let writer = try LedgerRepository(path: path)
        let account = Account(name: "另一实例创建", openingMinor: 100_00)
        _ = try await writer.addAccount(account, makeDefault: true)
        let draft = EntryDraft(amountText: "8.", accountID: account.id, note: "另一实例的草稿")
        let written = try await writer.saveEntry(expense(accountID: account.id), expectedVersion: nil,
                                                 nextDraft: draft, revision: 7)

        let refreshed = try await reader.repository.snapshot()
        assertPersistedState(refreshed, equals: written)
        XCTAssertEqual(refreshed.draftRevision, 0)
        XCTAssertEqual(reader.snapshot.book, LedgerBook())
        XCTAssertNil(reader.snapshot.draft)
        XCTAssertEqual(reader.snapshot.settings, LedgerSettings())

        try await writer.saveDraft(nil, revision: 8)
        let changedAgain = try await writer.setDefaultAccount(nil)
        let refreshedAgain = try await reader.repository.snapshot()
        assertPersistedState(refreshedAgain, equals: changedAgain)
        XCTAssertNil(refreshedAgain.draft)
        XCTAssertNil(refreshedAgain.settings.defaultAccountID)
        XCTAssertEqual(refreshedAgain.draftRevision, 0)
        let reopened = try LedgerRepository.open(path: path)
        assertPersistedState(reopened.snapshot, equals: refreshedAgain)
    }

    private func expense(accountID: UUID) -> LedgerEntry {
        let date = Date(timeIntervalSinceReferenceDate: 812_345_678.123456)
        return LedgerEntry(kind: .expense, amount: Money(minorUnits: 20_10), accountID: accountID,
                           categoryID: SeedData.mealsID, occurredAt: date, createdAt: date,
                           title: "快照测试", note: "合成数据")
    }

    private func assertPersistedState(_ actual: LedgerSnapshot, equals expected: LedgerSnapshot,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.book, expected.book, file: file, line: line)
        XCTAssertEqual(actual.draft, expected.draft, file: file, line: line)
        XCTAssertEqual(actual.settings, expected.settings, file: file, line: line)
    }

    private func testDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
