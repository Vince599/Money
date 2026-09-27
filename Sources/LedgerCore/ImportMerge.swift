import Foundation

public enum ImportMergeField: String, CaseIterable, Sendable {
    case title, date, category, subject, note, tags, project
    public var name: String {
        switch self { case .title: "标题"; case .date: "日期"; case .category: "分类"; case .subject: "主体"; case .note: "备注"; case .tags: "标签"; case .project: "项目" }
    }
}
public struct ImportMergeReview: Sendable {
    public let batchID: UUID
    public let source: LedgerEntry
    public let target: LedgerEntry
    public let differences: [ImportMergeField]
    public let expectedBook: LedgerBook
}
public struct ImportMergePlan: Sendable { public let review: ImportMergeReview }
public struct ImportUnlinkPlan: Sendable {
    public let batchID: UUID
    public let rowID: UUID
    public let target: LedgerEntry
    public let expectedBook: LedgerBook
}

extension ImportEngine {
    public static func prepareUnlink(batchID: UUID, rowID: UUID, in book: LedgerBook) throws -> ImportUnlinkPlan {
        try LedgerEngine.validate(book)
        guard let batch = book.importBatches.first(where: { $0.id == batchID }), batch.revertedAt == nil,
              let row = batch.rows.first(where: { $0.id == rowID }), row.state == .merged,
              let target = book.entries.first(where: { $0.id == row.mergedEntryID }) else { throw ImportError.unavailableRow }
        return ImportUnlinkPlan(batchID: batchID, rowID: rowID, target: target, expectedBook: book)
    }
    public static func unlink(_ plan: ImportUnlinkPlan, in book: LedgerBook) throws -> LedgerBook {
        var result = plan.expectedBook
        guard let index = result.importBatches.firstIndex(where: { $0.id == plan.batchID }), result.importBatches[index].version < Int.max,
              let rowIndex = result.importBatches[index].rows.firstIndex(where: { $0.id == plan.rowID }) else { throw ImportError.invalidState }
        result.importBatches[index].rows[rowIndex].state = .unlinked
        result.importBatches[index].version += 1
        try LedgerEngine.validate(result)
        if book == result { return book }
        guard book == plan.expectedBook else { throw ImportError.stalePreview }
        return result
    }
    /// Only suggestions. Equal amount/day alone never authorizes a merge.
    public static func mergeCandidates(batchID: UUID, rowID: UUID, in book: LedgerBook, now: Date = Date()) throws -> [LedgerEntry] {
        try LedgerEngine.validate(book)
        let (batch, row) = try mergeSource(batchID: batchID, rowID: rowID, book: book)
        let source = try candidate(row, batch: batch, in: book, now: now)
        return book.entries.filter { compatibleMerge(source, $0) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    private static func mergeSource(batchID: UUID, rowID: UUID, book: LedgerBook) throws -> (ImportBatch, ImportRow) {
        guard let batch = book.importBatches.first(where: { $0.id == batchID }), batch.revertedAt == nil,
              let row = batch.rows.first(where: { $0.id == rowID }), row.state == .pending,
              !row.sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.unavailableRow }
        guard !book.retiredOperationIDs.contains(row.operationID), !book.entries.contains(where: { $0.id == row.id || $0.operationID == row.operationID }) else { throw ImportError.invalidState }
        for other in book.importBatches where other.namespace == batch.namespace {
            if other.rows.contains(where: { $0.id != row.id && $0.sourceID == row.sourceID && ($0.state == .imported || $0.state == .merged || (other.id == batchID && $0.state == .pending)) }) {
                throw ImportError.invalidFile("来源交易号已处理或本批重复，请先核对来源冲突。")
            }
        }
        return (batch, row)
    }
    private static func compatibleMerge(_ source: LedgerEntry, _ target: LedgerEntry) -> Bool {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return source.id != target.id && [.expense, .income, .transfer].contains(target.kind)
            && source.kind == target.kind && source.amount == target.amount && source.accountID == target.accountID
            && source.destinationAccountID == target.destinationAccountID
            && calendar.isDate(source.occurredAt, inSameDayAs: target.occurredAt)
    }
    public static func reviewMerge(batchID: UUID, rowID: UUID, entryID: UUID, in book: LedgerBook, now: Date = Date()) throws -> ImportMergeReview {
        try LedgerEngine.validate(book)
        let (batch, row) = try mergeSource(batchID: batchID, rowID: rowID, book: book)
        let source = try candidate(row, batch: batch, in: book, now: now)
        guard let target = book.entries.first(where: { $0.id == entryID }), compatibleMerge(source, target) else {
            throw ImportError.invalidFile("本入口只合并同日、同方向、同币种金额及相同账户的来源；差异资金记录需另行核对。")
        }
        let differences = ImportMergeField.allCases.filter { field in
            switch field {
            case .title: source.title != target.title
            case .date: source.occurredAt != target.occurredAt
            case .category: source.categoryID != target.categoryID
            case .subject: source.subjectID != target.subjectID
            case .note: source.note != target.note
            case .tags: source.tagIDs != target.tagIDs
            case .project: source.projectID != target.projectID
            }
        }
        return ImportMergeReview(batchID: batchID, source: source, target: target, differences: differences, expectedBook: book)
    }
    public static func prepareMerge(_ review: ImportMergeReview, keepExisting: Set<ImportMergeField>) throws -> ImportMergePlan {
        guard keepExisting == Set(review.differences) else { throw ImportError.invalidFile("请逐项确认差异保留已有流水的值；若需采用来源值，返回单独编辑后重新核对。") }
        return ImportMergePlan(review: review)
    }
    public static func merge(_ plan: ImportMergePlan, in book: LedgerBook) throws -> LedgerBook {
        let review = plan.review
        var result = review.expectedBook
        guard let index = result.importBatches.firstIndex(where: { $0.id == review.batchID }), result.importBatches[index].version < Int.max,
              let rowIndex = result.importBatches[index].rows.firstIndex(where: { $0.id == review.source.id }) else { throw ImportError.invalidState }
        result.importBatches[index].rows[rowIndex].state = .merged
        result.importBatches[index].rows[rowIndex].mergedEntryID = review.target.id
        result.importBatches[index].version += 1
        result.retiredOperationIDs.insert(review.source.operationID)
        try LedgerEngine.validate(result)
        if book == result { return book }
        guard book == review.expectedBook else { throw ImportError.stalePreview }
        return result
    }
}
