import Foundation

public enum ImportRowState: String, Codable, Sendable { case pending, imported, skipped }

public struct ImportRow: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var operationID: UUID
    public var raw: [String]
    public var accountID: UUID?
    public var destinationAccountID: UUID?
    public var categoryID: UUID?
    public var subjectID: UUID
    public var state: ImportRowState
    public var duplicateReviewToken: String?
    public var tagIDs: [UUID] = []
    public var projectID: UUID?
    public init(id: UUID = UUID(), operationID: UUID = UUID(), raw: [String], subjectID: UUID = SeedData.mpcID) {
        self.id = id; self.operationID = operationID; self.raw = raw; self.subjectID = subjectID; self.state = .pending
    }
    public var sourceID: String { raw[0] }
    public var sourceAccount: String { raw[5] }
    public var title: String { raw[8].isEmpty ? raw[7] : raw[8] }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        operationID = try values.decode(UUID.self, forKey: .operationID)
        raw = try values.decode([String].self, forKey: .raw)
        accountID = try values.decodeIfPresent(UUID.self, forKey: .accountID)
        destinationAccountID = try values.decodeIfPresent(UUID.self, forKey: .destinationAccountID)
        categoryID = try values.decodeIfPresent(UUID.self, forKey: .categoryID)
        subjectID = try values.decode(UUID.self, forKey: .subjectID)
        state = try values.decode(ImportRowState.self, forKey: .state)
        duplicateReviewToken = try values.decodeIfPresent(String.self, forKey: .duplicateReviewToken)
        tagIDs = try values.decodeIfPresent([UUID].self, forKey: .tagIDs) ?? []
        projectID = try values.decodeIfPresent(UUID.self, forKey: .projectID)
    }
}

public struct ImportBatch: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var namespace: String
    public var createdAt: Date
    public var version: Int
    public var rows: [ImportRow]
    public var proposedAccounts: [Account]
    public init(id: UUID = UUID(), name: String, namespace: String, createdAt: Date = Date(), rows: [ImportRow], proposedAccounts: [Account] = []) {
        self.id = id; self.name = name; self.namespace = namespace; self.createdAt = createdAt
        self.version = 1; self.rows = rows; self.proposedAccounts = proposedAccounts
    }
}

public enum ImportRowReview: Equatable, Sendable {
    case ready
    case duplicate
    case conflict
    case similar(token: String, count: Int)
    case blocked(String)
    case finished
    public var explanation: String {
        switch self {
        case .ready: "可导入"
        case .duplicate: "同来源交易号已导入，原始内容一致；请确认跳过。"
        case .conflict: "同来源交易号内容冲突或本批重复，请核对；不能直接入账。"
        case .similar(_, let count): "发现 \(count) 笔同日、同账户、同方向、同金额流水，请核对是否为独立交易。"
        case .blocked(let reason): reason
        case .finished: "已处理"
        }
    }
}

/// Transient confirmation snapshot. Any intervening business edit invalidates it.
public struct ImportPlan: Equatable, Sendable {
    public let batchID: UUID
    public let importIDs: Set<UUID>
    public let skipIDs: Set<UUID>
    public let newAccountIDs: Set<UUID>
    public let expectedBook: LedgerBook
}

public enum ImportEngine {
    public static func validate(_ book: LedgerBook) throws {
        let batches = book.importBatches
        guard Set(batches.map(\.id)).count == batches.count else { throw ImportError.invalidState }
        let rows = batches.flatMap(\.rows)
        guard Set(rows.map(\.id)).count == rows.count, Set(rows.map(\.operationID)).count == rows.count else { throw ImportError.invalidState }
        let consumed = book.retiredOperationIDs.union(book.entries.map(\.operationID))
        // Duplicate operation IDs are checked by LedgerEngine; do not build a trapping dictionary here.
        let liveOperations = Dictionary(book.entries.map { ($0.operationID, $0.id) }, uniquingKeysWith: { first, _ in first })
        var proposedIDs = Set<UUID>()
        for batch in batches {
            guard !batch.namespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  batch.namespace.utf8.count <= 256, batch.version > 0, BackupDates.isSupported(batch.createdAt),
                  batch.rows.count <= ImportCSV.maximumRows else { throw ImportError.invalidState }
            for account in batch.proposedAccounts {
                guard proposedIDs.insert(account.id).inserted, !book.accounts.contains(where: { $0.id == account.id }),
                      !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      BackupDates.isSupported(account.openingDate) else { throw ImportError.invalidState }
            }
            for row in batch.rows {
                guard row.raw.count == ImportCSV.header.count, row.raw.allSatisfy({ $0.utf8.count <= 65_536 }),
                      Set(row.tagIDs).count == row.tagIDs.count,
                      row.state != .imported || consumed.contains(row.operationID) else { throw ImportError.invalidState }
                if let entryID = liveOperations[row.operationID], entryID != row.id { throw ImportError.invalidState }
                if let token = row.duplicateReviewToken, !BackupTable.isHex(token, count: 64) { throw ImportError.invalidState }
            }
        }
        var importedKeys = Set<[String]>()
        for batch in batches {
            for row in batch.rows where row.state == .imported {
                guard !row.sourceID.isEmpty, importedKeys.insert([batch.namespace, row.sourceID]).inserted else { throw ImportError.invalidState }
            }
        }
    }

    public static func save(_ batch: ImportBatch, in book: LedgerBook, expectedVersion: Int? = nil) throws -> LedgerBook {
        try LedgerEngine.validate(book)
        var result = book
        if let index = book.importBatches.firstIndex(where: { $0.id == batch.id }) {
            let old = book.importBatches[index]
            guard expectedVersion == old.version, batch.version == old.version, old.version < Int.max,
                  batch.namespace == old.namespace, batch.createdAt == old.createdAt,
                  batch.rows.map(\.id) == old.rows.map(\.id) else { throw ImportError.stalePreview }
            for (before, after) in zip(old.rows, batch.rows) {
                guard before.raw == after.raw, before.operationID == after.operationID,
                      before.state == after.state, before.state == .pending || before == after else { throw ImportError.invalidState }
            }
            var updated = batch; updated.version += 1; result.importBatches[index] = updated
        } else {
            guard expectedVersion == nil, batch.version == 1, batch.rows.allSatisfy({ $0.state == .pending }) else { throw ImportError.invalidState }
            result.importBatches.append(batch)
        }
        try LedgerEngine.validate(result)
        return result
    }

    public static func reviews(batch: ImportBatch, rowIDs: Set<UUID>, in book: LedgerBook, now: Date = Date()) -> [UUID: ImportRowReview] {
        let candidates = batch.rows.filter { $0.state == .pending }.compactMap { try? candidate($0, batch: batch, in: book, now: now) }
        return Dictionary(uniqueKeysWithValues: batch.rows.filter { rowIDs.contains($0.id) }.map {
            ($0.id, review($0, batch: batch, in: book, now: now, preparedCandidates: candidates))
        })
    }

    public static func review(_ row: ImportRow, batch: ImportBatch, in book: LedgerBook, now: Date = Date(), preparedCandidates: [LedgerEntry]? = nil) -> ImportRowReview {
        guard row.state == .pending else { return .finished }
        guard row.raw.count == ImportCSV.header.count else { return .blocked("原始列数错误。") }
        guard !row.sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .blocked("缺少稳定的 source_id，请修正源文件。") }
        for priorBatch in book.importBatches {
            for prior in priorBatch.rows where prior.state == .imported && priorBatch.namespace == batch.namespace && prior.sourceID == row.sourceID {
                return prior.raw == row.raw ? .duplicate : .conflict
            }
        }
        if batch.rows.contains(where: { $0.id != row.id && $0.state == .pending && $0.sourceID == row.sourceID }) { return .conflict }
        do {
            let entry = try candidate(row, batch: batch, in: book, now: now)
            let similar = similarEntries(to: entry, batch: batch, in: book, now: now, preparedCandidates: preparedCandidates)
            if !similar.isEmpty {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let token = BackupSHA256.hex(try encoder.encode([entry] + similar))
                if row.duplicateReviewToken != token { return .similar(token: token, count: similar.count) }
            }
            return .ready
        } catch let ImportError.invalidFile(reason) { return .blocked(reason) }
        catch { return .blocked("账户、分类或主体不可用，请重新映射。") }
    }

    public static func similarEntries(to entry: LedgerEntry, batch: ImportBatch, in book: LedgerBook, now: Date = Date(), preparedCandidates: [LedgerEntry]? = nil) -> [LedgerEntry] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let pending = preparedCandidates ?? batch.rows.filter { $0.state == .pending && $0.id != entry.id }.compactMap {
            try? candidate($0, batch: batch, in: book, now: now)
        }
        return (book.entries + pending).filter {
            $0.id != entry.id && $0.kind == entry.kind && $0.accountID == entry.accountID && $0.amount == entry.amount
                && calendar.isDate($0.occurredAt, inSameDayAs: entry.occurredAt)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public static func candidate(_ row: ImportRow, batch: ImportBatch, in book: LedgerBook, now: Date) throws -> LedgerEntry {
        guard row.raw.count == ImportCSV.header.count else { throw ImportError.invalidState }
        guard row.raw[10] == "success" else { throw ImportError.invalidFile("非 success 状态，需核对后跳过或留待处理。") }
        guard let kind = EntryKind(rawValue: row.raw[2]), [.expense, .income, .transfer].contains(kind) else {
            throw ImportError.invalidFile("当前普通导入只支持 expense／income／transfer；退款、贷款等需专门核对。")
        }
        guard let date = ImportCSV.date(row.raw[1]), BackupDates.isSupported(date) else { throw ImportError.invalidFile("日期必须为含时区的 ISO 8601，例如 2026-01-15T12:30:00+08:00。") }
        guard date <= now else { throw ImportError.invalidFile("未来日期暂留草稿，不计入已发生流水。") }
        guard let currency = Currency(rawValue: row.raw[4]) else { throw ImportError.invalidFile("币种当前支持 CNY／HKD／USD。") }
        let amount: Money
        do { amount = try Money.parse(row.raw[3], currency: currency) }
        catch { throw ImportError.invalidFile("金额须为最多两位小数的正数，不能填写算式。") }
        guard amount.minorUnits > 0 else { throw ImportError.invalidFile("零额或负金额须先核对。") }
        guard let accountID = row.accountID else { throw ImportError.invalidFile("请选择付款／收款账户；不会自动使用默认账户。") }
        let accounts = book.accounts + batch.proposedAccounts
        guard let account = accounts.first(where: { $0.id == accountID }), account.isActive, account.currency == currency else { throw ImportError.invalidFile("账户缺失、已停用或币种不匹配。") }
        if kind == .transfer {
            guard let destinationID = row.destinationAccountID, destinationID != accountID,
                  accounts.contains(where: { $0.id == destinationID && $0.isActive && $0.currency == currency }) else {
                throw ImportError.invalidFile("转账需选择不同的同币种转入账户。")
            }
        } else {
            guard let category = book.categories.first(where: { $0.id == row.categoryID }), category.isActive,
                  category.direction == kind, let parent = book.categories.first(where: { $0.id == category.parentID }), parent.isActive else {
                throw ImportError.invalidFile("请选择对应方向的启用二级分类。")
            }
        }
        guard book.subjects.contains(where: { $0.id == row.subjectID && $0.isActive }) else { throw ImportError.invalidFile("请选择有效主体。") }
        guard Set(row.tagIDs).count == row.tagIDs.count,
              row.tagIDs.allSatisfy({ id in book.tags.contains { $0.id == id && $0.isActive } }) else {
            throw ImportError.invalidFile("标签缺失或已停用，请移除或重新选择。")
        }
        if let projectID = row.projectID, !book.projects.contains(where: { $0.id == projectID && !$0.isArchived }) {
            throw ImportError.invalidFile("项目缺失或已归档，请清除或重新选择。")
        }
        return LedgerEntry(id: row.id, operationID: row.operationID, kind: kind, amount: amount, accountID: accountID,
                           destinationAccountID: kind == .transfer ? row.destinationAccountID : nil,
                           categoryID: kind.needsCategory ? row.categoryID : nil, subjectID: row.subjectID,
                           occurredAt: date, createdAt: batch.createdAt, title: row.raw[8], note: row.raw[9],
                           tagIDs: row.tagIDs, projectID: row.projectID)
    }

    public static func prepare(batchID: UUID, importIDs: Set<UUID>, skipIDs: Set<UUID>, in book: LedgerBook, now: Date = Date()) throws -> ImportPlan {
        try LedgerEngine.validate(book)
        guard importIDs.isDisjoint(with: skipIDs), !importIDs.isEmpty || !skipIDs.isEmpty else { throw ImportError.unavailableRow }
        guard importIDs.count + skipIDs.count <= 200 else { throw ImportError.tooManySelected }
        guard let batch = book.importBatches.first(where: { $0.id == batchID }),
              importIDs.union(skipIDs).isSubset(of: Set(batch.rows.filter { $0.state == .pending }.map(\.id))) else { throw ImportError.unavailableRow }
        var newAccounts = Set<UUID>()
        let reviews = reviews(batch: batch, rowIDs: importIDs, in: book, now: now)
        for row in batch.rows where importIDs.contains(row.id) {
            guard reviews[row.id] == .ready else { throw ImportError.unavailableRow }
            let candidate = try candidate(row, batch: batch, in: book, now: now)
            newAccounts.formUnion([candidate.accountID, candidate.destinationAccountID].compactMap { $0 }.filter { id in batch.proposedAccounts.contains { $0.id == id } })
        }
        return ImportPlan(batchID: batchID, importIDs: importIDs, skipIDs: skipIDs, newAccountIDs: newAccounts, expectedBook: book)
    }

    public static func commit(_ plan: ImportPlan, in book: LedgerBook, now: Date = Date()) throws -> LedgerBook {
        // A lost successful response may be retried against the exact committed state.
        if book != plan.expectedBook {
            let committed = try apply(plan, in: plan.expectedBook, now: now)
            guard book == committed else { throw ImportError.stalePreview }
            return book
        }
        return try apply(plan, in: book, now: now)
    }

    private static func apply(_ plan: ImportPlan, in book: LedgerBook, now: Date) throws -> LedgerBook {
        guard book == plan.expectedBook else { throw ImportError.stalePreview }
        guard try prepare(batchID: plan.batchID, importIDs: plan.importIDs, skipIDs: plan.skipIDs, in: book, now: now) == plan else { throw ImportError.stalePreview }
        var result = book
        let index = result.importBatches.firstIndex { $0.id == plan.batchID }!
        let batch = result.importBatches[index]
        let originalCandidates = batch.rows.filter { $0.state == .pending }.compactMap { try? candidate($0, batch: batch, in: book, now: now) }
        guard batch.version < Int.max else { throw ImportError.invalidState }
        result.accounts += batch.proposedAccounts.filter { plan.newAccountIDs.contains($0.id) }
        result.importBatches[index].proposedAccounts.removeAll { plan.newAccountIDs.contains($0.id) }
        for (rowIndex, row) in batch.rows.enumerated() {
            if plan.importIDs.contains(row.id) {
                // Recheck against earlier rows committed in this same transaction.
                let pendingIDs = Set(result.importBatches[index].rows.filter { $0.state == .pending }.map(\.id))
                guard review(row, batch: result.importBatches[index], in: result, now: now,
                             preparedCandidates: originalCandidates.filter { pendingIDs.contains($0.id) }) == .ready else { throw ImportError.unavailableRow }
                let entry = try candidate(row, batch: result.importBatches[index], in: result, now: now)
                result = try LedgerEngine.record(entry, in: result)
                result.importBatches[index].rows[rowIndex].state = .imported
            } else if plan.skipIDs.contains(row.id) { result.importBatches[index].rows[rowIndex].state = .skipped }
        }
        result.importBatches[index].version += 1
        try LedgerEngine.validate(result)
        return result
    }
}
