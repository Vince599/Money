import Foundation

public enum ImportRuleSourceField: String, Codable, CaseIterable, Sendable {
    case title, note, category, account, kind
    public var name: String {
        switch self { case .title: "标题"; case .note: "备注"; case .category: "来源分类"; case .account: "来源账户"; case .kind: "收支方向" }
    }
    var column: Int { switch self { case .title: 8; case .note: 9; case .category: 7; case .account: 5; case .kind: 2 } }
}
public enum ImportRuleComparison: String, Codable, CaseIterable, Sendable {
    case equals, contains
    public var name: String { self == .equals ? "等于" : "包含" }
}
public struct ImportRuleCondition: Codable, Equatable, Sendable {
    public var field: ImportRuleSourceField
    public var comparison: ImportRuleComparison
    public var value: String
    public init(field: ImportRuleSourceField = .title, comparison: ImportRuleComparison = .contains, value: String = "") {
        self.field = field; self.comparison = comparison; self.value = value
    }
}
public enum ImportRuleTargetField: String, Codable, CaseIterable, Sendable {
    case account, destinationAccount, category, subject, tag, project
    public var name: String { switch self { case .account: "付款／收款账户"; case .destinationAccount: "转入账户"; case .category: "分类"; case .subject: "主体"; case .tag: "追加标签"; case .project: "项目" } }
    public func value(in row: ImportRow) -> UUID? {
        switch self { case .account: row.accountID; case .destinationAccount: row.destinationAccountID; case .category: row.categoryID; case .subject: row.subjectID; case .tag: nil; case .project: row.projectID }
    }
}
extension ImportRuleTargetField {
    /// Tag actions append one target, but comparisons and previews retain the complete ordered list.
    public func values(in row: ImportRow) -> [UUID] {
        self == .tag ? row.tagIDs : value(in: row).map { [$0] } ?? []
    }
}
public struct ImportRuleAction: Codable, Equatable, Sendable {
    public var field: ImportRuleTargetField
    public var targetID: UUID
    public init(field: ImportRuleTargetField, targetID: UUID) { self.field = field; self.targetID = targetID }
}
public struct ImportRule: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var namespace: String?
    public var priority: Int
    public var isEnabled: Bool
    public var version: Int
    public var currency: Currency?
    public var minimumMinor: Int64?
    public var maximumMinor: Int64?
    public var conditions: [ImportRuleCondition]
    public var actions: [ImportRuleAction]
    public init(id: UUID = UUID(), name: String = "", namespace: String? = nil, priority: Int = 100,
                isEnabled: Bool = true, version: Int = 1, currency: Currency? = nil,
                minimumMinor: Int64? = nil, maximumMinor: Int64? = nil,
                conditions: [ImportRuleCondition] = [], actions: [ImportRuleAction] = []) {
        self.id = id; self.name = name; self.namespace = namespace; self.priority = priority
        self.isEnabled = isEnabled; self.version = version; self.currency = currency
        self.minimumMinor = minimumMinor; self.maximumMinor = maximumMinor; self.conditions = conditions; self.actions = actions
    }
}
public struct ImportRuleChoice: Identifiable, Sendable {
    public let id: UUID
    public let rules: [ImportRule]
}
public struct ImportRuleSuggestion: Identifiable, Sendable {
    public let id: ImportRuleTargetField
    public let currentID: UUID?
    public let choices: [ImportRuleChoice]
    /// A tied top priority with different values has no preferred answer.
    public let preferredID: UUID?
    public var hasConflict: Bool { choices.count > 1 }
}
public struct ImportRuleReview: Sendable {
    public let batchID: UUID
    public let rowID: UUID
    public let matchedRules: [ImportRule]
    public let suggestions: [ImportRuleSuggestion]
    public let warnings: [String]
    public let expectedBook: LedgerBook
}
public struct ImportRuleApplyPlan: Sendable {
    public let batch: ImportBatch
    public let rowID: UUID
    public let expectedBook: LedgerBook
}

public enum ImportRuleEngine {
    public static func validate(_ rules: [ImportRule]) throws {
        guard Set(rules.map(\.id)).count == rules.count else { throw ImportError.invalidState }
        for rule in rules {
            guard !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, rule.name.utf8.count <= 256,
                  (0...10_000).contains(rule.priority), rule.version > 0,
                  !rule.conditions.isEmpty || rule.minimumMinor != nil || rule.maximumMinor != nil,
                  rule.conditions.count <= 12, !rule.actions.isEmpty, rule.actions.count <= ImportRuleTargetField.allCases.count,
                  Set(rule.actions.map(\.field)).count == rule.actions.count else { throw ImportError.invalidFile("规则须填写名称、至少一个条件及动作；优先级范围为 0—10000。") }
            if let namespace = rule.namespace {
                guard !namespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, namespace.utf8.count <= 256 else { throw ImportError.invalidFile("来源身份不能为空白，最多 256 字节。") }
            }
            for condition in rule.conditions {
                guard !condition.value.isEmpty, condition.value.utf8.count <= 4096 else { throw ImportError.invalidFile("条件文字不能为空，且不能超过 4096 字节。") }
                if condition.field == .kind {
                    guard condition.comparison == .equals, ["expense", "income", "transfer"].contains(condition.value) else { throw ImportError.invalidFile("方向条件须选择支出、收入或转账。") }
                }
            }
            if rule.minimumMinor != nil || rule.maximumMinor != nil {
                guard rule.currency != nil, (rule.minimumMinor ?? 0) >= 0, (rule.maximumMinor ?? 0) >= 0,
                      (rule.minimumMinor ?? 0) <= (rule.maximumMinor ?? Int64.max) else { throw ImportError.invalidFile("金额范围需指定币种，且最小金额不能大于最大金额。") }
            }
        }
    }
    /// Missing/inactive references pause suggestions; they remain visible and repairable.
    public static func availabilityIssues(_ rule: ImportRule, in book: LedgerBook) -> [String] {
        rule.actions.compactMap { action in
            switch action.field {
            case .account, .destinationAccount:
                guard let account = book.accounts.first(where: { $0.id == action.targetID }), account.isActive else { return "账户缺失或已停用" }
                if let currency = rule.currency, account.currency != currency { return "账户与规则币种不同" }
            case .category:
                guard let category = book.categories.first(where: { $0.id == action.targetID }), category.isActive,
                      let parent = book.categories.first(where: { $0.id == category.parentID }), parent.isActive else { return "分类缺失、已停用或不是启用的二级分类" }
            case .tag:
                guard book.tags.contains(where: { $0.id == action.targetID && $0.isActive }) else { return "标签缺失或已停用" }
            case .project:
                guard book.projects.contains(where: { $0.id == action.targetID && !$0.isArchived }) else { return "项目缺失或已归档" }
            case .subject:
                guard book.subjects.contains(where: { $0.id == action.targetID && $0.isActive }) else { return "主体缺失或已停用" }
            }
            return nil
        }
    }
    public static func save(_ rule: ImportRule, expectedVersion: Int? = nil, in book: LedgerBook) throws -> LedgerBook {
        try LedgerEngine.validate(book); try validate([rule])
        if rule.isEnabled, !availabilityIssues(rule, in: book).isEmpty { throw ImportError.invalidFile("规则目标不可用，请修复动作或关闭启用开关后保存。") }
        var result = book
        if let index = result.importRules.firstIndex(where: { $0.id == rule.id }) {
            let old = result.importRules[index]
            guard old.version == expectedVersion, rule.version == old.version, old.version < Int.max else { throw ImportError.stalePreview }
            var updated = rule; updated.version += 1; result.importRules[index] = updated
        } else {
            guard expectedVersion == nil, rule.version == 1 else { throw ImportError.stalePreview }
            result.importRules.append(rule)
        }
        try LedgerEngine.validate(result)
        return result
    }
    public static func affectedRules(field: ImportRuleTargetField, id: UUID, in book: LedgerBook) -> [ImportRule] {
        book.importRules.filter { rule in rule.actions.contains { action in
            (action.field == field || (field == .account && action.field == .destinationAccount)) && (action.targetID == id || (field == .category && book.categories.contains { $0.id == action.targetID && $0.parentID == id }))
        } }
    }
    private static func matches(_ rule: ImportRule, row: ImportRow, batch: ImportBatch) -> Bool {
        guard rule.namespace == nil || rule.namespace == batch.namespace,
              rule.currency == nil || rule.currency?.rawValue == row.raw[4] else { return false }
        for condition in rule.conditions {
            let value = row.raw[condition.field.column]
            if condition.comparison == .equals ? value != condition.value : !value.contains(condition.value) { return false }
        }
        if rule.minimumMinor != nil || rule.maximumMinor != nil {
            guard let currency = rule.currency, let amount = try? Money.parse(row.raw[3], currency: currency),
                  amount.minorUnits >= (rule.minimumMinor ?? 0), amount.minorUnits <= (rule.maximumMinor ?? Int64.max) else { return false }
        }
        return true
    }
    public static func review(batchID: UUID, rowID: UUID, in book: LedgerBook) throws -> ImportRuleReview {
        try LedgerEngine.validate(book)
        guard let batch = book.importBatches.first(where: { $0.id == batchID }), batch.revertedAt == nil,
              let row = batch.rows.first(where: { $0.id == rowID }), row.state == .pending else { throw ImportError.unavailableRow }
        return reviewValidated(row: row, batch: batch, in: book)
    }
    // Call only after validating the book and selected pending rows.
    static func reviewValidated(row: ImportRow, batch: ImportBatch, in book: LedgerBook) -> ImportRuleReview {
        let rules = book.importRules.filter { $0.isEnabled && matches($0, row: row, batch: batch) }.sorted {
            $0.priority == $1.priority ? $0.id.uuidString < $1.id.uuidString : $0.priority < $1.priority
        }
        var warnings: [String] = [], valid: [ImportRuleTargetField: [(UUID, ImportRule)]] = [:]
        for rule in rules {
            let issues = availabilityIssues(rule, in: book)
            guard issues.isEmpty else { warnings.append(rule.name + "：已暂停建议（" + issues.joined(separator: "、") + "）"); continue }
            for action in rule.actions {
                if action.field == .destinationAccount && row.raw[2] != "transfer" {
                    warnings.append(rule.name + "：转入账户只适用于转账"); continue
                }
                if (action.field == .account || action.field == .destinationAccount), book.accounts.first(where: { $0.id == action.targetID })?.currency.rawValue != row.raw[4] {
                    warnings.append(rule.name + "：账户币种与此行不符"); continue
                }
                if action.field == .category, book.categories.first(where: { $0.id == action.targetID })?.direction.rawValue != row.raw[2] {
                    warnings.append(rule.name + "：分类方向与此行不符"); continue
                }
                valid[action.field, default: []].append((action.targetID, rule))
            }
        }
        let suggestions = ImportRuleTargetField.allCases.compactMap { field -> ImportRuleSuggestion? in
            let values = valid[field, default: []]
            guard let first = values.first else { return nil }
            var seen = Set<UUID>()
            let choices = values.compactMap { target, _ -> ImportRuleChoice? in
                guard seen.insert(target).inserted else { return nil }
                return ImportRuleChoice(id: target, rules: values.filter { $0.0 == target }.map { $0.1 })
            }
            let top = Set(values.filter { $0.1.priority == first.1.priority }.map { $0.0 })
            return ImportRuleSuggestion(id: field, currentID: field.value(in: row), choices: choices, preferredID: top.count == 1 ? first.0 : nil)
        }
        return ImportRuleReview(batchID: batch.id, rowID: row.id, matchedRules: rules, suggestions: suggestions, warnings: warnings, expectedBook: book)
    }
    public static func prepare(_ review: ImportRuleReview, selections: [ImportRuleTargetField: UUID]) throws -> ImportRuleApplyPlan {
        guard !selections.isEmpty else { throw ImportError.invalidFile("请明确选择要应用的字段；未选择的字段保持原值。") }
        var batch = review.expectedBook.importBatches.first { $0.id == review.batchID }!
        let index = batch.rows.firstIndex { $0.id == review.rowID }!
        batch.rows[index] = try applying(selections, to: batch.rows[index], review: review)
        return ImportRuleApplyPlan(batch: batch, rowID: review.rowID, expectedBook: review.expectedBook)
    }
    static func applying(_ selections: [ImportRuleTargetField: UUID], to original: ImportRow, review: ImportRuleReview) throws -> ImportRow {
        var row = original
        for (field, target) in selections {
            guard review.suggestions.contains(where: { $0.id == field && $0.choices.contains { $0.id == target } }) else { throw ImportError.invalidState }
            switch field {
            case .account: row.accountID = target
            case .destinationAccount: row.destinationAccountID = target
            case .project: row.projectID = target
            case .tag: if !row.tagIDs.contains(target) { row.tagIDs.append(target) }
            case .category: row.categoryID = target
            case .subject: row.subjectID = target
            }
        }
        if row.raw[2] == "transfer", selections[.account] != nil || selections[.destinationAccount] != nil,
           let account = row.accountID, account == row.destinationAccountID {
            throw ImportError.invalidFile("来源交易 " + row.sourceID + " 的转出与转入账户不能相同，请调整选择。")
        }
        return row
    }
    public static func apply(_ plan: ImportRuleApplyPlan, in book: LedgerBook) throws -> LedgerBook {
        guard book == plan.expectedBook else { throw ImportError.stalePreview }
        return try ImportEngine.save(plan.batch, in: book, expectedVersion: plan.batch.version)
    }
}
