import Foundation
import XCTest
import LedgerCore
@testable import Ledger

@MainActor
final class ShortcutModelTests: XCTestCase {
    func testConcurrentStartCallersLoadTheInjectedRepositoryAndLaterStartsKeepCurrentState() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try LedgerRepository(path: directory.appendingPathComponent("ledger.sqlite").path)
        let account = Account(name: "启动测试", openingMinor: 100_00)
        _ = try await repo.addAccount(account, makeDefault: true)
        let draft = EntryDraft(amountText: "12+(", accountID: account.id, note: "启动时恢复")
        try await repo.saveDraft(draft, revision: 7)
        let model = LedgerAppModel(repository: repo)

        let first = Task { @MainActor in
            await model.start()
            return model.isLoaded && model.settings.defaultAccountID == account.id && model.draft == draft
        }
        let second = Task { @MainActor in
            await model.start()
            return model.isLoaded && model.settings.defaultAccountID == account.id && model.draft == draft
        }
        let firstLoaded = await first.value
        let secondLoaded = await second.value
        XCTAssertTrue(firstLoaded)
        XCTAssertTrue(secondLoaded)
        XCTAssertEqual(model.book.accounts, [account])
        XCTAssertNil(model.errorMessage)

        // A later intent calling start must not reload over current editor input.
        var continued = draft
        continued.amountText = "12+(3"
        let autosave = model.updateDraft(continued)
        await model.start()
        await autosave.value
        XCTAssertEqual(model.draft, continued)
        let persisted = try await repo.snapshot()
        XCTAssertEqual(persisted.draft, continued)
        XCTAssertEqual(persisted.draftRevision, 8)
    }

    func testShortcutReviewPreservesOldDraftUntilExplicitReplacementAndConfirmation() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try LedgerRepository(path: directory.appendingPathComponent("ledger.sqlite").path)
        let account = Account(name: "确认测试", openingMinor: 100_00)
        _ = try await repo.addAccount(account, makeDefault: true)
        let manualDraft = EntryDraft(amountText: "36+(", accountID: account.id,
                                     expenseCategoryID: SeedData.taxiID, note: "手动未完成")
        try await repo.saveDraft(manualDraft, revision: 10)
        let model = LedgerAppModel(repository: repo)
        let request = ShortcutEntryRequest(amountText: "20.10", categoryID: SeedData.mealsID,
                                           title: "快捷午餐", note: "待确认")
        try await model.prepareShortcut(request)
        XCTAssertTrue(model.isLoaded)
        XCTAssertEqual(model.pendingShortcut, request)
        XCTAssertEqual(model.draft, manualDraft)
        XCTAssertTrue(model.book.entries.isEmpty)
        let prepared = try await repo.snapshot()
        XCTAssertEqual(prepared.draft, manualDraft)
        XCTAssertEqual(prepared.draftRevision, 10)
        XCTAssertTrue(prepared.book.entries.isEmpty)

        let secondRequest = ShortcutEntryRequest(amountText: "8.00", categoryID: SeedData.taxiID)
        do {
            try await model.prepareShortcut(secondRequest)
            XCTFail("A second request must not replace a pending review")
        } catch {
            if case .pendingReview? = error as? ShortcutExecutionError {} else {
                XCTFail("Expected pendingReview, got \(error)")
            }
        }
        XCTAssertEqual(model.pendingShortcut, request)

        do {
            try await model.installShortcutDraft(request, replacingExisting: false)
            XCTFail("Installing over an existing draft requires an explicit replacement")
        } catch {
            if case .existingDraft? = error as? ShortcutExecutionError {} else {
                XCTFail("Expected existingDraft, got \(error)")
            }
        }
        XCTAssertEqual(model.draft, manualDraft)
        let refused = try await repo.snapshot()
        XCTAssertEqual(refused.draft, manualDraft)
        XCTAssertEqual(refused.draftRevision, 10)
        XCTAssertEqual(refused.book, prepared.book)

        let expectedDraft = try request.makeDraft(in: model.book, settings: model.settings)
        try await model.installShortcutDraft(request, replacingExisting: true)
        XCTAssertEqual(model.draft, expectedDraft)
        XCTAssertFalse(model.isBusy)
        let installed = try await repo.snapshot()
        XCTAssertEqual(installed.draft, expectedDraft)
        XCTAssertEqual(installed.draftRevision, 11)
        XCTAssertTrue(installed.book.entries.isEmpty)

        let entry = try expectedDraft.entry(in: model.book)
        let confirmed = await model.save(entry)
        XCTAssertTrue(confirmed)
        XCTAssertEqual(model.book.entries, [entry])
        XCTAssertNil(model.draft)
        let saved = try await repo.snapshot()
        XCTAssertEqual(saved.book.entries, [entry])
        XCTAssertNil(saved.draft)
    }

    func testDirectShortcutRefreshesModelAndPreservesManualDraftAndRevision() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try LedgerRepository(path: directory.appendingPathComponent("ledger.sqlite").path)
        let account = Account(name: "直接记账", openingMinor: 100_00)
        _ = try await repo.addAccount(account, makeDefault: true)
        let manualDraft = EntryDraft(amountText: "12.", accountID: account.id, note: "保留草稿")
        try await repo.saveDraft(manualDraft, revision: 5)
        let model = LedgerAppModel(repository: repo)
        let request = ShortcutEntryRequest(amountText: "28.50", categoryID: SeedData.mealsID,
                                           title: "快捷午餐")
        let saved = try await model.recordShortcut(request)
        XCTAssertTrue(model.isLoaded)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(saved.operationID, request.operationID)
        XCTAssertEqual(saved.amount.minorUnits, 28_50)
        XCTAssertEqual(model.book.entries, [saved])
        XCTAssertEqual(model.balance(account)?.minorUnits, 71_50)
        XCTAssertEqual(model.draft, manualDraft)
        XCTAssertNil(model.pendingShortcut)
        let persisted = try await repo.snapshot()
        XCTAssertEqual(persisted.book, model.book)
        XCTAssertEqual(persisted.draft, manualDraft)
        XCTAssertEqual(persisted.draftRevision, 5)

        let retried = try await model.recordShortcut(request)
        XCTAssertEqual(retried, saved)
        XCTAssertEqual(model.book.entries, [saved])
        XCTAssertEqual(model.draft, manualDraft)
        var continued = manualDraft
        continued.amountText = "12.5"
        await model.updateDraft(continued).value
        let afterAutosave = try await repo.snapshot()
        XCTAssertEqual(afterAutosave.draft, continued)
        XCTAssertEqual(afterAutosave.draftRevision, 6)
    }

    func testInvalidDirectShortcutReturnsLocalizedErrorWithoutChangingState() async throws {
        let directory = try testDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try LedgerRepository(path: directory.appendingPathComponent("ledger.sqlite").path)
        let account = Account(name: "错误提示", openingMinor: 100_00)
        _ = try await repo.addAccount(account, makeDefault: true)
        let manualDraft = EntryDraft(amountText: "36+(", accountID: account.id)
        try await repo.saveDraft(manualDraft, revision: 9)
        let model = LedgerAppModel(repository: repo)
        await model.start()
        let original = try await repo.snapshot()

        do {
            _ = try await model.recordShortcut(ShortcutEntryRequest(amountText: "1+2",
                                                                     categoryID: SeedData.mealsID))
            XCTFail("Shortcut decimal input must reject expressions")
        } catch {
            XCTAssertEqual(error as? ShortcutEntryError, .invalidAmount)
            XCTAssertEqual((error as? LocalizedError)?.errorDescription,
                           "请输入大于 0 的金额，最多保留两位小数，不支持算式。")
        }
        // Missing required data reaches normal entry validation and is localized too.
        do {
            _ = try await model.recordShortcut(ShortcutEntryRequest(amountText: "20.00"))
            XCTFail("A direct expense requires a category")
        } catch {
            XCTAssertTrue(error is ShortcutExecutionError)
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "请选择当前类型对应的二级分类。")
        }
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.book, original.book)
        XCTAssertEqual(model.draft, manualDraft)
        XCTAssertNil(model.pendingShortcut)
        let after = try await repo.snapshot()
        XCTAssertEqual(after.book, original.book)
        XCTAssertEqual(after.draft, manualDraft)
        XCTAssertEqual(after.draftRevision, 9)
    }

    private func testDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShortcutModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
