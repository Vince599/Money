import Foundation
import Observation
import LedgerCore
import LedgerStore

struct HistoryDayGroup: Sendable {
    let day: Date
    var entries: [LedgerEntry]
    var summary: EntryDaySummary?
}

struct HistoryPage: Sendable {
    let groups: [HistoryDayGroup]
    let totalCount: Int
    let nextCursor: EntryPageCursor?

    // Called on the repository actor, never from a SwiftUI body.
    static func make(_ page: EntryPage) -> HistoryPage {
        var groups: [HistoryDayGroup] = []
        let calendar = BookDate.calendar
        for entry in page.entries {
            let day = calendar.startOfDay(for: entry.occurredAt)
            if groups.last?.day == day { groups[groups.count - 1].entries.append(entry) }
            else { groups.append(HistoryDayGroup(day: day, entries: [entry],
                summary: page.daySummaries.first { $0.day == day })) }
        }
        return HistoryPage(groups: groups, totalCount: page.totalCount, nextCursor: page.nextCursor)
    }
}

struct HistoryRequest: Equatable, Sendable {
    var filter: EntryFilter
    var revision: UInt64
    var isLoaded: Bool
}

/// View-owned state: tab/detail navigation retains filters and loaded rows.
@Observable @MainActor
final class HistoryPageModel {
    private(set) var groups: [HistoryDayGroup] = []
    private(set) var totalCount = 0
    private(set) var nextCursor: EntryPageCursor?
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    private var request: HistoryRequest?
    private var completedRequest: HistoryRequest?
    private var generation: UInt64 = 0

    typealias ReadPage = @MainActor (EntryFilter, EntryPageCursor?) async throws -> HistoryPage

    func reload(_ value: HistoryRequest, force: Bool = false, debounce: Bool = true,
                read: ReadPage) async {
        guard force || request != value || completedRequest != value || !hasLoaded else { return }
        let delaySearch = debounce && request?.filter.keyword != value.filter.keyword
            && !value.filter.keyword.isEmpty
        let dataChanged = request?.revision != value.revision || !value.isLoaded
        generation += 1
        let current = generation
        request = value
        errorMessage = nil
        if !force, completedRequest == value, hasLoaded {
            isLoading = false
            return
        }
        // Keep the list/search field stable while the user types. Replacing the
        // book must still remove rows belonging to the old snapshot immediately.
        if dataChanged {
            groups = []; totalCount = 0; nextCursor = nil
            hasLoaded = false; completedRequest = nil
        }
        isLoading = value.isLoaded
        guard value.isLoaded else { return }
        defer { if generation == current { isLoading = false } }
        do {
            if delaySearch { try await Task.sleep(for: .milliseconds(200)) }
            try Task.checkCancellation()
            let page = try await read(value.filter, nil)
            guard generation == current, !Task.isCancelled else { return }
            groups = page.groups; totalCount = page.totalCount; nextCursor = page.nextCursor
            hasLoaded = true; completedRequest = value
        } catch {
            guard generation == current, !Task.isCancelled, !(error is CancellationError) else { return }
            groups = []; totalCount = 0; nextCursor = nil
            hasLoaded = false; completedRequest = nil
            errorMessage = error is EntryQueryError
                ? "请检查日期、币种和金额范围。" : "流水读取失败，请重试。"
        }
    }

    func loadMore(read: ReadPage) async {
        guard !isLoading, let request, request == completedRequest, let cursor = nextCursor else { return }
        let current = generation
        isLoading = true; errorMessage = nil
        defer { if generation == current { isLoading = false } }
        do {
            let page = try await read(request.filter, cursor)
            guard generation == current, !Task.isCancelled else { return }
            // A page boundary can split a day; retain a single section for that day.
            var remainder = page.groups
            if let last = groups.last, let first = remainder.first, last.day == first.day {
                groups[groups.count - 1].entries.append(contentsOf: first.entries)
                // Both pages carry the same complete-day value; never sum page summaries.
                groups[groups.count - 1].summary = first.summary
                remainder.removeFirst()
            }
            groups.append(contentsOf: remainder)
            totalCount = page.totalCount; nextCursor = page.nextCursor
        } catch LedgerStoreError.staleHistoryCursor {
            guard generation == current, !Task.isCancelled else { return }
            await reload(request, force: true, debounce: false, read: read)
        } catch {
            guard generation == current, !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = "后续流水读取失败，已加载的记录仍保留，请重试。"
        }
    }
}
