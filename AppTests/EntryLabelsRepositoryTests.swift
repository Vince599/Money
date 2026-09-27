import Foundation
import XCTest
import LedgerCore
@testable import Ledger

@MainActor
final class EntryLabelsRepositoryTests: XCTestCase {
    func testCatalogEditsPreserveNewerDraftAndBackupRestoresArchivedLinks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.sqlite").path
        let repo = try LedgerRepository(path: path)
        let account = Account(name: "标签测试", openingMinor: 10_000)
        _ = try await repo.addAccount(account, makeDefault: true)
        var tag = EntryTag(name: "旅行")
        var project = EntryProject(name: "上海")
        _ = try await repo.saveTag(tag)
        _ = try await repo.saveProject(project)
        let draft = EntryDraft(amountText: "20.10", accountID: account.id, expenseCategoryID: SeedData.mealsID,
                               tagIDs: [tag.id], projectID: project.id)
        let initial = try await repo.snapshot()
        let entry = try draft.entry(in: initial.book)
        _ = try await repo.saveEntry(entry, expectedVersion: nil, nextDraft: nil, revision: 1)
        let manual = EntryDraft(amountText: "13+(", tagIDs: [tag.id], projectID: project.id)
        try await repo.saveDraft(manual, revision: 5)
        tag.name = "旅途"; tag.isActive = false; project.isArchived = true
        _ = try await repo.saveTag(tag)
        let expected = try await repo.saveProject(project)
        try await repo.saveDraft(nil, revision: 4)
        let archived = try await repo.snapshot()
        XCTAssertEqual(archived.draft, manual)
        XCTAssertEqual(archived.draftRevision, 5)
        XCTAssertEqual(archived.book.entries, [entry])
        let data = try await repo.exportBackup()
        let reopened = try LedgerRepository(path: path)
        let reopenedSnapshot = try await reopened.snapshot()
        XCTAssertEqual(reopenedSnapshot.book, expected.book)
        XCTAssertEqual(reopenedSnapshot.draft, manual)
        project.isArchived = false
        _ = try await reopened.saveProject(project)
        let preview = try await reopened.prepareRestore(data)
        XCTAssertEqual(preview.tagCount, 1)
        XCTAssertEqual(preview.projectCount, 1)
        let restored = try await reopened.restore(previewID: preview.id, revision: 10)
        XCTAssertEqual(restored.book, expected.book)
        XCTAssertEqual(restored.draft, manual)
        XCTAssertEqual(try LedgerEngine.balance(of: account.id, in: restored.book).minorUnits, 7_990)
    }

    func testFailedSelectionPreservesDraftAndHistoricalEditKeepsArchivedProject() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try LedgerRepository(path: directory.appendingPathComponent("ledger.sqlite").path)
        let account = Account(name: "银行卡")
        _ = try await repo.addAccount(account, makeDefault: true)
        var project = EntryProject(name: "旅行")
        _ = try await repo.saveProject(project)
        let entry = LedgerEntry(kind: .expense, amount: Money(minorUnits: 100), accountID: account.id,
                                categoryID: SeedData.mealsID, projectID: project.id)
        _ = try await repo.saveEntry(entry, expectedVersion: nil, nextDraft: nil, revision: 1)
        let draft = EntryDraft(amountText: "25", accountID: account.id, projectID: project.id)
        try await repo.saveDraft(draft, revision: 2)
        project.isArchived = true
        _ = try await repo.saveProject(project)
        var new = entry; new.id = UUID(); new.operationID = UUID()
        do {
            _ = try await repo.saveEntry(new, expectedVersion: nil, nextDraft: nil, revision: 3)
            XCTFail("Archived project must not be selected for a new entry")
        } catch { XCTAssertEqual(error as? LedgerError, .invalidProject) }
        let failed = try await repo.snapshot()
        XCTAssertEqual(failed.draft, draft)
        XCTAssertEqual(failed.draftRevision, 2)
        var editing = entry; editing.operationID = UUID(); editing.note = "补充信息"
        let updated = try await repo.saveEntry(editing, expectedVersion: 1, nextDraft: nil, revision: 4)
        XCTAssertEqual(updated.book.entries[0].projectID, project.id)
        XCTAssertEqual(updated.draft, draft)
        XCTAssertEqual(updated.book.entries.count, 1)
    }
}
