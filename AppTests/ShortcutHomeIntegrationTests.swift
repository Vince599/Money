import Foundation
import XCTest
import LedgerCore
@testable import Ledger

@MainActor
final class ShortcutHomeIntegrationTests: XCTestCase {
    func testDelayedHomeSnapshotCannotReplaceShortcutCommitOrCurrentDraft() async throws {
        try await exerciseDelayedRefresh(fails: false)
    }

    func testDelayedHomeErrorCannotReplaceSuccessfulShortcutState() async throws {
        try await exerciseDelayedRefresh(fails: true)
    }

    private func exerciseDelayedRefresh(fails: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShortcutHome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try LedgerRepository(path: directory.appendingPathComponent("ledger.sqlite").path)
        let account = Account(name: "快捷首页集成", openingMinor: 100_00)
        _ = try await repo.addAccount(account, makeDefault: true)
        var manualDraft = EntryDraft(amountText: "12+(", accountID: account.id,
                                     expenseCategoryID: SeedData.taxiID, note: "保留手动输入")
        try await repo.saveDraft(manualDraft, revision: 7)
        let clock = Clock()
        let gate = Gate()
        let model = LedgerAppModel(repository: repo, now: { clock.date },
                                   homeSnapshot: { _ in try await gate.read() })
        await model.start()
        XCTAssertEqual(model.draft, manualDraft)

        // Simulate foregrounding in the following month. The delayed response
        // remains current for the injected clock, so only the generation fence
        // can reject it after the shortcut has committed.
        clock.date = try XCTUnwrap(model.home?.month).end.addingTimeInterval(60)
        let old = try await repo.snapshot(at: clock.date)
        XCTAssertTrue(old.book.entries.isEmpty)
        XCTAssertTrue(try XCTUnwrap(old.home).isCurrent(at: clock.date))
        let refresh = Task { await model.refreshHomeIfNeeded() }
        defer {
            refresh.cancel()
            gate.release(.failure(CancellationError()))
        }
        await gate.waitUntilReading()

        // New manual input must survive both the direct shortcut and the older
        // snapshot, without the shortcut advancing the editor's draft sequence.
        manualDraft.amountText = "12+(3"
        await model.updateDraft(manualDraft).value
        let request = ShortcutEntryRequest(amountText: "20.10", categoryID: SeedData.mealsID,
                                           title: "快捷午餐", note: "后台直接记账")
        let saved = try await model.recordShortcut(request)
        let committedBook = model.book
        let committedHome = try XCTUnwrap(model.home)
        let month = try XCTUnwrap(committedHome.month)
        let summary = try XCTUnwrap(committedHome.summary)
        XCTAssertEqual(committedBook.entries, [saved])
        XCTAssertEqual(saved.operationID, request.operationID)
        XCTAssertEqual(saved.amount.minorUnits, 20_10)
        XCTAssertEqual(summary.recentEntries, [saved])
        XCTAssertEqual(summary.currencySummaries.first?.totals?.assets.minorUnits, 79_90)
        XCTAssertEqual(summary.currencySummaries.first?.totals?.liabilities.minorUnits, 0)
        XCTAssertEqual(summary.currencySummaries.first?.totals?.netAsset.minorUnits, 79_90)
        let expectedConsumption: Int64 = saved.occurredAt >= month.start && saved.occurredAt < month.end ? 20_10 : 0
        XCTAssertEqual(summary.monthlyConsumption?.minorUnits, expectedConsumption)
        XCTAssertEqual(summary, try LedgerEngine.homeSummary(in: committedBook, from: month.start, to: month.end))
        XCTAssertEqual(model.draft, manualDraft)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isBusy)

        XCTAssertTrue(try XCTUnwrap(old.home).isCurrent(at: clock.date))
        gate.release(fails ? .failure(LedgerError.overflow) : .success(old))
        await refresh.value
        XCTAssertEqual(model.book, committedBook)
        XCTAssertEqual(model.home, committedHome)
        XCTAssertEqual(model.draft, manualDraft)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.pendingShortcut)

        let persisted = try await repo.snapshot(at: month.start)
        XCTAssertEqual(persisted.book, committedBook)
        XCTAssertEqual(persisted.home, committedHome)
        XCTAssertEqual(persisted.draft, manualDraft)
        XCTAssertEqual(persisted.draftRevision, 8)
        manualDraft.amountText = "12+(3)"
        await model.updateDraft(manualDraft).value
        let continued = try await repo.snapshot(at: month.start)
        XCTAssertEqual(continued.book, committedBook)
        XCTAssertEqual(continued.home, committedHome)
        XCTAssertEqual(continued.draft, manualDraft)
        XCTAssertEqual(continued.draftRevision, 9)
    }

    @MainActor
    private final class Clock { var date = Date() }

    /// Only the home response is delayed; shortcut persistence uses the real repository.
    @MainActor
    private final class Gate {
        private var pending: CheckedContinuation<LedgerSnapshot, any Error>?
        private var observer: CheckedContinuation<Void, Never>?

        func read() async throws -> LedgerSnapshot {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                observer?.resume()
                observer = nil
            }
        }

        func waitUntilReading() async {
            if pending != nil { return }
            await withCheckedContinuation { observer = $0 }
        }

        func release(_ result: Result<LedgerSnapshot, any Error>) {
            pending?.resume(with: result)
            pending = nil
        }
    }
}
