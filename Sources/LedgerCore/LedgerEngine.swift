import Foundation

/// The single source of account arithmetic. Mutations return a fully validated new value.
public enum LedgerEngine {
    public static func balance(of accountID: UUID, in book: LedgerBook) throws -> Money {
        guard let result = try validatedBalances(in: book)[accountID] else {
            throw LedgerError.accountNotFound
        }
        return result
    }

    public static func record(_ entry: LedgerEntry, in book: LedgerBook) throws -> LedgerBook {
        try validate(book)
        guard !book.retiredOperationIDs.contains(entry.operationID) else { throw LedgerError.operationConflict }
        if let existing = book.entries.first(where: { $0.operationID == entry.operationID }) {
            var retry = entry
            retry.id = existing.id
            retry.createdAt = existing.createdAt
            guard existing == retry else { throw LedgerError.operationConflict }
            return book
        }
        guard !book.adjustments.contains(where: { $0.operationID == entry.operationID }) else {
            throw LedgerError.operationConflict
        }
        guard !book.entries.contains(where: { $0.id == entry.id }),
              !book.adjustments.contains(where: { $0.id == entry.id }) else { throw LedgerError.duplicateID }
        guard entry.version == 1 else { throw LedgerError.staleVersion }
        try checkEntry(entry, in: book)
        try checkActiveReferences(entry, replacing: nil, in: book)
        var result = book
        result.entries.append(entry)
        try validate(result)
        return result
    }

    public static func replace(_ entry: LedgerEntry, expectedVersion: Int, in book: LedgerBook) throws -> LedgerBook {
        try validate(book)
        guard let index = book.entries.firstIndex(where: { $0.id == entry.id }) else {
            throw LedgerError.entryNotFound
        }
        let existing = book.entries[index]
        guard expectedVersion > 0, entry.version == expectedVersion else { throw LedgerError.staleVersion }
        let increment = expectedVersion.addingReportingOverflow(1)
        guard !increment.overflow else { throw LedgerError.overflow }
        var replacement = entry
        replacement.version = increment.partialValue
        replacement.createdAt = existing.createdAt
        // A response may have been lost after a successful edit. Retrying it must not increment again.
        if existing.version == replacement.version, existing == replacement { return book }
        guard existing.version == expectedVersion else { throw LedgerError.staleVersion }
        guard entry.operationID != existing.operationID,
              !book.retiredOperationIDs.contains(entry.operationID),
              !book.entries.contains(where: { $0.id != entry.id && $0.operationID == entry.operationID }),
              !book.adjustments.contains(where: { $0.operationID == entry.operationID }) else {
            throw LedgerError.operationConflict
        }
        try checkEntry(replacement, in: book)
        try checkActiveReferences(replacement, replacing: existing, in: book)
        var result = book
        result.retiredOperationIDs.insert(existing.operationID)
        result.entries[index] = replacement
        try validate(result)
        return result
    }

    public static func delete(entryID: UUID, in book: LedgerBook) throws -> LedgerBook {
        try validate(book)
        guard let existing = book.entries.first(where: { $0.id == entryID }) else { return book }
        var result = book
        result.retiredOperationIDs.insert(existing.operationID)
        result.entries.removeAll { $0.id == entryID }
        try validate(result)
        return result
    }

    public static func adjustBalance(accountID: UUID, to target: Money, operationID: UUID,
                                     at date: Date, note: String, in book: LedgerBook) throws -> LedgerBook {
        let balances = try validatedBalances(in: book)
        guard !book.retiredOperationIDs.contains(operationID) else { throw LedgerError.operationConflict }
        if let existing = book.adjustments.first(where: { $0.operationID == operationID }) {
            guard existing.accountID == accountID, existing.target == target,
                  existing.occurredAt == date, existing.note == note else { throw LedgerError.operationConflict }
            return book
        }
        guard !book.entries.contains(where: { $0.operationID == operationID }) else {
            throw LedgerError.operationConflict
        }
        guard let current = balances[accountID], let account = book.accounts.first(where: { $0.id == accountID }) else {
            throw LedgerError.accountNotFound
        }
        guard account.isActive else { throw LedgerError.inactiveAccount }
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw LedgerError.invalidAccount }
        let difference = try target.subtracting(current)
        var result = book
        result.adjustments.append(BalanceAdjustment(operationID: operationID, accountID: accountID,
                                                    difference: difference, target: target, occurredAt: date, note: note))
        try validate(result)
        return result
    }

    public static func validate(_ book: LedgerBook) throws {
        _ = try validatedBalances(in: book)
    }

    /// Periods are half-open: `from <= occurredAt < to`. Transfers and adjustments never consume budget.
    public static func consumption(in book: LedgerBook, from: Date, to: Date, currency: Currency) throws -> Money {
        try validate(book)
        guard from.timeIntervalSinceReferenceDate.isFinite, to.timeIntervalSinceReferenceDate.isFinite,
              from <= to else { throw LedgerError.unsupportedOperation }
        var total: Int128 = 0
        for entry in book.entries where entry.kind == .expense && entry.amount.currency == currency
            && entry.occurredAt >= from && entry.occurredAt < to {
            total += Int128(entry.amount.minorUnits)
        }
        return try money(total, currency: currency)
    }

    /// Validates the book once, then derives all home-page values from the same balances and entries.
    /// Included accounts contribute even when inactive; all entries remain eligible for consumption and recency.
    /// Aggregate overflow is local to a currency or consumption, while an invalid book still throws.
    public static func homeSummary(in book: LedgerBook, from: Date, to: Date) throws -> HomeSummary {
        let balances = try validatedBalances(in: book)
        guard from.timeIntervalSinceReferenceDate.isFinite, to.timeIntervalSinceReferenceDate.isFinite,
              from <= to else { throw LedgerError.unsupportedOperation }

        var totalsByCurrency: [Currency: (assets: Int128, liabilities: Int128)] = [:]
        for account in book.accounts where account.includedInSummary {
            guard let balance = balances[account.id] else { throw LedgerError.accountNotFound }
            var totals = totalsByCurrency[account.currency, default: (0, 0)]
            if account.nature == .asset { totals.assets += Int128(balance.minorUnits) }
            else { totals.liabilities += Int128(balance.minorUnits) }
            totalsByCurrency[account.currency] = totals
        }
        let currencySummaries = Currency.allCases.compactMap { currency -> HomeSummary.CurrencySummary? in
            guard let totals = totalsByCurrency[currency] else { return nil }
            let amounts = try? HomeSummary.AccountTotals(
                assets: money(totals.assets, currency: currency),
                liabilities: money(totals.liabilities, currency: currency),
                netAsset: money(totals.assets - totals.liabilities, currency: currency)
            )
            return HomeSummary.CurrencySummary(currency: currency, totals: amounts)
        }

        var consumption: Int128 = 0
        var recentEntries: [LedgerEntry] = []
        recentEntries.reserveCapacity(5)
        for entry in book.entries {
            if entry.kind == .expense, entry.amount.currency == .cny,
               entry.occurredAt >= from, entry.occurredAt < to {
                consumption += Int128(entry.amount.minorUnits)
            }
            // A bounded insertion list avoids sorting the entire book. Strict comparison leaves
            // entries with identical occurrence and creation dates in their original array order.
            let insertionIndex = recentEntries.firstIndex { existing in
                entry.occurredAt == existing.occurredAt
                    ? entry.createdAt > existing.createdAt
                    : entry.occurredAt > existing.occurredAt
            } ?? recentEntries.count
            if insertionIndex < 5 {
                if recentEntries.count == 5 { recentEntries.removeLast() }
                recentEntries.insert(entry, at: insertionIndex)
            }
        }
        return HomeSummary(currencySummaries: currencySummaries,
                           monthlyConsumption: try? money(consumption, currency: .cny),
                           recentEntries: recentEntries)
    }

    // Int128 aggregation avoids order-dependent overflow when large debits and credits offset.
    // Stored amounts and public balances still have the checked Int64 cash boundary.
    private static func money(_ value: Int128, currency: Currency) throws -> Money {
        guard let minor = Int64(exactly: value) else { throw LedgerError.overflow }
        return Money(minorUnits: minor, currency: currency)
    }

    private static func unique(_ ids: [UUID]) throws {
        guard Set(ids).count == ids.count else { throw LedgerError.duplicateID }
    }

    private static func validatedBalances(in book: LedgerBook) throws -> [UUID: Money] {
        try unique(book.accounts.map(\.id))
        try unique(book.subjects.map(\.id))
        try unique(book.categories.map(\.id))
        try unique(book.entries.map(\.id) + book.adjustments.map(\.id))
        let operations = book.entries.map(\.operationID) + book.adjustments.map(\.operationID)
        guard Set(operations).count == operations.count,
              book.retiredOperationIDs.isDisjoint(with: operations) else { throw LedgerError.operationConflict }
        guard book.subjects.contains(where: \.isActive),
              book.subjects.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw LedgerError.invalidSubject
        }
        let categories = Dictionary(uniqueKeysWithValues: book.categories.map { ($0.id, $0) })
        for category in book.categories {
            guard category.direction != .transfer,
                  !category.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LedgerError.invalidCategory
            }
            if let parentID = category.parentID {
                guard parentID != category.id, let parent = categories[parentID], parent.parentID == nil,
                      parent.direction == category.direction else { throw LedgerError.invalidCategory }
            }
        }
        let accounts = Dictionary(uniqueKeysWithValues: book.accounts.map { ($0.id, $0) })
        var balances: [UUID: Int128] = [:]
        for account in book.accounts {
            guard !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  account.openingDate.timeIntervalSinceReferenceDate.isFinite else { throw LedgerError.invalidAccount }
            balances[account.id] = Int128(account.openingMinor)
        }
        for entry in book.entries {
            try checkEntry(entry, in: book)
            try apply(postings(for: entry), accounts: accounts, balances: &balances)
        }
        for adjustment in book.adjustments {
            guard let account = accounts[adjustment.accountID] else { throw LedgerError.accountNotFound }
            guard adjustment.difference.currency == account.currency, adjustment.target.currency == account.currency else {
                throw LedgerError.currencyMismatch
            }
            guard adjustment.occurredAt.timeIntervalSinceReferenceDate.isFinite else { throw LedgerError.invalidAccount }
            let normalDebit = account.nature == .asset
            let delta = Int128(adjustment.difference.minorUnits)
            let signedDebit = normalDebit ? delta : -delta
            try apply([
                Posting(accountID: account.id, signedDebit: signedDebit, currency: account.currency),
                Posting(accountID: nil, signedDebit: -signedDebit, currency: account.currency)
            ], accounts: accounts, balances: &balances)
        }
        var result: [UUID: Money] = [:]
        for account in book.accounts {
            result[account.id] = try money(balances[account.id, default: 0], currency: account.currency)
        }
        return result
    }

    private static func checkEntry(_ entry: LedgerEntry, in book: LedgerBook) throws {
        guard entry.amount.minorUnits > 0 else { throw LedgerError.invalidAmount }
        guard entry.version > 0 else { throw LedgerError.staleVersion }
        guard entry.occurredAt.timeIntervalSinceReferenceDate.isFinite,
              entry.createdAt.timeIntervalSinceReferenceDate.isFinite else { throw LedgerError.invalidAmount }
        guard book.subjects.contains(where: { $0.id == entry.subjectID }) else { throw LedgerError.invalidSubject }
        guard let account = book.accounts.first(where: { $0.id == entry.accountID }) else { throw LedgerError.accountNotFound }
        guard account.currency == entry.amount.currency else { throw LedgerError.currencyMismatch }
        if entry.kind == .transfer {
            guard entry.categoryID == nil else { throw LedgerError.invalidCategory }
            guard let destinationID = entry.destinationAccountID,
                  let destination = book.accounts.first(where: { $0.id == destinationID }) else {
                throw LedgerError.accountNotFound
            }
            guard destinationID != account.id else { throw LedgerError.sameAccountTransfer }
            guard destination.currency == account.currency else { throw LedgerError.currencyMismatch }
        } else {
            guard entry.destinationAccountID == nil else { throw LedgerError.unsupportedOperation }
            guard let categoryID = entry.categoryID,
                  let category = book.categories.first(where: { $0.id == categoryID }),
                  category.parentID != nil,
                  category.direction == entry.kind,
                  !book.categories.contains(where: { $0.parentID == categoryID }) else { throw LedgerError.invalidCategory }
        }
    }

    private static func checkActiveReferences(_ entry: LedgerEntry, replacing previous: LedgerEntry?, in book: LedgerBook) throws {
        let previousAccounts = previous.map { Set([$0.accountID, $0.destinationAccountID].compactMap { $0 }) } ?? []
        let selectedAccounts = Set([entry.accountID, entry.destinationAccountID].compactMap { $0 })
        for id in selectedAccounts.subtracting(previousAccounts) {
            guard book.accounts.first(where: { $0.id == id })?.isActive == true else { throw LedgerError.inactiveAccount }
        }
        if previous?.subjectID != entry.subjectID {
            guard book.subjects.first(where: { $0.id == entry.subjectID })?.isActive == true else { throw LedgerError.invalidSubject }
        }
        if let categoryID = entry.categoryID, previous?.categoryID != categoryID {
            guard let category = book.categories.first(where: { $0.id == categoryID }), category.isActive else {
                throw LedgerError.invalidCategory
            }
            if let parentID = category.parentID {
                guard book.categories.first(where: { $0.id == parentID })?.isActive == true else { throw LedgerError.invalidCategory }
            }
        }
    }

    /// Non-account sides represent the event's income/expense/equity counter-entry.
    private struct Posting {
        var accountID: UUID?
        var signedDebit: Int128
        var currency: Currency
    }

    private static func postings(for entry: LedgerEntry) -> [Posting] {
        let amount = Int128(entry.amount.minorUnits)
        let currency = entry.amount.currency
        switch entry.kind {
        case .expense:
            return [Posting(accountID: entry.accountID, signedDebit: -amount, currency: currency),
                    Posting(accountID: nil, signedDebit: amount, currency: currency)]
        case .income:
            return [Posting(accountID: entry.accountID, signedDebit: amount, currency: currency),
                    Posting(accountID: nil, signedDebit: -amount, currency: currency)]
        case .transfer:
            return [Posting(accountID: entry.accountID, signedDebit: -amount, currency: currency),
                    Posting(accountID: entry.destinationAccountID, signedDebit: amount, currency: currency)]
        }
    }

    private static func apply(_ postings: [Posting], accounts: [UUID: Account], balances: inout [UUID: Int128]) throws {
        guard let currency = postings.first?.currency,
              postings.allSatisfy({ $0.currency == currency }),
              postings.reduce(Int128(0), { $0 + $1.signedDebit }) == 0 else { throw LedgerError.currencyMismatch }
        for posting in postings {
            guard let id = posting.accountID else { continue }
            guard let account = accounts[id] else { throw LedgerError.accountNotFound }
            guard account.currency == posting.currency else { throw LedgerError.currencyMismatch }
            let delta = account.nature == .asset ? posting.signedDebit : -posting.signedDebit
            balances[id, default: 0] += delta
        }
    }
}
