import Foundation
import Testing
@testable import LedgerCore

@Suite("LedgerCoreTests ledger engine")
struct LedgerEngineTests {
    private let day = Date(timeIntervalSince1970: 1_000_000)

    private func expense(_ amount: Int64, account: Account, at date: Date? = nil) -> LedgerEntry {
        LedgerEntry(kind: .expense, amount: Money(minorUnits: amount, currency: account.currency),
                    accountID: account.id, categoryID: SeedData.mealsID,
                    occurredAt: date ?? day, createdAt: day)
    }

    private func income(_ amount: Int64, account: Account) -> LedgerEntry {
        LedgerEntry(kind: .income, amount: Money(minorUnits: amount, currency: account.currency),
                    accountID: account.id, categoryID: SeedData.salaryIncomeID,
                    occurredAt: day, createdAt: day)
    }

    private func transfer(_ amount: Int64, from source: Account, to destination: Account) -> LedgerEntry {
        LedgerEntry(kind: .transfer, amount: Money(minorUnits: amount, currency: source.currency),
                    accountID: source.id, destinationAccountID: destination.id,
                    occurredAt: day, createdAt: day)
    }

    private func consumed(_ book: LedgerBook, currency: Currency = .cny) throws -> Int64 {
        try LedgerEngine.consumption(in: book, from: day.addingTimeInterval(-100_000),
                                     to: day.addingTimeInterval(100_000), currency: currency).minorUnits
    }

    @Test func a10TransferPreservesAssetsAndDoesNotConsumeBudget() throws {
        let wallet = Account(name: "微信", kind: .wallet, openingMinor: 20_000)
        let bank = Account(name: "银行卡", openingMinor: 10_000)
        let original = LedgerBook(accounts: [wallet, bank])
        let entry = transfer(10_000, from: wallet, to: bank)
        let result = try LedgerEngine.record(entry, in: original)
        #expect(try LedgerEngine.balance(of: wallet.id, in: result).minorUnits == 10_000)
        #expect(try LedgerEngine.balance(of: bank.id, in: result).minorUnits == 20_000)
        #expect(try consumed(result) == 0)
        #expect(original.entries.isEmpty)
        #expect(try LedgerEngine.record(entry, in: result) == result)
    }

    @Test func a11CreditCardExpenseAndRepaymentOnlyConsumeOnce() throws {
        let bank = Account(name: "银行卡", openingMinor: 30_000)
        let card = Account(name: "信用卡", kind: .creditCard, nature: .liability)
        let charged = try LedgerEngine.record(expense(10_000, account: card), in: LedgerBook(accounts: [bank, card]))
        #expect(try LedgerEngine.balance(of: card.id, in: charged).minorUnits == 10_000)
        #expect(try LedgerEngine.balance(of: bank.id, in: charged).minorUnits == 30_000)
        let repayment = transfer(10_000, from: bank, to: card)
        let paid = try LedgerEngine.record(repayment, in: charged)
        #expect(try LedgerEngine.balance(of: card.id, in: paid).minorUnits == 0)
        #expect(try LedgerEngine.balance(of: bank.id, in: paid).minorUnits == 20_000)
        #expect(try consumed(paid) == 10_000)
        let undone = try LedgerEngine.delete(entryID: repayment.id, in: paid)
        #expect(try LedgerEngine.balance(of: card.id, in: undone).minorUnits == 10_000)
        #expect(try LedgerEngine.balance(of: bank.id, in: undone).minorUnits == 30_000)
        #expect(try consumed(undone) == 10_000)
    }

    @Test func a57HistoricalEntryChangesCurrentBalanceAndAdjustmentIsNotIncome() throws {
        let bank = Account(name: "银行卡", openingMinor: 1_000_000, openingDate: day.addingTimeInterval(86_400))
        let imported = try LedgerEngine.record(expense(200_000, account: bank), in: LedgerBook(accounts: [bank]))
        #expect(try LedgerEngine.balance(of: bank.id, in: imported).minorUnits == 800_000)
        let operation = UUID()
        let target = Money(minorUnits: 1_000_000)
        let adjusted = try LedgerEngine.adjustBalance(accountID: bank.id, to: target, operationID: operation,
                                                      at: day, note: "实际余额", in: imported)
        #expect(try LedgerEngine.balance(of: bank.id, in: adjusted) == target)
        #expect(adjusted.adjustments.first?.difference.minorUnits == 200_000)
        #expect(adjusted.entries.count == 1)
        #expect(try consumed(adjusted) == 200_000)
        let later = try LedgerEngine.record(income(10_000, account: bank), in: adjusted)
        let retry = try LedgerEngine.adjustBalance(accountID: bank.id, to: target, operationID: operation,
                                                   at: day, note: "实际余额", in: later)
        #expect(retry == later)
        #expect(try LedgerEngine.balance(of: bank.id, in: retry).minorUnits == 1_010_000)
        #expect(throws: LedgerError.operationConflict) {
            try LedgerEngine.adjustBalance(accountID: bank.id, to: Money(minorUnits: 2_000_000),
                                            operationID: operation, at: day, note: "实际余额", in: adjusted)
        }
    }

    @Test func a58ExcludedStoredValueStillTracksBalanceAndConsumption() throws {
        let bank = Account(name: "银行卡", openingMinor: 100_000)
        let phone = Account(name: "话费", kind: .storedValue, includedInSummary: false)
        let funded = try LedgerEngine.record(transfer(10_000, from: bank, to: phone),
                                            in: LedgerBook(accounts: [bank, phone]))
        #expect(try consumed(funded) == 0)
        let spent = try LedgerEngine.record(expense(2_000, account: phone), in: funded)
        #expect(try LedgerEngine.balance(of: bank.id, in: spent).minorUnits == 90_000)
        #expect(try LedgerEngine.balance(of: phone.id, in: spent).minorUnits == 8_000)
        #expect(try consumed(spent) == 2_000)
        var included = spent
        included.accounts[1].includedInSummary = true
        #expect(try LedgerEngine.balance(of: phone.id, in: included) == LedgerEngine.balance(of: phone.id, in: spent))
    }

    @Test func retryIgnoresGeneratedIdentityAndCreationTimeButRejectsChangedBusinessData() throws {
        let account = Account(name: "现金")
        let entry = expense(100, account: account)
        let saved = try LedgerEngine.record(entry, in: LedgerBook(accounts: [account]))
        var retry = entry
        retry.id = UUID()
        retry.createdAt = day.addingTimeInterval(60)
        #expect(try LedgerEngine.record(retry, in: saved) == saved)
        retry.amount = Money(minorUnits: 101)
        #expect(throws: LedgerError.operationConflict) { try LedgerEngine.record(retry, in: saved) }
        var conflictingID = entry
        conflictingID.operationID = UUID()
        #expect(throws: LedgerError.duplicateID) { try LedgerEngine.record(conflictingID, in: saved) }
    }

    @Test func replaceChangesOneEventAndRetiresOldOperation() throws {
        let cash = Account(name: "现金", openingMinor: 1_000)
        let bank = Account(name: "银行", openingMinor: 5_000)
        let original = expense(100, account: cash)
        let saved = try LedgerEngine.record(original, in: LedgerBook(accounts: [cash, bank]))
        var edit = original
        edit.operationID = UUID()
        edit.accountID = bank.id
        edit.amount = Money(minorUnits: 250)
        edit.createdAt = day.addingTimeInterval(50)
        let changed = try LedgerEngine.replace(edit, expectedVersion: 1, in: saved)
        #expect(changed.entries.count == 1)
        #expect(changed.entries[0].version == 2)
        #expect(changed.entries[0].createdAt == original.createdAt)
        #expect(try LedgerEngine.balance(of: cash.id, in: changed).minorUnits == 1_000)
        #expect(try LedgerEngine.balance(of: bank.id, in: changed).minorUnits == 4_750)
        #expect(try consumed(changed) == 250)
        #expect(changed.retiredOperationIDs.contains(original.operationID))
        #expect(try LedgerEngine.replace(edit, expectedVersion: 1, in: changed) == changed)
        #expect(throws: LedgerError.operationConflict) { try LedgerEngine.record(original, in: changed) }
        var stale = edit
        stale.note = "different edit"
        #expect(throws: LedgerError.staleVersion) { try LedgerEngine.replace(stale, expectedVersion: 1, in: changed) }
        var reusedOperation = original
        reusedOperation.note = "changed business request"
        #expect(throws: LedgerError.operationConflict) {
            try LedgerEngine.replace(reusedOperation, expectedVersion: 1, in: saved)
        }
    }

    @Test func replacingExpenseWithIncomeRemovesItsBudgetUse() throws {
        let account = Account(name: "现金", openingMinor: 1_000)
        let original = expense(100, account: account)
        let saved = try LedgerEngine.record(original, in: LedgerBook(accounts: [account]))
        var edit = original
        edit.operationID = UUID()
        edit.kind = .income
        edit.categoryID = SeedData.salaryIncomeID
        let changed = try LedgerEngine.replace(edit, expectedVersion: 1, in: saved)
        #expect(try LedgerEngine.balance(of: account.id, in: changed).minorUnits == 1_100)
        #expect(try consumed(changed) == 0)
        let deleted = try LedgerEngine.delete(entryID: original.id, in: changed)
        #expect(try LedgerEngine.balance(of: account.id, in: deleted).minorUnits == 1_000)
        #expect(try LedgerEngine.delete(entryID: original.id, in: deleted) == deleted)
        #expect(throws: LedgerError.operationConflict) { try LedgerEngine.record(original, in: deleted) }
        #expect(throws: LedgerError.operationConflict) { try LedgerEngine.record(changed.entries[0], in: deleted) }
    }

    @Test func rejectsCrossCurrencyMissingAccountsAndMalformedTransfers() throws {
        let cny = Account(name: "人民币")
        let hkd = Account(name: "港币", currency: .hkd)
        let book = LedgerBook(accounts: [cny, hkd])
        #expect(throws: LedgerError.currencyMismatch) { try LedgerEngine.record(transfer(1, from: cny, to: hkd), in: book) }
        #expect(throws: LedgerError.sameAccountTransfer) { try LedgerEngine.record(transfer(1, from: cny, to: cny), in: book) }
        var wrong = expense(1, account: cny)
        wrong.amount = Money(minorUnits: 1, currency: .usd)
        #expect(throws: LedgerError.currencyMismatch) { try LedgerEngine.record(wrong, in: book) }
        wrong = expense(1, account: cny)
        wrong.accountID = UUID()
        #expect(throws: LedgerError.accountNotFound) { try LedgerEngine.record(wrong, in: book) }
        var malformed = transfer(1, from: cny, to: hkd)
        malformed.categoryID = SeedData.mealsID
        #expect(throws: LedgerError.invalidCategory) { try LedgerEngine.record(malformed, in: book) }
        #expect(throws: LedgerError.accountNotFound) { try LedgerEngine.balance(of: UUID(), in: book) }
    }

    @Test func requiresLeafCategoryCorrectDirectionAndExistingSubject() throws {
        let account = Account(name: "现金")
        let book = LedgerBook(accounts: [account])
        for categoryID in [SeedData.foodID, SeedData.salaryIncomeID, UUID()] {
            var invalid = expense(1, account: account)
            invalid.categoryID = categoryID
            #expect(throws: LedgerError.invalidCategory) { try LedgerEngine.record(invalid, in: book) }
        }
        var invalid = expense(1, account: account)
        invalid.subjectID = UUID()
        #expect(throws: LedgerError.invalidSubject) { try LedgerEngine.record(invalid, in: book) }
        invalid = expense(1, account: account)
        invalid.destinationAccountID = UUID()
        #expect(throws: LedgerError.unsupportedOperation) { try LedgerEngine.record(invalid, in: book) }
    }

    @Test func historicalInactiveReferencesRemainReadableButCannotBeSelectedForNewEntries() throws {
        let account = Account(name: "现金", openingMinor: 1_000)
        let original = expense(100, account: account)
        var book = try LedgerEngine.record(original, in: LedgerBook(accounts: [account]))
        book.accounts[0].isActive = false
        book.categories[1].isActive = false
        book.subjects[0].isActive = false
        book.subjects.append(Subject(name: "另一个主体"))
        try LedgerEngine.validate(book)
        #expect(try LedgerEngine.balance(of: account.id, in: book).minorUnits == 900)
        #expect(throws: LedgerError.inactiveAccount) { try LedgerEngine.record(expense(20, account: account), in: book) }
        var edit = original
        edit.operationID = UUID()
        edit.note = "只修正历史备注"
        let changed = try LedgerEngine.replace(edit, expectedVersion: 1, in: book)
        #expect(try LedgerEngine.balance(of: account.id, in: changed).minorUnits == 900)
        book.accounts[0].isActive = true
        var invalidSubject = expense(20, account: account)
        #expect(throws: LedgerError.invalidSubject) { try LedgerEngine.record(invalidSubject, in: book) }
        invalidSubject.subjectID = book.subjects[1].id
        #expect(throws: LedgerError.invalidCategory) { try LedgerEngine.record(invalidSubject, in: book) }
    }

    @Test(arguments: [EntryKind.expense, EntryKind.income])
    func topLevelCategoryWithoutChildrenCannotBeUsedForRecordingEditingOrRestore(_ kind: EntryKind) throws {
        let account = Account(name: "现金", openingMinor: 1_000)
        let unusedTopLevel = Category(name: "没有子类的一级分类", direction: kind)
        var book = LedgerBook(accounts: [account])
        book.categories.append(unusedTopLevel)
        // Empty top-level groups are valid catalog data, but never selectable transaction categories.
        try LedgerEngine.validate(book)
        let original = kind == .expense ? expense(100, account: account) : income(100, account: account)
        var invalid = original
        invalid.categoryID = unusedTopLevel.id
        #expect(throws: LedgerError.invalidCategory) { try LedgerEngine.record(invalid, in: book) }

        let saved = try LedgerEngine.record(original, in: book)
        invalid.operationID = UUID()
        #expect(throws: LedgerError.invalidCategory) {
            try LedgerEngine.replace(invalid, expectedVersion: 1, in: saved)
        }
        #expect(saved.entries == [original])
        #expect(saved.retiredOperationIDs.isEmpty)

        var brokenRestore = book
        brokenRestore.entries = [invalid]
        #expect(throws: LedgerError.invalidCategory) { try LedgerEngine.validate(brokenRestore) }
    }

    @Test func validationRejectsBrokenRestoredState() throws {
        let account = Account(name: "现金")
        #expect(throws: LedgerError.duplicateID) { try LedgerEngine.validate(LedgerBook(accounts: [account, account])) }
        var book = LedgerBook(accounts: [account])
        book.categories[1].parentID = UUID()
        #expect(throws: LedgerError.invalidCategory) { try LedgerEngine.validate(book) }
        book = LedgerBook(accounts: [account])
        book.categories[0].parentID = book.categories[1].id
        #expect(throws: LedgerError.invalidCategory) { try LedgerEngine.validate(book) }
        book = LedgerBook(accounts: [account])
        let entry = expense(10, account: account)
        book.entries = [entry]
        book.retiredOperationIDs = [entry.operationID]
        #expect(throws: LedgerError.operationConflict) { try LedgerEngine.validate(book) }
        book = LedgerBook(accounts: [account])
        book.adjustments = [BalanceAdjustment(accountID: UUID(), difference: Money(minorUnits: 1), target: Money(minorUnits: 1))]
        #expect(throws: LedgerError.accountNotFound) { try LedgerEngine.validate(book) }
    }

    @Test func checksBothBalanceAndConsumptionOverflowWithoutMutatingOriginal() throws {
        let maximum = Account(name: "最大", openingMinor: .max)
        let original = LedgerBook(accounts: [maximum])
        #expect(throws: LedgerError.overflow) { try LedgerEngine.record(income(1, account: maximum), in: original) }
        #expect(original.entries.isEmpty)
        let minimum = Account(name: "最小", openingMinor: .min)
        #expect(throws: LedgerError.overflow) { try LedgerEngine.record(expense(1, account: minimum), in: LedgerBook(accounts: [minimum])) }
        #expect(throws: LedgerError.overflow) {
            try LedgerEngine.adjustBalance(accountID: minimum.id, to: Money(minorUnits: .max), operationID: UUID(),
                                            at: day, note: "", in: LedgerBook(accounts: [minimum]))
        }
        let account = Account(name: "汇总边界")
        // Net balance fits, but the total of the expenses does not.
        let book = LedgerBook(accounts: [account], entries: [expense(.max, account: account), expense(1, account: account), income(.max, account: account)])
        #expect(try LedgerEngine.balance(of: account.id, in: book).minorUnits == -1)
        #expect(throws: LedgerError.overflow) { try consumed(book) }
        var reordered = book
        reordered.entries.reverse()
        #expect(try LedgerEngine.balance(of: account.id, in: reordered).minorUnits == -1)
    }

    @Test func rejectsInvalidAmountsDatesAndVersionOverflow() throws {
        let account = Account(name: "现金")
        let book = LedgerBook(accounts: [account])
        for amount: Int64 in [0, -1, .min] {
            #expect(throws: LedgerError.invalidAmount) { try LedgerEngine.record(expense(amount, account: account), in: book) }
        }
        var invalid = expense(1, account: account)
        invalid.occurredAt = Date(timeIntervalSinceReferenceDate: .infinity)
        #expect(throws: LedgerError.invalidAmount) { try LedgerEngine.record(invalid, in: book) }
        var lastVersion = expense(1, account: account)
        lastVersion.version = .max
        let restored = LedgerBook(accounts: [account], entries: [lastVersion])
        lastVersion.operationID = UUID()
        #expect(throws: LedgerError.overflow) {
            try LedgerEngine.replace(lastVersion, expectedVersion: .max, in: restored)
        }
    }

    @Test func adjustmentOperationsCannotCollideWithEntriesAndLiabilityAdjustmentUsesNormalBalance() throws {
        let card = Account(name: "信用卡", kind: .creditCard, nature: .liability, openingMinor: 5_000)
        let entry = expense(100, account: card)
        let saved = try LedgerEngine.record(entry, in: LedgerBook(accounts: [card]))
        #expect(throws: LedgerError.operationConflict) {
            try LedgerEngine.adjustBalance(accountID: card.id, to: Money(minorUnits: 1_000), operationID: entry.operationID,
                                            at: day, note: "", in: saved)
        }
        let adjusted = try LedgerEngine.adjustBalance(accountID: card.id, to: Money(minorUnits: 1_000), operationID: UUID(),
                                                      at: day, note: "", in: saved)
        #expect(adjusted.adjustments[0].difference.minorUnits == -4_100)
        #expect(try LedgerEngine.balance(of: card.id, in: adjusted).minorUnits == 1_000)
        #expect(try consumed(adjusted) == 100)
    }

    @Test func consumptionUsesHalfOpenDatesAndOnlyRequestedCurrency() throws {
        let cny = Account(name: "人民币")
        let hkd = Account(name: "港币", currency: .hkd)
        let book = LedgerBook(accounts: [cny, hkd], entries: [expense(100, account: cny),
            expense(200, account: cny, at: day.addingTimeInterval(100)), expense(300, account: hkd)])
        #expect(try LedgerEngine.consumption(in: book, from: day, to: day.addingTimeInterval(100), currency: .cny).minorUnits == 100)
        #expect(try LedgerEngine.consumption(in: book, from: day, to: day, currency: .cny).minorUnits == 0)
        #expect(try consumed(book, currency: .hkd) == 300)
        #expect(throws: LedgerError.unsupportedOperation) {
            try LedgerEngine.consumption(in: book, from: day.addingTimeInterval(1), to: day, currency: .cny)
        }
    }
}
