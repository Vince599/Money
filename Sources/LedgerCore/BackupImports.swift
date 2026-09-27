import Foundation

/// Explicit CSV columns for raw source, draft mapping, completion state and staged accounts.
enum BackupImports {
    private static func id(_ value: UUID?) -> String? { value?.uuidString.lowercased() }
    static func encode(_ batches: [ImportBatch]) throws -> [String: [[String?]]] {
        var result: [String: [[String?]]] = [:]
        result[BackupSchema.importBatches.name] = try batches.enumerated().map { position, batch in
            [String(position), id(batch.id), batch.name, batch.namespace, String(batch.version)] + (try BackupDates.values(batch.createdAt))
        }
        let rows = batches.flatMap { batch in batch.rows.map { (batch.id, $0) } }
        result[BackupSchema.importRows.name] = rows.enumerated().map { position, pair in
            let (batchID, row) = pair
            return [String(position), id(batchID), id(row.id), id(row.operationID), id(row.accountID), id(row.destinationAccountID),
                    id(row.categoryID), id(row.subjectID), row.state.rawValue, row.duplicateReviewToken] + row.raw.map(Optional.some) + [id(row.projectID)]
        }
        let links = rows.flatMap { pair in pair.1.tagIDs.map { [id(pair.1.id), id($0)] } }
        result[BackupSchema.importRowTags.name] = links.enumerated().map { [String($0.offset)] + $0.element }
        let accounts = batches.flatMap { batch in batch.proposedAccounts.map { (batch.id, $0) } }
        result[BackupSchema.importAccounts.name] = try accounts.enumerated().map { position, pair in
            let (batchID, account) = pair
            return [id(batchID), String(position), id(account.id), account.name, account.kind.rawValue, account.nature.rawValue,
                    account.currency.rawValue, String(account.openingMinor)] + (try BackupDates.values(account.openingDate))
                + [String(account.includedInSummary), String(account.isActive), account.institutionID, account.templateID, account.iconID]
        }
        return result
    }
    static func decode(_ tables: [String: [BackupRow]]) throws -> [ImportBatch] {
        func ordered(_ table: BackupTable) throws -> [BackupRow] {
            let records = tables[table.name] ?? []
            for (position, record) in records.enumerated() {
                guard try record.int("position") == position else { throw BackupError.invalidArchive(reason: "Invalid import row order") }
            }
            return records
        }
        var links: [UUID: [UUID]] = [:]
        for record in try ordered(BackupSchema.importRowTags) {
            let rowID = try record.uuid("row_id"), tagID = try record.uuid("tag_id")
            guard !links[rowID, default: []].contains(tagID) else { throw BackupError.invalidArchive(reason: "Duplicate import tag link") }
            links[rowID, default: []].append(tagID)
        }
        var rows: [UUID: [ImportRow]] = [:], accounts: [UUID: [Account]] = [:]
        for record in try ordered(BackupSchema.importRows) {
            let batchID = try record.uuid("batch_id")
            var row = ImportRow(id: try record.uuid("id"), operationID: try record.uuid("operation_id"),
                                raw: try ImportCSV.header.map { try record.string("raw_" + $0) }, subjectID: try record.uuid("subject_id"))
            row.accountID = try record.optionalUUID("account_id"); row.destinationAccountID = try record.optionalUUID("destination_account_id")
            row.categoryID = try record.optionalUUID("category_id"); row.state = try record.enumeration("state")
            row.duplicateReviewToken = record.optionalString("duplicate_review_token")
            row.tagIDs = links.removeValue(forKey: row.id) ?? []
            row.projectID = try record.optionalUUID("project_id")
            rows[batchID, default: []].append(row)
        }
        for record in try ordered(BackupSchema.importAccounts) {
            let account = Account(id: try record.uuid("id"), name: try record.string("name"), kind: try record.enumeration("kind"),
                                  nature: try record.enumeration("nature"), currency: try record.enumeration("currency"),
                                  openingMinor: try record.int64("opening_minor"), openingDate: try record.date("opening_at"),
                                  includedInSummary: try record.bool("included_in_summary"), isActive: try record.bool("is_active"),
                                  institutionID: record.optionalString("institution_id"), templateID: record.optionalString("template_id"), iconID: record.optionalString("icon_id"))
            accounts[try record.uuid("batch_id"), default: []].append(account)
        }
        var result: [ImportBatch] = []
        for record in try ordered(BackupSchema.importBatches) {
            let batchID = try record.uuid("id")
            var batch = ImportBatch(id: batchID, name: try record.string("name"), namespace: try record.string("namespace"),
                                    createdAt: try record.date("created_at"), rows: rows.removeValue(forKey: batchID) ?? [],
                                    proposedAccounts: accounts.removeValue(forKey: batchID) ?? [])
            batch.version = try record.int("version")
            result.append(batch)
        }
        guard rows.isEmpty, accounts.isEmpty, links.isEmpty else { throw BackupError.invalidArchive(reason: "Orphan import rows or staged accounts") }
        return result
    }
}
