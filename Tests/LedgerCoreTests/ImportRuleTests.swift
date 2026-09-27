import Foundation
import Testing
@testable import LedgerCore

@Suite("Persistent import rules and explicit suggestions")
struct ImportRuleTests {
    private func fixture() throws -> (LedgerBook, ImportBatch, Account, Account) {
        let a = Account(name: "银行卡", openingMinor: 10_000), b = Account(name: "零钱", openingMinor: 5_000)
        var batch = try ImportCSV.parse(ImportCSV.template, name: "rules", namespace: "bank")
        batch.rows[0].raw[8] = "Coffee 早餐"; batch.rows[0].raw[9] = "工作日"
        batch.rows[0].raw[3] = "20.10"
        batch.rows[0].accountID = a.id; batch.rows[0].categoryID = SeedData.mealsID
        var raw = batch.rows[0].raw; raw[0] = "second"
        batch.rows.append(ImportRow(raw: raw))
        let book = try ImportEngine.save(batch, in: LedgerBook(accounts: [a, b]))
        return (book, batch, a, b)
    }
    private func rule(_ target: UUID, priority: Int = 100, field: ImportRuleTargetField = .account) -> ImportRule {
        ImportRule(name: "早餐映射", priority: priority, conditions: [.init(field: .title, comparison: .contains, value: "Coffee")], actions: [.init(field: field, targetID: target)])
    }
    private func review(_ book: LedgerBook, _ batch: ImportBatch) throws -> ImportRuleReview {
        try ImportRuleEngine.review(batchID: batch.id, rowID: batch.rows[0].id, in: book)
    }

    @Test func exactSourceAndCurrencyAndInclusiveMoneyBoundsWithANDTextConditions() throws {
        var (book, batch, _, b) = try fixture()
        var value = rule(b.id); value.namespace = "bank"; value.currency = .cny
        value.minimumMinor = 2010; value.maximumMinor = 2010
        value.conditions += [.init(field: .note, comparison: .equals, value: "工作日"), .init(field: .kind, comparison: .equals, value: "expense")]
        book.importRules = [value]
        #expect(try review(book, batch).suggestions.first?.preferredID == b.id)
        for changed in ["coffee 早餐", "Coffee 早餐 "] {
            var exact = book; exact.importRules[0].conditions[0].comparison = .equals
            exact.importRules[0].conditions[0].value = changed
            #expect(try review(exact, batch).suggestions.isEmpty)
        }
        var wrong = book; wrong.importRules[0].namespace = "another"
        #expect(try review(wrong, batch).suggestions.isEmpty)
        wrong = book; wrong.importRules[0].currency = .usd
        #expect(try review(wrong, batch).suggestions.isEmpty)
        wrong = book; wrong.importRules[0].conditions[1].value = "周末"
        #expect(try review(wrong, batch).suggestions.isEmpty)
        wrong = book; wrong.importRules[0].minimumMinor = 2011; wrong.importRules[0].maximumMinor = nil
        #expect(try review(wrong, batch).suggestions.isEmpty)
        wrong = book; wrong.importRules[0].minimumMinor = nil; wrong.importRules[0].maximumMinor = 2009
        #expect(try review(wrong, batch).suggestions.isEmpty)
    }

    @Test func allConflictsAreVisibleAndPriorityIsPerFieldWithNoTieWinner() throws {
        var (book, batch, a, b) = try fixture()
        var first = rule(a.id, priority: 10); first.actions.append(.init(field: .category, targetID: SeedData.mealsID))
        let second = rule(b.id, priority: 20)
        book.importRules = [second, first]
        let result = try review(book, batch)
        let account = try #require(result.suggestions.first { $0.id == .account })
        #expect(account.hasConflict && account.preferredID == a.id && account.choices.count == 2)
        #expect(result.suggestions.first { $0.id == .category }?.preferredID == SeedData.mealsID)
        book.importRules[0].priority = 10
        #expect(try review(book, batch).suggestions.first { $0.id == .account }?.preferredID == nil)
        book.importRules.reverse()
        #expect(try review(book, batch).suggestions.first { $0.id == .account }?.preferredID == nil)
        book.importRules[1].actions[0].targetID = a.id
        let same = try #require(review(book, batch).suggestions.first { $0.id == .account })
        #expect(!same.hasConflict && same.preferredID == a.id && same.choices[0].rules.count == 2)
    }

    @Test func unavailableTargetPausesWholeRuleAndReactivationRestoresSuggestions() throws {
        var (book, batch, _, b) = try fixture()
        var value = rule(b.id); value.actions.append(.init(field: .category, targetID: SeedData.mealsID))
        book = try ImportRuleEngine.save(value, in: book)
        book.accounts[1].isActive = false
        let paused = try review(book, batch)
        #expect(paused.suggestions.isEmpty && paused.warnings.count == 1)
        #expect(ImportRuleEngine.affectedRules(field: .account, id: b.id, in: book).count == 1)
        let parent = try #require(book.categories.first { $0.id == SeedData.mealsID }?.parentID)
        #expect(ImportRuleEngine.affectedRules(field: .category, id: parent, in: book).count == 1)
        #expect(throws: ImportError.self) { try ImportRuleEngine.save(book.importRules[0], expectedVersion: 1, in: book) }
        var disabled = book.importRules[0]; disabled.isEnabled = false
        #expect(try ImportRuleEngine.save(disabled, expectedVersion: 1, in: book).importRules[0].version == 2)
        book.accounts[1].isActive = true
        #expect(try review(book, batch).suggestions.count == 2)
        let parentIndex = try #require(book.categories.firstIndex { $0.id == parent })
        book.categories[parentIndex].isActive = false
        #expect(try review(book, batch).suggestions.isEmpty)
    }

    @Test func incompatibleRowActionsWarnWhileOtherValidFieldsRemainAvailable() throws {
        var (book, batch, _, _) = try fixture()
        let foreign = Account(name: "美元", currency: .usd)
        book.accounts.append(foreign)
        var value = rule(foreign.id)
        value.actions += [.init(field: .category, targetID: SeedData.salaryIncomeID), .init(field: .subject, targetID: batch.rows[0].subjectID)]
        book = try ImportRuleEngine.save(value, in: book)
        let result = try review(book, batch)
        #expect(result.warnings.count == 2 && result.suggestions.map(\.id) == [.subject])
    }

    @Test func onlyExplicitFieldsChangePreservingRawOtherRowsLabelsAndCash() throws {
        var (book, batch, _, b) = try fixture()
        let tag = EntryTag(name: "保留"); book.tags = [tag]; book.importBatches[0].rows[0].tagIDs = [tag.id]
        var value = rule(b.id); value.actions.append(.init(field: .category, targetID: SeedData.otherExpenseID))
        book = try ImportRuleEngine.save(value, in: book)
        let inspected = try review(book, batch)
        #expect(throws: ImportError.self) { try ImportRuleEngine.prepare(inspected, selections: [:]) }
        #expect(throws: ImportError.invalidState) { try ImportRuleEngine.prepare(inspected, selections: [.account: UUID()]) }
        let plan = try ImportRuleEngine.prepare(inspected, selections: [.account: b.id])
        let saved = try ImportRuleEngine.apply(plan, in: book)
        #expect(saved.entries == book.entries && saved.accounts == book.accounts)
        #expect(saved.importBatches[0].rows[0].accountID == b.id)
        #expect(saved.importBatches[0].rows[0].categoryID == SeedData.mealsID)
        #expect(saved.importBatches[0].rows[0].tagIDs == [tag.id])
        #expect(saved.importBatches[0].rows[1] == book.importBatches[0].rows[1])
        #expect(saved.importBatches[0].rows.map(\.raw) == book.importBatches[0].rows.map(\.raw))
        #expect(saved.importBatches[0].version == 2)
        #expect(throws: ImportError.stalePreview) { try ImportRuleEngine.apply(plan, in: saved) }
    }

    @Test func changedRuleOrMappingInvalidatesPreviewAndRuleSaveNeverRewritesRows() throws {
        var (book, batch, _, b) = try fixture()
        book = try ImportRuleEngine.save(rule(b.id), in: book)
        let plan = try ImportRuleEngine.prepare(review(book, batch), selections: [.account: b.id])
        var changed = book.importRules[0]; changed.name = "改名"; changed.isEnabled = false
        let newer = try ImportRuleEngine.save(changed, expectedVersion: 1, in: book)
        #expect(newer.importBatches == book.importBatches && newer.entries == book.entries)
        #expect(throws: ImportError.stalePreview) { try ImportRuleEngine.apply(plan, in: newer) }
        #expect(throws: ImportError.stalePreview) { try ImportRuleEngine.save(changed, expectedVersion: 1, in: newer) }
        var mapping = book.importBatches[0]; mapping.rows[0].categoryID = SeedData.otherExpenseID
        let remapped = try ImportEngine.save(mapping, in: book, expectedVersion: 1)
        #expect(throws: ImportError.stalePreview) { try ImportRuleEngine.apply(plan, in: remapped) }
    }

    @Test func completedSkippedAndRevertedRowsCannotReceiveRules() throws {
        let (book, batch, _, b) = try fixture()
        let configured = try ImportRuleEngine.save(rule(b.id), in: book)
        let posted = try ImportEngine.commit(ImportEngine.prepare(batchID: batch.id, importIDs: [batch.rows[0].id], skipIDs: [batch.rows[1].id], in: configured), in: configured)
        for row in batch.rows {
            #expect(throws: ImportError.unavailableRow) { try ImportRuleEngine.review(batchID: batch.id, rowID: row.id, in: posted) }
        }
        let undo = try #require(ImportEngine.reviewUndo(batchID: batch.id, in: posted).plan)
        let reverted = try ImportEngine.undo(undo, in: posted)
        #expect(throws: ImportError.unavailableRow) { try review(reverted, batch) }
    }

    @Test func invalidRuleShapesAndUnusableTargetsCannotBeSavedEnabled() throws {
        let (book, _, _, b) = try fixture()
        let valid = rule(b.id)
        var bad = valid; bad.actions.append(bad.actions[0])
        #expect(throws: ImportError.self) { try ImportRuleEngine.save(bad, in: book) }
        bad = valid; bad.minimumMinor = 1
        #expect(throws: ImportError.self) { try ImportRuleEngine.save(bad, in: book) }
        bad = valid; bad.currency = .cny; bad.minimumMinor = 2; bad.maximumMinor = 1
        #expect(throws: ImportError.self) { try ImportRuleEngine.save(bad, in: book) }
        bad = valid; bad.conditions = []
        #expect(throws: ImportError.self) { try ImportRuleEngine.save(bad, in: book) }
        bad = valid; bad.actions[0].targetID = UUID()
        #expect(throws: ImportError.self) { try ImportRuleEngine.save(bad, in: book) }
        bad.isEnabled = false
        #expect(try ImportRuleEngine.save(bad, in: book).importRules.count == 1)
        bad = valid; bad.conditions = [.init(field: .kind, comparison: .contains, value: "expense")]
        #expect(throws: ImportError.self) { try ImportRuleEngine.save(bad, in: book) }
    }

    @Test func completeBackupPreservesRulesAndUnavailableTargetsAndRejectsOrphans() throws {
        var (book, _, _, b) = try fixture()
        var value = rule(b.id); value.namespace = "bank"; value.currency = .cny; value.maximumMinor = Int64.max
        value.name = "规则,含逗号\n及换行"; value.conditions.append(.init(field: .note, comparison: .equals, value: "=工作日"))
        book = try ImportRuleEngine.save(value, in: book)
        book.importRules[0].actions[0].targetID = UUID()
        let snapshot = LedgerBackupSnapshot(book: book, draft: EntryDraft(amountText: "12+("), settings: LedgerSettings())
        let files = try BackupCodec.encode(snapshot)
        #expect(files.count == 23 && BackupSchema.dbVersion == "8")
        #expect(try BackupCodec.decode(files) == snapshot)
        for table in [BackupSchema.importRuleConditions, BackupSchema.importRuleActions] {
            var damaged = files
            var rows = try BackupCSV.decode(damaged[table.name]!, file: table.name)
            rows[1][1] = UUID().uuidString.lowercased()
            damaged[table.name] = BackupCSV.encode(rows)
            try rehash(&damaged)
            #expect(throws: BackupError.self) { try BackupCodec.decode(damaged) }
        }
    }

    @Test func exactProfileSevenRestoresWithoutRulesAndOldJSONDefaultsToEmpty() throws {
        let (book, _, _, _) = try fixture()
        let snapshot = LedgerBackupSnapshot(book: book, draft: nil, settings: LedgerSettings())
        var files = try BackupCodec.encode(snapshot).filter { Set(BackupSchema.v7All.map(\.name)).contains($0.key) }
        var manifest = try BackupSchema.manifest.read(files["manifest.csv"]!)[0].values
        manifest["profile"] = "ledger-core-v7"; manifest["backup_format_version"] = "7.0"; manifest["db_schema_version"] = "7"; manifest["file_count"] = "20"
        files["manifest.csv"] = BackupCSV.encode([BackupSchema.v7Manifest.header, BackupSchema.v7Manifest.columns.map { manifest[$0.name] }])
        files["schema_dictionary.csv"] = BackupSchema.dictionaryData(for: BackupSchema.v7All)
        try rehash(&files)
        #expect(try BackupCodec.decode(files) == snapshot)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(book)) as? [String: Any])
        json.removeValue(forKey: "importRules")
        #expect(try JSONDecoder().decode(LedgerBook.self, from: JSONSerialization.data(withJSONObject: json)) == book)
    }

    private func rehash(_ files: inout [String: Data]) throws {
        let count = files.count
        let counts: [[String?]] = try files.keys.sorted().map { name in
            [name, String(name == "counts.csv" ? count : name == "checksums.csv" ? count - 1 : try BackupCSV.decode(files[name]!, file: name).count - 1)]
        }
        files["counts.csv"] = BackupCSV.encode([BackupSchema.counts.header] + counts)
        files["checksums.csv"] = BackupCSV.encode([BackupSchema.checksums.header] + files.keys.filter { $0 != "checksums.csv" }.sorted().map { [$0, BackupSHA256.hex(files[$0]!)] })
    }
}
