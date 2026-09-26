import Foundation
import Testing
@testable import LedgerCore

@Suite("LedgerCoreTests copying entries")
struct EntryCopyTests {
    private let originalDate = Date(timeIntervalSince1970: 1_000_000)
    private let copyDate = Date(timeIntervalSince1970: 2_000_000)

    private func expense(account: Account, subjectID: UUID = SeedData.mpcID) -> LedgerEntry {
        LedgerEntry(kind: .expense, amount: Money(minorUnits: 2_010, currency: account.currency),
                    accountID: account.id, categoryID: SeedData.mealsID, subjectID: subjectID,
                    occurredAt: originalDate, createdAt: originalDate, title: "午餐", note: "两人，含饮品")
    }

    @Test func copyPostsAsIndependentEventWithNewIdentityAndCreationDate() throws {
        let account = Account(name: "钱包", openingMinor: 10_000)
        var original = expense(account: account)
        original.version = 3
        let book = LedgerBook(accounts: [account], entries: [original])
        let draft = try EntryDraft.copying(original, in: book, at: copyDate)
        #expect(draft.entryID != original.id && draft.operationID != original.operationID)
        #expect(draft.occurredAt == copyDate)
        #expect(draft.amountText == "20.10")
        #expect(draft.title == original.title && draft.note == original.note)
        #expect(book.entries == [original])

        let createdAt = copyDate.addingTimeInterval(15)
        let copiedEntry = try draft.entry(in: book, createdAt: createdAt)
        #expect(copiedEntry.createdAt == createdAt && copiedEntry.version == 1)
        let saved = try LedgerEngine.record(copiedEntry, in: book)
        #expect(saved.entries.count == 2 && saved.entries[0] == original)
        #expect(try LedgerEngine.balance(of: account.id, in: saved).minorUnits == 5_980)
        #expect(try LedgerEngine.record(copiedEntry, in: saved) == saved)

        let anotherDraft = try EntryDraft.copying(original, in: saved, at: copyDate)
        #expect(anotherDraft.entryID != draft.entryID && anotherDraft.operationID != draft.operationID)
    }

    @Test func inactiveAccountAndCategoryAreClearedInsteadOfUsingDefaults() throws {
        var account = Account(name: "旧卡")
        let original = expense(account: account)
        account.isActive = false
        let replacement = Account(name: "新卡")
        var book = LedgerBook(accounts: [account, replacement], entries: [original])
        book.categories[book.categories.firstIndex(where: { $0.id == SeedData.mealsID })!].isActive = false
        var draft = try EntryDraft.copying(original, in: book,
                                          settings: LedgerSettings(defaultAccountID: replacement.id), at: copyDate)
        #expect(draft.accountID == nil && draft.categoryID == nil)
        #expect(throws: LedgerError.accountNotFound) { try draft.entry(in: book) }
        draft.accountID = replacement.id
        #expect(throws: LedgerError.invalidCategory) {
            try LedgerEngine.record(draft.entry(in: book), in: book)
        }
        draft.categoryID = SeedData.taxiID
        #expect(try LedgerEngine.record(draft.entry(in: book), in: book).entries.count == 2)
    }

    @Test func inactiveParentAndInvalidCategoryStructureAreNotCopied() throws {
        let account = Account(name: "钱包")
        var original = expense(account: account)
        var book = LedgerBook(accounts: [account])
        book.categories[book.categories.firstIndex(where: { $0.id == SeedData.foodID })!].isActive = false
        #expect(try EntryDraft.copying(original, in: book, at: copyDate).categoryID == nil)
        book.categories = SeedData.categories
        original.categoryID = SeedData.foodID
        #expect(try EntryDraft.copying(original, in: book, at: copyDate).categoryID == nil)
        original.categoryID = SeedData.salaryIncomeID
        #expect(try EntryDraft.copying(original, in: book, at: copyDate).categoryID == nil)
        original.categoryID = UUID()
        #expect(try EntryDraft.copying(original, in: book, at: copyDate).categoryID == nil)
    }

    @Test func expenseAndIncomePopulateOnlyTheirOwnCategorySelection() throws {
        let account = Account(name: "钱包")
        let book = LedgerBook(accounts: [account])
        let expenseDraft = try EntryDraft.copying(expense(account: account), in: book, at: copyDate)
        #expect(expenseDraft.expenseCategoryID == SeedData.mealsID && expenseDraft.incomeCategoryID == nil)
        let income = LedgerEntry(kind: .income, amount: Money(minorUnits: 123_456), accountID: account.id,
                                 categoryID: SeedData.salaryIncomeID, occurredAt: originalDate)
        var incomeDraft = try EntryDraft.copying(income, in: book, at: copyDate)
        #expect(incomeDraft.kind == .income && incomeDraft.amountText == "1234.56")
        #expect(incomeDraft.incomeCategoryID == SeedData.salaryIncomeID && incomeDraft.expenseCategoryID == nil)
        #expect(try LedgerEngine.record(incomeDraft.entry(in: book), in: book).entries.count == 1)
        incomeDraft.kind = .expense
        #expect(incomeDraft.categoryID == nil)
    }

    @Test func transferCopiesBothAccountsWithoutCategoriesAndRequiresInactiveDestinationReplacement() throws {
        let source = Account(name: "现金", openingMinor: 10_000)
        var destination = Account(name: "银行卡")
        let transfer = LedgerEntry(kind: .transfer, amount: Money(minorUnits: 3_000), accountID: source.id,
                                   destinationAccountID: destination.id, occurredAt: originalDate)
        let book = try LedgerEngine.record(transfer, in: LedgerBook(accounts: [source, destination]))
        let draft = try EntryDraft.copying(transfer, in: book, at: copyDate)
        #expect(draft.kind == .transfer && draft.accountID == source.id && draft.destinationAccountID == destination.id)
        #expect(draft.expenseCategoryID == nil && draft.incomeCategoryID == nil)
        let saved = try LedgerEngine.record(draft.entry(in: book), in: book)
        #expect(try LedgerEngine.balance(of: source.id, in: saved).minorUnits == 4_000)
        #expect(try LedgerEngine.balance(of: destination.id, in: saved).minorUnits == 6_000)

        destination.isActive = false
        let disabledBook = LedgerBook(accounts: [source, destination], entries: [transfer])
        let incomplete = try EntryDraft.copying(transfer, in: disabledBook, at: copyDate)
        #expect(incomplete.accountID == source.id && incomplete.destinationAccountID == nil)
        #expect(throws: LedgerError.accountNotFound) {
            try LedgerEngine.record(incomplete.entry(in: disabledBook), in: disabledBook)
        }
    }

    @Test func subjectPreservesActiveOriginalThenFallsBackToSettingsMPCAndFirstActive() throws {
        let account = Account(name: "钱包")
        var originalSubject = LedgerCore.Subject(name: "家人")
        let preferred = LedgerCore.Subject(name: "共同")
        let original = expense(account: account, subjectID: originalSubject.id)
        var book = LedgerBook(accounts: [account], subjects: [originalSubject, preferred] + SeedData.subjects)
        let settings = LedgerSettings(defaultSubjectID: preferred.id)
        #expect(try EntryDraft.copying(original, in: book, settings: settings).subjectID == originalSubject.id)
        originalSubject.isActive = false
        book.subjects[0] = originalSubject
        #expect(try EntryDraft.copying(original, in: book, settings: settings).subjectID == preferred.id)
        let missingSettings = LedgerSettings(defaultSubjectID: UUID())
        #expect(try EntryDraft.copying(original, in: book, settings: missingSettings).subjectID == SeedData.mpcID)
        book.subjects = [originalSubject, preferred]
        #expect(try EntryDraft.copying(original, in: book, settings: missingSettings).subjectID == preferred.id)
        book.subjects = [originalSubject]
        #expect(throws: LedgerError.invalidSubject) { try EntryDraft.copying(original, in: book) }
    }

    @Test func missingAndWrongCurrencyAccountsStayUnselected() throws {
        let account = Account(name: "港币", currency: .hkd)
        var original = expense(account: account)
        let missingBook = LedgerBook()
        #expect(try EntryDraft.copying(original, in: missingBook).accountID == nil)
        original.amount = Money(minorUnits: 2_010, currency: .cny)
        let mismatchedBook = LedgerBook(accounts: [account])
        #expect(try EntryDraft.copying(original, in: mismatchedBook).accountID == nil)
        let validDraft = try EntryDraft.copying(expense(account: account), in: mismatchedBook)
        #expect(try validDraft.entry(in: mismatchedBook).amount.currency == .hkd)
    }

    @Test func invalidDateOrNonpositiveAmountCannotCreateCopy() {
        let account = Account(name: "钱包")
        var original = expense(account: account)
        let book = LedgerBook(accounts: [account])
        #expect(throws: LedgerError.invalidAmount) {
            try EntryDraft.copying(original, in: book, at: Date(timeIntervalSince1970: .infinity))
        }
        original.amount = Money(minorUnits: 0)
        #expect(throws: LedgerError.invalidAmount) { try EntryDraft.copying(original, in: book) }
    }
}
