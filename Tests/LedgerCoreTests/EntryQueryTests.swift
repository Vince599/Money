import Foundation
import Testing
@testable import LedgerCore

@Suite("LedgerCoreTests entry query")
struct EntryQueryTests {
    private let day = Date(timeIntervalSince1970: 1_000_000)
    private let firstAccount = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let secondAccount = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
    private let otherSubject = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!

    private func entry(_ sequence: Int, kind: EntryKind = .expense, amount: Int64 = 1_000,
                       currency: Currency = .cny, accountID: UUID? = nil,
                       destinationAccountID: UUID? = nil, categoryID: UUID? = SeedData.mealsID,
                       subjectID: UUID = SeedData.mpcID, occurred: TimeInterval = 0,
                       created: TimeInterval = 0, title: String = "", note: String = "") -> LedgerEntry {
        let suffix = String(repeating: "0", count: 12 - String(sequence).count) + String(sequence)
        return LedgerEntry(id: UUID(uuidString: "30000000-0000-4000-8000-\(suffix)")!, kind: kind,
                           amount: Money(minorUnits: amount, currency: currency),
                           accountID: accountID ?? firstAccount, destinationAccountID: destinationAccountID,
                           categoryID: categoryID, subjectID: subjectID, occurredAt: day.addingTimeInterval(occurred),
                           createdAt: day.addingTimeInterval(created), title: title, note: note)
    }

    @Test func blankSearchReturnsAllEntriesAndOnlyOrdersACopy() throws {
        let older = entry(1, occurred: -1)
        let latest = entry(2, occurred: 1)
        let book = LedgerBook(entries: [older, latest])
        let before = book
        #expect(try EntryQuery.entries(in: book) == [latest, older])
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(keyword: " \n\t ")) == [latest, older])
        #expect(book == before)
    }

    @Test func filterIdentityPreservesLiteralUnicodeSearchDifferences() throws {
        let composed = EntryFilter(keyword: "café")
        let decomposed = EntryFilter(keyword: "cafe\u{0301}")
        #expect(composed.keyword == decomposed.keyword)
        #expect(composed != decomposed)
        let first = entry(1, title: composed.keyword)
        let second = entry(2, title: decomposed.keyword)
        let book = LedgerBook(entries: [first, second])
        #expect(try EntryQuery.entries(in: book, matching: composed) == [first])
        #expect(try EntryQuery.entries(in: book, matching: decomposed) == [second])
    }

    @Test func searchTrimsEdgesMatchesTitleOrNoteAndIgnoresCase() throws {
        let title = entry(1, title: "Lunch With ALICE")
        let note = entry(2, title: "午餐", note: "\nAlice 请客补记\n")
        let unrelated = entry(3, title: "午餐")
        let book = LedgerBook(entries: [unrelated, note, title])
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(keyword: "  alice\n")) == [title, note])
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(keyword: "请客")) == [note])
    }

    @Test func searchTreatsMetacharactersAndInternalWhitespaceLiterally() throws {
        let literal = entry(1, title: "套餐 [A].*", note: "two  spaces")
        let ordinary = entry(2, title: "套餐 ABC", note: "two spaces")
        let book = LedgerBook(entries: [ordinary, literal])
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(keyword: "[A].*")) == [literal])
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(keyword: "two  spaces")) == [literal])
    }

    @Test func searchDoesNotIncludeAccountCategoryOrSubjectNames() throws {
        let record = entry(1)
        var book = LedgerBook(accounts: [Account(id: firstAccount, name: "SEARCH-MARKER")], entries: [record])
        book.subjects[0].name = "SEARCH-MARKER"
        let index = try #require(book.categories.firstIndex { $0.id == SeedData.mealsID })
        book.categories[index].name = "SEARCH-MARKER"
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(keyword: "search-marker")).isEmpty)
    }

    @Test func allConditionsCombineWithAndInsteadOfBroadeningResults() throws {
        let match = entry(1, amount: 100, subjectID: otherSubject, title: "午餐")
        let wrongKind = entry(2, kind: .income, amount: 100, subjectID: otherSubject, title: "午餐")
        let wrongAccount = entry(3, amount: 100, accountID: secondAccount, subjectID: otherSubject, title: "午餐")
        let wrongCategory = entry(4, amount: 100, categoryID: SeedData.taxiID, subjectID: otherSubject, title: "午餐")
        let wrongSubject = entry(5, amount: 100, title: "午餐")
        let wrongCurrency = entry(6, amount: 100, currency: .hkd, subjectID: otherSubject, title: "午餐")
        let tooSmall = entry(7, amount: 99, subjectID: otherSubject, title: "午餐")
        let tooLarge = entry(8, amount: 101, subjectID: otherSubject, title: "午餐")
        let tooEarly = entry(9, amount: 100, subjectID: otherSubject, occurred: -1, title: "午餐")
        let tooLate = entry(10, amount: 100, subjectID: otherSubject, occurred: 1, title: "午餐")
        let wrongKeyword = entry(11, amount: 100, subjectID: otherSubject, title: "晚餐")
        let book = LedgerBook(entries: [wrongKind, wrongAccount, wrongCategory, wrongSubject, wrongCurrency,
                                        tooSmall, tooLarge, tooEarly, tooLate, wrongKeyword, match])
        let filter = EntryFilter(keyword: "午餐", kind: .expense, accountID: firstAccount,
                                 categoryID: SeedData.foodID, subjectID: otherSubject, currency: .cny,
                                 minimumMinor: 100, maximumMinor: 100, from: day, to: day.addingTimeInterval(1))
        #expect(try EntryQuery.entries(in: book, matching: filter) == [match])
    }

    @Test func transferMatchesEitherAccountAndAppearsOnce() throws {
        let transfer = entry(1, kind: .transfer, destinationAccountID: secondAccount, categoryID: nil)
        let expense = entry(2)
        let income = entry(3, kind: .income, accountID: secondAccount, categoryID: SeedData.salaryIncomeID)
        let book = LedgerBook(entries: [transfer, expense, income])
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(accountID: firstAccount)) == [transfer, expense])
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(accountID: secondAccount)) == [transfer, income])
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(kind: .transfer, accountID: secondAccount)) == [transfer])
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(accountID: UUID())).isEmpty)
    }

    @Test func categoryParentIncludesDirectChildrenAndLeafMatchesOnlyItself() throws {
        let secondFoodID = try #require(SeedData.categories.first { $0.parentID == SeedData.foodID && $0.id != SeedData.mealsID }?.id)
        let meal = entry(1)
        let secondFood = entry(2, categoryID: secondFoodID)
        let taxi = entry(3, categoryID: SeedData.taxiID)
        let transfer = entry(4, kind: .transfer, destinationAccountID: secondAccount, categoryID: nil)
        let book = LedgerBook(entries: [transfer, taxi, secondFood, meal])
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(categoryID: SeedData.foodID)) == [meal, secondFood])
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(categoryID: SeedData.mealsID)) == [meal])
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(categoryID: UUID())).isEmpty)
    }

    @Test func inactiveCatalogRecordsRemainAvailableForHistoricalFiltering() throws {
        let record = entry(1, subjectID: otherSubject)
        var book = LedgerBook(accounts: [Account(id: firstAccount, name: "停用账户", isActive: false)], entries: [record],
                              subjects: [LedgerCore.Subject(id: otherSubject, name: "停用主体", isActive: false)])
        for index in book.categories.indices where book.categories[index].id == SeedData.foodID || book.categories[index].id == SeedData.mealsID {
            book.categories[index].isActive = false
        }
        let filter = EntryFilter(accountID: firstAccount, categoryID: SeedData.foodID, subjectID: otherSubject)
        #expect(try EntryQuery.entries(in: book, matching: filter) == [record])
    }

    @Test func dateBoundariesUseOccurredTimeAndAreHalfOpen() throws {
        let before = entry(1, occurred: -0.001, created: 1)
        let first = entry(2, created: 2)
        let middle = entry(3, occurred: 0.5, created: -2)
        let end = entry(4, occurred: 1, created: 0.5)
        let book = LedgerBook(entries: [before, first, middle, end])
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(from: day, to: day.addingTimeInterval(1))) == [middle, first])
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(from: day.addingTimeInterval(1))) == [end])
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(to: day)) == [before])
    }

    @Test func invalidDateIntervalsRejectEqualReversedAndNonFiniteBounds() throws {
        let invalidFilters = [
            EntryFilter(from: day, to: day),
            EntryFilter(from: day, to: day.addingTimeInterval(-1)),
            EntryFilter(from: Date(timeIntervalSinceReferenceDate: .nan)),
            EntryFilter(to: Date(timeIntervalSinceReferenceDate: .infinity))
        ]
        for filter in invalidFilters {
            #expect(throws: EntryQueryError.invalidDateRange) { try EntryQuery.entries(in: LedgerBook(), matching: filter) }
        }
    }

    @Test func amountBoundsAreInclusiveExactAndNeverCompareAcrossCurrencies() throws {
        let below = entry(1, amount: 9_007_199_254_740_992)
        let lower = entry(2, amount: 9_007_199_254_740_993)
        let highest = entry(3, kind: .income, amount: Int64.max, categoryID: SeedData.salaryIncomeID)
        let sameForeignAmount = entry(4, amount: 9_007_199_254_740_993, currency: .usd)
        let book = LedgerBook(entries: [below, lower, highest, sameForeignAmount])
        let filter = EntryFilter(currency: .cny, minimumMinor: lower.amount.minorUnits, maximumMinor: Int64.max)
        #expect(try EntryQuery.entries(in: book, matching: filter) == [lower, highest])
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(currency: .usd)) == [sameForeignAmount])
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(currency: .cny, maximumMinor: below.amount.minorUnits)) == [below])
        #expect(try EntryQuery.entries(in: book, matching: EntryFilter(currency: .cny, minimumMinor: 0)).count == 3)
    }

    @Test func invalidAmountFiltersRejectNegativeReversedAndMissingCurrency() throws {
        for filter in [EntryFilter(currency: .cny, minimumMinor: -1), EntryFilter(currency: .cny, maximumMinor: Int64.min),
                       EntryFilter(currency: .cny, minimumMinor: 100, maximumMinor: 99)] {
            #expect(throws: EntryQueryError.invalidAmountRange) { try EntryQuery.validate(filter) }
        }
        for filter in [EntryFilter(minimumMinor: 0), EntryFilter(maximumMinor: 100), EntryFilter(minimumMinor: 1, maximumMinor: 100)] {
            #expect(throws: EntryQueryError.amountCurrencyRequired) { try EntryQuery.entries(in: LedgerBook(), matching: filter) }
        }
    }

    @Test func sortUsesOccurrenceThenCreationThenIdentifierRegardlessOfInputOrder() throws {
        let old = entry(1, occurred: -1, created: 10)
        let earlyCreation = entry(2, created: -1)
        let firstTie = entry(3)
        let secondTie = entry(4)
        let latest = entry(5, occurred: 1, created: -10)
        let expected = [latest, firstTie, secondTie, earlyCreation, old]
        let inputs = [expected, Array(expected.reversed()), [secondTie, old, latest, earlyCreation, firstTie]]
        for entries in inputs {
            #expect(try EntryQuery.entries(in: LedgerBook(entries: entries)) == expected)
        }
    }
}
