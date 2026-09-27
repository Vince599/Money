import Foundation
import Testing
@testable import LedgerCore

@Suite("LedgerCoreTests catalog editing")
struct CatalogEditorTests {
    private let day = Date(timeIntervalSince1970: 1_000_000)

    private func expense(accountID: UUID, subjectID: UUID = SeedData.mpcID,
                         categoryID: UUID = SeedData.mealsID) -> LedgerEntry {
        LedgerEntry(kind: .expense, amount: Money(minorUnits: 100), accountID: accountID,
                    categoryID: categoryID, subjectID: subjectID, occurredAt: day, createdAt: day)
    }

    private func fixture() throws -> (Account, LedgerBook) {
        let account = Account(name: "银行卡", openingMinor: 1_000, openingDate: day)
        return (account, try LedgerEngine.record(expense(accountID: account.id), in: LedgerBook(accounts: [account])))
    }

    @Test func ordinarySeedCatalogMatchesDocumentCountsAndGroupOrder() throws {
        let categories = SeedData.categories
        #expect(categories.count == 100)
        #expect(Set(categories.map(\.id)).count == 100)
        #expect(categories.allSatisfy { $0.isActive && !$0.symbol.isEmpty })
        #expect(categories.filter { $0.direction == .expense && $0.parentID == nil }.count == 15)
        #expect(categories.filter { $0.direction == .expense && $0.parentID != nil }.count == 70)
        #expect(categories.filter { $0.direction == .income && $0.parentID == nil }.count == 5)
        #expect(categories.filter { $0.direction == .income && $0.parentID != nil }.count == 10)
        let rootNames = categories.filter { $0.parentID == nil }.map(\.name)
        #expect(rootNames == ["餐饮", "交通", "居住", "购物", "数码设备", "通信", "医疗健康",
                              "教育学习", "休闲运动", "人情往来", "数字服务", "生活服务", "保险",
                              "财务费用", "其他支出", "工作收入", "经营收入", "资金收益", "赠与补助", "其他收入"])
        #expect(categories.filter { $0.parentID == SeedData.foodID }.map(\.name) == ["正餐", "外卖", "饮品", "零食", "食材", "水果"])
        #expect(categories.filter { $0.parentID == SeedData.transportID }.map(\.name) ==
                ["公交地铁", "打车", "火车", "机票", "燃油充电", "停车", "路桥费", "车辆养护"])
        #expect(categories.filter { $0.direction == .income && $0.parentID != nil }.map(\.name) ==
                ["工资", "奖金", "兼职劳务", "经营所得", "租金", "存款利息", "借出利息", "收礼", "补助", "其他明确收入"])
        #expect(!rootNames.contains { ["宠物", "育儿", "照护", "税费与行政"].contains($0) })
        try LedgerEngine.validate(LedgerBook())
    }

    @Test func seedIdentifiersPreserveExistingReferencesAndDoNotDependOnArrayPosition() throws {
        let expectations: [(UUID, String, UUID?)] = [
            (SeedData.foodID, "餐饮", nil), (SeedData.mealsID, "正餐", SeedData.foodID),
            (SeedData.transportID, "交通", nil), (SeedData.taxiID, "打车", SeedData.transportID),
            (SeedData.otherID, "其他支出", nil), (SeedData.otherExpenseID, "其他明确支出", SeedData.otherID),
            (SeedData.salaryID, "工作收入", nil), (SeedData.salaryIncomeID, "工资", SeedData.salaryID)
        ]
        for (id, name, parent) in expectations {
            let category = try #require(SeedData.categories.first { $0.id == id })
            #expect(category.name == name)
            #expect(category.parentID == parent)
        }
        #expect(SeedData.categories.first { $0.name == "手机话费" }?.id == UUID(uuidString: "00000000-0000-4000-8000-000000001501"))
        #expect(SeedData.categories.first { $0.name == "其他明确收入" }?.id == UUID(uuidString: "00000000-0000-4000-8000-000000002401"))
        #expect(SeedData.subjects == [Subject(id: SeedData.mpcID, name: "MPC")])
        let restored = try JSONDecoder().decode(LedgerBook.self, from: JSONEncoder().encode(LedgerBook()))
        #expect(restored.categories == SeedData.categories)
    }

    @Test func renamingCatalogRecordsLeavesHistoryAndBalanceUntouched() throws {
        let (account, original) = try fixture()
        var renamedAccount = account
        renamedAccount.name = "工资银行卡"
        renamedAccount.includedInSummary = false
        var result = try CatalogEditor.saveAccount(renamedAccount, in: original)
        var category = try #require(result.categories.first { $0.id == SeedData.mealsID })
        category.name = "三餐"
        category.symbol = "fork.knife.circle"
        result = try CatalogEditor.saveCategory(category, in: result)
        var subject = result.subjects[0]
        subject.name = "我"
        result = try CatalogEditor.saveSubject(subject, in: result)
        #expect(result.accounts.count == original.accounts.count)
        #expect(result.categories.count == original.categories.count)
        #expect(result.subjects.count == original.subjects.count)
        #expect(result.entries == original.entries)
        #expect(result.adjustments == original.adjustments)
        #expect(result.retiredOperationIDs == original.retiredOperationIDs)
        #expect(try LedgerEngine.balance(of: account.id, in: result).minorUnits == 900)
        #expect(try LedgerEngine.consumption(in: result, from: day, to: day.addingTimeInterval(1), currency: .cny).minorUnits == 100)
        #expect(original.accounts[0].name == "银行卡")
    }

    @Test func appearanceOnlyEditsPreserveIdentityHistoryAndBalance() throws {
        let (account, recorded) = try fixture()
        var original = try LedgerEngine.adjustBalance(accountID: account.id, to: Money(minorUnits: 850),
                                                      operationID: UUID(), at: day, note: "原有更正", in: recorded)
        original.retiredOperationIDs.insert(UUID())
        original.accounts[0].name = "用户自己的名字"
        original.accounts[0].includedInSummary = false
        original.accounts[0].isActive = false
        var appearance = original.accounts[0]
        appearance.institutionID = "future.institution"
        appearance.templateID = "future.template"
        appearance.iconID = "future.icon"

        let changed = try CatalogEditor.saveAccount(appearance, in: original)
        #expect(changed.accounts == [appearance])
        #expect(try LedgerEngine.balance(of: account.id, in: changed).minorUnits == 850)
        var withoutAppearanceChange = changed
        withoutAppearanceChange.accounts[0] = original.accounts[0]
        #expect(withoutAppearanceChange == original)
        var restoredAccount = changed.accounts[0]
        restoredAccount.institutionID = nil
        restoredAccount.templateID = nil
        restoredAccount.iconID = nil
        #expect(restoredAccount == original.accounts[0])
        #expect(try CatalogEditor.saveAccount(restoredAccount, in: changed) == original)
    }

    @Test func inactiveAccountPreservesHistoryAndCanBeReenabled() throws {
        let (account, original) = try fixture()
        var changed = account
        changed.isActive = false
        let disabled = try CatalogEditor.saveAccount(changed, in: original)
        #expect(disabled.entries == original.entries)
        #expect(try LedgerEngine.balance(of: account.id, in: disabled).minorUnits == 900)
        #expect(throws: LedgerError.inactiveAccount) {
            try LedgerEngine.record(expense(accountID: account.id), in: disabled)
        }
        changed.isActive = true
        let enabled = try CatalogEditor.saveAccount(changed, in: disabled)
        let recorded = try LedgerEngine.record(expense(accountID: account.id), in: enabled)
        #expect(try LedgerEngine.balance(of: account.id, in: recorded).minorUnits == 800)
    }

    @Test func existingAccountStructureAndOpeningCannotBeReinterpreted() throws {
        let (account, book) = try fixture()
        var variants: [Account] = []
        var changed = account; changed.kind = .wallet; variants.append(changed)
        changed = account; changed.nature = .liability; variants.append(changed)
        changed = account; changed.currency = .hkd; variants.append(changed)
        changed = account; changed.openingMinor += 1; variants.append(changed)
        changed = account; changed.openingDate = day.addingTimeInterval(1); variants.append(changed)
        for variant in variants {
            #expect(throws: CatalogError.immutableAccountFields) { try CatalogEditor.saveAccount(variant, in: book) }
        }
        #expect(book.accounts == [account])
        #expect(try LedgerEngine.balance(of: account.id, in: book).minorUnits == 900)
    }

    @Test func newAccountMayChooseItsStructureButMustBeValid() throws {
        let original = LedgerBook()
        let card = Account(name: "信用卡", kind: .creditCard, nature: .liability,
                           currency: .hkd, openingMinor: 25_000, openingDate: day)
        let added = try CatalogEditor.saveAccount(card, in: original)
        #expect(added.accounts == [card])
        #expect(try LedgerEngine.balance(of: card.id, in: added) == Money(minorUnits: 25_000, currency: .hkd))
        #expect(throws: LedgerError.invalidAccount) { try CatalogEditor.saveAccount(Account(name: " \n "), in: original) }
        #expect(original.accounts.isEmpty)
    }

    @Test func disablingParentDoesNotRewriteChildStateOrHistoricalEvents() throws {
        let (account, original) = try fixture()
        var parent = try #require(original.categories.first { $0.id == SeedData.foodID })
        parent.isActive = false
        let disabled = try CatalogEditor.saveCategory(parent, in: original)
        #expect(disabled.categories.first { $0.id == SeedData.mealsID }?.isActive == true)
        #expect(disabled.entries == original.entries)
        #expect(try LedgerEngine.balance(of: account.id, in: disabled).minorUnits == 900)
        #expect(throws: LedgerError.invalidCategory) {
            try LedgerEngine.record(expense(accountID: account.id), in: disabled)
        }
        parent.isActive = true
        let enabled = try CatalogEditor.saveCategory(parent, in: disabled)
        let recorded = try LedgerEngine.record(expense(accountID: account.id), in: enabled)
        #expect(recorded.entries.count == 2)
    }

    @Test func disablingChildRemainsIndependentWhenParentIsReenabled() throws {
        let (account, original) = try fixture()
        var child = try #require(original.categories.first { $0.id == SeedData.mealsID })
        child.isActive = false
        var result = try CatalogEditor.saveCategory(child, in: original)
        var parent = try #require(result.categories.first { $0.id == SeedData.foodID })
        parent.isActive = false
        result = try CatalogEditor.saveCategory(parent, in: result)
        parent.isActive = true
        result = try CatalogEditor.saveCategory(parent, in: result)
        #expect(result.categories.first { $0.id == child.id }?.isActive == false)
        #expect(throws: LedgerError.invalidCategory) { try LedgerEngine.record(expense(accountID: account.id), in: result) }
        child.isActive = true
        result = try CatalogEditor.saveCategory(child, in: result)
        #expect(try LedgerEngine.record(expense(accountID: account.id), in: result).entries.count == 2)
    }

    @Test func newChildNeedsActiveTopLevelParentWithMatchingDirection() throws {
        let original = LedgerBook()
        let parent = Category(name: "自建一级", direction: .expense)
        let withParent = try CatalogEditor.saveCategory(parent, in: original)
        let child = Category(name: "自建二级", parentID: parent.id, direction: .expense)
        let withChild = try CatalogEditor.saveCategory(child, in: withParent)
        #expect(withChild.categories.suffix(2).map(\.id) == [parent.id, child.id])
        for parentID in [UUID(), SeedData.mealsID, SeedData.salaryID] {
            let invalid = Category(name: "无效父类", parentID: parentID, direction: .expense)
            #expect(throws: CatalogError.invalidCategoryParent) { try CatalogEditor.saveCategory(invalid, in: original) }
        }
        var inactive = parent
        inactive.isActive = false
        let disabled = try CatalogEditor.saveCategory(inactive, in: withParent)
        #expect(throws: CatalogError.invalidCategoryParent) { try CatalogEditor.saveCategory(child, in: disabled) }
        #expect(throws: LedgerError.invalidCategory) {
            try CatalogEditor.saveCategory(Category(name: "转账不设分类", direction: .transfer), in: original)
        }
    }

    @Test func changingExistingCategoryStructureRequiresSeparateMigrationFlow() throws {
        let (_, book) = try fixture()
        let original = try #require(book.categories.first { $0.id == SeedData.mealsID })
        var moved = original
        moved.parentID = SeedData.otherID
        #expect(throws: CatalogError.immutableCategoryStructure) { try CatalogEditor.saveCategory(moved, in: book) }
        moved = original; moved.direction = .income
        #expect(throws: CatalogError.immutableCategoryStructure) { try CatalogEditor.saveCategory(moved, in: book) }
        moved = original; moved.parentID = nil
        #expect(throws: CatalogError.immutableCategoryStructure) { try CatalogEditor.saveCategory(moved, in: book) }
        moved = original; moved.name = "   "
        #expect(throws: LedgerError.invalidCategory) { try CatalogEditor.saveCategory(moved, in: book) }
        moved = original; moved.symbol = "   "
        #expect(throws: LedgerError.invalidCategory) { try CatalogEditor.saveCategory(moved, in: book) }
        #expect(book.categories.first { $0.id == original.id } == original)
    }

    @Test func lastActiveSubjectCannotBeDisabledButHistoricalSubjectCanBeRetainedInactive() throws {
        let (account, original) = try fixture()
        var mpc = original.subjects[0]
        mpc.isActive = false
        #expect(throws: CatalogError.lastActiveSubject) { try CatalogEditor.saveSubject(mpc, in: original) }
        let other = Subject(name: "LZY")
        let added = try CatalogEditor.saveSubject(other, in: original)
        let disabled = try CatalogEditor.saveSubject(mpc, in: added)
        #expect(disabled.entries == original.entries)
        #expect(disabled.subjects.count == 2)
        #expect(try LedgerEngine.balance(of: account.id, in: disabled).minorUnits == 900)
        #expect(throws: LedgerError.invalidSubject) {
            try LedgerEngine.record(expense(accountID: account.id), in: disabled)
        }
        #expect(try LedgerEngine.record(expense(accountID: account.id, subjectID: other.id), in: disabled).entries.count == 2)
        mpc.isActive = true
        let reenabled = try CatalogEditor.saveSubject(mpc, in: disabled)
        #expect(try LedgerEngine.record(expense(accountID: account.id), in: reenabled).entries.count == 2)
        #expect(throws: LedgerError.invalidSubject) { try CatalogEditor.saveSubject(Subject(name: " \n"), in: original) }
    }
}
