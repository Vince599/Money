import Foundation
import Testing
@testable import LedgerCore

@Suite("Recovery association queries")
struct EntryRecoveryQueryTests {
    private let day = Date(timeIntervalSince1970: 1_768_435_200)

    private func fixture() throws -> (LedgerBook, LedgerEntry, LedgerEntry, [LedgerEntry]) {
        let paying = Account(name: "Bank", openingMinor: 200_000)
        let receiving = Account(name: "Wallet", includedInSummary: false)
        let original = LedgerEntry(kind: .expense, amount: Money(minorUnits: 100_000), accountID: paying.id,
            categoryID: SeedData.mealsID, occurredAt: day, title: "Original")
        let plain = LedgerEntry(kind: .expense, amount: Money(minorUnits: 100_000), accountID: paying.id,
            categoryID: SeedData.mealsID, occurredAt: day, title: "Plain")
        var book = LedgerBook(accounts: [paying, receiving])
        for entry in [original, plain] { book = try LedgerEngine.record(entry, in: book) }
        let children = [EntryKind.refund, .recovery].map {
            LedgerEntry(kind: $0, amount: Money(minorUnits: 10_000), accountID: receiving.id,
                occurredAt: day.addingTimeInterval(40 * 86_400), originalEntryID: original.id)
        }
        for child in children { book = try LedgerEngine.record(child, in: book) }
        return (book, original, plain, children)
    }

    private func ids(_ book: LedgerBook, _ filter: EntryFilter) throws -> Set<UUID> {
        Set(try EntryQuery.entries(in: book, matching: filter).map(\.id))
    }

    @Test func bothSidesAreUniqueAndLinksSurviveDateAndAccountFiltering() throws {
        let (book, original, plain, children) = try fixture()
        let before = book
        let linked = try EntryQuery.entries(in: book, matching: EntryFilter(recoveryLinkMode: .linked))
        #expect(linked.count == 3)
        #expect(Set(linked.map(\.id)) == Set([original.id] + children.map(\.id)))
        #expect(try ids(book, EntryFilter(recoveryLinkMode: .unlinked)) == [plain.id])
        #expect(try ids(book, EntryFilter(kind: .expense, recoveryLinkMode: .linked)) == [original.id])
        #expect(try ids(book, EntryFilter(accountID: original.accountID, from: day,
            to: day.addingTimeInterval(86_400), recoveryLinkMode: .linked)) == [original.id])
        #expect(try ids(book, EntryFilter(keyword: "plain", recoveryLinkMode: .linked)).isEmpty)
        #expect(try ids(book, EntryFilter(currency: .cny, minimumMinor: 50_000,
            recoveryLinkMode: .linked)) == [original.id])
        #expect(EntryFilter() != EntryFilter(recoveryLinkMode: .linked))
        #expect(EntryFilter(recoveryLinkMode: .linked) != EntryFilter(recoveryLinkMode: .unlinked))
        #expect(book == before)
    }

    @Test func deletingLastRecoveryChangesOriginalMembership() throws {
        var (book, original, plain, children) = try fixture()
        book = try LedgerEngine.delete(entryID: children[0].id, in: book)
        #expect(try ids(book, EntryFilter(recoveryLinkMode: .linked)) == [original.id, children[1].id])
        book = try LedgerEngine.delete(entryID: children[1].id, in: book)
        #expect(try ids(book, EntryFilter(recoveryLinkMode: .linked)).isEmpty)
        #expect(try ids(book, EntryFilter(recoveryLinkMode: .unlinked)) == [original.id, plain.id])
    }

    @Test func movingRecoveryToAnotherPurchaseRecomputesBothParents() throws {
        var (book, original, plain, children) = try fixture()
        book = try LedgerEngine.delete(entryID: children[1].id, in: book)
        var moved = children[0]
        moved.originalEntryID = plain.id; moved.operationID = UUID()
        book = try LedgerEngine.replace(moved, expectedVersion: moved.version, in: book)
        #expect(try ids(book, EntryFilter(recoveryLinkMode: .linked)) == [plain.id, moved.id])
        #expect(try ids(book, EntryFilter(recoveryLinkMode: .unlinked)) == [original.id])
    }

    @Test func sourceAndAssociationFiltersIntersectWithoutPullingInOtherRows() throws {
        let account = Account(name: "Bank", openingMinor: 10_000)
        var batch = try ImportCSV.parse(ImportCSV.template, name: "bank.csv", namespace: "Bank")
        batch.rows[0].accountID = account.id; batch.rows[0].categoryID = SeedData.mealsID
        var book = try ImportEngine.save(batch, in: LedgerBook(accounts: [account]))
        book = try ImportEngine.commit(ImportEngine.prepare(batchID: batch.id,
            importIDs: [batch.rows[0].id], skipIDs: [], in: book), in: book)
        let original = try #require(book.entries.first)
        let refund = LedgerEntry(kind: .refund, amount: Money(minorUnits: 100), accountID: account.id,
            occurredAt: original.occurredAt.addingTimeInterval(86_400), originalEntryID: original.id)
        book = try LedgerEngine.record(refund, in: book)
        #expect(try ids(book, EntryFilter(importNamespace: "Bank", recoveryLinkMode: .linked)) == [original.id])
        #expect(try ids(book, EntryFilter(importSourceMode: .unlinked, recoveryLinkMode: .linked)) == [refund.id])
        #expect(try ids(book, EntryFilter(importNamespace: "Bank", recoveryLinkMode: .unlinked)).isEmpty)
    }

    @Test func backupRestoreRetainsBothSidesWithoutPersistingFilterSettings() throws {
        let (book, _, _, _) = try fixture()
        let restored = try BackupCodec.decode(BackupCodec.encode(LedgerBackupSnapshot(
            book: book, draft: nil, settings: LedgerSettings())))
        for mode in EntryRecoveryLinkMode.allCases {
            let filter = EntryFilter(recoveryLinkMode: mode)
            #expect(try EntryQuery.entries(in: restored.book, matching: filter) == EntryQuery.entries(in: book, matching: filter))
        }
    }
}
