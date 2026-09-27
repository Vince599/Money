import Foundation
import UIKit
import XCTest
import LedgerCore
@testable import Ledger

@MainActor
final class CategorySymbolPresentationTests: XCTestCase {
    func testEveryOfferedAndSeedSymbolExistsInTheActualSDK() {
        XCTAssertNotNil(UIImage(systemName: CategorySymbolCatalog.fallback))
        for item in CategorySymbolCatalog.all {
            XCTAssertNotNil(UIImage(systemName: item.id), item.id)
            XCTAssertEqual(CategorySymbolPresentation.resolved(item.id), item.id)
            XCTAssertTrue(CategorySymbolPresentation.availableIDs.contains(item.id))
        }
        for category in SeedData.categories {
            XCTAssertNotNil(UIImage(systemName: category.symbol), category.name)
        }
    }

    func testUnsupportedSymbolFallsBackWithoutMutatingSavedIdentity() {
        let category = LedgerCore.Category(name: "未来图标", direction: .expense, symbol: "ledger.nonexistent.symbol")
        XCTAssertEqual(CategorySymbolPresentation.resolved(category.symbol), "tag")
        XCTAssertEqual(CategorySymbolPresentation.name(category.symbol), "暂用通用图标")
        XCTAssertEqual(category.symbol, "ledger.nonexistent.symbol")
        // Legacy symbols outside the current library still render when supported by the OS.
        XCTAssertEqual(CategorySymbolPresentation.resolved("car.fill"), "car.fill")
    }

    func testExistingAppearanceSurvivesReopenBackupAndDefaultReset() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ledger.sqlite").path
        let repo = try LedgerRepository(path: path)
        let snapshot = try await repo.snapshot()
        var category = try XCTUnwrap(snapshot.book.categories.first { $0.id == SeedData.foodID })
        category.name = "已改名餐饮"; category.symbol = "cup.and.saucer"; category.isActive = false
        _ = try await repo.saveCategory(category)
        var legacy = try XCTUnwrap(snapshot.book.categories.first { $0.id == UUID(uuidString: "00000000-0000-4000-8000-000000001a00") })
        legacy.name = "旧版自定义数字服务"; legacy.symbol = "future.symbol"
        _ = try await repo.saveCategory(legacy)
        let expected = try await repo.snapshot()
        let data = try await repo.exportBackup()
        let reopened = try LedgerRepository(path: path)
        let actual = try await reopened.snapshot()
        XCTAssertEqual(actual.book, expected.book)
        var reset = category
        reset.symbol = CategorySymbolCatalog.defaultSymbol(for: reset.id)
        let afterReset = try await reopened.saveCategory(reset)
        XCTAssertEqual(afterReset.book.categories.first { $0.id == SeedData.foodID }?.symbol, "fork.knife")
        XCTAssertEqual(afterReset.book.categories.first { $0.id == SeedData.foodID }?.name, category.name)
        XCTAssertEqual(afterReset.book.categories.first { $0.id == SeedData.foodID }?.isActive, false)
        let preview = try await reopened.prepareRestore(data)
        let restored = try await reopened.restore(previewID: preview.id, revision: 1)
        XCTAssertEqual(restored.book, expected.book)
        XCTAssertEqual(restored.book.categories.first { $0.id == SeedData.mealsID }?.symbol, "fork.knife")
    }
}
