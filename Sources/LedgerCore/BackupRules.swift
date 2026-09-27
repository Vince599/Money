import Foundation

enum BackupRules {
    static func encode(_ rules: [ImportRule]) -> [String: [[String?]]] {
        let conditions = rules.flatMap { rule in rule.conditions.map { (rule.id, $0) } }
        let actions = rules.flatMap { rule in rule.actions.map { (rule.id, $0) } }
        return [
            BackupSchema.importRules.name: rules.enumerated().map { index, rule in
                [String(index), rule.id.uuidString.lowercased(), rule.name, rule.namespace, String(rule.priority), String(rule.isEnabled), String(rule.version),
                 rule.currency?.rawValue, rule.minimumMinor.map(String.init), rule.maximumMinor.map(String.init)]
            },
            BackupSchema.importRuleConditions.name: conditions.enumerated().map { index, pair in
                [String(index), pair.0.uuidString.lowercased(), pair.1.field.rawValue, pair.1.comparison.rawValue, pair.1.value]
            },
            BackupSchema.importRuleActions.name: actions.enumerated().map { index, pair in
                [String(index), pair.0.uuidString.lowercased(), pair.1.field.rawValue, pair.1.targetID.uuidString.lowercased()]
            }
        ]
    }
    static func decode(_ tables: [String: [BackupRow]]) throws -> [ImportRule] {
        func ordered(_ table: BackupTable) throws -> [BackupRow] {
            let rows = tables[table.name] ?? []
            for (index, row) in rows.enumerated() {
                guard try row.int("position") == index else { throw BackupError.invalidArchive(reason: "Invalid rule order") }
            }
            return rows
        }
        var conditions: [UUID: [ImportRuleCondition]] = [:], actions: [UUID: [ImportRuleAction]] = [:]
        for row in try ordered(BackupSchema.importRuleConditions) {
            conditions[try row.uuid("rule_id"), default: []].append(ImportRuleCondition(field: try row.enumeration("field"), comparison: try row.enumeration("comparison"), value: try row.string("value")))
        }
        for row in try ordered(BackupSchema.importRuleActions) {
            actions[try row.uuid("rule_id"), default: []].append(ImportRuleAction(field: try row.enumeration("field"), targetID: try row.uuid("target_id")))
        }
        let result = try ordered(BackupSchema.importRules).map { row in
            let id = try row.uuid("id")
            return ImportRule(id: id, name: try row.string("name"), namespace: row.optionalString("namespace"), priority: try row.int("priority"),
                              isEnabled: try row.bool("is_enabled"), version: try row.int("version"),
                              currency: try row.optionalString("currency").map { _ in try row.enumeration("currency") },
                              minimumMinor: try row.optionalString("minimum_minor").map { _ in try row.int64("minimum_minor") },
                              maximumMinor: try row.optionalString("maximum_minor").map { _ in try row.int64("maximum_minor") },
                              conditions: conditions.removeValue(forKey: id) ?? [], actions: actions.removeValue(forKey: id) ?? [])
        }
        guard conditions.isEmpty, actions.isEmpty else { throw BackupError.invalidArchive(reason: "Orphan import rule condition or action") }
        return result
    }
}
