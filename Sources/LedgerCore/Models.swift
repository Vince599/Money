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

public enum EntryKind: String, Codable, CaseIterable, Sendable {
    case expense, income, transfer, refund, recovery
    public var isRecovery: Bool { self == .refund || self == .recovery }
    public var needsCategory: Bool { self == .expense || self == .income }
    public var displayName: String {
        switch self {
        case .expense: "支出"
        case .income: "收入"
        case .transfer: "转账"
        case .refund: "退款"
        case .recovery: "出售回收"
        }
    }
}

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

public struct EntryTag: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var isActive: Bool
    public init(id: UUID = UUID(), name: String, isActive: Bool = true) {
        self.id = id; self.name = name; self.isActive = isActive
    }
}

public struct EntryProject: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var isArchived: Bool
    public init(id: UUID = UUID(), name: String, isArchived: Bool = false) {
        self.id = id; self.name = name; self.isArchived = isArchived
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
    public var tagIDs: [UUID]
    public var projectID: UUID?
    public var originalEntryID: UUID?
    /// Explicit purchase-level opt-in; nil in older records means disabled.
    public var allowsNetRecovery: Bool?
    public init(id: UUID = UUID(), operationID: UUID = UUID(), kind: EntryKind, amount: Money,
                accountID: UUID, destinationAccountID: UUID? = nil, categoryID: UUID? = nil,
                subjectID: UUID = SeedData.mpcID, occurredAt: Date = Date(), createdAt: Date = Date(),
                title: String = "", note: String = "", version: Int = 1,
                originalEntryID: UUID? = nil, allowsNetRecovery: Bool? = nil,
                tagIDs: [UUID] = [], projectID: UUID? = nil) {
        self.id = id; self.operationID = operationID; self.kind = kind; self.amount = amount
        self.accountID = accountID; self.destinationAccountID = destinationAccountID
        self.categoryID = categoryID; self.subjectID = subjectID; self.occurredAt = occurredAt
        self.createdAt = createdAt; self.title = title; self.note = note; self.version = version
        self.tagIDs = tagIDs; self.projectID = projectID
        self.originalEntryID = originalEntryID; self.allowsNetRecovery = allowsNetRecovery
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(UUID.self, forKey: .id)
        self.operationID = try values.decode(UUID.self, forKey: .operationID)
        self.kind = try values.decode(EntryKind.self, forKey: .kind)
        self.amount = try values.decode(Money.self, forKey: .amount)
        self.accountID = try values.decode(UUID.self, forKey: .accountID)
        self.destinationAccountID = try values.decodeIfPresent(UUID.self, forKey: .destinationAccountID)
        self.categoryID = try values.decodeIfPresent(UUID.self, forKey: .categoryID)
        self.subjectID = try values.decode(UUID.self, forKey: .subjectID)
        self.occurredAt = try values.decode(Date.self, forKey: .occurredAt)
        self.createdAt = try values.decode(Date.self, forKey: .createdAt)
        self.title = try values.decode(String.self, forKey: .title)
        self.note = try values.decode(String.self, forKey: .note)
        self.version = try values.decode(Int.self, forKey: .version)
        self.tagIDs = try values.decodeIfPresent([UUID].self, forKey: .tagIDs) ?? []
        self.projectID = try values.decodeIfPresent(UUID.self, forKey: .projectID)
        self.originalEntryID = try values.decodeIfPresent(UUID.self, forKey: .originalEntryID)
        self.allowsNetRecovery = try values.decodeIfPresent(Bool.self, forKey: .allowsNetRecovery)
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
    public var tags: [EntryTag]
    public var projects: [EntryProject]
    public var importBatches: [ImportBatch]
    public var importRules: [ImportRule]
    /// Consumed command identifiers only; deleted entry contents are not retained as a recycle bin.
    public var retiredOperationIDs: Set<UUID>
    public init(accounts: [Account] = [], entries: [LedgerEntry] = [], adjustments: [BalanceAdjustment] = [],
                subjects: [Subject] = SeedData.subjects, categories: [Category] = SeedData.categories,
                retiredOperationIDs: Set<UUID> = [], tags: [EntryTag] = [], projects: [EntryProject] = [], importBatches: [ImportBatch] = [], importRules: [ImportRule] = []) {
        self.accounts = accounts; self.entries = entries; self.adjustments = adjustments
        self.subjects = subjects; self.categories = categories
        self.retiredOperationIDs = retiredOperationIDs
        self.tags = tags; self.projects = projects; self.importBatches = importBatches; self.importRules = importRules
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.accounts = try values.decode([Account].self, forKey: .accounts)
        self.entries = try values.decode([LedgerEntry].self, forKey: .entries)
        self.adjustments = try values.decode([BalanceAdjustment].self, forKey: .adjustments)
        self.subjects = try values.decode([Subject].self, forKey: .subjects)
        self.categories = try values.decode([Category].self, forKey: .categories)
        self.tags = try values.decodeIfPresent([EntryTag].self, forKey: .tags) ?? []
        self.projects = try values.decodeIfPresent([EntryProject].self, forKey: .projects) ?? []
        self.importBatches = try values.decodeIfPresent([ImportBatch].self, forKey: .importBatches) ?? []
        self.importRules = try values.decodeIfPresent([ImportRule].self, forKey: .importRules) ?? []
        self.retiredOperationIDs = try values.decode(Set<UUID>.self, forKey: .retiredOperationIDs)
    }

}

public enum LedgerError: Error, Equatable, Sendable {
    case invalidAmount, overflow, currencyMismatch, accountNotFound, inactiveAccount
    case sameAccountTransfer, invalidCategory, invalidSubject, duplicateID, operationConflict
    case invalidAccount, entryNotFound, staleVersion, unsupportedOperation
    case invalidTag, invalidProject
    case invalidRecovery, linkedEntriesExist, excessRecoveryRequiresConfirmation
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
