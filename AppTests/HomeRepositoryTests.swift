import Foundation
import XCTest
import LedgerCore
@testable import Ledger

@MainActor
final class HomeRepositoryTests: XCTestCase {
    func testOpeningAndEveryBookMutationReturnMatchingHomeData() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.sqlite").path
        let opened = try await Task.detached { try LedgerRepository.open(path: path) }.value
        try assertHome(opened.snapshot)
        let repo = opened.repository
        var account = Account(name: "账户", openingMinor: 100_00)
        try assertHome(try await repo.addAccount(account, makeDefault: true))
        var entry = LedgerEntry(kind: .expense, amount: Money(minorUnits: 20_10), accountID: account.id,
                                categoryID: SeedData.mealsID, title: "午餐")
        let saved = try await repo.saveEntry(entry, expectedVersion: nil, nextDraft: nil, revision: 1)
        try assertHome(saved)
        XCTAssertEqual(saved.home?.summary?.monthlyConsumption?.minorUnits, 20_10)
        let backup = try await repo.exportBackup()
        entry.operationID = UUID(); entry.amount = Money(minorUnits: 18_50)
        try assertHome(try await repo.saveEntry(entry, expectedVersion: 1, nextDraft: nil, revision: 2))
        try assertHome(try await repo.adjustAccount(account.id, target: Money(minorUnits: 90_00),
                                                   note: "更正", operationID: UUID()))
        account.name = "改名"; account.includedInSummary = false
        let excluded = try await repo.saveAccount(account)
        try assertHome(excluded)
        XCTAssertEqual(excluded.home?.summary?.currencySummaries, [])
        XCTAssertEqual(excluded.home?.summary?.monthlyConsumption?.minorUnits, 18_50)
        var category = try XCTUnwrap(excluded.book.categories.first { $0.id == SeedData.mealsID })
        category.name = "正餐改名"
        try assertHome(try await repo.saveCategory(category))
        let subject = LedgerCore.Subject(name: "另一个主体")
        try assertHome(try await repo.saveSubject(subject))
        try assertHome(try await repo.setDefaultSubject(subject.id))
        try assertHome(try await repo.setDefaultAccount(nil))
        let deleted = try await repo.deleteEntry(entry.id)
        try assertHome(deleted)
        XCTAssertEqual(deleted.home?.summary?.recentEntries, [])
        let preview = try await repo.prepareRestore(backup)
        let restored = try await repo.restore(previewID: preview.id, revision: 5)
        try assertHome(restored)
        XCTAssertEqual(restored.book, saved.book)
        XCTAssertEqual(restored.home?.summary, saved.home?.summary)
        let reopened = try await Task.detached { try LedgerRepository.open(path: path) }.value
        try assertHome(reopened.snapshot)
    }

    func testAggregateOverflowDoesNotReportSuccessfulCommitAsFailure() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try LedgerRepository(path: directory.appendingPathComponent("ledger.sqlite").path)
        let first = Account(name: "边界资产", openingMinor: .max)
        let second = Account(name: "另一资产")
        _ = try await repo.addAccount(first, makeDefault: false)
        _ = try await repo.addAccount(second, makeDefault: true)
        let entry = LedgerEntry(kind: .income, amount: Money(minorUnits: 1), accountID: second.id,
                                categoryID: SeedData.salaryIncomeID)
        let saved = try await repo.saveEntry(entry, expectedVersion: nil, nextDraft: nil, revision: 1)
        XCTAssertEqual(saved.book.entries, [entry])
        XCTAssertNil(saved.home?.summary?.currencySummaries.first?.totals)
        XCTAssertEqual(saved.home?.summary?.monthlyConsumption?.minorUnits, 0)
        XCTAssertEqual(saved.home?.summary?.recentEntries, [entry])
        let persisted = try await repo.snapshot()
        XCTAssertEqual(persisted.book, saved.book)
        XCTAssertEqual(persisted.home?.summary, saved.home?.summary)
    }

    private func assertHome(_ snapshot: LedgerSnapshot, file: StaticString = #filePath, line: UInt = #line) throws {
        let home = try XCTUnwrap(snapshot.home, file: file, line: line)
        let month = try XCTUnwrap(home.month, file: file, line: line)
        let expected = try LedgerEngine.homeSummary(in: snapshot.book, from: month.start, to: month.end)
        XCTAssertEqual(home.summary, expected, file: file, line: line)
    }

    private func testDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HomeRepository-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
