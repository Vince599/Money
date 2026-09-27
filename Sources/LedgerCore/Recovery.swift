import Foundation

public struct RecoverySummary: Equatable, Sendable {
    public let recovered: Money
    /// Negative means net recovery; presentation must label it explicitly.
    public let netCost: Money
    public let count: Int
}

public enum RecoveryRules {
    static func validate(_ book: LedgerBook) throws {
        _ = try summaries(in: book)
    }

    /// One linear pass over links; callers already validate ordinary entry/account fields.
    public static func summaries(in book: LedgerBook) throws -> [UUID: RecoverySummary] {
        var originals: [UUID: LedgerEntry] = [:]
        for entry in book.entries {
            guard originals.updateValue(entry, forKey: entry.id) == nil else { throw LedgerError.duplicateID }
        }
        var totals: [UUID: (amount: Int128, count: Int)] = [:]
        for entry in book.entries where entry.kind.isRecovery {
            guard let id = entry.originalEntryID, let original = originals[id], original.kind == .expense,
                  entry.occurredAt >= original.occurredAt,
                  entry.subjectID == original.subjectID else { throw LedgerError.invalidRecovery }
            guard entry.amount.currency == original.amount.currency else { throw LedgerError.currencyMismatch }
            guard entry.amount.minorUnits > 0 else { throw LedgerError.invalidAmount }
            var total = totals[id, default: (0, 0)]
            total.amount += Int128(entry.amount.minorUnits); total.count += 1
            totals[id] = total
        }
        var result: [UUID: RecoverySummary] = [:]
        for (id, total) in totals {
            let original = originals[id]!
            guard total.amount <= Int128(original.amount.minorUnits) || original.allowsNetRecovery == true else {
                throw LedgerError.excessRecoveryRequiresConfirmation
            }
            guard let recovered = Int64(exactly: total.amount),
                  let net = Int64(exactly: Int128(original.amount.minorUnits) - total.amount) else { throw LedgerError.overflow }
            result[id] = RecoverySummary(recovered: Money(minorUnits: recovered, currency: original.amount.currency),
                                         netCost: Money(minorUnits: net, currency: original.amount.currency), count: total.count)
        }
        return result
    }
}

public struct DeletionAccountImpact: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let before: Money
    public let after: Money
}

/// Exact preview of one deletion command. A changed group or affected balance requires a fresh preview.
public struct EntryDeletionPlan: Equatable, Sendable {
    public let entryID: UUID
    public let includesRecoveries: Bool
    public let entries: [LedgerEntry]
    public let accounts: [DeletionAccountImpact]
}

extension LedgerEngine {
    public static func deletionPlan(entryID: UUID, includingRecoveries: Bool = false,
                                    in book: LedgerBook) throws -> EntryDeletionPlan {
        try validate(book)
        guard let entry = book.entries.first(where: { $0.id == entryID }) else { throw LedgerError.entryNotFound }
        let children = book.entries.filter { $0.originalEntryID == entryID }
        guard children.isEmpty || includingRecoveries else { throw LedgerError.linkedEntriesExist }
        let entries = [entry] + children
        let ids = Set(entries.map(\.id))
        var after = book
        after.entries.removeAll { ids.contains($0.id) }
        after.retiredOperationIDs.formUnion(entries.map(\.operationID))
        try validate(after)
        let affected = Set(entries.flatMap { [$0.accountID, $0.destinationAccountID].compactMap { $0 } })
        let accounts = try book.accounts.filter { affected.contains($0.id) }.map { account in
            DeletionAccountImpact(id: account.id, before: try balance(of: account.id, in: book),
                                  after: try balance(of: account.id, in: after))
        }
        return EntryDeletionPlan(entryID: entryID, includesRecoveries: includingRecoveries, entries: entries, accounts: accounts)
    }

    public static func delete(_ plan: EntryDeletionPlan, in book: LedgerBook) throws -> LedgerBook {
        let current = try deletionPlan(entryID: plan.entryID, includingRecoveries: plan.includesRecoveries, in: book)
        guard current == plan else { throw LedgerError.staleVersion }
        let ids = Set(plan.entries.map(\.id))
        var result = book
        result.entries.removeAll { ids.contains($0.id) }
        result.retiredOperationIDs.formUnion(plan.entries.map(\.operationID))
        try validate(result)
        return result
    }
}
