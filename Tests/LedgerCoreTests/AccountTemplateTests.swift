import Foundation
import Testing
@testable import LedgerCore

@Suite("LedgerCoreTests account templates")
struct AccountTemplateTests {
    private let day = Date(timeIntervalSince1970: 1_000_000)

    @Test(arguments: ["工行", "ICBC", "icbc", "IcBc", "gongshang"])
    func searchFindsAnInstitutionByChineseOrCaseInsensitiveAlias(_ query: String) {
        let matches = AccountTemplateCatalog.search(query)
        #expect(matches.contains { $0.id == "cn.icbc.debit" })
        #expect(matches.contains { $0.id == "cn.icbc.credit" })
    }

    @Test func searchTrimsWhitespaceAndCombinesTermsWithAnOptionalGroup() {
        let debit = AccountTemplateCatalog.search(" \t工行\n", group: .bank)
        #expect(debit.contains { $0.id == "cn.icbc.debit" })
        #expect(debit.allSatisfy { $0.group == .bank })
        #expect(!debit.contains { $0.id == "cn.icbc.credit" })

        let credit = AccountTemplateCatalog.search("  ICBC\t信用卡 \n", group: .creditCard)
        #expect(credit.contains { $0.id == "cn.icbc.credit" })
        #expect(credit.allSatisfy { $0.group == .creditCard })
        #expect(AccountTemplateCatalog.search("工行 no-such-template-term").isEmpty)

        let browse = AccountTemplateCatalog.search(" \n\t", group: .wallet)
        #expect(browse.contains { $0.id == "cn.wechat-pay.balance" })
        #expect(browse.contains { $0.id == "cn.alipay.balance" })
        #expect(browse.allSatisfy { $0.group == .wallet })
        #expect(AccountTemplateCatalog.search(" \n\t") == AccountTemplateCatalog.search(""))
    }

    @Test func reusingATemplateCreatesDistinctUnsavedAccountsAndKeepsUserOpeningValues() throws {
        let template = try #require(AccountTemplateCatalog.template(id: "cn.icbc.debit"))
        let first = template.makeAccount(openingDate: day)
        let second = template.makeAccount(name: "工资卡 8899", openingMinor: 123_456,
                                          openingDate: day.addingTimeInterval(-86_400))

        #expect(first.id != second.id)
        #expect(first.name == template.name)
        #expect(first.openingMinor == 0)
        #expect(first.openingDate == day)
        #expect(second.name == "工资卡 8899")
        #expect(second.openingMinor == 123_456)
        #expect(second.openingDate == day.addingTimeInterval(-86_400))
        #expect(second.kind == .bank && second.nature == .asset && second.currency == .cny)
        #expect(second.isActive)
        try LedgerEngine.validate(LedgerBook(accounts: [first, second]))
    }

    @Test func phoneBalanceStaysOutsideSummaryAndCreditCardUsesLiabilityArithmetic() throws {
        let phoneTemplate = try #require(AccountTemplateCatalog.template(id: "cn.china-mobile.balance"))
        let creditTemplate = try #require(AccountTemplateCatalog.template(id: "cn.icbc.credit"))
        let phone = phoneTemplate.makeAccount(openingMinor: 5_000, openingDate: day)
        let credit = creditTemplate.makeAccount(openingMinor: 20_000, openingDate: day)

        #expect(phone.kind == .storedValue && phone.nature == .asset && phone.currency == .cny)
        #expect(!phone.includedInSummary)
        #expect(credit.kind == .creditCard && credit.nature == .liability && credit.currency == .cny)
        #expect(credit.includedInSummary)

        let book = LedgerBook(accounts: [phone, credit])
        try LedgerEngine.validate(book)
        let expense = LedgerEntry(kind: .expense, amount: Money(minorUnits: 1_000),
                                  accountID: credit.id, categoryID: SeedData.mealsID,
                                  occurredAt: day, createdAt: day)
        let updated = try LedgerEngine.record(expense, in: book)
        #expect(try LedgerEngine.balance(of: credit.id, in: updated).minorUnits == 21_000)
        #expect(try LedgerEngine.balance(of: phone.id, in: updated).minorUnits == 5_000)
    }

    @Test func compatibilityRejectsChangesToKindNatureOrCurrency() throws {
        let template = try #require(AccountTemplateCatalog.template(id: "cn.icbc.debit"))
        let account = template.makeAccount(openingDate: day)
        #expect(template.isCompatible(with: account))

        var differentKind = account
        differentKind.kind = .wallet
        #expect(!template.isCompatible(with: differentKind))
        var differentNature = account
        differentNature.nature = .liability
        #expect(!template.isCompatible(with: differentNature))
        var differentCurrency = account
        differentCurrency.currency = .hkd
        #expect(!template.isCompatible(with: differentCurrency))

        let credit = try #require(AccountTemplateCatalog.template(id: "cn.icbc.credit"))
        #expect(!credit.isCompatible(with: account))
    }

    @Test func selectingACompatibleTemplatePreservesExistingAccountAndHistory() throws {
        let template = try #require(AccountTemplateCatalog.template(id: "cn.icbc.debit"))
        var account = template.makeAccount(name: "我自己起的账户名", openingMinor: 90_000,
                                          openingDate: day)
        account.includedInSummary = false
        let expense = LedgerEntry(kind: .expense, amount: Money(minorUnits: 1_000),
                                  accountID: account.id, categoryID: SeedData.mealsID,
                                  occurredAt: day, createdAt: day)
        let book = try LedgerEngine.record(expense, in: LedgerBook(accounts: [account]))
        let snapshot = book

        let selected = try #require(AccountTemplateCatalog.search("ICBC", group: .bank)
            .first { $0.id == template.id && $0.isCompatible(with: account) })
        #expect(AccountTemplateCatalog.institution(id: "icbc") != nil)
        #expect(AccountTemplateCatalog.icon(id: selected.iconID) != nil)
        let unsaved = selected.makeAccount(openingDate: day)

        #expect(unsaved.id != account.id)
        #expect(book == snapshot)
        #expect(book.accounts == [account])
        #expect(!book.accounts.contains { $0.id == unsaved.id })
        #expect(try LedgerEngine.balance(of: account.id, in: book).minorUnits == 89_000)
        #expect(account.name == "我自己起的账户名")
        #expect(!account.includedInSummary)
    }
}
