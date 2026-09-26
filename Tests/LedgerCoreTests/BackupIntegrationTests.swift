import Foundation
import Testing
@testable import LedgerCore

@Suite("LedgerCoreTests complete ZIP backup")
struct BackupIntegrationTests {
    @Test func historicalExpenseAndAdjustmentRoundTripWithoutReplayingCash() throws {
        let today = Date(timeIntervalSince1970: 1_790_380_800.123456)
        let lastMonth = today.addingTimeInterval(-32 * 86_400)
        let account = Account(name: "银行卡", openingMinor: 10_000_00, openingDate: today)
        var book = LedgerBook(accounts: [account])
        let expense = LedgerEntry(kind: .expense, amount: Money(minorUnits: 2_000_00), accountID: account.id,
                                  categoryID: SeedData.mealsID, occurredAt: lastMonth, createdAt: today,
                                  title: "补录历史", note: "逗号,双引号\"\n换行\r\n原文 \\N")
        book = try LedgerEngine.record(expense, in: book)
        #expect(try LedgerEngine.balance(of: account.id, in: book).minorUnits == 8_000_00)
        book = try LedgerEngine.adjustBalance(accountID: account.id, to: Money(minorUnits: 10_000_00),
                                               operationID: UUID(), at: today, note: "手工更正", in: book)
        let draft = EntryDraft(kind: .income, amountText: "12.", accountID: account.id,
                               incomeCategoryID: SeedData.salaryIncomeID, occurredAt: today, note: "  未完成  ")
        let snapshot = LedgerBackupSnapshot(book: book, draft: draft, settings: LedgerSettings(defaultAccountID: account.id))
        let zip = try BackupArchive.encode(BackupCodec.encode(snapshot, createdAt: today))
        let restored = try BackupCodec.decode(BackupArchive.decode(zip))
        #expect(restored == snapshot)
        #expect(try LedgerEngine.balance(of: account.id, in: restored.book).minorUnits == 10_000_00)
        #expect(try LedgerEngine.consumption(in: restored.book, from: lastMonth, to: today, currency: .cny).minorUnits == 2_000_00)
        #expect(try LedgerEngine.record(expense, in: restored.book) == book)
    }

    @Test func deletedOperationRemainsConsumedAfterCompleteBackup() throws {
        let account = Account(name: "微信", openingMinor: 100_00)
        let entry = LedgerEntry(kind: .expense, amount: Money(minorUnits: 25_00), accountID: account.id,
                                categoryID: SeedData.mealsID, note: "删除后不应回到备份")
        let recorded = try LedgerEngine.record(entry, in: LedgerBook(accounts: [account]))
        let deleted = try LedgerEngine.delete(entryID: entry.id, in: recorded)
        let snapshot = LedgerBackupSnapshot(book: deleted, draft: nil, settings: LedgerSettings())
        let files = try BackupCodec.encode(snapshot)
        #expect(!files.values.contains { String(data: $0, encoding: .utf8)?.contains(entry.note) == true })
        let restored = try BackupCodec.decode(BackupArchive.decode(BackupArchive.encode(files)))
        #expect(restored == snapshot)
        #expect(throws: LedgerError.operationConflict) { try LedgerEngine.record(entry, in: restored.book) }
        #expect(try LedgerEngine.balance(of: account.id, in: restored.book).minorUnits == 100_00)
    }
}
