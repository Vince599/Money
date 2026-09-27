import Foundation

public struct ImportRuleBatchReview: Sendable {
    public let batch: ImportBatch
    /// File order, irrespective of the order in which checkboxes were selected.
    public let rows: [ImportRuleReview]
    public let expectedBook: LedgerBook
}

public struct ImportRuleRowChange: Identifiable, Sendable {
    public var id: UUID { before.id }
    public let before: ImportRow
    public let after: ImportRow
    public let fields: [ImportRuleTargetField]
}

public struct ImportRuleBatchPlan: Sendable {
    public let batch: ImportBatch
    public let changes: [ImportRuleRowChange]
    public let expectedBook: LedgerBook
}

extension ImportRuleEngine {
    public static func reviewBatch(batchID: UUID, rowIDs: Set<UUID>, in book: LedgerBook) throws -> ImportRuleBatchReview {
        guard !rowIDs.isEmpty else { throw ImportError.unavailableRow }
        guard rowIDs.count <= 200 else { throw ImportError.tooManySelected }
        try LedgerEngine.validate(book)
        guard let batch = book.importBatches.first(where: { $0.id == batchID }), batch.revertedAt == nil else { throw ImportError.unavailableRow }
        let rows = batch.rows.filter { rowIDs.contains($0.id) }
        guard rows.count == rowIDs.count, rows.allSatisfy({ $0.state == .pending }) else { throw ImportError.unavailableRow }
        // Validate once; repeated row suggestions share the same copy-on-write snapshot.
        let reviews = rows.map { reviewValidated(row: $0, batch: batch, in: book) }
        return ImportRuleBatchReview(batch: batch, rows: reviews, expectedBook: book)
    }

    /// Opt-in convenience only. Never fills an existing mapping, even if only one rule matches.
    /// Any competing value excludes that field, including lower-priority competing rules.
    public static func unambiguousEmptySelections(_ review: ImportRuleBatchReview) -> [UUID: [ImportRuleTargetField: UUID]] {
        var result: [UUID: [ImportRuleTargetField: UUID]] = [:]
        for row in review.rows {
            for suggestion in row.suggestions where suggestion.currentID == nil && !suggestion.hasConflict {
                if let target = suggestion.preferredID { result[row.rowID, default: [:]][suggestion.id] = target }
            }
        }
        return result
    }

    public static func prepareBatch(_ review: ImportRuleBatchReview, selections: [UUID: [ImportRuleTargetField: UUID]]) throws -> ImportRuleBatchPlan {
        let reviewed = Dictionary(uniqueKeysWithValues: review.rows.map { ($0.rowID, $0) })
        guard Set(selections.keys).isSubset(of: Set(reviewed.keys)) else { throw ImportError.unavailableRow }
        var batch = review.batch
        var changes: [ImportRuleRowChange] = []
        for index in batch.rows.indices {
            let before = batch.rows[index]
            guard let fields = selections[before.id], !fields.isEmpty, let rowReview = reviewed[before.id] else { continue }
            // Use the same selection validation as the single-row review.
            let after = try applying(fields, to: before, review: rowReview)
            let changedFields = ImportRuleTargetField.allCases.filter { $0.value(in: before) != $0.value(in: after) }
            if !changedFields.isEmpty {
                batch.rows[index] = after
                changes.append(ImportRuleRowChange(before: before, after: after, fields: changedFields))
            }
        }
        guard !changes.isEmpty else { throw ImportError.invalidFile("没有实际修改，请选择要采用的不同值。") }
        return ImportRuleBatchPlan(batch: batch, changes: changes, expectedBook: review.expectedBook)
    }

    public static func applyBatch(_ plan: ImportRuleBatchPlan, in book: LedgerBook) throws -> LedgerBook {
        guard book == plan.expectedBook else { throw ImportError.stalePreview }
        return try ImportEngine.save(plan.batch, in: book, expectedVersion: plan.batch.version)
    }
}
