import Foundation

public struct LedgerSettings: Codable, Equatable, Sendable {
    public var defaultAccountID: UUID?
    public var defaultSubjectID: UUID
    public init(defaultAccountID: UUID? = nil, defaultSubjectID: UUID = SeedData.mpcID) {
        self.defaultAccountID = defaultAccountID; self.defaultSubjectID = defaultSubjectID
    }
}

/// An unfinished input is not a ledger event. Its stable operation ID survives an interrupted save.
public struct EntryDraft: Codable, Equatable, Sendable {
    public var entryID: UUID
    public var operationID: UUID
    public var kind: EntryKind
    public var amountText: String
    public var accountID: UUID?
    public var destinationAccountID: UUID?
    public var subjectID: UUID
    public var expenseCategoryID: UUID?
    public var incomeCategoryID: UUID?
    public var occurredAt: Date
    public var title: String
    public var note: String
    public var originalEntryID: UUID?
    public var allowsNetRecovery: Bool?
    public init(entryID: UUID = UUID(), operationID: UUID = UUID(), kind: EntryKind = .expense,
                amountText: String = "", accountID: UUID? = nil, destinationAccountID: UUID? = nil,
                subjectID: UUID = SeedData.mpcID, expenseCategoryID: UUID? = nil, incomeCategoryID: UUID? = nil,
                occurredAt: Date = Date(), title: String = "", note: String = "",
                originalEntryID: UUID? = nil, allowsNetRecovery: Bool? = nil) {
        self.entryID = entryID; self.operationID = operationID; self.kind = kind
        self.amountText = amountText; self.accountID = accountID; self.destinationAccountID = destinationAccountID
        self.subjectID = subjectID; self.expenseCategoryID = expenseCategoryID; self.incomeCategoryID = incomeCategoryID
        self.occurredAt = occurredAt; self.title = title; self.note = note
        self.originalEntryID = originalEntryID; self.allowsNetRecovery = allowsNetRecovery
    }
    public var categoryID: UUID? {
        get { kind == .expense ? expenseCategoryID : kind == .income ? incomeCategoryID : nil }
        set {
            switch kind {
            case .expense: expenseCategoryID = newValue
            case .income: incomeCategoryID = newValue
            case .transfer, .refund, .recovery: break
            }
        }
    }
    public func entry(in book: LedgerBook, createdAt: Date = Date()) throws -> LedgerEntry {
        guard let accountID, let account = book.accounts.first(where: { $0.id == accountID }) else {
            throw LedgerError.accountNotFound
        }
        let amount = try AmountExpression.evaluate(amountText, currency: account.currency).money
        guard amount.minorUnits > 0 else { throw LedgerError.invalidAmount }
        return LedgerEntry(id: entryID, operationID: operationID, kind: kind, amount: amount,
                           accountID: accountID, destinationAccountID: kind == .transfer ? destinationAccountID : nil,
                           categoryID: categoryID, subjectID: subjectID, occurredAt: occurredAt,
                           createdAt: createdAt, title: title, note: note,
                           originalEntryID: kind.isRecovery ? originalEntryID : nil,
                           allowsNetRecovery: kind == .expense ? allowsNetRecovery : nil)
    }
    public func nextEntry(at date: Date = Date()) -> EntryDraft {
        EntryDraft(kind: kind, accountID: accountID, subjectID: subjectID, occurredAt: date,
                   originalEntryID: kind.isRecovery ? originalEntryID : nil)
    }
}
