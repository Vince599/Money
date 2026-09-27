import SwiftUI
import LedgerCore

private struct ImportAccountKey: Hashable, Identifiable {
    let name: String
    let currency: String
    var id: Self { self }
}

struct ImportAccountMappingView: View {
    @Bindable var model: LedgerAppModel
    @State var batch: ImportBatch
    @State private var addAccount = false
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss
    private var groups: [ImportAccountKey] {
        var seen = Set<ImportAccountKey>(), result: [ImportAccountKey] = []
        for row in batch.rows where row.state == .pending {
            let names = row.raw[2] == "transfer" ? [row.raw[5], row.raw[6]] : [row.raw[5]]
            for name in names {
                let key = ImportAccountKey(name: name, currency: row.raw[4])
                if seen.insert(key).inserted { result.append(key) }
            }
        }
        return result
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("在本批新建账户") { addAccount = true }
                    ForEach(batch.proposedAccounts) { account in
                        HStack {
                            Text(account.name + " · " + account.currency.rawValue)
                            Spacer()
                            Button("移除草稿账户") {
                                batch.proposedAccounts.removeAll { $0.id == account.id }
                                for index in batch.rows.indices where batch.rows[index].state == .pending {
                                    if batch.rows[index].accountID == account.id { batch.rows[index].accountID = nil }
                                    if batch.rows[index].destinationAccountID == account.id { batch.rows[index].destinationAccountID = nil }
                                }
                            }.buttonStyle(.borderless)
                        }
                    }
                } footer: { Text("这里新增的账户仅属于导入草稿。确认导入使用该账户的流水时，才会与流水一起创建；关闭且不保存不会保留本页修改。") }
                ForEach(groups) { group in
                    Section(group.name.isEmpty ? "来源未提供账户名" : group.name) {
                        Text("\(group.currency) · \(affected(group).count) 行")
                        Picker("对应账户", selection: selection(group)) {
                            Text("暂缓／未统一映射").tag(Optional<UUID>.none)
                            ForEach((model.book.accounts + batch.proposedAccounts).filter { $0.isActive && $0.currency.rawValue == group.currency }) { account in
                                Text(account.name + (batch.proposedAccounts.contains { $0.id == account.id } ? "（草稿）" : "")).tag(Optional(account.id))
                            }
                        }
                        DisclosureGroup("查看本组示例") {
                            ForEach(affected(group).prefix(5)) { row in
                                Text("\(row.raw[1]) · \(row.title) · \(row.raw[3])")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let message { Text(message).foregroundStyle(.red) }
                Button("保存本批账户映射") {
                    Task { if await model.saveImport(batch, expectedVersion: batch.version) { dismiss() } else { message = model.errorMessage } }
                }
                Text("只修改本批未处理行，不保存以后自动匹配规则，也不改已入账流水。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("本批账户匹配").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .sheet(isPresented: $addAccount) {
                AddAccountView(model: model, stageAccount: { batch.proposedAccounts.append($0) })
            }
            .disabled(model.isBusy).interactiveDismissDisabled(model.isBusy)
        }
    }
    private func affected(_ group: ImportAccountKey) -> [ImportRow] {
        batch.rows.filter { $0.state == .pending && $0.raw[4] == group.currency && ($0.raw[5] == group.name || ($0.raw[2] == "transfer" && $0.raw[6] == group.name)) }
    }
    private func selection(_ group: ImportAccountKey) -> Binding<UUID?> {
        Binding(get: {
            let ids = affected(group).flatMap { row -> [UUID?] in
                var values: [UUID?] = []
                if row.raw[5] == group.name { values.append(row.accountID) }
                if row.raw[2] == "transfer" && row.raw[6] == group.name { values.append(row.destinationAccountID) }
                return values
            }
            return Set(ids).count == 1 ? (ids.first ?? nil) : nil
        }, set: { id in
            for index in batch.rows.indices where batch.rows[index].state == .pending && batch.rows[index].raw[4] == group.currency {
                if batch.rows[index].raw[5] == group.name { batch.rows[index].accountID = id }
                if batch.rows[index].raw[2] == "transfer" && batch.rows[index].raw[6] == group.name { batch.rows[index].destinationAccountID = id }
            }
        })
    }
}

struct ImportClassificationView: View {
    @Bindable var model: LedgerAppModel
    let batch: ImportBatch
    let rowIDs: Set<UUID>
    @State private var categoryID: UUID?
    @State private var changeSubject = false
    @State private var subjectID = SeedData.mpcID
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss
    private var rows: [ImportRow] { batch.rows.filter { rowIDs.contains($0.id) && $0.state == .pending } }
    private var direction: String? {
        let kinds = Set(rows.map { $0.raw[2] })
        return kinds.count == 1 ? kinds.first : nil
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if direction == "expense" || direction == "income" {
                        Picker("分类", selection: $categoryID) {
                            Text("不修改分类").tag(Optional<UUID>.none)
                            ForEach(model.book.categories.filter { category in
                                category.direction.rawValue == direction && category.isActive && category.parentID != nil
                                    && model.book.categories.contains { $0.id == category.parentID && $0.isActive }
                            }) { category in
                                Text((model.book.categories.first { $0.id == category.parentID }?.name ?? "") + " / " + category.name).tag(Optional(category.id))
                            }
                        }
                    } else { Text("同时选择不同类型时仅可修改主体；修改分类请先选择同方向行。") }
                    Toggle("修改主体", isOn: $changeSubject)
                    if changeSubject {
                        Picker("主体", selection: $subjectID) {
                            ForEach(model.book.subjects.filter(\.isActive)) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                Section("受影响的 \(rows.count) 行") {
                    ForEach(rows) { row in Text("\(row.title) · \(row.raw[3]) \(row.raw[4]) · \(row.raw[1])") }
                }
                if let message { Text(message).foregroundStyle(.red) }
                Button("仅应用到所选行") {
                    var updated = batch
                    for index in updated.rows.indices where rowIDs.contains(updated.rows[index].id) && updated.rows[index].state == .pending {
                        if let categoryID { updated.rows[index].categoryID = categoryID }
                        if changeSubject { updated.rows[index].subjectID = subjectID }
                    }
                    Task { if await model.saveImport(updated, expectedVersion: batch.version) { dismiss() } else { message = model.errorMessage } }
                }.disabled(rows.isEmpty || rows.count > 200 || (categoryID == nil && !changeSubject))
                Text("本次修改不会创建长期规则；正式入账仍需单独预览并确认。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("本批分类／主体").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .disabled(model.isBusy).interactiveDismissDisabled(model.isBusy)
        }
    }
}
