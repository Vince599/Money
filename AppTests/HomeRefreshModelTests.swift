import Foundation
import XCTest
import LedgerCore
@testable import Ledger

@MainActor
final class HomeRefreshModelTests: XCTestCase {
    func testDelayedRefreshCannotReplaceSavedBookOrHome() async throws {
        let context = try Context()
        defer { context.cleanup() }
        await context.model.start()
        let old = try await context.beginRefresh()
        let entry = context.expense()
        let saved = await context.model.save(entry)
        XCTAssertTrue(saved)
        let committedHome = context.model.home
        context.gate.release(1, .success(old.snapshot))
        await old.task.value
        XCTAssertEqual(context.model.book.entries, [entry])
        XCTAssertEqual(context.model.home, committedHome)
        XCTAssertEqual(context.model.home?.summary?.recentEntries, [entry])
    }

    func testDelayedRefreshCannotReplaceRestoredBook() async throws {
        let context = try Context()
        defer { context.cleanup() }
        await context.model.start()
        let empty = LedgerBackupSnapshot(book: LedgerBook(), draft: nil, settings: LedgerSettings())
        let data = try BackupArchive.encode(BackupCodec.encode(empty))
        let preview = try await context.repo.prepareRestore(data)
        let old = try await context.beginRefresh()
        let restored = await context.model.restore(preview)
        XCTAssertTrue(restored)
        let restoredHome = context.model.home
        context.gate.release(1, .success(old.snapshot))
        await old.task.value
        XCTAssertEqual(context.model.book, LedgerBook())
        XCTAssertEqual(context.model.home, restoredHome)
        XCTAssertEqual(context.model.home?.summary?.recentEntries, [])
    }

    func testReverseRefreshCompletionAndStaleErrorCannotReplaceNewerState() async throws {
        let context = try Context()
        defer { context.cleanup() }
        await context.model.start()
        let first = try await context.beginRefresh()
        context.clock.date = BookDate.calendar.date(byAdding: .month, value: 1, to: context.clock.date)!
        let latest = try await context.repo.snapshot(at: context.clock.date)
        let second = Task { await context.model.refreshHomeIfNeeded() }
        await context.gate.waitForRequest(2)
        context.gate.release(2, .success(latest))
        await second.value
        context.model.errorMessage = "后续操作提示"
        context.gate.release(1, .failure(LedgerError.overflow))
        await first.task.value
        XCTAssertEqual(context.model.home, latest.home)
        XCTAssertEqual(context.model.errorMessage, "后续操作提示")

        // A successful response computed for a month that has already ended is
        // also discarded even when no write or newer refresh took place.
        let third = try await context.beginRefresh(request: 3)
        context.clock.date = BookDate.calendar.date(byAdding: .month, value: 1, to: context.clock.date)!
        context.gate.release(3, .success(third.snapshot))
        await third.task.value
        XCTAssertEqual(context.model.home, latest.home)
    }

    func testDraftInputSurvivesRefreshAndSameMonthDoesNotReload() async throws {
        let context = try Context()
        defer { context.cleanup() }
        await context.model.start()
        let pending = try await context.beginRefresh()
        let input = EntryDraft(amountText: "12+(", accountID: context.account.id, note: "尚未完成")
        await context.model.updateDraft(input).value
        context.gate.release(1, .success(pending.snapshot))
        await pending.task.value
        XCTAssertEqual(context.model.draft, input)
        XCTAssertEqual(context.model.home, pending.snapshot.home)
        await context.model.refreshHomeIfNeeded()
        await context.model.updateDraft(EntryDraft(amountText: "12+(3", accountID: context.account.id)).value
        await context.model.refreshHomeIfNeeded()
        XCTAssertEqual(context.gate.requests, 1)
    }

    func testBusyMonthBoundaryRetriesAfterBusyEndsAndCancellationDoesNotPublish() async throws {
        let context = try Context()
        defer { context.cleanup() }
        await context.model.start()
        context.clock.date = BookDate.calendar.date(byAdding: .month, value: 1, to: Date())!
        context.model.isBusy = true
        await context.model.refreshHomeIfNeeded()
        XCTAssertEqual(context.gate.requests, 0)
        context.model.isBusy = false
        let before = context.model.home
        let snapshot = try await context.repo.snapshot(at: context.clock.date)
        let task = Task { await context.model.refreshHomeIfNeeded() }
        await context.gate.waitForRequest(1)
        task.cancel()
        context.gate.release(1, .success(snapshot))
        await task.value
        XCTAssertEqual(context.model.home, before)
        let retried = Task { await context.model.refreshHomeIfNeeded() }
        await context.gate.waitForRequest(2)
        context.gate.release(2, .success(snapshot))
        await retried.value
        XCTAssertEqual(context.model.home, snapshot.home)
    }

    func testFailedWriteInvalidatesEarlierRefreshError() async throws {
        let context = try Context()
        defer { context.cleanup() }
        await context.model.start()
        let pending = try await context.beginRefresh()
        var invalid = context.expense()
        invalid.amount = Money(minorUnits: 0)
        let saved = await context.model.save(invalid)
        XCTAssertFalse(saved)
        let saveError = context.model.errorMessage
        context.gate.release(1, .failure(LedgerError.overflow))
        await pending.task.value
        XCTAssertEqual(context.model.errorMessage, saveError)
        XCTAssertTrue(context.model.book.entries.isEmpty)
    }

    @MainActor
    private final class Clock { var date = Date() }

    /// Explicit continuation gates exercise completion order without timing sleeps.
    @MainActor
    private final class Gate {
        var requests = 0
        var pending: [Int: CheckedContinuation<LedgerSnapshot, any Error>] = [:]
        var observers: [(Int, CheckedContinuation<Void, Never>)] = []
        func read() async throws -> LedgerSnapshot {
            try await withCheckedThrowingContinuation { continuation in
                requests += 1
                pending[requests] = continuation
                let ready = observers.filter { $0.0 <= requests }
                observers.removeAll { $0.0 <= requests }
                for (_, observer) in ready { observer.resume() }
            }
        }
        func waitForRequest(_ count: Int) async {
            if requests >= count { return }
            await withCheckedContinuation { observers.append((count, $0)) }
        }
        func release(_ request: Int, _ result: Result<LedgerSnapshot, any Error>) {
            pending.removeValue(forKey: request)!.resume(with: result)
        }
    }

    @MainActor
    private final class Context {
        let directory: URL
        let repo: LedgerRepository
        let account = Account(name: "首页测试", openingMinor: 100_00)
        let clock = Clock()
        let gate = Gate()
        let model: LedgerAppModel
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("HomeRefresh-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            repo = try LedgerRepository(path: directory.appendingPathComponent("ledger.sqlite").path)
            let clock = clock, gate = gate
            model = LedgerAppModel(repository: repo, now: { clock.date }, homeSnapshot: { _ in try await gate.read() })
        }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
        func expense() -> LedgerEntry {
            LedgerEntry(kind: .expense, amount: Money(minorUnits: 20_10), accountID: account.id,
                        categoryID: SeedData.mealsID, occurredAt: Date(), title: "午餐")
        }
        func beginRefresh(request: Int = 1) async throws -> (snapshot: LedgerSnapshot, task: Task<Void, Never>) {
            if model.book.accounts.isEmpty { _ = await model.addAccount(account, makeDefault: true) }
            clock.date = BookDate.calendar.date(byAdding: .month, value: 1, to: clock.date)!
            let snapshot = try await repo.snapshot(at: clock.date)
            let task = Task { await model.refreshHomeIfNeeded() }
            await gate.waitForRequest(request)
            return (snapshot, task)
        }
    }
}
