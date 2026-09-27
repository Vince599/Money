import Foundation
import LedgerCore

/// A derived value for one book snapshot and one Shanghai calendar month.
/// Failure stays local to the overview; it must not turn a committed save into a failure.
struct HomeOverview: Equatable, Sendable {
    let month: DateInterval?
    let summary: HomeSummary?

    static func make(book: LedgerBook, at date: Date = Date()) -> HomeOverview {
        guard let month = BookDate.month(containing: date) else {
            return HomeOverview(month: nil, summary: nil)
        }
        do {
            let summary = try LedgerPerformance.measure("Home.Summary") {
                try LedgerEngine.homeSummary(in: book, from: month.start, to: month.end)
            }
            return HomeOverview(month: month, summary: summary)
        } catch {
            return HomeOverview(month: month, summary: nil)
        }
    }

    func isCurrent(at date: Date) -> Bool {
        guard let month, let current = BookDate.month(containing: date) else { return false }
        return month == current
    }
}
