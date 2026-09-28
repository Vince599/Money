import Foundation

public enum TagMatchMode: String, CaseIterable, Sendable { case all, any }
public enum EntryImportSourceMode: String, CaseIterable, Sendable { case all, linked, unlinked }

/// Transient list conditions. All populated conditions are combined with AND.
public struct EntryFilter: Equatable, Sendable {
    public var tagIDs: Set<UUID>
    public var tagMatch: TagMatchMode
    public var projectID: UUID?
    public var importSourceMode: EntryImportSourceMode
    public var importNamespace: String?
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
                from: Date? = nil, to: Date? = nil, tagIDs: Set<UUID> = [],
                tagMatch: TagMatchMode = .all, projectID: UUID? = nil,
                importSourceMode: EntryImportSourceMode = .all, importNamespace: String? = nil) {
        self.tagIDs = tagIDs; self.tagMatch = tagMatch; self.projectID = projectID
        self.importSourceMode = importSourceMode; self.importNamespace = importNamespace
        self.keyword = keyword; self.kind = kind; self.accountID = accountID
        self.categoryID = categoryID; self.subjectID = subjectID; self.currency = currency
        self.minimumMinor = minimumMinor; self.maximumMinor = maximumMinor
        self.from = from; self.to = to
    }

    public static func == (lhs: EntryFilter, rhs: EntryFilter) -> Bool {
        // String equality normalizes Unicode, but the literal search below does
        // not. Request identity must distinguish those different query bytes.
        lhs.keyword.utf8.elementsEqual(rhs.keyword.utf8)
            && lhs.tagIDs == rhs.tagIDs && lhs.tagMatch == rhs.tagMatch && lhs.projectID == rhs.projectID
            && lhs.importSourceMode == rhs.importSourceMode && lhs.importNamespace == rhs.importNamespace
            && lhs.kind == rhs.kind && lhs.accountID == rhs.accountID
            && lhs.categoryID == rhs.categoryID && lhs.subjectID == rhs.subjectID
            && lhs.currency == rhs.currency && lhs.minimumMinor == rhs.minimumMinor
            && lhs.maximumMinor == rhs.maximumMinor && lhs.from == rhs.from && lhs.to == rhs.to
    }
}

public enum EntryQueryError: Error, Equatable, Sendable {
    case invalidDateRange, invalidAmountRange, amountCurrencyRequired
}

/// Queries existing entries without changing their accounting effects or persisted state.
public enum EntryQuery {
    /// Only live provenance links participate; undo/unlink history never becomes a live source.
    /// Return IDs rather than rows so multiple sources cannot multiply amounts or page counts.
    public static func importSourceEntryIDs(in batches: [ImportBatch], namespace: String? = nil) -> Set<UUID> {
        var result: Set<UUID> = []
        for batch in batches where batch.revertedAt == nil && (namespace == nil || batch.namespace == namespace) {
            for row in batch.rows {
                if row.state == .imported { result.insert(row.id) }
                else if row.state == .merged, let id = row.mergedEntryID { result.insert(id) }
            }
        }
        return result
    }
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
        if filter.importSourceMode == .unlinked && filter.importNamespace != nil { return [] }
        let restrictSources = filter.importSourceMode != .all || filter.importNamespace != nil
        let sourceIDs = restrictSources ? importSourceEntryIDs(in: book.importBatches, namespace: filter.importNamespace) : []
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
            if restrictSources,
               filter.importSourceMode == .unlinked ? sourceIDs.contains(entry.id) : !sourceIDs.contains(entry.id) { return false }
            if let id = filter.projectID, entry.projectID != id { return false }
            if !filter.tagIDs.isEmpty {
                let tags = Set(entry.tagIDs)
                if filter.tagMatch == .all ? !filter.tagIDs.isSubset(of: tags) : filter.tagIDs.isDisjoint(with: tags) { return false }
            }
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
