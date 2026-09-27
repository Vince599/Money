import Foundation
import Testing
@testable import LedgerCore

@Suite("LedgerCoreTests shortcut entries")
struct ShortcutEntryTests {
    private let date = Date(timeIntervalSince1970: 2_000_000)

    @Test func exactExpenseUsesDefaultsAndStableIdentityForRetries() throws {
        let account = Account(name: "钱包", openingMinor: 10_000)
        let subject = LedgerCore.Subject(name: "共同")
        let book = LedgerBook(accounts: [account], subjects: [subject])
        let settings = LedgerSettings(defaultAccountID: account.id, defaultSubjectID: subject.id)
        let request = ShortcutEntryRequest(amountText: " 20.1\n", categoryID: SeedData.mealsID,
                                           occurredAt: date, title: "午餐", note: "两人")
        let draft = try request.makeDraft(in: book, settings: settings)
        #expect(draft.amountText == "20.10" && draft.accountID == account.id && draft.subjectID == subject.id)
        #expect(draft.entryID == request.entryID && draft.operationID == request.operationID)
        #expect(draft.occurredAt == date && draft.title == "午餐" && draft.note == "两人")
        #expect(draft.expenseCategoryID == SeedData.mealsID && draft.incomeCategoryID == nil)
        #expect(try request.makeDraft(in: book, settings: settings) == draft)

        let saved = try LedgerEngine.record(draft.entry(in: book, createdAt: date), in: book)
        #expect(try LedgerEngine.balance(of: account.id, in: saved).minorUnits == 7_990)
        let retry = try request.makeDraft(in: saved, settings: settings).entry(in: saved)
        #expect(try LedgerEngine.record(retry, in: saved) == saved)
        #expect(book.entries.isEmpty)
        #expect(ShortcutEntryRequest().operationID != request.operationID)
    }

    @Test func incomeUsesExplicitSelectionsAndAccountCurrency() throws {
        let defaultAccount = Account(name: "人民币")
        let account = Account(name: "港币", currency: .hkd)
        let subject = LedgerCore.Subject(name: "家人")
        let book = LedgerBook(accounts: [defaultAccount, account], subjects: SeedData.subjects + [subject])
        let request = ShortcutEntryRequest(kind: .income, amountText: "0.10", accountID: account.id,
                                           categoryID: SeedData.salaryIncomeID, subjectID: subject.id)
        let draft = try request.makeDraft(in: book, settings: LedgerSettings(defaultAccountID: defaultAccount.id))
        #expect(draft.accountID == account.id && draft.subjectID == subject.id)
        #expect(draft.expenseCategoryID == nil && draft.incomeCategoryID == SeedData.salaryIncomeID)
        let entry = try draft.entry(in: book)
        #expect(entry.amount == Money(minorUnits: 10, currency: .hkd))
        #expect(try LedgerEngine.record(entry, in: book).entries == [entry])
    }

    @Test func incompleteReviewRemainsUnpostedAndDoesNotInventAccountOrCategory() throws {
        let account = Account(name: "钱包")
        let book = LedgerBook(accounts: [account])
        let blank = try ShortcutEntryRequest().makeDraft(in: book)
        #expect(blank.accountID == nil && blank.categoryID == nil && blank.amountText.isEmpty)
        #expect(throws: LedgerError.accountNotFound) { try blank.entry(in: book) }

        let prefilled = try ShortcutEntryRequest(amountText: "12.30", accountID: account.id).makeDraft(in: book)
        #expect(prefilled.amountText == "12.30" && prefilled.categoryID == nil)
        #expect(throws: LedgerError.invalidCategory) {
            try LedgerEngine.record(prefilled.entry(in: book), in: book)
        }
        let noAmount = try ShortcutEntryRequest(accountID: account.id, categoryID: SeedData.mealsID).makeDraft(in: book)
        #expect(throws: (any Error).self) { try noAmount.entry(in: book) }
        #expect(book.entries.isEmpty)
    }

    @Test(arguments: ["", " ", "0", "-1", "0.00", "1.001", "1+2", "1/3", "1e2", "1,000", "NaN", "1.", ".5", "+3", "１２"])
    func invalidShortcutAmountsAreRejectedBeforeReview(_ amount: String) {
        #expect(throws: ShortcutEntryError.invalidAmount) {
            try ShortcutEntryRequest(amountText: amount).makeDraft(in: LedgerBook())
        }
    }

    @Test func exactUpperCashBoundaryIsPreservedAndOverflowIsExplained() throws {
        let account = Account(name: "钱包")
        let book = LedgerBook(accounts: [account])
        let request = ShortcutEntryRequest(kind: .income, amountText: "92233720368547758.07",
                                           accountID: account.id, categoryID: SeedData.salaryIncomeID)
        let draft = try request.makeDraft(in: book)
        #expect(draft.amountText == "92233720368547758.07")
        let saved = try LedgerEngine.record(draft.entry(in: book), in: book)
        #expect(try LedgerEngine.balance(of: account.id, in: saved).minorUnits == Int64.max)
        #expect(throws: ShortcutEntryError.amountOverflow) {
            try ShortcutEntryRequest(amountText: "92233720368547758.08").makeDraft(in: book)
        }
    }

    @Test func explicitMissingOrInactiveReferencesNeverUseDefaults() throws {
        let defaultAccount = Account(name: "默认账户")
        let inactiveAccount = Account(name: "停用账户", isActive: false)
        let inactiveSubject = LedgerCore.Subject(name: "停用主体", isActive: false)
        let book = LedgerBook(accounts: [defaultAccount, inactiveAccount], subjects: SeedData.subjects + [inactiveSubject])
        let settings = LedgerSettings(defaultAccountID: defaultAccount.id)
        for id in [UUID(), inactiveAccount.id] {
            #expect(throws: ShortcutEntryError.accountUnavailable) {
                try ShortcutEntryRequest(accountID: id).makeDraft(in: book, settings: settings)
            }
            #expect(throws: ShortcutEntryError.destinationUnavailable) {
                try ShortcutEntryRequest(kind: .transfer, destinationAccountID: id).makeDraft(in: book, settings: settings)
            }
        }
        for id in [UUID(), inactiveSubject.id] {
            #expect(throws: ShortcutEntryError.subjectUnavailable) {
                try ShortcutEntryRequest(subjectID: id).makeDraft(in: book, settings: settings)
            }
        }
        #expect(throws: ShortcutEntryError.accountUnavailable) {
            try ShortcutEntryRequest().makeDraft(in: book, settings: LedgerSettings(defaultAccountID: inactiveAccount.id))
        }
        #expect(throws: ShortcutEntryError.subjectUnavailable) {
            try ShortcutEntryRequest().makeDraft(in: book, settings: LedgerSettings(defaultSubjectID: inactiveSubject.id))
        }
    }

    @Test func unavailableOrInappropriateCategoriesAreRejected() {
        let book = LedgerBook()
        for id in [UUID(), SeedData.foodID, SeedData.salaryIncomeID] {
            #expect(throws: ShortcutEntryError.categoryUnavailable) {
                try ShortcutEntryRequest(categoryID: id).makeDraft(in: book)
            }
        }
        for id in [SeedData.mealsID, SeedData.foodID] {
            var disabled = book
            disabled.categories[disabled.categories.firstIndex(where: { $0.id == id })!].isActive = false
            #expect(throws: ShortcutEntryError.categoryUnavailable) {
                try ShortcutEntryRequest(categoryID: SeedData.mealsID).makeDraft(in: disabled)
            }
        }
        #expect(throws: ShortcutEntryError.categoryNotAllowed) {
            try ShortcutEntryRequest(kind: .transfer, categoryID: SeedData.mealsID).makeDraft(in: book)
        }
        #expect(throws: ShortcutEntryError.destinationNotAllowed) {
            try ShortcutEntryRequest(destinationAccountID: UUID()).makeDraft(in: book)
        }
    }

    @Test func transferBalancesBothAccountsAndRejectsInvalidPairs() throws {
        let source = Account(name: "现金", openingMinor: 10_000)
        let destination = Account(name: "银行卡")
        let foreign = Account(name: "港币", currency: .hkd)
        let book = LedgerBook(accounts: [source, destination, foreign])
        let settings = LedgerSettings(defaultAccountID: source.id)
        let request = ShortcutEntryRequest(kind: .transfer, amountText: "35.75", destinationAccountID: destination.id)
        let draft = try request.makeDraft(in: book, settings: settings)
        #expect(draft.accountID == source.id && draft.destinationAccountID == destination.id)
        #expect(draft.expenseCategoryID == nil && draft.incomeCategoryID == nil)
        let saved = try LedgerEngine.record(draft.entry(in: book), in: book)
        #expect(try LedgerEngine.balance(of: source.id, in: saved).minorUnits == 6_425)
        #expect(try LedgerEngine.balance(of: destination.id, in: saved).minorUnits == 3_575)
        #expect(throws: ShortcutEntryError.sameAccountTransfer) {
            try ShortcutEntryRequest(kind: .transfer, destinationAccountID: source.id).makeDraft(in: book, settings: settings)
        }
        #expect(throws: ShortcutEntryError.currencyMismatch) {
            try ShortcutEntryRequest(kind: .transfer, destinationAccountID: foreign.id).makeDraft(in: book, settings: settings)
        }
        let incomplete = try ShortcutEntryRequest(kind: .transfer, amountText: "1").makeDraft(in: book, settings: settings)
        #expect(incomplete.destinationAccountID == nil)
        #expect(throws: LedgerError.accountNotFound) {
            try LedgerEngine.record(incomplete.entry(in: book), in: book)
        }
    }

    @Test func invalidDateAndLocalizedErrors() {
        #expect(throws: ShortcutEntryError.invalidDate) {
            try ShortcutEntryRequest(occurredAt: Date(timeIntervalSince1970: .infinity)).makeDraft(in: LedgerBook())
        }
        #expect(ShortcutEntryError.invalidAmount.localizedDescription.contains("两位小数"))
        #expect(ShortcutEntryError.currencyMismatch.localizedDescription.contains("相同币种"))
    }
}
