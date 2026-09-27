import Foundation
import Testing
@testable import LedgerCore

@Suite("LedgerCoreTests home summary")
struct HomeSummaryTests {
    private let day = Date(timeIntervalSince1970: 1_000_000)

    private func entry(_ amount: Int64, account: Account, kind: EntryKind = .expense,
                       occurred: TimeInterval = 0, created: TimeInterval = 0,
                       destination: Account? = nil) -> LedgerEntry {
        LedgerEntry(kind: kind, amount: Money(minorUnits: amount, currency: account.currency),
                    accountID: account.id, destinationAccountID: destination?.id,
                    categoryID: kind == .transfer ? nil : kind == .income ? SeedData.salaryIncomeID : SeedData.mealsID,
                    occurredAt: day.addingTimeInterval(occurred), createdAt: day.addingTimeInterval(created))
    }

    private func summary(_ book: LedgerBook) throws -> HomeSummary {
        try LedgerEngine.homeSummary(in: book, from: day, to: day.addingTimeInterval(100))
    }

    private func totals(_ summary: HomeSummary, currency: Currency = .cny) throws -> HomeSummary.AccountTotals {
        let row = try #require(summary.currencySummaries.first { $0.currency == currency })
        return try #require(row.totals)
    }

    @Test func emptyBookHasZeroConsumptionAndNoCurrencyRowsOrRecentEntries() throws {
        let book = LedgerBook()
        #expect(try summary(book) == HomeSummary(currencySummaries: [], monthlyConsumption: Money(minorUnits: 0),
                                                recentEntries: []))
    }

    @Test func aggregatesValidatedBalancesWithoutChangingAccountingOrHistoricalVisibility() throws {
        let bank = Account(name: "银行", openingMinor: 30_000)
        let card = Account(name: "信用卡", kind: .creditCard, nature: .liability, openingMinor: 5_000)
        let phone = Account(name: "话费", kind: .storedValue, openingMinor: 10_000, includedInSummary: false)
        let wallet = Account(name: "已停用钱包", openingMinor: 2_000, isActive: false)
        let hkd = Account(name: "港币", currency: .hkd, openingMinor: 200)
        let usd = Account(name: "美元负债", nature: .liability, currency: .usd, openingMinor: 30)
        let entries = [entry(1_000, account: card), entry(2_000, account: bank, kind: .transfer, destination: card),
                       entry(300, account: phone), entry(100, account: wallet, kind: .income),
                       entry(50, account: wallet), entry(20, account: hkd), entry(5, account: usd, kind: .income)]
        let adjustment = BalanceAdjustment(accountID: bank.id, difference: Money(minorUnits: 500),
                                           target: Money(minorUnits: 28_500), occurredAt: day)
        let book = LedgerBook(accounts: [usd, phone, bank, card, hkd, wallet], entries: entries, adjustments: [adjustment])
        let original = book
        let result = try summary(book)
        #expect(result.currencySummaries.map(\.currency) == [.cny, .hkd, .usd])
        #expect(try totals(result) == HomeSummary.AccountTotals(assets: Money(minorUnits: 30_550),
                                                                liabilities: Money(minorUnits: 4_000),
                                                                netAsset: Money(minorUnits: 26_550)))
        #expect(try totals(result, currency: .hkd).netAsset == Money(minorUnits: 180, currency: .hkd))
        #expect(try totals(result, currency: .usd).liabilities == Money(minorUnits: 25, currency: .usd))
        #expect(try totals(result, currency: .usd).netAsset == Money(minorUnits: -25, currency: .usd))
        #expect(result.monthlyConsumption == Money(minorUnits: 1_350))
        #expect(result.recentEntries == Array(entries.prefix(5)))
        #expect(book == original)
    }

    @Test func excludedCurrenciesDoNotProduceRowsButStillContributeConsumptionAndRecency() throws {
        let excluded = Account(name: "不计入资产的停用账户", includedInSummary: false, isActive: false)
        let foreign = Account(name: "不计入资产的外币账户", currency: .usd, includedInSummary: false)
        let expense = entry(42, account: excluded)
        let income = entry(15, account: foreign, kind: .income)
        let result = try summary(LedgerBook(accounts: [excluded, foreign], entries: [expense, income]))
        #expect(result.currencySummaries.isEmpty)
        #expect(result.monthlyConsumption == Money(minorUnits: 42))
        #expect(result.recentEntries == [expense, income])
    }

    @Test func consumptionUsesCNYExpensesAndHalfOpenOccurrenceDates() throws {
        let cny = Account(name: "人民币")
        let other = Account(name: "转入账户")
        let hkd = Account(name: "港币", currency: .hkd)
        let entries = [entry(100, account: cny, occurred: -1), entry(200, account: cny),
                       entry(300, account: cny, occurred: 99), entry(400, account: cny, occurred: 100),
                       entry(500, account: cny, occurred: 101), entry(600, account: cny, kind: .income),
                       entry(700, account: cny, kind: .transfer, destination: other), entry(800, account: hkd)]
        let adjustment = BalanceAdjustment(accountID: cny.id, difference: Money(minorUnits: 900),
                                           target: Money(minorUnits: -700), occurredAt: day)
        let book = LedgerBook(accounts: [cny, other, hkd], entries: entries, adjustments: [adjustment])
        let result = try summary(book)
        #expect(result.monthlyConsumption == Money(minorUnits: 500))
        #expect(try result.monthlyConsumption == LedgerEngine.consumption(in: book, from: day,
                                                                      to: day.addingTimeInterval(100), currency: .cny))
        #expect(try LedgerEngine.homeSummary(in: book, from: day, to: day).monthlyConsumption == Money(minorUnits: 0))
        #expect(result.recentEntries.first == entries[4])
    }

    @Test(arguments: [Int64.max, Int64.min])
    func aggregatesAtBothInt64BoundariesAfterOffsettingIntermediateOverflow(_ boundary: Int64) throws {
        let step: Int64 = boundary == .max ? 1 : -1
        let accounts = [AccountNature.asset, .liability].flatMap { nature in
            [boundary, step, -step].map { Account(name: "边界", nature: nature, openingMinor: $0) }
        }
        let result = try summary(LedgerBook(accounts: accounts))
        let amounts = try totals(result)
        #expect(amounts.assets.minorUnits == boundary)
        #expect(amounts.liabilities.minorUnits == boundary)
        #expect(amounts.netAsset.minorUnits == 0)
        #expect(try summary(LedgerBook(accounts: Array(accounts.reversed()))) == result)
    }

    @Test(arguments: [AccountNature.asset, .liability])
    func aggregateOverflowOnlyDisablesItsCurrencyEvenWhenNetAssetFits(_ nature: AccountNature) throws {
        let large = Account(name: "最大", nature: nature, openingMinor: .max)
        let extra = Account(name: "超出一分", nature: nature, openingMinor: 1)
        let offset = Account(name: "净资产抵消", nature: nature == .asset ? .liability : .asset, openingMinor: 1)
        let hkd = Account(name: "港币", currency: .hkd, openingMinor: 80)
        let usd = Account(name: "美元", currency: .usd, openingMinor: -20)
        let expense = entry(10, account: hkd)
        let result = try summary(LedgerBook(accounts: [large, extra, offset, hkd, usd], entries: [expense]))
        #expect(result.currencySummaries.first?.currency == .cny)
        #expect(result.currencySummaries.first?.totals == nil)
        #expect(try totals(result, currency: .hkd).assets == Money(minorUnits: 70, currency: .hkd))
        #expect(try totals(result, currency: .usd).assets == Money(minorUnits: -20, currency: .usd))
        #expect(result.monthlyConsumption == Money(minorUnits: 0))
        #expect(result.recentEntries == [expense])
    }

    @Test(arguments: [Int64.max, Int64.min])
    func netAssetOverflowIsUnavailableEvenWhenAssetsAndLiabilitiesFit(_ boundary: Int64) throws {
        let assets = Account(name: "资产", openingMinor: boundary)
        let debt = Account(name: "负债", nature: .liability, openingMinor: boundary == .max ? -1 : 1)
        let result = try summary(LedgerBook(accounts: [assets, debt]))
        #expect(result.currencySummaries.count == 1)
        #expect(result.currencySummaries[0].totals == nil)
        #expect(result.monthlyConsumption == Money(minorUnits: 0))
    }

    @Test func consumptionOverflowDoesNotHideValidBalancesOrEntries() throws {
        let account = Account(name: "消费超界但余额有效")
        let entries = [entry(.max, account: account), entry(1, account: account),
                       entry(.max, account: account, kind: .income)]
        let book = LedgerBook(accounts: [account], entries: entries)
        let result = try summary(book)
        #expect(result.monthlyConsumption == nil)
        #expect(try totals(result).assets == Money(minorUnits: -1))
        #expect(result.recentEntries == entries)
        #expect(throws: LedgerError.overflow) {
            try LedgerEngine.consumption(in: book, from: day, to: day.addingTimeInterval(100), currency: .cny)
        }
    }

    @Test func rejectsInvalidBooksInsteadOfReturningPlausiblePartialTotals() throws {
        let account = Account(name: "现金")
        #expect(throws: LedgerError.duplicateID) { try summary(LedgerBook(accounts: [account, account])) }
        var invalid = entry(1, account: account)
        invalid.categoryID = SeedData.foodID
        #expect(throws: LedgerError.invalidCategory) { try summary(LedgerBook(accounts: [account], entries: [invalid])) }
        let excluded = Account(name: "排除账户也须校验", openingMinor: .max, includedInSummary: false)
        #expect(throws: LedgerError.overflow) {
            try summary(LedgerBook(accounts: [excluded], entries: [entry(1, account: excluded, kind: .income)]))
        }
    }

    @Test func rejectsReversedAndNonFiniteIntervals() throws {
        let intervals = [(day.addingTimeInterval(1), day), (Date(timeIntervalSinceReferenceDate: .nan), day),
                         (day, Date(timeIntervalSinceReferenceDate: .infinity)),
                         (Date(timeIntervalSinceReferenceDate: -.infinity), day)]
        for (from, to) in intervals {
            #expect(throws: LedgerError.unsupportedOperation) {
                try LedgerEngine.homeSummary(in: LedgerBook(), from: from, to: to)
            }
        }
    }

    @Test func recentFiveUsesAllEntriesAndKeepsInputOrderForExactTimeTies() throws {
        let cny = Account(name: "人民币")
        let excluded = Account(name: "排除账户", includedInSummary: false)
        let hkd = Account(name: "停用港币", currency: .hkd, isActive: false)
        let usd = Account(name: "美元", currency: .usd)
        let old = entry(1, account: cny, occurred: -2, created: 100)
        let firstTie = entry(1, account: cny)
        let laterCreation = entry(1, account: cny, created: 1)
        let future = entry(1, account: hkd, occurred: 200, created: -20)
        let secondTie = entry(1, account: excluded, kind: .transfer, destination: cny)
        let earlierOccurrence = entry(1, account: cny, occurred: -1, created: 999)
        let newer = entry(1, account: usd, kind: .income, occurred: 1, created: -3)
        let thirdTie = entry(1, account: usd, kind: .income)
        let fourthTie = entry(1, account: hkd)
        let entries = [old, firstTie, laterCreation, future, secondTie, earlierOccurrence, newer, thirdTie, fourthTie]
        let accounts = [cny, excluded, hkd, usd]
        #expect(try summary(LedgerBook(accounts: accounts, entries: entries)).recentEntries ==
                [future, newer, laterCreation, firstTie, secondTie])
        #expect(try summary(LedgerBook(accounts: accounts, entries: Array(entries.reversed()))).recentEntries ==
                [future, newer, laterCreation, fourthTie, thirdTie])
    }

    @Test func boundedRecentSelectionMatchesThePreviousStableSortAcrossALargerBook() throws {
        let account = Account(name: "最近流水")
        let entries = (0..<500).map { index in
            entry(1, account: account, kind: index.isMultiple(of: 2) ? .expense : .income,
                  occurred: TimeInterval((index * 37) % 31), created: TimeInterval((index * 13) % 7))
        }
        for input in [entries, Array(entries.reversed())] {
            let expected = input.sorted {
                $0.occurredAt == $1.occurredAt ? $0.createdAt > $1.createdAt : $0.occurredAt > $1.occurredAt
            }.prefix(5)
            #expect(try summary(LedgerBook(accounts: [account], entries: input)).recentEntries == Array(expected))
        }
    }
}
