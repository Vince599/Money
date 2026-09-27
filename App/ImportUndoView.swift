import SwiftUI
import LedgerCore

struct ImportUndoView: View {
    @Bindable var model: LedgerAppModel
    let batchID: UUID
    @State private var review: ImportUndoReview?
    @State private var confirm = false
    @State private var message: String?
    @State private var linkedEntry: LedgerEntry?
    @State private var loading = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("撤销本批新增流水的余额和消费影响；已合并来源只解除关联，已有流水与后续编辑保留。账户及期初余额保留，不恢复整本旧账，也不删除后续记录。")
                    Text("撤销后本批关闭并保留来源记录，未处理行不再从此批提交。需要重新导入时，新建批次并重新核对。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let review {
                    if let plan = review.plan {
                        Section("账户余额变化") {
                            if plan.accounts.isEmpty { Text("本次只解除来源，账户余额保持不变。") }
                            ForEach(plan.accounts) { impact in
                                LabeledContent(model.accountName(impact.id), value: impact.before.decimalString + " → " + impact.after.decimalString + " " + impact.after.currency.rawValue)
                                    .accessibilityIdentifier("import.undo.effect." + impact.id.uuidString.lowercased())
                            }
                        }
                        if !plan.entries.isEmpty {
                            Section("将撤销的 \(plan.entries.count) 笔流水") {
                                ForEach(plan.entries) { entry in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(model.displayTitle(entry)).foregroundStyle(.primary)
                                        Text(entry.kind.displayName + " · " + entry.amount.decimalString + " " + entry.amount.currency.rawValue + " · " + BookDate.day(entry.occurredAt))
                                            .font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if !plan.mergedRows.isEmpty {
                            Section("解除 \(plan.mergedRows.count) 份合并来源（不改余额）") {
                                ForEach(plan.mergedRows) { Text(rowTitle($0.id)) }
                            }
                        }
                        Button("确认撤销本批的上述影响", role: .destructive) { confirm = true }
                            .disabled(model.isBusy || loading).accessibilityIdentifier("import.undo.execute")
                    } else {
                        Section("需要先处理的影响") {
                            Text("本批暂不能整批撤销。请核对下列记录，可返回流水单独编辑或删除；这里不会自动解除关联。")
                            ForEach(review.blockers) { blocker in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(rowTitle(blocker.rowID)).foregroundStyle(.primary)
                                    Text(blocker.reason).font(.subheadline).foregroundStyle(.secondary)
                                    if let entry = model.book.entries.first(where: { $0.id == blocker.entryID }) {
                                        Button("查看：" + model.displayTitle(entry)) { linkedEntry = entry }
                                    }
                                }
                            }
                        }
                    }
                }
                if loading { ProgressView("正在核对流水及关联…") }
                if let message { Text(message).foregroundStyle(.red) }
                Button("重新核对影响") { Task { await reload() } }.disabled(model.isBusy || loading)
            }
            .navigationTitle("撤销本批导入").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(model.isBusy) } }
            .task { await reload() }
            .sheet(item: $linkedEntry, onDismiss: { Task { await reload() } }) { EntryDetailView(model: model, entryID: $0.id) }
            .confirmationDialog("确认撤销上述新增流水及来源关联并关闭本批？账户和期初保留。", isPresented: $confirm, titleVisibility: .visible) {
                Button("确认撤销本批", role: .destructive) {
                    if let plan = review?.plan {
                        Task {
                            if await model.undoImport(plan) { dismiss() }
                            else { message = model.errorMessage; review = nil }
                        }
                    }
                }
            }
            .interactiveDismissDisabled(model.isBusy)
        }
    }
    private func rowTitle(_ id: UUID) -> String {
        guard let row = model.book.importBatches.first(where: { $0.id == batchID })?.rows.first(where: { $0.id == id }) else { return "来源记录" }
        return (row.title.isEmpty ? row.sourceID : row.title) + " · " + row.raw[3] + " " + row.raw[4]
    }
    private func reload() async {
        guard !loading else { return }
        loading = true; review = nil; message = nil
        defer { loading = false }
        do {
            let result = try await model.reviewImportUndo(batchID: batchID)
            guard !Task.isCancelled else { return }
            review = result
        } catch { if !Task.isCancelled { message = model.message(for: error) } }
    }
}
