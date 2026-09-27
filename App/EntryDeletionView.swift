import SwiftUI
import LedgerCore

struct EntryDeletionView: View {
    @Bindable var model: LedgerAppModel
    let entryID: UUID
    let didDelete: () -> Void
    @State private var plan: EntryDeletionPlan?
    @State private var removeGroup = false
    @State private var confirm = false
    @State private var linkedEntry: LedgerEntry?
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let plan {
                    Section {
                        Text(plan.entries.count > 1
                             ? "原购买关联了退款或回收。可点开关联记录，手动改为另一笔购买的回收或普通收入，再回来删除；也可明确选择整组删除。"
                             : "删除将撤销这笔流水对账户的影响，无回收站。")
                        if plan.entries.first?.kind.isRecovery == true {
                            Text("原购买保留，累计回收减少、净花费增加；消费与预算占用不变。")
                        }
                        if let original = plan.entries.first, original.kind == .expense {
                            Text("删除原购买后，原发生期的个人消费及相应预算占用减少 " + original.amount.decimalString + " " + original.amount.currency.rawValue + "。")
                        }
                    }
                    Section("将删除的记录") {
                        ForEach(plan.entries) { entry in
                            Button { linkedEntry = entry } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.kind.displayName + " · " + model.displayTitle(entry)).foregroundStyle(.primary)
                                    Text(entry.amount.decimalString + " " + entry.amount.currency.rawValue + " · " + BookDate.day(entry.occurredAt))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }.disabled(entry.id == entryID)
                        }
                    }
                    Section(plan.entries.count > 1 ? "整组删除后的账户变化" : "账户变化") {
                        ForEach(plan.accounts) { impact in
                            LabeledContent(model.accountName(impact.id), value: impact.before.decimalString + " → " + impact.after.decimalString + " " + impact.after.currency.rawValue)
                        }
                    }
                    Section {
                        if plan.entries.count > 1 {
                            Toggle("同时删除原购买和以上全部回收记录", isOn: $removeGroup)
                                .accessibilityIdentifier("delete.group")
                        }
                        Button(plan.entries.count > 1 ? "删除整组 \(plan.entries.count) 笔" : "删除流水", role: .destructive) { confirm = true }
                            .disabled(model.isBusy || (plan.entries.count > 1 && !removeGroup))
                            .accessibilityIdentifier("delete.execute")
                    }
                }
                if let message { Text(message).foregroundStyle(.red) }
                if message != nil { Button("重新核对影响") { Task { await reload() } } }
                if plan == nil && message == nil { ProgressView("正在核对影响…") }
            }
            .navigationTitle("删除影响").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(model.isBusy) } }
            .task { await reload() }
            .sheet(item: $linkedEntry, onDismiss: { Task { await reload() } }) { EntryDetailView(model: model, entryID: $0.id) }
            .confirmationDialog("确认删除上述记录？此操作不能撤销。", isPresented: $confirm, titleVisibility: .visible) {
                Button("确认删除", role: .destructive) {
                    if let plan {
                        Task {
                            if await model.delete(plan) { dismiss(); didDelete() }
                            else { message = model.errorMessage; self.plan = nil; removeGroup = false }
                        }
                    }
                }
            }
            .interactiveDismissDisabled(model.isBusy)
        }
    }
    private func reload() async {
        removeGroup = false
        plan = nil; message = nil
        do {
            plan = try await model.deletionPreview(entryID)
            message = nil
        } catch { plan = nil; message = model.message(for: error) }
    }
}
