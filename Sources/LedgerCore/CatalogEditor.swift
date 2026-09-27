import Foundation

public enum CatalogError: Error, Equatable, Sendable {
    case immutableAccountFields
    case immutableCategoryStructure
    case invalidCategoryParent
    case lastActiveSubject
}

/// Changes catalog records in place by stable ID without rewriting any historical event.
public enum CatalogEditor {
    public static func saveTag(_ tag: EntryTag, in book: LedgerBook) throws -> LedgerBook {
        try LedgerEngine.validate(book)
        var result = book
        if let index = result.tags.firstIndex(where: { $0.id == tag.id }) { result.tags[index] = tag }
        else { result.tags.append(tag) }
        try LedgerEngine.validate(result)
        return result
    }

    public static func saveProject(_ project: EntryProject, in book: LedgerBook) throws -> LedgerBook {
        try LedgerEngine.validate(book)
        var result = book
        if let index = result.projects.firstIndex(where: { $0.id == project.id }) { result.projects[index] = project }
        else { result.projects.append(project) }
        try LedgerEngine.validate(result)
        return result
    }

    public static func saveAccount(_ account: Account, in book: LedgerBook) throws -> LedgerBook {
        try LedgerEngine.validate(book)
        var result = book
        if let index = result.accounts.firstIndex(where: { $0.id == account.id }) {
            let existing = result.accounts[index]
            guard account.kind == existing.kind, account.nature == existing.nature,
                  account.currency == existing.currency, account.openingMinor == existing.openingMinor,
                  account.openingDate == existing.openingDate else { throw CatalogError.immutableAccountFields }
            result.accounts[index] = account
        } else {
            result.accounts.append(account)
        }
        try LedgerEngine.validate(result)
        return result
    }

    public static func saveCategory(_ category: Category, in book: LedgerBook) throws -> LedgerBook {
        try LedgerEngine.validate(book)
        guard category.direction.needsCategory,
              !category.symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LedgerError.invalidCategory
        }
        var result = book
        if let index = result.categories.firstIndex(where: { $0.id == category.id }) {
            let existing = result.categories[index]
            guard category.parentID == existing.parentID, category.direction == existing.direction else {
                throw CatalogError.immutableCategoryStructure
            }
            // A parent may be disabled independently; keep the child's own saved active state.
            result.categories[index] = category
        } else {
            if let parentID = category.parentID {
                guard let parent = result.categories.first(where: { $0.id == parentID }),
                      parent.parentID == nil, parent.isActive, parent.direction == category.direction else {
                    throw CatalogError.invalidCategoryParent
                }
            }
            result.categories.append(category)
        }
        try LedgerEngine.validate(result)
        return result
    }

    public static func saveSubject(_ subject: Subject, in book: LedgerBook) throws -> LedgerBook {
        try LedgerEngine.validate(book)
        guard !subject.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LedgerError.invalidSubject
        }
        var result = book
        if let index = result.subjects.firstIndex(where: { $0.id == subject.id }) {
            result.subjects[index] = subject
        } else {
            result.subjects.append(subject)
        }
        guard result.subjects.contains(where: \.isActive) else { throw CatalogError.lastActiveSubject }
        try LedgerEngine.validate(result)
        return result
    }
}
