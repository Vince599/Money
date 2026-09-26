import Foundation
import Testing
@testable import LedgerCore

@Suite("LedgerCoreTests money and drafts") struct MoneyDraftTests {
    @Test func exactAmountsAndBoundaries() throws {
        #expect(try Money.parse("0.10").adding(Money.parse("0.20")).minorUnits == 30)
        #expect(try Money.parse("92233720368547758.07").minorUnits == Int64.max)
        #expect(try Money.parse("-92233720368547758.08").minorUnits == Int64.min)
        #expect(Money(minorUnits: Int64.min).decimalString == "-92233720368547758.08")
        #expect(throws: LedgerError.overflow) { try Money.parse("92233720368547758.08") }
        #expect(throws: LedgerError.overflow) { try Money(minorUnits: .max).adding(Money(minorUnits: 1)) }
        #expect(throws: LedgerError.currencyMismatch) { try Money.parse("1", currency: .hkd).adding(Money.parse("1")) }
    }
    @Test(arguments: ["", "NaN", "1e2", "1,000", "1.001", "1.", ".5", "+3", "１２", "--1", "1.2.3"])
    func rejectsMalformedAmounts(_ input: String) {
        #expect(throws: (any Error).self) { try Money.parse(input) }
    }
    @Test func switchingTypePreservesIndependentCategorySelections() throws {
        var draft = EntryDraft(amountText: "28", expenseCategoryID: SeedData.mealsID, note: "午餐")
        draft.kind = .income; draft.categoryID = SeedData.salaryIncomeID
        draft.kind = .transfer
        #expect(draft.categoryID == nil)
        #expect(draft.amountText == "28")
        #expect(draft.note == "午餐")
        draft.kind = .expense
        #expect(draft.categoryID == SeedData.mealsID)
        draft.kind = .income
        #expect(draft.categoryID == SeedData.salaryIncomeID)
        let restored = try JSONDecoder().decode(EntryDraft.self, from: JSONEncoder().encode(draft))
        #expect(restored == draft)
    }
    @Test func continueClearsPreviousContentAndGetsNewIdentity() {
        let accountID = UUID()
        let draft = EntryDraft(amountText: "20", accountID: accountID, expenseCategoryID: SeedData.mealsID,
                               title: "上一笔", note: "不应沿用")
        let next = draft.nextEntry()
        #expect(next.accountID == accountID && next.subjectID == draft.subjectID)
        #expect(next.amountText.isEmpty && next.categoryID == nil && next.title.isEmpty && next.note.isEmpty)
        #expect(next.operationID != draft.operationID && next.entryID != draft.entryID)
    }
    @Test func blankBookDoesNotInventAccountsOrTransactions() {
        let book = LedgerBook()
        #expect(book.accounts.isEmpty && book.entries.isEmpty && book.adjustments.isEmpty)
        #expect(book.subjects.first?.id == SeedData.mpcID)
    }
}
