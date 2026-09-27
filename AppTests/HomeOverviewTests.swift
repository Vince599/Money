import Foundation
import XCTest
import LedgerCore
@testable import Ledger

@MainActor
final class HomeOverviewTests: XCTestCase {
    func testMonthAndConsumptionChangeAtShanghaiMidnight() throws {
        let account = Account(name: "月界账户", openingMinor: 10_000)
        let before = date("2026-09-30T15:59:59Z")
        let boundary = date("2026-09-30T16:00:00Z")
        let septemberEntry = expense(account: account, amount: 1_200, at: before)
        let octoberEntry = expense(account: account, amount: 1_800, at: boundary)
        let book = LedgerBook(accounts: [account], entries: [septemberEntry, octoberEntry])

        let september = HomeOverview.make(book: book, at: before)
        let october = HomeOverview.make(book: book, at: boundary)
        XCTAssertEqual(september.month?.start, date("2026-08-31T16:00:00Z"))
        XCTAssertEqual(september.month?.end, boundary)
        XCTAssertEqual(october.month?.start, boundary)
        XCTAssertEqual(october.month?.end, date("2026-10-31T16:00:00Z"))
        XCTAssertTrue(september.isCurrent(at: date("2026-09-01T00:00:00Z")))
        XCTAssertFalse(september.isCurrent(at: boundary))
        XCTAssertTrue(october.isCurrent(at: boundary))
        XCTAssertEqual(september.summary?.monthlyConsumption?.minorUnits, 1_200)
        XCTAssertEqual(october.summary?.monthlyConsumption?.minorUnits, 1_800)
        // Recent entries and current balances are independent of the selected month.
        XCTAssertEqual(september.summary?.recentEntries, [octoberEntry, septemberEntry])
        XCTAssertEqual(october.summary?.recentEntries, september.summary?.recentEntries)
        XCTAssertEqual(october.summary?.currencySummaries, september.summary?.currencySummaries)
    }

    func testCurrencyOverflowDoesNotHideAnotherCurrencyOrConsumption() throws {
        let largest = Account(name: "人民币一", openingMinor: .max)
        let extra = Account(name: "人民币二", openingMinor: 1)
        let hongKong = Account(name: "港币", currency: .hkd, openingMinor: 4_500)
        let overview = HomeOverview.make(book: LedgerBook(accounts: [largest, extra, hongKong]),
                                         at: date("2026-09-15T00:00:00Z"))
        let summary = try XCTUnwrap(overview.summary)
        XCTAssertEqual(summary.currencySummaries.map(\.currency), [.cny, .hkd])
        XCTAssertNil(summary.currencySummaries.first?.totals)
        let totals = try XCTUnwrap(summary.currencySummaries.last?.totals)
        XCTAssertEqual(totals.assets, Money(minorUnits: 4_500, currency: .hkd))
        XCTAssertEqual(totals.liabilities, Money(minorUnits: 0, currency: .hkd))
        XCTAssertEqual(totals.netAsset, Money(minorUnits: 4_500, currency: .hkd))
        XCTAssertEqual(summary.monthlyConsumption, Money(minorUnits: 0))
        XCTAssertTrue(summary.recentEntries.isEmpty)
    }

    func testConsumptionOverflowKeepsBalancesAndRecentEntryDetails() throws {
        let first = Account(name: "大额一", openingMinor: .max)
        let second = Account(name: "大额二", openingMinor: .max)
        let now = date("2026-09-15T00:00:00Z")
        let earlier = expense(account: first, amount: .max, at: now.addingTimeInterval(-1))
        var latest = expense(account: second, amount: .max, at: now)
        latest.title = "保留标题"
        latest.note = "保留备注"
        latest.version = 3
        let overview = HomeOverview.make(book: LedgerBook(accounts: [first, second], entries: [earlier, latest]),
                                         at: now)
        let summary = try XCTUnwrap(overview.summary)
        XCTAssertNil(summary.monthlyConsumption)
        let totals = try XCTUnwrap(summary.currencySummaries.first?.totals)
        XCTAssertEqual(totals.assets, Money(minorUnits: 0))
        XCTAssertEqual(totals.liabilities, Money(minorUnits: 0))
        XCTAssertEqual(totals.netAsset, Money(minorUnits: 0))
        XCTAssertEqual(summary.recentEntries, [latest, earlier])
        XCTAssertTrue(overview.isCurrent(at: now))
    }

    func testRecentEntriesAreLimitedToFiveAndPreserveTheirValues() throws {
        let account = Account(name: "最近流水", openingMinor: 10_000)
        let now = date("2026-09-15T00:00:00Z")
        let entries = (0..<7).map { index in
            var entry = expense(account: account, amount: Int64(index + 1),
                                at: now.addingTimeInterval(Double(index)))
            entry.title = "第\(index)笔"
            entry.note = "完整记录\(index)"
            return entry
        }
        let overview = HomeOverview.make(book: LedgerBook(accounts: [account], entries: entries), at: now)
        XCTAssertEqual(overview.summary?.recentEntries, Array(entries.reversed().prefix(5)))
    }

    func testInvalidBookProducesUnavailableSummaryForCurrentMonth() {
        let now = date("2026-09-15T00:00:00Z")
        let missingAccount = Account(name: "不存在的账户")
        let invalid = LedgerBook(entries: [expense(account: missingAccount, amount: 100, at: now)])
        let overview = HomeOverview.make(book: invalid, at: now)
        XCTAssertNotNil(overview.month)
        XCTAssertNil(overview.summary)
        // A failed derivation does not trigger another scan on every view redraw.
        XCTAssertTrue(overview.isCurrent(at: now))
    }

    func testInvalidDatesAreUnavailableAndNeverCurrent() {
        let current = HomeOverview.make(book: LedgerBook(), at: date("2026-09-15T00:00:00Z"))
        for interval in [Double.nan, Double.infinity, -Double.infinity] {
            let invalid = Date(timeIntervalSinceReferenceDate: interval)
            let overview = HomeOverview.make(book: LedgerBook(), at: invalid)
            XCTAssertNil(BookDate.month(containing: invalid))
            XCTAssertNil(overview.month)
            XCTAssertNil(overview.summary)
            XCTAssertFalse(overview.isCurrent(at: invalid))
            XCTAssertFalse(current.isCurrent(at: invalid))
        }
    }

    private func expense(account: Account, amount: Int64, at date: Date) -> LedgerEntry {
        LedgerEntry(kind: .expense, amount: Money(minorUnits: amount, currency: account.currency),
                    accountID: account.id, categoryID: SeedData.mealsID,
                    occurredAt: date, createdAt: date)
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }
}
