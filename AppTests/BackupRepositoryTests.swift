import XCTest
import LedgerCore
@testable import Ledger

@MainActor
final class BackupRepositoryTests: XCTestCase {
    func testRestoreReplacesBookSettingsAndDraftAndPreservesCurrentSafetyCopy() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.sqlite").path
        let repo = try LedgerRepository(path: path)
        let account = Account(name: "银行卡", openingMinor: 10_000_00,
                              institutionID: "icbc", templateID: "cn.icbc.debit", iconID: "brand.icbc")
        _ = try await repo.addAccount(account, makeDefault: true)
        let input = EntryDraft(amountText: "28.50", accountID: account.id, expenseCategoryID: SeedData.mealsID,
                               note: "备注,引号\"与换行\n\\N")
        let initial = try await repo.snapshot()
        let entry = try input.entry(in: initial.book)
        _ = try await repo.saveEntry(entry, expectedVersion: nil, nextDraft: nil, revision: 1)
        let unfinished = EntryDraft(amountText: "12.", accountID: account.id, note: "尚未填完")
        try await repo.saveDraft(unfinished, revision: 2)
        let expected = try await repo.snapshot()
        let archive = try await repo.exportBackup()

        var renamed = account; renamed.name = "恢复前名称"; renamed.includedInSummary = false
        renamed.institutionID = "future.institution"
        renamed.templateID = "future.template"
        renamed.iconID = "future.icon"
        _ = try await repo.saveAccount(renamed)
        _ = try await repo.deleteEntry(entry.id)
        _ = try await repo.setDefaultAccount(nil)
        try await repo.saveDraft(nil, revision: 3)
        let beforeRestore = try await repo.snapshot()
        let preview = try await repo.prepareRestore(archive)
        XCTAssertEqual(preview.entryCount, 1)
        let afterPreview = try await repo.snapshot()
        XCTAssertEqual(afterPreview.book, beforeRestore.book)

        let restored = try await repo.restore(previewID: preview.id, revision: 10)
        XCTAssertEqual(restored.book, expected.book)
        XCTAssertEqual(restored.book.accounts.first?.templateID, "cn.icbc.debit")
        XCTAssertEqual(restored.settings, expected.settings)
        XCTAssertEqual(restored.draft, unfinished)
        let copies = try await repo.safetyBackups()
        XCTAssertEqual(copies.count, 1)
        let copy = try XCTUnwrap(copies.first)
        let saved = try BackupCodec.decode(BackupArchive.decode(Data(contentsOf: copy.url)))
        XCTAssertEqual(saved.book, beforeRestore.book)
        XCTAssertEqual(saved.book.accounts.first?.templateID, "future.template")
        XCTAssertEqual(saved.book.accounts.first?.iconID, "future.icon")
        XCTAssertEqual(saved.settings, beforeRestore.settings)
        XCTAssertNil(saved.draft)

        // An old autosave arriving after restore cannot modify the new book's draft.
        try await repo.saveDraft(input, revision: 9)
        let reopened = try LedgerRepository(path: path)
        let persisted = try await reopened.snapshot()
        XCTAssertEqual(persisted.book, expected.book)
        XCTAssertEqual(persisted.book.accounts.first?.iconID, "brand.icbc")
        XCTAssertEqual(persisted.settings, expected.settings)
        XCTAssertEqual(persisted.draft, unfinished)
        do {
            _ = try await repo.restore(previewID: preview.id, revision: 11)
            XCTFail("A successful restore preview must be consumed")
        } catch { XCTAssertEqual(error as? RepositoryError, .restorePreviewExpired) }
    }

    func testBadNewSelectionInvalidatesEarlierPreviewWithoutChangingBook() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try LedgerRepository(path: directory.appendingPathComponent("ledger.sqlite").path)
        _ = try await repo.addAccount(Account(name: "微信", openingMinor: 30_00), makeDefault: true)
        let original = try await repo.snapshot()
        let exported = try await repo.exportBackup()
        let validPreview = try await repo.prepareRestore(exported)
        do { _ = try await repo.prepareRestore(Data([0, 1, 2])); XCTFail("Bad ZIP must fail") }
        catch { /* Expected: the previous preview is no longer actionable. */ }
        do {
            _ = try await repo.restore(previewID: validPreview.id, revision: 5)
            XCTFail("Stale preview must fail")
        } catch { XCTAssertEqual(error as? RepositoryError, .restorePreviewExpired) }
        let after = try await repo.snapshot()
        XCTAssertEqual(after.book, original.book)
        XCTAssertEqual(after.settings, original.settings)
        let copies = try await repo.safetyBackups()
        XCTAssertTrue(copies.isEmpty)
    }

    func testSafetyCopyFailurePreventsRestore() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try LedgerRepository(path: directory.appendingPathComponent("ledger.sqlite").path)
        _ = try await repo.addAccount(Account(name: "原账户", openingMinor: 125_00), makeDefault: true)
        let original = try await repo.snapshot()
        let empty = LedgerBackupSnapshot(book: LedgerBook(), draft: nil, settings: LedgerSettings())
        let preview = try await repo.prepareRestore(BackupArchive.encode(BackupCodec.encode(empty)))
        // A regular file at the directory location models a failed safety-copy destination.
        try Data("occupied".utf8).write(to: directory.appendingPathComponent("RecoveryBackups"))
        do {
            _ = try await repo.restore(previewID: preview.id, revision: 1)
            XCTFail("Restore must wait for a persisted safety copy")
        } catch { XCTAssertEqual(error as? RepositoryError, .safetyBackupFailed) }
        let after = try await repo.snapshot()
        XCTAssertEqual(after.book, original.book)
        XCTAssertEqual(after.settings, original.settings)
        XCTAssertEqual(after.draft, original.draft)
    }

    func testDisablingDefaultAccountClearsOnlyTheDefaultAndSubjectDefaultMustBeReassigned() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try LedgerRepository(path: directory.appendingPathComponent("ledger.sqlite").path)
        var account = Account(name: "微信", openingMinor: 42_00)
        _ = try await repo.addAccount(account, makeDefault: true)
        account.isActive = false
        let disabled = try await repo.saveAccount(account)
        XCTAssertNil(disabled.settings.defaultAccountID)
        XCTAssertEqual(try LedgerEngine.balance(of: account.id, in: disabled.book).minorUnits, 42_00)
        var subject = try XCTUnwrap(disabled.book.subjects.first)
        subject.isActive = false
        do { _ = try await repo.saveSubject(subject); XCTFail("Default subject cannot be disabled") }
        catch { XCTAssertEqual(error as? RepositoryError, .defaultSubjectMustRemainActive) }
        let other = LedgerCore.Subject(name: "LZY")
        _ = try await repo.saveSubject(other)
        _ = try await repo.setDefaultSubject(other.id)
        let changed = try await repo.saveSubject(subject)
        XCTAssertEqual(changed.settings.defaultSubjectID, other.id)
        XCTAssertFalse(try XCTUnwrap(changed.book.subjects.first(where: { $0.id == subject.id })).isActive)
    }

    private func testDirectory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
}
