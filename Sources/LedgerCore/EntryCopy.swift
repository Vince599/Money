import Foundation

extension EntryDraft {
    /// Copying prepares new input only. It neither edits the source nor posts another ledger event.
    /// Unavailable references remain unselected so the user can choose replacements explicitly.
    public static func copying(_ entry: LedgerEntry, in book: LedgerBook,
                               settings: LedgerSettings = LedgerSettings(),
                               at date: Date = Date()) throws -> EntryDraft {
        guard entry.amount.minorUnits > 0, date.timeIntervalSinceReferenceDate.isFinite else {
            throw LedgerError.invalidAmount
        }

        let activeSubjects = book.subjects.filter(\.isActive)
        let preferredSubjects = [entry.subjectID, settings.defaultSubjectID, SeedData.mpcID]
        guard let subjectID = preferredSubjects.first(where: { candidate in
            activeSubjects.contains(where: { $0.id == candidate })
        }) ?? activeSubjects.first?.id else { throw LedgerError.invalidSubject }

        let accountID = book.accounts.first(where: {
            $0.id == entry.accountID && $0.isActive && $0.currency == entry.amount.currency
        })?.id
        let destinationID = entry.kind == .transfer ? book.accounts.first(where: {
            $0.id == entry.destinationAccountID && $0.id != entry.accountID
                && $0.isActive && $0.currency == entry.amount.currency
        })?.id : nil

        var categoryID: UUID?
        if entry.kind != .transfer,
           let category = book.categories.first(where: { $0.id == entry.categoryID }),
           category.isActive, category.direction == entry.kind,
           let parentID = category.parentID,
           let parent = book.categories.first(where: { $0.id == parentID }),
           parent.isActive, parent.parentID == nil, parent.direction == entry.kind,
           !book.categories.contains(where: { $0.parentID == category.id }) {
            categoryID = category.id
        }

        return EntryDraft(kind: entry.kind, amountText: entry.amount.decimalString,
                          accountID: accountID, destinationAccountID: destinationID,
                          subjectID: entry.kind.isRecovery ? entry.subjectID : subjectID,
                          expenseCategoryID: entry.kind == .expense ? categoryID : nil,
                          incomeCategoryID: entry.kind == .income ? categoryID : nil,
                          occurredAt: date, title: entry.title, note: entry.note,
                          originalEntryID: entry.originalEntryID)
    }
}
