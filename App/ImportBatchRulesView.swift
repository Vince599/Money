import SwiftUI
import LedgerCore

struct ImportBatchRulesView: View {
    @Bindable var model: LedgerAppModel
    let batchID: UUID
    let rowIDs: Set<UUID>
    @State private var review: ImportRuleBatchReview?
    @State private var selections: [UUID: [ImportRuleTargetField: UUID]] = [:]
    @State private var plan: ImportRuleBatchPlan?
    @State private var message: String?
    @State private var loading = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let plan { confirmation(plan) }
                else if let review {
                    Section {
                        Text("已选 \(review.rows.count) 行；默认全部保持当前值。展开每行核对规则及冲突，再选择字段。")
                        Button("仅填充无冲突的空字段") {
                            for (id, fields) in ImportRuleEngine.unambiguousEmptySelections(review) {
                                for (field, target) in fields where selections[id]?[field] == nil {
                                    selections[id, default: [:]][field] = target
                                }
                            }
                            message = "已选择可填充的空字段，尚未保存；有冲突或已有值的字段保持原状。"
                        }.accessibilityIdentifier("import.batchRules.fillEmpty")
                        Button("清除本次全部选择") { selections = [:]; message = nil }
                    } footer: {
                        Text("快捷填充也不会选择存在较低优先级冲突的字段。主体已有默认值，需逐行明确选择才会变更；追加标签也需逐行选择。")
                    }
                    ForEach(review.rows, id: \.rowID) { rowReview in
                        if let row = review.batch.rows.first(where: { $0.id == rowReview.rowID }) {
                            DisclosureGroup {
                                rowChoices(rowReview, review: review)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.title.isEmpty ? row.sourceID : row.title).foregroundStyle(.primary)
                                    Text(row.raw[3] + " " + row.raw[4] + " · " + row.raw[1]).font(.caption).foregroundStyle(.secondary)
                                    Text("命中 \(rowReview.matchedRules.count) 条规则 · 冲突 \(rowReview.suggestions.filter(\.hasConflict).count) 项 · 已选 \(selections[row.id]?.count ?? 0) 个字段")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Button("预览本次修改") { prepare(review) }
                        .disabled(!selections.values.contains { !$0.isEmpty })
                        .accessibilityIdentifier("import.batchRules.preview")
                }
                if loading { ProgressView("正在核对…") }
                if let message { Text(message).foregroundStyle(.secondary) }
                Button("重新读取并清除本次选择") { Task { await reload() } }
            }.navigationTitle("所选行的规则建议").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .disabled(model.isBusy || loading).interactiveDismissDisabled(model.isBusy || loading)
                .task { await reload() }
        }
    }

    @ViewBuilder private func rowChoices(_ row: ImportRuleReview, review: ImportRuleBatchReview) -> some View {
        if row.suggestions.isEmpty { Text("暂无可用建议").foregroundStyle(.secondary) }
        ForEach(row.suggestions) { suggestion in
            VStack(alignment: .leading, spacing: 6) {
                if let current = review.batch.rows.first(where: { $0.id == row.rowID }) {
                    LabeledContent(suggestion.id.name + "当前值", value: ImportRuleDisplay.current(current, field: suggestion.id, book: review.expectedBook))
                }
                if suggestion.id == .tag { Text("采用后追加此标签，已有标签保留。").font(.footnote) }
                if suggestion.hasConflict {
                    Text(suggestion.preferredID == nil ? "同级冲突，请明确选择。" : "多个建议不一致，请核对。")
                        .font(.footnote)
                }
                if let preferred = suggestion.preferredID {
                    Text("优先级建议：" + name(preferred, field: suggestion.id, review: review)).font(.footnote)
                }
                ForEach(suggestion.choices) { choice in
                    Text(name(choice.id, field: suggestion.id, review: review) + " ← " + choice.rules.map { "\($0.name)（优先级 \($0.priority)，版本 \($0.version)）" }.joined(separator: "、"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("本次采用", selection: Binding<UUID?>(get: { selections[row.rowID]?[suggestion.id] }, set: {
                    selections[row.rowID, default: [:]][suggestion.id] = $0
                })) {
                    Text("保持当前值").tag(Optional<UUID>.none)
                    ForEach(suggestion.choices) { Text(name($0.id, field: suggestion.id, review: review)).tag(Optional($0.id)) }
                }
            }
        }
        ForEach(Array(row.warnings.enumerated()), id: \.offset) { Text($0.element).font(.footnote).foregroundStyle(.secondary) }
    }

    @ViewBuilder private func confirmation(_ plan: ImportRuleBatchPlan) -> some View {
        Section("将修改 \(plan.changes.count) 行、\(plan.changes.reduce(0) { $0 + $1.fields.count }) 个字段") {
            Text("以下仅列实际变化，按文件顺序显示。确认后一次保存所有修改；不入账，其他行与未选字段保持原值。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(plan.changes) { change in
            Section(change.before.title.isEmpty ? change.before.sourceID : change.before.title) {
                Text(change.before.raw[3] + " " + change.before.raw[4] + " · " + change.before.raw[1]).font(.caption).foregroundStyle(.secondary)
                if let review {
                    ForEach(change.fields, id: \.self) { field in
                        LabeledContent(field.name, value: ImportRuleDisplay.current(change.before, field: field, book: review.expectedBook) + " → " + ImportRuleDisplay.current(change.after, field: field, book: review.expectedBook))
                    }
                }
            }
        }
        Button("确认保存以上草稿修改") {
            Task { if await model.applyImportBatchRules(plan) { dismiss() } else { message = model.errorMessage } }
        }.accessibilityIdentifier("import.batchRules.confirm")
        Button("返回调整选择") { self.plan = nil; message = nil }
    }
    private func name(_ id: UUID?, field: ImportRuleTargetField, review: ImportRuleBatchReview) -> String {
        if (field == .account || field == .destinationAccount), let account = review.batch.proposedAccounts.first(where: { $0.id == id }) { return account.name + "（草稿）" }
        return ImportRuleDisplay.target(id, field: field, book: review.expectedBook)
    }
    private func prepare(_ review: ImportRuleBatchReview) {
        loading = true
        Task {
            defer { loading = false }
            do { plan = try await model.prepareImportBatchRules(review, selections: selections); message = nil }
            catch { message = model.message(for: error) }
        }
    }
    private func reload() async {
        guard !loading else { return }
        loading = true; review = nil; plan = nil; selections = [:]
        defer { loading = false }
        do {
            let value = try await model.reviewImportBatchRules(batchID: batchID, rowIDs: rowIDs)
            guard !Task.isCancelled else { return }
            review = value; message = nil
        } catch { if !Task.isCancelled { message = model.message(for: error) } }
    }
}
