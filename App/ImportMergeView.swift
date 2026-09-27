import SwiftUI
import LedgerCore

struct ImportMergeView: View {
    @Bindable var model: LedgerAppModel
    let batchID: UUID
    let rowID: UUID
    @State private var candidates: [LedgerEntry] = []
    @State private var review: ImportMergeReview?
    @State private var kept: Set<ImportMergeField> = []
    @State private var message: String?
    @State private var loading = false
    @State private var visibleCount = 50
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("仅合并来源，保留已有流水。金额、账户、手写内容和余额均不改变，不会新增扣款。")
                    Text("同日同金额只用于列出候选，请核对是否确为同一笔。不是同一笔时关闭本页，返回核对页选择保留独立交易。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let review {
                    Section("共同资金信息") {
                        LabeledContent("金额", value: review.target.amount.decimalString + " " + review.target.amount.currency.rawValue)
                        LabeledContent("账户", value: model.accountName(review.target.accountID))
                        if review.target.kind == .transfer { LabeledContent("转入账户", value: model.accountName(review.target.destinationAccountID)) }
                    }
                    ForEach(ImportMergeField.allCases, id: \.self) { field in
                        Section(field.name) {
                            LabeledContent("已有流水", value: value(field, entry: review.target, book: review.expectedBook))
                            LabeledContent("导入来源", value: value(field, entry: review.source, book: review.expectedBook))
                            if review.differences.contains(field) {
                                Toggle("确认保留已有流水的" + field.name, isOn: Binding(get: { kept.contains(field) }, set: {
                                    if $0 { kept.insert(field) } else { kept.remove(field) }
                                }))
                            }
                        }
                    }
                    Button("确认合并来源，保留已有流水") {
                        do {
                            let plan = try ImportEngine.prepareMerge(review, keepExisting: kept)
                            Task { if await model.mergeImport(plan) { dismiss() } else { message = model.errorMessage } }
                        } catch { message = model.message(for: error) }
                    }.disabled(kept != Set(review.differences)).accessibilityIdentifier("import.merge.confirm")
                    Button("返回候选列表") { self.review = nil; kept = []; message = nil }
                } else {
                    Section("可能相同的已入账流水（\(candidates.count) 笔）") {
                        ForEach(candidates.prefix(visibleCount)) { entry in
                            Button {
                                loading = true
                                Task {
                                    defer { loading = false }
                                    do { review = try await model.reviewImportMerge(batchID: batchID, rowID: rowID, entryID: entry.id); kept = []; message = nil }
                                    catch { message = model.message(for: error) }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.title.isEmpty ? entry.kind.displayName : entry.title).foregroundStyle(.primary)
                                    Text(BookDate.dateTime(entry.occurredAt) + " · " + entry.amount.decimalString).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if visibleCount < candidates.count { Button("显示更多") { visibleCount += 50 } }
                        if candidates.isEmpty && !loading { Text("没有同日、同方向、同币种金额及相同账户的候选。请先完成本行映射；资金信息不同的记录不能从此入口合并。") }
                    }
                }
                if loading { ProgressView("正在核对…") }
                if let message { Text(message).foregroundStyle(.red) }
                Button("重新读取并清除选择") { Task { await reload() } }
            }.navigationTitle("合并来源").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .disabled(model.isBusy || loading).interactiveDismissDisabled(model.isBusy || loading)
                .task { await reload() }
        }
    }
    private func value(_ field: ImportMergeField, entry: LedgerEntry, book: LedgerBook) -> String {
        switch field {
        case .title: return entry.title.isEmpty ? "（空）" : entry.title
        case .date: return entry.occurredAt.ISO8601Format(.init(includingFractionalSeconds: true))
        case .category: return ImportRuleDisplay.target(entry.categoryID, field: .category, book: book)
        case .subject: return ImportRuleDisplay.target(entry.subjectID, field: .subject, book: book)
        case .note: return entry.note.isEmpty ? "（空）" : entry.note
        case .tags: return entry.tagIDs.isEmpty ? "无" : entry.tagIDs.map { ImportRuleDisplay.target($0, field: .tag, book: book) }.joined(separator: "、")
        case .project: return ImportRuleDisplay.target(entry.projectID, field: .project, book: book)
        }
    }
    private func reload() async {
        guard !loading else { return }
        loading = true; review = nil; kept = []; candidates = []; visibleCount = 50
        defer { loading = false }
        do {
            let values = try await model.importMergeCandidates(batchID: batchID, rowID: rowID)
            guard !Task.isCancelled else { return }
            candidates = values; message = nil
        } catch { if !Task.isCancelled { message = model.message(for: error) } }
    }
}

private struct ImportUnlinkSelection: Identifiable {
    let batchID: UUID
    let id: UUID
}
struct ImportSourceSection: View {
    @Bindable var model: LedgerAppModel
    let entryIDs: Set<UUID>
    @State private var unlinkSelection: ImportUnlinkSelection?
    var body: some View {
        let batches = model.book.importBatches.filter { batch in batch.rows.contains {
            ($0.state == .imported && entryIDs.contains($0.id)) || ($0.state == .merged && $0.mergedEntryID.map(entryIDs.contains) == true)
        } }
        if !batches.isEmpty {
            Section("导入来源") {
                ForEach(batches) { batch in
                    NavigationLink(batch.name + " · " + batch.namespace) { ImportBatchView(model: model, batchID: batch.id) }
                    ForEach(batch.rows.filter { ($0.state == .imported && entryIDs.contains($0.id)) || ($0.state == .merged && $0.mergedEntryID.map(entryIDs.contains) == true) }) { row in
                        DisclosureGroup(row.sourceID + (row.state == .merged ? " · 合并来源" : " · 原始导入")) {
                            ForEach(Array(ImportCSV.header.enumerated()), id: \.offset) { index, field in LabeledContent(field, value: row.raw[index].isEmpty ? "（空）" : row.raw[index]) }
                            if row.state == .merged {
                                Button("预览解除此来源") { unlinkSelection = ImportUnlinkSelection(batchID: batch.id, id: row.id) }
                            }
                        }
                    }
                }
                Text("删除前需先处理合并来源。可单独解除，或打开对应批次预览撤销；解除来源不改变已有流水或余额。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.sheet(item: $unlinkSelection) { ImportUnlinkView(model: model, batchID: $0.batchID, rowID: $0.id) }
        }
    }
}

struct ImportUnlinkView: View {
    @Bindable var model: LedgerAppModel
    let batchID: UUID
    let rowID: UUID
    @State private var plan: ImportUnlinkPlan?
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Text("只解除这一份来源，保留已有流水、金额及后续编辑；其他来源和本批其他记录不变。来源原文及历史目标仍保存为已解除状态。")
                if let plan {
                    LabeledContent("保留的流水", value: plan.target.title.isEmpty ? plan.target.kind.displayName : plan.target.title)
                    LabeledContent("金额保持", value: plan.target.amount.decimalString + " " + plan.target.amount.currency.rawValue)
                    Button("确认解除此来源") {
                        Task { if await model.unlinkImport(plan) { dismiss() } else { message = model.errorMessage } }
                    }.accessibilityIdentifier("import.unlink.confirm")
                }
                if let message { Text(message).foregroundStyle(.red) }
                Button("重新核对") { Task { await reload() } }
            }.navigationTitle("解除来源").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .disabled(model.isBusy).interactiveDismissDisabled(model.isBusy).task { await reload() }
        }
    }
    private func reload() async {
        plan = nil
        do { plan = try await model.prepareImportUnlink(batchID: batchID, rowID: rowID); message = nil }
        catch { message = model.message(for: error) }
    }
}
