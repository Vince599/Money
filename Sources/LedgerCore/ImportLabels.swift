import Foundation

/// Explicit, transient actions. Keeping, adding, replacing and clearing are different operations.
public enum ImportTagChange: Equatable, Sendable {
    case keep, add([UUID]), remove([UUID]), replace([UUID]), clear
}
public enum ImportProjectChange: Equatable, Sendable {
    case keep, set(UUID), clear
}
public struct ImportLabelsPlan: Sendable {
    public let batch: ImportBatch
    public let rowIDs: Set<UUID>
    public let expectedBook: LedgerBook
}

extension ImportEngine {
    public static func prepareLabels(batchID: UUID, rowIDs: Set<UUID>, tags: ImportTagChange,
                                     project: ImportProjectChange, in book: LedgerBook) throws -> ImportLabelsPlan {
        guard let batch = book.importBatches.first(where: { $0.id == batchID }) else { throw ImportError.unavailableRow }
        return ImportLabelsPlan(batch: try changingLabels(in: batch, rowIDs: rowIDs, tags: tags, project: project, book: book),
                                rowIDs: rowIDs, expectedBook: book)
    }
    public static func commitLabels(_ plan: ImportLabelsPlan, in book: LedgerBook) throws -> LedgerBook {
        guard book == plan.expectedBook else { throw ImportError.stalePreview }
        return try save(plan.batch, in: book, expectedVersion: plan.batch.version)
    }
    /// Builds a preview without saving or posting. Persist it with the original batch version.
    /// Draft references are soft: removing unavailable references is always possible.
    public static func changingLabels(in batch: ImportBatch, rowIDs: Set<UUID>, tags: ImportTagChange,
                                      project: ImportProjectChange, book: LedgerBook) throws -> ImportBatch {
        try LedgerEngine.validate(book)
        guard let current = book.importBatches.first(where: { $0.id == batch.id }), current == batch else {
            throw ImportError.stalePreview
        }
        guard !rowIDs.isEmpty, rowIDs.isSubset(of: Set(batch.rows.filter { $0.state == .pending }.map(\.id))) else {
            throw ImportError.unavailableRow
        }
        guard rowIDs.count <= 200 else { throw ImportError.tooManySelected }
        switch tags {
        case .add(let ids), .replace(let ids):
            guard Set(ids).count == ids.count, ids.allSatisfy({ id in book.tags.contains { $0.id == id && $0.isActive } }) else {
                throw ImportError.invalidFile("只能添加启用的标签；请重新选择。")
            }
        case .keep, .remove, .clear: break
        }
        if case .set(let id) = project, !book.projects.contains(where: { $0.id == id && !$0.isArchived }) {
            throw ImportError.invalidFile("只能设置未归档的项目；请重新选择。")
        }
        var result = batch
        for index in result.rows.indices where rowIDs.contains(result.rows[index].id) {
            switch tags {
            case .keep: break
            case .add(let ids):
                let existing = result.rows[index].tagIDs
                result.rows[index].tagIDs = existing + ids.filter { !existing.contains($0) }
            case .remove(let ids): result.rows[index].tagIDs.removeAll { ids.contains($0) }
            case .replace(let ids): result.rows[index].tagIDs = ids
            case .clear: result.rows[index].tagIDs = []
            }
            switch project {
            case .keep: break
            case .set(let id): result.rows[index].projectID = id
            case .clear: result.rows[index].projectID = nil
            }
        }
        return result
    }
}
