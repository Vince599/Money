import XCTest
import LedgerCore
import LedgerStore
@testable import Ledger

@MainActor
final class HistoryPageModelTests: XCTestCase {
    func testPagesMergeSameDayAndReopeningDoesNotReadAgain() async throws {
        let context = try Context()
        defer { context.cleanup() }
        let history = HistoryPageModel()
        var reads = 0
        let read: HistoryPageModel.ReadPage = { filter, cursor in
            reads += 1
            return try await context.repo.historyPage(matching: filter, after: cursor, limit: 2)
        }
        await history.reload(context.request, debounce: false, read: read)
        XCTAssertEqual(history.groups.count, 1)
        XCTAssertEqual(history.groups[0].entries.count, 2)
        XCTAssertEqual(history.totalCount, 5)
        await history.loadMore(read: read)
        await history.loadMore(read: read)
        XCTAssertEqual(history.groups.count, 1)
        XCTAssertEqual(history.groups[0].entries.count, 5)
        XCTAssertEqual(Set(history.groups[0].entries.map(\.id)).count, 5)
        XCTAssertNil(history.nextCursor)
        await history.reload(context.request, read: read)
        await history.loadMore(read: read)
        XCTAssertEqual(reads, 3)
    }

    func testOlderSuccessAndFailureCannotReplaceLatestSearch() async throws {
        let context = try Context()
        defer { context.cleanup() }
        let history = HistoryPageModel()
        let gate = Gate()
        let page = try await context.repo.historyPage(matching: EntryFilter())
        let first = Task { await history.reload(context.request, debounce: false, read: gate.read) }
        await gate.waitForRequest(1)
        var newer = context.request
        newer.filter.keyword = "absent"
        await history.reload(newer, debounce: false) { filter, cursor in
            try await context.repo.historyPage(matching: filter, after: cursor)
        }
        gate.release(1, .success(page))
        await first.value
        XCTAssertTrue(history.hasLoaded)
        XCTAssertEqual(history.totalCount, 0)
        XCTAssertTrue(history.groups.isEmpty)

        let oldFailure = Task { await history.reload(context.request, debounce: false, read: gate.read) }
        await gate.waitForRequest(2)
        await history.reload(newer, debounce: false) { filter, cursor in
            try await context.repo.historyPage(matching: filter, after: cursor)
        }
        gate.release(2, .failure(LedgerError.overflow))
        await oldFailure.value
        XCTAssertNil(history.errorMessage)
        XCTAssertEqual(history.totalCount, 0)
    }

    func testDelayedNextPageCannotAppendAfterFilterChanges() async throws {
        let context = try Context()
        defer { context.cleanup() }
        let history = HistoryPageModel()
        await history.reload(context.request, debounce: false) { filter, cursor in
            try await context.repo.historyPage(matching: filter, after: cursor, limit: 2)
        }
        let cursor = try XCTUnwrap(history.nextCursor)
        let next = try await context.repo.historyPage(matching: EntryFilter(), after: cursor, limit: 2)
        let gate = Gate()
        let pending = Task { await history.loadMore(read: gate.read) }
        await gate.waitForRequest(1)
        var newer = context.request
        newer.filter.kind = .income
        await history.reload(newer, debounce: false) { filter, cursor in
            try await context.repo.historyPage(matching: filter, after: cursor)
        }
        gate.release(1, .success(next))
        await pending.value
        XCTAssertEqual(history.totalCount, 0)
        XCTAssertTrue(history.groups.isEmpty)
        XCTAssertNil(history.nextCursor)
        XCTAssertFalse(history.isLoading)
    }

    func testCancelledInitialReadCanRetryAndNextPageFailurePreservesRows() async throws {
        let context = try Context()
        defer { context.cleanup() }
        let history = HistoryPageModel()
        let gate = Gate()
        let page = try await context.repo.historyPage(matching: EntryFilter(), limit: 2)
        let pending = Task { await history.reload(context.request, debounce: false, read: gate.read) }
        await gate.waitForRequest(1)
        pending.cancel()
        gate.release(1, .success(page))
        await pending.value
        XCTAssertFalse(history.hasLoaded)
        XCTAssertFalse(history.isLoading)
        XCTAssertNil(history.errorMessage)
        await history.reload(context.request, debounce: false) { _, _ in page }
        let ids = history.groups.flatMap(\.entries).map(\.id)
        await history.loadMore { _, _ in throw LedgerError.overflow }
        XCTAssertEqual(history.groups.flatMap(\.entries).map(\.id), ids)
        XCTAssertNotNil(history.errorMessage)
        XCTAssertNotNil(history.nextCursor)
        await history.loadMore { filter, cursor in
            try await context.repo.historyPage(matching: filter, after: cursor)
        }
        XCTAssertEqual(history.groups.flatMap(\.entries).count, 5)
        XCTAssertNil(history.errorMessage)
    }

    func testStaleCursorRestartsFromCurrentDatabaseWithoutDuplicateRows() async throws {
        let context = try Context()
        defer { context.cleanup() }
        let history = HistoryPageModel()
        let read: HistoryPageModel.ReadPage = { filter, cursor in
            try await context.repo.historyPage(matching: filter, after: cursor, limit: 2)
        }
        await history.reload(context.request, debounce: false, read: read)
        _ = try await context.repo.deleteEntry(context.book.entries[0].id)
        await history.loadMore(read: read)
        XCTAssertEqual(history.totalCount, 4)
        XCTAssertEqual(history.groups.flatMap(\.entries).count, 2)
        await history.loadMore(read: read)
        XCTAssertEqual(history.groups.flatMap(\.entries).count, 4)
        XCTAssertFalse(history.groups.flatMap(\.entries).contains { $0.id == context.book.entries[0].id })
        XCTAssertNil(history.nextCursor)
        XCTAssertNil(history.errorMessage)
    }

    func testModelRevisionChangesOnSavedStateButNotDraftKeystrokes() async throws {
        let context = try Context()
        defer { context.cleanup() }
        let model = LedgerAppModel(repository: context.repo)
        await model.start()
        let initialRevision = model.historyRevision
        await model.updateDraft(EntryDraft(amountText: "12+(3", accountID: context.book.accounts[0].id)).value
        XCTAssertEqual(model.historyRevision, initialRevision)
        let deleted = await model.delete(context.book.entries[0].id)
        XCTAssertTrue(deleted)
        XCTAssertGreaterThan(model.historyRevision, initialRevision)
        let page = try await model.historyPage(matching: EntryFilter(), after: nil)
        XCTAssertEqual(page.totalCount, 4)
    }

    private struct Context {
        let directory: URL
        let repo: LedgerRepository
        let book: LedgerBook
        let request = HistoryRequest(filter: EntryFilter(), revision: 1, isLoaded: true)
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("history.sqlite").path
            let store = try SQLiteLedgerStore(path: path)
            let account = Account(name: "历史测试", openingMinor: 10_000)
            let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
            let entries = (0..<5).map { index in
                LedgerEntry(kind: .expense, amount: Money(minorUnits: Int64(index + 1)),
                            accountID: account.id, categoryID: SeedData.mealsID,
                            occurredAt: date, createdAt: date.addingTimeInterval(Double(index)), title: "Lunch")
            }
            book = LedgerBook(accounts: [account], entries: entries)
            try store.saveBook(book)
            repo = try LedgerRepository(path: path)
        }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }

    private final class Gate {
        var requests = 0
        var pending: [Int: CheckedContinuation<HistoryPage, any Error>] = [:]
        var observers: [(Int, CheckedContinuation<Void, Never>)] = []
        func read(_ filter: EntryFilter, _ cursor: EntryPageCursor?) async throws -> HistoryPage {
            try await withCheckedThrowingContinuation { continuation in
                requests += 1; pending[requests] = continuation
                let ready = observers.filter { $0.0 <= requests }
                observers.removeAll { $0.0 <= requests }
                for (_, observer) in ready { observer.resume() }
            }
        }
        func waitForRequest(_ count: Int) async {
            guard requests < count else { return }
            await withCheckedContinuation { observers.append((count, $0)) }
        }
        func release(_ count: Int, _ result: Result<HistoryPage, any Error>) {
            pending.removeValue(forKey: count)!.resume(with: result)
        }
    }
}
