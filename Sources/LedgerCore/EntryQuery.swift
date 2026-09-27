import Foundation

/// Transient list conditions. All populated conditions are combined with AND.
public struct EntryFilter: Equatable, Sendable {
    public var keyword: String
    public var kind: EntryKind?
    public var accountID: UUID?
    public var categoryID: UUID?
    public var subjectID: UUID?
    public var currency: Currency?
    /// Inclusive bounds in the selected currency's smallest unit, without a direction sign.
    public var minimumMinor: Int64?
    public var maximumMinor: Int64?
    /// Occurrence interval: inclusive start and exclusive end.
    public var from: Date?
    public var to: Date?

    public init(keyword: String = "", kind: EntryKind? = nil, accountID: UUID? = nil,
                categoryID: UUID? = nil, subjectID: UUID? = nil, currency: Currency? = nil,
                minimumMinor: Int64? = nil, maximumMinor: Int64? = nil,
                from: Date? = nil, to: Date? = nil) {
        self.keyword = keyword; self.kind = kind; self.accountID = accountID
        self.categoryID = categoryID; self.subjectID = subjectID; self.currency = currency
        self.minimumMinor = minimumMinor; self.maximumMinor = maximumMinor
        self.from = from; self.to = to
    }
}

public enum EntryQueryError: Error, Equatable, Sendable {
    case invalidDateRange, invalidAmountRange, amountCurrencyRequired
}

/// Queries existing entries without changing their accounting effects or persisted state.
public enum EntryQuery {
    /// Shared by the in-memory reference query and SQLite's search function.
    /// Percent signs, underscores and quotes are ordinary text, never SQL patterns.
    public static func containsKeyword(_ keyword: String, title: String, note: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .literal]
        let locale = Locale(identifier: "en_US_POSIX")
        return title.range(of: keyword, options: options, locale: locale) != nil
            || note.range(of: keyword, options: options, locale: locale) != nil
    }
    public static func validate(_ filter: EntryFilter) throws {
        if let from = filter.from, !from.timeIntervalSinceReferenceDate.isFinite {
            throw EntryQueryError.invalidDateRange
        }
        if let to = filter.to, !to.timeIntervalSinceReferenceDate.isFinite {
            throw EntryQueryError.invalidDateRange
        }
        if let from = filter.from, let to = filter.to, from >= to {
            throw EntryQueryError.invalidDateRange
        }
        if let minimum = filter.minimumMinor, minimum < 0 {
            throw EntryQueryError.invalidAmountRange
        }
        if let maximum = filter.maximumMinor, maximum < 0 {
            throw EntryQueryError.invalidAmountRange
        }
        if let minimum = filter.minimumMinor, let maximum = filter.maximumMinor, minimum > maximum {
            throw EntryQueryError.invalidAmountRange
        }
        if (filter.minimumMinor != nil || filter.maximumMinor != nil), filter.currency == nil {
            throw EntryQueryError.amountCurrencyRequired
        }
    }

    /// A top-level category includes its direct children; a leaf matches only itself.
    /// An unknown category matches nothing. Inactive catalog records remain searchable.
    /// Transfer account matching includes either end, while returning the entry only once.
    public static func entries(in book: LedgerBook, matching filter: EntryFilter = EntryFilter()) throws -> [LedgerEntry] {
        try validate(filter)
        let keyword = filter.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let categoryIDs: Set<UUID>?
        if let categoryID = filter.categoryID {
            guard let category = book.categories.first(where: { $0.id == categoryID }) else { return [] }
            if category.parentID == nil {
                categoryIDs = Set(book.categories.lazy.filter { $0.parentID == categoryID }.map(\.id))
            } else {
                categoryIDs = [categoryID]
            }
        } else {
            categoryIDs = nil
        }
        return book.entries.filter { entry in
            if let kind = filter.kind, entry.kind != kind { return false }
            if let accountID = filter.accountID,
               entry.accountID != accountID && !(entry.kind == .transfer && entry.destinationAccountID == accountID) {
                return false
            }
            if let categoryIDs {
                guard let categoryID = entry.categoryID, categoryIDs.contains(categoryID) else { return false }
            }
            if let subjectID = filter.subjectID, entry.subjectID != subjectID { return false }
            if let currency = filter.currency, entry.amount.currency != currency { return false }
            if let minimum = filter.minimumMinor, entry.amount.minorUnits < minimum { return false }
            if let maximum = filter.maximumMinor, entry.amount.minorUnits > maximum { return false }
            if let from = filter.from, entry.occurredAt < from { return false }
            if let to = filter.to, entry.occurredAt >= to { return false }
            if !keyword.isEmpty {
                if !containsKeyword(keyword, title: entry.title, note: entry.note) { return false }
            }
            return true
        }.sorted { lhs, rhs in
            if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt > rhs.occurredAt }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
