import SwiftUI
import LedgerCore

struct AccountsView: View {
    @Bindable var model: LedgerAppModel
    @State private var add = false
    @State private var settings = false
    @State private var selected: Account?
    var body: some View {
        List {
            if model.book.accounts.isEmpty {
                ContentUnavailableView("还没有账户", systemImage: "wallet.bifold",
                                       description: Text("添加账户后即可记账；期初余额不会计为收入。"))
            }
            ForEach(model.book.accounts) { account in
                Button { selected = account } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(account.name).foregroundStyle(.primary)
                            Text((account.includedInSummary ? "计入总资产" : "不计入总资产") + (model.settings.defaultAccountID == account.id ? " · 默认账户" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text((model.balance(account)?.decimalString ?? "暂不可用") + " " + account.currency.rawValue)
                            .monospacedDigit().foregroundStyle(.primary)
                    }
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("account.row." + account.id.uuidString.lowercased())
            }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("账户")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("设置").accessibilityIdentifier("accounts.settings") }
            ToolbarItem(placement: .topBarTrailing) { Button("添加") { add = true }.accessibilityIdentifier("accounts.add") }
        }
        .sheet(isPresented: $add, onDismiss: unblockShortcuts) { AddAccountView(model: model) }
        .sheet(isPresented: $settings, onDismiss: unblockShortcuts) { LedgerSettingsView(model: model) }
        .sheet(item: $selected, onDismiss: unblockShortcuts) { account in AccountDetailView(model: model, accountID: account.id) }
        .onChange(of: add || settings || selected != nil) { _, presented in
            if presented { model.shortcutBlockingSheets.insert("accounts") }
        }
    }
    private func unblockShortcuts() {
        if !add, !settings, selected == nil { model.shortcutBlockingSheets.remove("accounts") }
    }
}

struct AddAccountView: View {
    @Bindable var model: LedgerAppModel
    @State private var name = "微信"
    @State private var kind = AccountKind.wallet
    @State private var currency = Currency.cny
    @State private var opening = "0.00"
    @State private var openingDate = Date()
    @State private var included = true
    @State private var makeDefault: Bool
    @State private var message: String?
    @State private var accountID = UUID()
    @Environment(\.dismiss) private var dismiss
    init(model: LedgerAppModel) { self.model = model; _makeDefault = State(initialValue: model.settings.defaultAccountID == nil) }
    private var nature: AccountNature { [.creditCard, .loan].contains(kind) ? .liability : .asset }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("账户名称", text: $name).accessibilityIdentifier("account.name")
                    Picker("类型", selection: $kind) {
                        Text("钱包").tag(AccountKind.wallet); Text("银行卡").tag(AccountKind.bank)
                        Text("现金").tag(AccountKind.cash); Text("储值（例如话费）").tag(AccountKind.storedValue)
                        Text("信用卡").tag(AccountKind.creditCard)
                    }
                    Picker("币种", selection: $currency) { ForEach(Currency.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    LabeledContent("期初性质", value: nature == .liability ? "尚欠金额" : "账户余额")
                    TextField("期初金额", text: $opening).keyboardType(.numbersAndPunctuation).monospacedDigit()
                        .accessibilityIdentifier("account.opening")
                    DatePicker("期初日期", selection: $openingDate, in: ...Date(), displayedComponents: .date)
                } footer: { Text("期初不计收入或消费。以后补录的历史实账仍会正常影响余额。") }
                Section {
                    Toggle("计入资产负债汇总", isOn: $included)
                    Toggle("设为默认记账账户", isOn: $makeDefault).accessibilityIdentifier("account.makeDefault")
                }
                if let message { Text(message).foregroundStyle(.red) }
                Button("保存账户") { save() }.disabled(model.isBusy).accessibilityIdentifier("account.save")
            }
            .navigationTitle("添加账户").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(model.isBusy) } }
            .onChange(of: kind) { _, value in included = value != .storedValue }
            .disabled(model.isBusy).interactiveDismissDisabled(model.isBusy)
        }
    }
    private func save() {
        do {
            let value = try Money.parse(opening, currency: currency)
            let account = Account(id: accountID, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                  kind: kind, nature: nature, currency: currency, openingMinor: value.minorUnits,
                                  openingDate: openingDate, includedInSummary: included)
            Task {
                if await model.addAccount(account, makeDefault: makeDefault) { dismiss() }
                else { message = model.errorMessage }
            }
        } catch { message = model.message(for: error) }
    }
}

struct AccountDetailView: View {
    @Bindable var model: LedgerAppModel
    let accountID: UUID
    @State private var target = ""
    @State private var note = ""
    @State private var operationID = UUID()
    @State private var message: String?
    @State private var success: String?
    @State private var edit = false
    @Environment(\.dismiss) private var dismiss
    private var account: Account? { model.book.accounts.first { $0.id == accountID } }
    var body: some View {
        NavigationStack {
            if let account {
                Form {
                    Section("当前账面余额 · " + account.currency.rawValue) {
                        Text(model.balance(account)?.decimalString ?? "暂不可用").font(.title2).monospacedDigit()
                        LabeledContent("汇总", value: account.includedInSummary ? "计入" : "不计入")
                        LabeledContent("状态", value: account.isActive ? "启用" : "已停用")
                        Button("编辑账户") { edit = true }
                        if account.isActive, model.settings.defaultAccountID != account.id {
                            Button("设为默认记账账户") { Task { _ = await model.setDefault(account.id) } }
                        }
                    }
                    Section {
                        TextField("实际余额", text: $target).keyboardType(.numbersAndPunctuation)
                        TextField("更正原因（可空）", text: $note)
                        Button("保存余额更正") { adjust(account) }.disabled(!account.isActive)
                    } header: { Text("手动更正余额") } footer: { Text("只记录差额，不增加收入或消费；原有流水保持不变。") }
                    if let message { Text(message).foregroundStyle(.red) }
                    if let success { Text(success).foregroundStyle(.secondary) }
                    Section("更正记录") {
                        ForEach(model.book.adjustments.filter { $0.accountID == account.id }.sorted { $0.occurredAt > $1.occurredAt }) { adjustment in
                            LabeledContent(adjustment.occurredAt.formatted(date: .abbreviated, time: .shortened),
                                           value: adjustment.difference.decimalString)
                        }
                    }
                }
                .navigationTitle(account.name).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .disabled(model.isBusy).interactiveDismissDisabled(model.isBusy)
                .sheet(isPresented: $edit) { EditAccountView(model: model, account: account) }
            }
        }
    }
    private func adjust(_ account: Account) {
        do {
            let amount = try Money.parse(target, currency: account.currency)
            Task {
                if await model.adjust(account.id, target: amount, note: note, operationID: operationID) {
                    target = ""; note = ""; operationID = UUID(); message = nil; success = "余额已更正，消费统计保持不变。"
                } else { message = model.errorMessage }
            }
        } catch { message = model.message(for: error) }
    }
}
