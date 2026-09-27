import Foundation
import Testing
@testable import LedgerCore

@Suite("Refund and recovery accounting")
struct RecoveryTests {
    private let january = Date(timeIntervalSinceReferenceDate: 789_000_000)
    private var june: Date { january.addingTimeInterval(150 * 86_400) }
    private func fixture() throws -> (LedgerBook, LedgerEntry, Account) {
        let wallet = Account(name: "购买账户", openingMinor: 200_000)
        let receiving = Account(name: "收款账户", includedInSummary: false)
        let original = LedgerEntry(kind: .expense, amount: Money(minorUnits: 100_000), accountID: wallet.id,
                                   categoryID: SeedData.mealsID, occurredAt: january, title: "购买", note: "原备注")
        return (try LedgerEngine.record(original, in: LedgerBook(accounts: [wallet, receiving])), original, receiving)
    }
    private func recovery(_ original: LedgerEntry, _ account: Account, amount: Int64 = 20_000, kind: EntryKind = .recovery) -> LedgerEntry {
        LedgerEntry(kind: kind, amount: Money(minorUnits: amount, currency: original.amount.currency), accountID: account.id,
                    subjectID: original.subjectID, occurredAt: june, originalEntryID: original.id)
    }

    @Test func crossPeriodRecoveryCreditsCashWithoutReducingConsumptionOrOriginal() throws {
        let (book, original, receiving) = try fixture()
        let refund = recovery(original, receiving, kind: .refund)
        let updated = try LedgerEngine.record(refund, in: book)
        #expect(updated.entries[0] == original)
        #expect(try LedgerEngine.balance(of: receiving.id, in: updated).minorUnits == 20_000)
        #expect(try LedgerEngine.consumption(in: updated, from: january, to: june, currency: .cny).minorUnits == 100_000)
        #expect(try LedgerEngine.consumption(in: updated, from: june, to: june.addingTimeInterval(86_400), currency: .cny).minorUnits == 0)
        let summary = try #require(RecoveryRules.summaries(in: updated)[original.id])
        #expect(summary.recovered.minorUnits == 20_000 && summary.netCost.minorUnits == 80_000 && summary.count == 1)
        #expect(try LedgerEngine.record(refund, in: updated) == updated)
        #expect(try LedgerEngine.homeSummary(in: updated, from: june, to: june.addingTimeInterval(86_400)).monthlyConsumption?.minorUnits == 0)
    }

    @Test func multiplePartialRefundsAndCreditCardRefundUseCorrectBalances() throws {
        var (book, original, receiving) = try fixture()
        receiving.kind = .creditCard; receiving.nature = .liability; receiving.openingMinor = 90_000
        book.accounts[1] = receiving
        book = try LedgerEngine.record(recovery(original, receiving, kind: .refund), in: book)
        book = try LedgerEngine.record(recovery(original, receiving, amount: 30_000), in: book)
        #expect(try LedgerEngine.balance(of: receiving.id, in: book).minorUnits == 40_000)
        #expect(try RecoveryRules.summaries(in: book)[original.id]?.netCost.minorUnits == 50_000)
    }

    @Test func invalidLinksAreRejectedWithoutMutatingBook() throws {
        let (book, original, receiving) = try fixture()
        let valid = recovery(original, receiving)
        var invalids: [LedgerEntry] = []
        var e = valid; e.originalEntryID = nil; invalids.append(e)
        e = valid; e.originalEntryID = UUID(); invalids.append(e)
        e = valid; e.originalEntryID = e.id; invalids.append(e)
        e = valid; e.categoryID = SeedData.mealsID; invalids.append(e)
        e = valid; e.destinationAccountID = original.accountID; invalids.append(e)
        e = valid; e.occurredAt = january.addingTimeInterval(-1); invalids.append(e)
        e = valid; e.allowsNetRecovery = true; invalids.append(e)
        for invalid in invalids { #expect(throws: LedgerError.self) { try LedgerEngine.record(invalid, in: book) } }
        let other = Subject(name: "另一个主体")
        var withSubject = book; withSubject.subjects.append(other)
        e = valid; e.subjectID = other.id
        #expect(throws: LedgerError.invalidRecovery) { try LedgerEngine.record(e, in: withSubject) }
        let usd = Account(name: "美元", currency: .usd)
        var withUSD = book; withUSD.accounts.append(usd)
        e = valid; e.accountID = usd.id; e.amount = Money(minorUnits: 20_000, currency: .usd)
        #expect(throws: LedgerError.currencyMismatch) { try LedgerEngine.record(e, in: withUSD) }
        #expect(book.entries == [original])
    }

    @Test func excessRequiresExplicitPurchaseOptInAndCannotBeTurnedOffWhileInvalid() throws {
        var (book, original, receiving) = try fixture()
        let excess = recovery(original, receiving, amount: 120_000)
        #expect(throws: LedgerError.excessRecoveryRequiresConfirmation) { try LedgerEngine.record(excess, in: book) }
        original.operationID = UUID(); original.allowsNetRecovery = true
        book = try LedgerEngine.replace(original, expectedVersion: 1, in: book)
        book = try LedgerEngine.record(excess, in: book)
        #expect(try RecoveryRules.summaries(in: book)[original.id]?.netCost.minorUnits == -20_000)
        var disable = book.entries[0]; disable.operationID = UUID(); disable.allowsNetRecovery = nil
        #expect(throws: LedgerError.excessRecoveryRequiresConfirmation) { try LedgerEngine.replace(disable, expectedVersion: 2, in: book) }
        var reduced = book.entries[0]; reduced.amount = Money(minorUnits: 10_000); reduced.operationID = UUID(); reduced.allowsNetRecovery = nil
        #expect(throws: LedgerError.excessRecoveryRequiresConfirmation) { try LedgerEngine.replace(reduced, expectedVersion: 2, in: book) }
    }

    @Test func reclassifyingOrRelinkingRecoveryPreservesOneCashEvent() throws {
        let (initial, original, receiving) = try fixture()
        let refund = recovery(original, receiving)
        let book = try LedgerEngine.record(refund, in: initial)
        var income = refund; income.kind = .income; income.originalEntryID = nil
        income.categoryID = SeedData.salaryIncomeID; income.operationID = UUID()
        let updated = try LedgerEngine.replace(income, expectedVersion: 1, in: book)
        #expect(updated.entries.count == 2)
        #expect(try LedgerEngine.balance(of: receiving.id, in: updated).minorUnits == 20_000)
        #expect(try RecoveryRules.summaries(in: updated).isEmpty)
        #expect(try LedgerEngine.delete(entryID: original.id, in: updated).entries.count == 1)
        let second = LedgerEntry(kind: .expense, amount: Money(minorUnits: 40_000), accountID: original.accountID,
                                 categoryID: SeedData.mealsID, occurredAt: january)
        let withSecond = try LedgerEngine.record(second, in: book)
        var linked = refund; linked.originalEntryID = second.id; linked.operationID = UUID()
        let relinked = try LedgerEngine.replace(linked, expectedVersion: 1, in: withSecond)
        #expect(try RecoveryRules.summaries(in: relinked)[original.id] == nil)
        #expect(try RecoveryRules.summaries(in: relinked)[second.id]?.netCost.minorUnits == 20_000)
        #expect(try LedgerEngine.balance(of: receiving.id, in: relinked).minorUnits == 20_000)
    }

    @Test func deletionRequiresExplicitGroupAndStalePreviewCannotDeleteNewLinks() throws {
        let (initial, original, receiving) = try fixture()
        let refund = recovery(original, receiving)
        let book = try LedgerEngine.record(refund, in: initial)
        #expect(throws: LedgerError.linkedEntriesExist) { try LedgerEngine.delete(entryID: original.id, in: book) }
        #expect(throws: LedgerError.linkedEntriesExist) { try LedgerEngine.deletionPlan(entryID: original.id, in: book) }
        let plan = try LedgerEngine.deletionPlan(entryID: original.id, includingRecoveries: true, in: book)
        #expect(plan.entries.count == 2)
        #expect(plan.accounts.first { $0.id == receiving.id }?.after.minorUnits == 0)
        let updated = try LedgerEngine.delete(plan, in: book)
        #expect(updated.entries.isEmpty)
        #expect(updated.retiredOperationIDs.isSuperset(of: [original.operationID, refund.operationID]))
        #expect(throws: LedgerError.operationConflict) { try LedgerEngine.record(refund, in: updated) }
        let changed = try LedgerEngine.record(recovery(original, receiving, amount: 1), in: book)
        #expect(throws: LedgerError.staleVersion) { try LedgerEngine.delete(plan, in: changed) }
        let childPlan = try LedgerEngine.deletionPlan(entryID: refund.id, in: book)
        #expect(try LedgerEngine.delete(childPlan, in: book).entries == [original])
    }

    @Test func backupAndDraftPreserveEveryNewFieldAndLegacyJSONDefaultsToNil() throws {
        var (book, original, receiving) = try fixture()
        original.operationID = UUID(); original.allowsNetRecovery = true
        book = try LedgerEngine.replace(original, expectedVersion: 1, in: book)
        book = try LedgerEngine.record(recovery(original, receiving, amount: 120_000), in: book)
        let draft = EntryDraft(kind: .refund, amountText: "20+", accountID: receiving.id, originalEntryID: original.id, allowsNetRecovery: true)
        let snapshot = LedgerBackupSnapshot(book: book, draft: draft, settings: LedgerSettings())
        let restored = try BackupCodec.decode(BackupArchive.decode(BackupArchive.encode(BackupCodec.encode(snapshot))))
        #expect(restored == snapshot)
        let files = try BackupCodec.encode(snapshot)
        let manifest = try #require(BackupSchema.manifest.read(files["manifest.csv"]!).first)
        #expect(try manifest.string("profile") == "ledger-core-v5")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "originalEntryID"); object.removeValue(forKey: "allowsNetRecovery")
        let legacy = try JSONDecoder().decode(LedgerEntry.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.originalEntryID == nil && legacy.allowsNetRecovery == nil)
        let copied = try EntryDraft.copying(book.entries[1], in: book)
        #expect(copied.originalEntryID == original.id && copied.operationID != book.entries[1].operationID)
        #expect(copied.allowsNetRecovery == nil)
    }

    @Test func recoveryRetainsInactiveHistoricalSubjectAndCannotBecomeACategory() throws {
        var (book, original, receiving) = try fixture()
        let subject = Subject(name: "已停用归属", isActive: false)
        book.subjects.append(subject)
        original.subjectID = subject.id
        book.entries = [original]
        let refund = recovery(original, receiving, kind: .refund)
        book = try LedgerEngine.record(refund, in: book)
        let draft = try EntryDraft.copying(refund, in: book)
        #expect(draft.subjectID == subject.id)
        #expect(try LedgerEngine.record(draft.entry(in: book), in: book).entries.count == 3)
        let category = Category(name: "不能新增的退款类别", direction: .refund)
        #expect(throws: LedgerError.invalidCategory) { try CatalogEditor.saveCategory(category, in: book) }
    }
}
