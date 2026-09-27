import Foundation
import Testing
@testable import LedgerCore

@Suite("LedgerCoreTests category symbols")
struct CategorySymbolTests {
    @Test func catalogCoversSeedDefaultsWithUniqueAccessibleNames() {
        let symbols = CategorySymbolCatalog.all
        #expect(Set(symbols.map(\.id)).count == symbols.count)
        #expect(symbols.allSatisfy { !$0.name.isEmpty && !$0.id.hasSuffix(".fill") })
        #expect(Set(symbols.map(\.theme)) == Set(CategorySymbolTheme.allCases))
        for category in SeedData.categories {
            #expect(CategorySymbolCatalog.symbol(category.symbol) != nil)
            #expect(CategorySymbolCatalog.defaultSymbol(for: category.id) == category.symbol)
        }
    }

    @Test func searchMatchesChineseSynonymsEnglishAndThemeWithoutReordering() {
        #expect(CategorySymbolCatalog.search("咖啡").map(\.id) == ["cup.and.saucer"])
        #expect(CategorySymbolCatalog.search("  COFFEE 茶 ").map(\.id) == ["cup.and.saucer"])
        #expect(CategorySymbolCatalog.search("运动衣").map(\.id) == ["tshirt"])
        #expect(CategorySymbolCatalog.search("健身房").map(\.id) == ["figure.run"])
        #expect(CategorySymbolCatalog.search("咖啡", theme: .transport).isEmpty)
        #expect(CategorySymbolCatalog.search("", theme: .transport) == CategorySymbolCatalog.all.filter { $0.theme == .transport })
        #expect(CategorySymbolCatalog.search("不存在的关键词").isEmpty)
        #expect(CategorySymbolCatalog.search(" \n ") == CategorySymbolCatalog.all)
    }

    @Test func defaultsAfterRenameAndParentEditPreserveChildrenHistoryAndBackup() throws {
        let account = Account(name: "图标验证", openingMinor: 10_000)
        let entry = LedgerEntry(kind: .expense, amount: Money(minorUnits: 100), accountID: account.id, categoryID: SeedData.mealsID)
        let original = try LedgerEngine.record(entry, in: LedgerBook(accounts: [account]))
        var parent = try #require(original.categories.first { $0.id == SeedData.foodID })
        parent.name = "我的餐饮"; parent.symbol = "cup.and.saucer"
        let edited = try CatalogEditor.saveCategory(parent, in: original)
        #expect(edited.categories.first { $0.id == SeedData.mealsID }?.symbol == "fork.knife")
        #expect(edited.entries == original.entries)
        #expect(try LedgerEngine.balance(of: account.id, in: edited) == LedgerEngine.balance(of: account.id, in: original))
        #expect(CategorySymbolCatalog.defaultSymbol(for: parent.id) == "fork.knife")
        let archive = try BackupArchive.encode(BackupCodec.encode(LedgerBackupSnapshot(book: edited, draft: nil, settings: LedgerSettings())))
        let restored = try BackupCodec.decode(BackupArchive.decode(archive))
        #expect(restored.book == edited)
        parent.symbol = CategorySymbolCatalog.defaultSymbol(for: parent.id)
        let reset = try CatalogEditor.saveCategory(parent, in: restored.book)
        #expect(reset.categories.first { $0.id == parent.id }?.name == "我的餐饮")
        #expect(reset.entries == original.entries)
    }

    @Test func customCategoryDefaultDoesNotGuessFromNameAndUnknownSymbolSurvivesBackup() throws {
        let category = Category(name: "餐饮", direction: .expense, symbol: "future.unavailable.symbol")
        let book = try CatalogEditor.saveCategory(category, in: LedgerBook())
        #expect(CategorySymbolCatalog.defaultSymbol(for: category.id) == "tag")
        let decoded = try BackupCodec.decode(BackupCodec.encode(LedgerBackupSnapshot(book: book, draft: nil, settings: LedgerSettings())))
        #expect(decoded.book.categories.last == category)
    }
}
