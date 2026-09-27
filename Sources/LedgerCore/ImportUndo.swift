import Foundation

public struct ImportUndoBlocker: Identifiable, Sendable {
    public let rowID: UUID
    public let entryID: UUID?
    public let reason: String
    public var id: String { rowID.uuidString + ":" + (entryID?.uuidString ?? "") + ":" + reason }
}
public struct ImportUndoPlan: Sendable {
    public let batchID: UUID
    public let entries: [LedgerEntry]
    public let mergedRows: [ImportRow]
    public let accounts: [DeletionAccountImpact]
    public let revertedAt: Date
    public let expectedBook: LedgerBook
}
public struct ImportUndoReview: Sendable {
    public let plan: ImportUndoPlan?
    public let blockers: [ImportUndoBlocker]
}

extension ImportEngine {
    /// Immutable source fields and finalized mappings reconstruct the initial v1 event.
    /// We never infer ownership just from an equal amount or a similar title.
    public static func reviewUndo(batchID: UUID, in book: LedgerBook, at date: Date = Date()) throws -> ImportUndoReview {
        try LedgerEngine.validate(book)
        guard BackupDates.isSupported(date), let batch = book.importBatches.first(where: { $0.id == batchID }) else { throw ImportError.invalidState }
        guard batch.revertedAt == nil else { throw ImportError.invalidFile("本批已撤销，不能再次撤销。") }
        let rows = batch.rows.filter { $0.state == .imported }
        let mergedRows = batch.rows.filter { $0.state == .merged }
        guard !rows.isEmpty || !mergedRows.isEmpty else { throw ImportError.invalidFile("本批没有已入账流水，无需撤销。") }
        var blockers: [ImportUndoBlocker] = [], entries: [LedgerEntry] = []
        let byID = Dictionary(uniqueKeysWithValues: book.entries.map { ($0.id, $0) })
        let children = Dictionary(grouping: book.entries.filter { $0.originalEntryID != nil }, by: { $0.originalEntryID! })
        for row in rows {
            guard let current = byID[row.id] else {
                blockers.append(ImportUndoBlocker(rowID: row.id, entryID: nil, reason: "原流水已被删除或缺失，不能按整批原状撤销。")); continue
            }
            if book.importBatches.contains(where: { other in other.id != batchID && other.rows.contains { $0.state == .merged && $0.mergedEntryID == row.id } }) {
                blockers.append(ImportUndoBlocker(rowID: row.id, entryID: row.id, reason: "存在其他批次合并的来源，请先单独解除来源或撤销相应来源批次。"))
            }
            if let original = try? originalEntry(row, batch: batch), current == original {
                entries.append(current)
            } else {
                blockers.append(ImportUndoBlocker(rowID: row.id, entryID: current.id, reason: "流水在导入后已编辑，或与原始入账内容不一致；请单独处理。"))
            }
            for child in children[row.id, default: []] {
                blockers.append(ImportUndoBlocker(rowID: row.id, entryID: child.id, reason: "存在关联退款／回收记录，请先处理关联；整批撤销不会删除后续收款。"))
            }
        }
        guard blockers.isEmpty else { return ImportUndoReview(plan: nil, blockers: blockers) }
        let after = try undoResult(batchID: batchID, entries: entries, at: date, in: book)
        let affected = Set(entries.flatMap { [$0.accountID, $0.destinationAccountID].compactMap { $0 } })
        let impacts = try book.accounts.filter { affected.contains($0.id) }.map {
            DeletionAccountImpact(id: $0.id, before: try LedgerEngine.balance(of: $0.id, in: book),
                                  after: try LedgerEngine.balance(of: $0.id, in: after))
        }
        return ImportUndoReview(plan: ImportUndoPlan(batchID: batchID, entries: entries, mergedRows: mergedRows, accounts: impacts, revertedAt: date, expectedBook: book), blockers: [])
    }

    public static func undo(_ plan: ImportUndoPlan, in book: LedgerBook) throws -> LedgerBook {
        // Plans can only be created after reviewing exact event identity and dependencies.
        let after = try undoResult(batchID: plan.batchID, entries: plan.entries, at: plan.revertedAt, in: plan.expectedBook)
        if book == after { return book } // Lost successful response: no second balance change.
        guard book == plan.expectedBook else { throw ImportError.stalePreview }
        return after
    }

    private static func undoResult(batchID: UUID, entries: [LedgerEntry], at date: Date, in book: LedgerBook) throws -> LedgerBook {
        var result = book
        guard let index = result.importBatches.firstIndex(where: { $0.id == batchID }),
              result.importBatches[index].revertedAt == nil, result.importBatches[index].version < Int.max,
              !entries.isEmpty || result.importBatches[index].rows.contains(where: { $0.state == .merged }) else { throw ImportError.invalidState }
        let ids = Set(entries.map(\.id))
        result.entries.removeAll { ids.contains($0.id) }
        result.retiredOperationIDs.formUnion(entries.map(\.operationID))
        for rowIndex in result.importBatches[index].rows.indices where ids.contains(result.importBatches[index].rows[rowIndex].id) || result.importBatches[index].rows[rowIndex].state == .merged {
            result.importBatches[index].rows[rowIndex].state = .reverted
        }
        result.importBatches[index].revertedAt = date
        result.importBatches[index].version += 1
        try LedgerEngine.validate(result)
        return result
    }
}
