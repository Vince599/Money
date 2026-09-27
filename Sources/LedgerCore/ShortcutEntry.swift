import Foundation

/// Validated shortcut input. Creating a draft never changes the book or an existing saved draft.
/// Keep the same request when retrying a save so the ledger can recognize its operation ID.
public struct ShortcutEntryRequest: Equatable, Sendable {
    public var entryID: UUID
    public var operationID: UUID
    public var kind: EntryKind
    public var amountText: String?
    public var accountID: UUID?
    public var destinationAccountID: UUID?
    public var categoryID: UUID?
    public var subjectID: UUID?
    public var occurredAt: Date
    public var title: String
    public var note: String

    public init(entryID: UUID = UUID(), operationID: UUID = UUID(), kind: EntryKind = .expense,
                amountText: String? = nil, accountID: UUID? = nil, destinationAccountID: UUID? = nil,
                categoryID: UUID? = nil, subjectID: UUID? = nil, occurredAt: Date = Date(),
                title: String = "", note: String = "") {
        self.entryID = entryID; self.operationID = operationID; self.kind = kind
        self.amountText = amountText; self.accountID = accountID; self.destinationAccountID = destinationAccountID
        self.categoryID = categoryID; self.subjectID = subjectID; self.occurredAt = occurredAt
        self.title = title; self.note = note
    }

    /// Missing fields stay available for review. Direct saves must also call `EntryDraft.entry`
    /// and the repository's normal validated ledger mutation path.
    public func makeDraft(in book: LedgerBook, settings: LedgerSettings = LedgerSettings()) throws -> EntryDraft {
        guard !kind.isRecovery else { throw LedgerError.unsupportedOperation }
        guard occurredAt.timeIntervalSinceReferenceDate.isFinite else { throw ShortcutEntryError.invalidDate }
        if kind != .transfer, destinationAccountID != nil { throw ShortcutEntryError.destinationNotAllowed }
        if kind == .transfer, categoryID != nil { throw ShortcutEntryError.categoryNotAllowed }

        // A supplied ID (including a configured default) must not silently select a different entity.
        let selectedAccountID = accountID ?? settings.defaultAccountID
        let account = try selectedAccountID.map { id in
            guard let account = book.accounts.first(where: { $0.id == id }), account.isActive else {
                throw ShortcutEntryError.accountUnavailable
            }
            return account
        }
        let destination = try destinationAccountID.map { id in
            guard let account = book.accounts.first(where: { $0.id == id }), account.isActive else {
                throw ShortcutEntryError.destinationUnavailable
            }
            return account
        }
        if let account, let destination {
            guard account.id != destination.id else { throw ShortcutEntryError.sameAccountTransfer }
            guard account.currency == destination.currency else { throw ShortcutEntryError.currencyMismatch }
        }

        let selectedSubjectID = subjectID ?? settings.defaultSubjectID
        guard book.subjects.contains(where: { $0.id == selectedSubjectID && $0.isActive }) else {
            throw ShortcutEntryError.subjectUnavailable
        }
        if let categoryID {
            guard let category = book.categories.first(where: { $0.id == categoryID }),
                  category.isActive, category.direction == kind,
                  let parentID = category.parentID,
                  let parent = book.categories.first(where: { $0.id == parentID }),
                  parent.isActive, parent.parentID == nil, parent.direction == kind,
                  !book.categories.contains(where: { $0.parentID == categoryID }) else {
                throw ShortcutEntryError.categoryUnavailable
            }
        }

        var normalizedAmount = ""
        if let amountText {
            do {
                // Shortcuts accept decimal cash only. Expressions and excess decimals must not round.
                let amount = try Money.parse(amountText, currency: account?.currency ?? destination?.currency ?? .cny)
                guard amount.minorUnits > 0 else { throw ShortcutEntryError.invalidAmount }
                normalizedAmount = amount.decimalString
            } catch LedgerError.overflow {
                throw ShortcutEntryError.amountOverflow
            } catch {
                throw ShortcutEntryError.invalidAmount
            }
        }

        return EntryDraft(entryID: entryID, operationID: operationID, kind: kind,
                          amountText: normalizedAmount, accountID: account?.id,
                          destinationAccountID: destination?.id, subjectID: selectedSubjectID,
                          expenseCategoryID: kind == .expense ? categoryID : nil,
                          incomeCategoryID: kind == .income ? categoryID : nil,
                          occurredAt: occurredAt, title: title, note: note)
    }
}

public enum ShortcutEntryError: Error, Equatable, LocalizedError, Sendable {
    case invalidAmount, amountOverflow, accountUnavailable, destinationUnavailable
    case subjectUnavailable, categoryUnavailable, destinationNotAllowed, categoryNotAllowed
    case sameAccountTransfer, currencyMismatch, invalidDate

    public var errorDescription: String? {
        switch self {
        case .invalidAmount: "请输入大于 0 的金额，最多保留两位小数，不支持算式。"
        case .amountOverflow: "金额超出可记账范围，请减小金额。"
        case .accountUnavailable: "所选账户或默认账户已停用或不存在，请重新选择。"
        case .destinationUnavailable: "转入账户已停用或不存在，请重新选择。"
        case .subjectUnavailable: "所选主体或默认主体已停用或不存在，请重新选择。"
        case .categoryUnavailable: "请选择与收支类型一致且已启用的二级分类。"
        case .destinationNotAllowed: "只有转账可以指定转入账户。"
        case .categoryNotAllowed: "转账不需要收支分类，请移除分类。"
        case .sameAccountTransfer: "转出账户和转入账户不能相同。"
        case .currencyMismatch: "快捷指令转账仅支持相同币种的账户。"
        case .invalidDate: "记账日期无效，请重新选择。"
        }
    }
}
