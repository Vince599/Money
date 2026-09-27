import Foundation

public enum ImportBatchScope: String, CaseIterable, Sendable { case all, open, reverted }

/// Temporary inspection conditions; never change import state or authorize a commit.
public struct ImportFilter: Equatable, Sendable {
    public var namespace: String?
    public var scope: ImportBatchScope
    public var state: ImportRowState?
    public var keyword: String
    public init(namespace: String? = nil, scope: ImportBatchScope = .all,
                state: ImportRowState? = nil, keyword: String = "") {
        self.namespace = namespace; self.scope = scope; self.state = state; self.keyword = keyword
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.namespace == rhs.namespace && lhs.scope == rhs.scope && lhs.state == rhs.state
            && lhs.keyword.utf8.elementsEqual(rhs.keyword.utf8)
    }
}

public struct ImportBatchMatch: Identifiable, Equatable, Sendable {
    public let batch: ImportBatch
    public let matchingRowCount: Int
    public var id: UUID { batch.id }
}

public enum ImportQuery {
    /// Reverse persisted batch order, matching the existing history list.
    public static func batches(in book: LedgerBook, matching filter: ImportFilter = ImportFilter()) -> [ImportBatchMatch] {
        book.importBatches.reversed().compactMap { batch in
            let count = rows(in: batch, matching: filter).count
            return count == 0 ? nil : ImportBatchMatch(batch: batch, matchingRowCount: count)
        }
    }
    /// AND conditions apply to the same row; source file order is preserved.
    /// Closed batches can contain historical pending rows, which remain read-only.
    public static func rows(in batch: ImportBatch, matching filter: ImportFilter = ImportFilter()) -> [ImportRow] {
        if let namespace = filter.namespace, namespace != batch.namespace { return [] }
        if filter.scope == .open && batch.revertedAt != nil { return [] }
        if filter.scope == .reverted && batch.revertedAt == nil { return [] }
        let keyword = filter.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        return batch.rows.filter { row in
            if let state = filter.state, row.state != state { return false }
            guard !keyword.isEmpty else { return true }
            guard row.raw.count == ImportCSV.header.count else { return false }
            return EntryQuery.containsKeyword(keyword, title: row.sourceID, note: row.title)
                || EntryQuery.containsKeyword(keyword, title: row.raw[9], note: "")
        }
    }
    /// Selection may only contain visible pending rows from an open batch.
    public static func selectableIDs(in batch: ImportBatch, matching filter: ImportFilter, limit: Int) -> Set<UUID> {
        guard batch.revertedAt == nil, limit > 0 else { return [] }
        return Set(rows(in: batch, matching: filter).prefix(limit).filter { $0.state == .pending }.prefix(200).map(\.id))
    }
}
