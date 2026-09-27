import Foundation

public enum Currency: String, Codable, CaseIterable, Sendable {
    case cny = "CNY", hkd = "HKD", usd = "USD"
    public var fractionDigits: Int { 2 }
}

public enum AccountNature: String, Codable, CaseIterable, Sendable { case asset, liability }
public enum AccountKind: String, Codable, CaseIterable, Sendable {
    case bank, wallet, cash, storedValue, creditCard, brokerage, loan
}

public struct Account: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: AccountKind
    public var nature: AccountNature
    public var currency: Currency
    public var openingMinor: Int64
    public var openingDate: Date
    public var includedInSummary: Bool
    public var isActive: Bool
    public var institutionID: String?
    public var templateID: String?
    public var iconID: String?
    public init(id: UUID = UUID(), name: String, kind: AccountKind = .bank, nature: AccountNature = .asset,
                currency: Currency = .cny, openingMinor: Int64 = 0, openingDate: Date = Date(),
                includedInSummary: Bool = true, isActive: Bool = true,
                institutionID: String? = nil, templateID: String? = nil, iconID: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.nature = nature; self.currency = currency
        self.openingMinor = openingMinor; self.openingDate = openingDate
        self.includedInSummary = includedInSummary; self.isActive = isActive
        self.institutionID = institutionID; self.templateID = templateID; self.iconID = iconID
    }
}

public enum EntryKind: String, Codable, CaseIterable, Sendable { case expense, income, transfer }

public struct Subject: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var isActive: Bool
    public init(id: UUID = UUID(), name: String, isActive: Bool = true) {
        self.id = id; self.name = name; self.isActive = isActive
    }
}

public struct Category: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var parentID: UUID?
    public var direction: EntryKind
    public var symbol: String
    public var isActive: Bool
    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil, direction: EntryKind,
                symbol: String = "tag", isActive: Bool = true) {
        self.id = id; self.name = name; self.parentID = parentID; self.direction = direction
        self.symbol = symbol; self.isActive = isActive
    }
}

public struct LedgerEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var operationID: UUID
    public var kind: EntryKind
    public var amount: Money
    /// Expense/income account, or transfer source. A liability balance is positive when owed.
    public var accountID: UUID
    public var destinationAccountID: UUID?
    public var categoryID: UUID?
    public var subjectID: UUID
    public var occurredAt: Date
    public var createdAt: Date
    public var title: String
    public var note: String
    public var version: Int
    public init(id: UUID = UUID(), operationID: UUID = UUID(), kind: EntryKind, amount: Money,
                accountID: UUID, destinationAccountID: UUID? = nil, categoryID: UUID? = nil,
                subjectID: UUID = SeedData.mpcID, occurredAt: Date = Date(), createdAt: Date = Date(),
                title: String = "", note: String = "", version: Int = 1) {
        self.id = id; self.operationID = operationID; self.kind = kind; self.amount = amount
        self.accountID = accountID; self.destinationAccountID = destinationAccountID
        self.categoryID = categoryID; self.subjectID = subjectID; self.occurredAt = occurredAt
        self.createdAt = createdAt; self.title = title; self.note = note; self.version = version
    }
}

public struct BalanceAdjustment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var operationID: UUID
    public var accountID: UUID
    public var difference: Money
    public var target: Money
    public var occurredAt: Date
    public var note: String
    public init(id: UUID = UUID(), operationID: UUID = UUID(), accountID: UUID, difference: Money,
                target: Money, occurredAt: Date = Date(), note: String = "") {
        self.id = id; self.operationID = operationID; self.accountID = accountID
        self.difference = difference; self.target = target; self.occurredAt = occurredAt; self.note = note
    }
}

public struct LedgerBook: Codable, Equatable, Sendable {
    public var accounts: [Account]
    public var entries: [LedgerEntry]
    public var adjustments: [BalanceAdjustment]
    public var subjects: [Subject]
    public var categories: [Category]
    /// Consumed command identifiers only; deleted entry contents are not retained as a recycle bin.
    public var retiredOperationIDs: Set<UUID>
    public init(accounts: [Account] = [], entries: [LedgerEntry] = [], adjustments: [BalanceAdjustment] = [],
                subjects: [Subject] = SeedData.subjects, categories: [Category] = SeedData.categories,
                retiredOperationIDs: Set<UUID> = []) {
        self.accounts = accounts; self.entries = entries; self.adjustments = adjustments
        self.subjects = subjects; self.categories = categories
        self.retiredOperationIDs = retiredOperationIDs
    }
}

public enum LedgerError: Error, Equatable, Sendable {
    case invalidAmount, overflow, currencyMismatch, accountNotFound, inactiveAccount
    case sameAccountTransfer, invalidCategory, invalidSubject, duplicateID, operationConflict
    case invalidAccount, entryNotFound, staleVersion, unsupportedOperation
}

public enum SeedData {
    public static let mpcID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    public static let foodID = UUID(uuidString: "00000000-0000-4000-8000-000000000010")!
    public static let mealsID = UUID(uuidString: "00000000-0000-4000-8000-000000000011")!
    public static let transportID = UUID(uuidString: "00000000-0000-4000-8000-000000000020")!
    public static let taxiID = UUID(uuidString: "00000000-0000-4000-8000-000000000021")!
    public static let otherID = UUID(uuidString: "00000000-0000-4000-8000-000000000030")!
    public static let otherExpenseID = UUID(uuidString: "00000000-0000-4000-8000-000000000031")!
    public static let salaryID = UUID(uuidString: "00000000-0000-4000-8000-000000000040")!
    public static let salaryIncomeID = UUID(uuidString: "00000000-0000-4000-8000-000000000041")!
    public static let subjects = [Subject(id: mpcID, name: "MPC")]
    public static let categories = SeedCatalog.categories
}
