import SwiftUI
import LedgerCore

enum ImportRuleDisplay {
    static func current(_ row: ImportRow, field: ImportRuleTargetField, book: LedgerBook) -> String {
        if field == .tag { return row.tagIDs.isEmpty ? "无标签" : row.tagIDs.map { target($0, field: .tag, book: book) }.joined(separator: "、") }
        if field == .account || field == .destinationAccount,
           let account = book.importBatches.flatMap(\.proposedAccounts).first(where: { $0.id == field.value(in: row) }) { return account.name + "（草稿）" }
        return target(field.value(in: row), field: field, book: book)
    }
    static func target(_ id: UUID?, field: ImportRuleTargetField, book: LedgerBook) -> String {
        guard let id else { return "未选择" }
        switch field {
        case .account, .destinationAccount: return book.accounts.first { $0.id == id }?.name ?? "不可用账户"
        case .category:
            guard let category = book.categories.first(where: { $0.id == id }) else { return "不可用分类" }
            return (book.categories.first { $0.id == category.parentID }?.name ?? "") + " / " + category.name
        case .tag: return book.tags.first { $0.id == id }?.name ?? "不可用标签"
        case .project: return book.projects.first { $0.id == id }?.name ?? "不可用项目"
        case .subject: return book.subjects.first { $0.id == id }?.name ?? "不可用主体"
        }
    }
}

struct ImportRulesListView: View {
    @Bindable var model: LedgerAppModel
    @State private var editing: ImportRule?
    var body: some View {
        List {
            Section {
                Button("新建导入规则") { editing = ImportRule() }.accessibilityIdentifier("import.rules.add")
            } footer: {
                Text("规则只提供待导入行的建议，需逐字段确认后保存。数字越小优先级越高；规则变更不会重写已入账流水。")
            }
            ForEach(model.book.importRules.sorted { $0.priority == $1.priority ? $0.id.uuidString < $1.id.uuidString : $0.priority < $1.priority }) { rule in
                Button { editing = rule } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(rule.name).foregroundStyle(.primary)
                        Text("优先级 \(rule.priority) · \(rule.namespace ?? "全部来源") · 版本 \(rule.version)").font(.caption).foregroundStyle(.secondary)
                        let issues = ImportRuleEngine.availabilityIssues(rule, in: model.book)
                        Text(!rule.isEnabled ? "已停用" : issues.isEmpty ? "可提供建议" : "已暂停：" + issues.joined(separator: "、"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }
        }.navigationTitle("导入规则")
            .sheet(item: $editing) { rule in
                ImportRuleEditor(model: model, rule: rule, existing: model.book.importRules.contains { $0.id == rule.id })
            }
    }
}

struct ImportRuleEditor: View {
    @Bindable var model: LedgerAppModel
    @State var rule: ImportRule
    let existing: Bool
    @State private var namespace: String
    @State private var minimum: String
    @State private var maximum: String
    @State private var enabledFields: Set<ImportRuleTargetField>
    @State private var targets: [ImportRuleTargetField: UUID]
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    init(model: LedgerAppModel, rule: ImportRule, existing: Bool = false, rememberedRow: ImportRow? = nil, namespace: String? = nil) {
        self.model = model; self.existing = existing
        var initial = rule
        if !existing && initial.conditions.isEmpty {
            let field: ImportRuleSourceField = rememberedRow?.raw[8].isEmpty == true ? .category : .title
            initial.conditions = [.init(field: field, comparison: .contains, value: rememberedRow?.title ?? "")]
        }
        _rule = State(initialValue: initial)
        _namespace = State(initialValue: rule.namespace ?? namespace ?? "")
        _minimum = State(initialValue: rule.minimumMinor.map { Money(minorUnits: $0, currency: rule.currency ?? .cny).decimalString } ?? "")
        _maximum = State(initialValue: rule.maximumMinor.map { Money(minorUnits: $0, currency: rule.currency ?? .cny).decimalString } ?? "")
        _enabledFields = State(initialValue: Set(rule.actions.map(\.field)))
        var choices = Dictionary(uniqueKeysWithValues: rule.actions.map { ($0.field, $0.targetID) })
        if let rememberedRow {
            for field in ImportRuleTargetField.allCases { choices[field] = field == .tag ? rememberedRow.tagIDs.first : field.value(in: rememberedRow) }
        }
        _targets = State(initialValue: choices)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("规则名称", text: $rule.name)
                    TextField("来源身份，留空适用全部来源", text: $namespace).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Stepper("优先级 \(rule.priority)（越小越优先）", value: $rule.priority, in: 0...10_000)
                    Toggle("启用规则", isOn: $rule.isEnabled)
                }
                Section {
                    ForEach(rule.conditions.indices, id: \.self) { index in
                        VStack(alignment: .leading) {
                            Picker("来源字段", selection: Binding(get: { rule.conditions[index].field }, set: { field in
                                rule.conditions[index].field = field
                                if field == .kind { rule.conditions[index].comparison = .equals; rule.conditions[index].value = "expense" }
                                else { rule.conditions[index].value = "" }
                            })) {
                                ForEach(ImportRuleSourceField.allCases, id: \.self) { Text($0.name).tag($0) }
                            }
                            if rule.conditions[index].field == .kind {
                                Picker("等于", selection: $rule.conditions[index].value) {
                                    Text("支出").tag("expense"); Text("收入").tag("income"); Text("转账").tag("transfer")
                                }
                            } else {
                                Picker("比较方式", selection: $rule.conditions[index].comparison) {
                                    ForEach(ImportRuleComparison.allCases, id: \.self) { Text($0.name).tag($0) }
                                }
                                TextField("匹配文字", text: $rule.conditions[index].value).textInputAutocapitalization(.never).autocorrectionDisabled()
                            }
                            Button("删除条件", role: .destructive) { rule.conditions.remove(at: index) }
                        }
                    }
                    Button("添加条件") { rule.conditions.append(.init()) }.disabled(rule.conditions.count >= 12)
                    Picker("币种", selection: $rule.currency) {
                        Text("不限币种").tag(Optional<Currency>.none)
                        ForEach(Currency.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                    }
                    TextField("最小金额（含），可留空", text: $minimum).keyboardType(.decimalPad)
                    TextField("最大金额（含），可留空", text: $maximum).keyboardType(.decimalPad)
                } header: { Text("全部条件同时满足") } footer: {
                    Text("文字匹配区分大小写，以 CSV 来源原文为准。金额范围必须指定币种；至少填写一个文字条件或金额边界。")
                }
                Section {
                    ForEach(ImportRuleTargetField.allCases, id: \.self) { field in
                        Toggle("建议" + field.name, isOn: Binding(get: { enabledFields.contains(field) }, set: {
                            if $0 { enabledFields.insert(field) } else { enabledFields.remove(field) }
                        }))
                        if enabledFields.contains(field) { targetPicker(field) }
                    }
                } header: { Text("独立选择要记住的字段") } footer: {
                    Text("未勾选的字段不会保存为动作。草稿中新建的账户需先完成入账，才能用于长期规则。规则不会自动应用。标签每条规则追加一个，保留原标签；项目设为所选值，转入账户仅用于转账。")
                }
                if let message { Text(message).foregroundStyle(.red) }
                Button("保存规则") { save() }.accessibilityIdentifier("import.rules.save")
            }.navigationTitle(existing ? "编辑导入规则" : "新建导入规则").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .disabled(model.isBusy).interactiveDismissDisabled(model.isBusy)
        }
    }

    @ViewBuilder private func targetPicker(_ field: ImportRuleTargetField) -> some View {
        Picker(field.name, selection: Binding<UUID?>(get: { targets[field] }, set: { targets[field] = $0 })) {
            Text("请选择").tag(Optional<UUID>.none)
            // Retain unavailable selections so opening an old rule never silently replaces its target.
            if let id = targets[field], !availableTargets(field).contains(id) {
                Text(ImportRuleDisplay.target(id, field: field, book: model.book) + "（不可用）").tag(Optional(id))
            }
            ForEach(availableTargets(field), id: \.self) { id in
                Text(ImportRuleDisplay.target(id, field: field, book: model.book)).tag(Optional(id))
            }
        }
    }
    private func availableTargets(_ field: ImportRuleTargetField) -> [UUID] {
        switch field {
        case .account, .destinationAccount: model.book.accounts.filter(\.isActive).map(\.id)
        case .category: model.book.categories.filter { category in
            category.isActive && category.parentID != nil && model.book.categories.contains { $0.id == category.parentID && $0.isActive }
        }.map(\.id)
        case .tag: model.book.tags.filter(\.isActive).map(\.id)
        case .project: model.book.projects.filter { !$0.isArchived }.map(\.id)
        case .subject: model.book.subjects.filter(\.isActive).map(\.id)
        }
    }
    private func save() {
        do {
            var value = rule
            value.namespace = namespace.isEmpty ? nil : namespace
            if !minimum.isEmpty || !maximum.isEmpty {
                guard let currency = rule.currency else { throw ImportError.invalidFile("设置金额范围时请选择币种。") }
                value.minimumMinor = minimum.isEmpty ? nil : try Money.parse(minimum, currency: currency).minorUnits
                value.maximumMinor = maximum.isEmpty ? nil : try Money.parse(maximum, currency: currency).minorUnits
            } else { value.minimumMinor = nil; value.maximumMinor = nil }
            value.actions = try ImportRuleTargetField.allCases.filter { enabledFields.contains($0) }.map { field in
                guard let id = targets[field] else { throw ImportError.invalidFile("请为已勾选的字段选择目标。") }
                return ImportRuleAction(field: field, targetID: id)
            }
            try ImportRuleEngine.validate([value])
            Task { if await model.saveImportRule(value, expectedVersion: existing ? rule.version : nil) { dismiss() } else { message = model.errorMessage } }
        } catch { message = model.message(for: error) }
    }
}

struct ImportRuleReviewView: View {
    @Bindable var model: LedgerAppModel
    let batchID: UUID
    let rowID: UUID
    @State private var review: ImportRuleReview?
    @State private var selections: [ImportRuleTargetField: UUID] = [:]
    @State private var plan: ImportRuleApplyPlan?
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                if let review {
                    Text("命中 \(review.matchedRules.count) 条规则。每个字段默认保持当前值，请明确选择要采用的建议。")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(review.suggestions) { suggestion in
                        Section(suggestion.id.name) {
                            if let current = review.expectedBook.importBatches.first(where: { $0.id == batchID })?.rows.first(where: { $0.id == rowID }) {
                                LabeledContent("当前值", value: ImportRuleDisplay.current(current, field: suggestion.id, book: review.expectedBook))
                            }
                            if suggestion.id == .tag { Text("采用后追加此标签，已有标签保留。").font(.footnote).foregroundStyle(.secondary) }
                            if suggestion.hasConflict {
                                Text(suggestion.preferredID == nil ? "同优先级存在冲突，需自行选择。" : "多条规则建议不同，请核对后选择。")
                            }
                            if let preferred = suggestion.preferredID {
                                LabeledContent("按优先级建议", value: name(preferred, field: suggestion.id, book: review.expectedBook))
                            }
                            ForEach(suggestion.choices) { choice in
                                VStack(alignment: .leading) {
                                    Text(name(choice.id, field: suggestion.id, book: review.expectedBook))
                                    Text(choice.rules.map { "\($0.name)（优先级 \($0.priority)，版本 \($0.version)）" }.joined(separator: "、"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Picker("本次采用", selection: Binding<UUID?>(get: { selections[suggestion.id] }, set: { selections[suggestion.id] = $0; plan = nil })) {
                                Text("保持当前值").tag(Optional<UUID>.none)
                                ForEach(suggestion.choices) { Text(name($0.id, field: suggestion.id, book: review.expectedBook)).tag(Optional($0.id)) }
                            }
                        }
                    }
                    if review.suggestions.isEmpty { Text("暂无可用建议，可返回手工映射或编辑规则。") }
                    ForEach(Array(review.warnings.enumerated()), id: \.offset) { Text($0.element).font(.footnote).foregroundStyle(.secondary) }
                    Button("预览所选修改") {
                        do { plan = try ImportRuleEngine.prepare(review, selections: selections); message = nil }
                        catch { message = model.message(for: error) }
                    }.disabled(selections.isEmpty)
                }
                if let plan, let before = review?.expectedBook.importBatches.first(where: { $0.id == batchID })?.rows.first(where: { $0.id == rowID }),
                   let after = plan.batch.rows.first(where: { $0.id == rowID }) {
                    Section("确认修改") {
                        ForEach(ImportRuleTargetField.allCases.filter { selections[$0] != nil }, id: \.self) { field in
                            LabeledContent(field.name, value: ImportRuleDisplay.current(before, field: field, book: plan.expectedBook) + " → " + ImportRuleDisplay.current(after, field: field, book: plan.expectedBook))
                        }
                        Text("仅保存本行导入草稿，不入账。其他字段、其他行和手工记账草稿保持不变。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("确认保存所选字段") {
                            Task { if await model.applyImportRule(plan) { dismiss() } else { message = model.errorMessage } }
                        }.accessibilityIdentifier("import.rules.apply")
                    }
                }
                if let message { Text(message).foregroundStyle(.red) }
                Button("重新读取规则与本行") { Task { await reload() } }
            }.navigationTitle("规则建议").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .disabled(model.isBusy).interactiveDismissDisabled(model.isBusy)
                .task { await reload() }
        }
    }
    private func name(_ id: UUID?, field: ImportRuleTargetField, book: LedgerBook) -> String {
        if (field == .account || field == .destinationAccount), let account = book.importBatches.first(where: { $0.id == batchID })?.proposedAccounts.first(where: { $0.id == id }) { return account.name + "（草稿）" }
        return ImportRuleDisplay.target(id, field: field, book: book)
    }
    private func reload() async {
        plan = nil; selections = [:]; review = nil
        do { review = try await model.reviewImportRules(batchID: batchID, rowID: rowID); message = nil }
        catch { message = model.message(for: error) }
    }
}

struct ImportRuleReferencesSection: View {
    let book: LedgerBook
    let field: ImportRuleTargetField
    let id: UUID
    var body: some View {
        let rules = ImportRuleEngine.affectedRules(field: field, id: id, in: book)
        if !rules.isEmpty {
            Section("关联导入规则") {
                ForEach(rules) { Text($0.name).font(.subheadline) }
                Text("停用或归档此资料会暂停相关规则的建议；恢复可用后，已启用的规则重新提供建议。已入账流水不会改变，可在设置的导入规则中修复动作。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
