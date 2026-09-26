import SwiftUI
import LedgerCore

struct LedgerRootView: View {
    @Bindable var model: LedgerAppModel
    @State private var showEntry = false
    @State private var showAccount = false
    @State private var selectedEntry: LedgerEntry?
    var body: some View {
        Group {
            if model.isLoaded {
                TabView {
                    NavigationStack { home.navigationTitle("我的账本").toolbar { recordToolbar } }
                        .tabItem { Label("首页", systemImage: "house") }
                    NavigationStack { HistoryView(model: model) { selectedEntry = $0 }.navigationTitle("流水").toolbar { recordToolbar } }
                        .tabItem { Label("流水", systemImage: "list.bullet.rectangle") }
                    NavigationStack { AccountsView(model: model) }
                        .tabItem { Label("账户", systemImage: "wallet.bifold") }
                }
            } else if model.errorMessage != nil {
                ContentUnavailableView {
                    Label("账本未能打开", systemImage: "externaldrive.badge.exclamationmark")
                } description: { Text(model.errorMessage ?? "") } actions: {
                    Button("重试") { Task { await model.start() } }
                }
            } else { ProgressView("正在打开账本") }
        }
        .sheet(isPresented: $showEntry) { EntryEditor(model: model) }
        .sheet(isPresented: $showAccount) { AddAccountView(model: model) }
        .sheet(item: $selectedEntry) { entry in EntryDetailView(model: model, entryID: entry.id) }
        .tint(.primary)
    }
    @ToolbarContentBuilder private var recordToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showEntry = true } label: { Image(systemName: "plus.circle.fill") }
                .accessibilityLabel("记一笔").accessibilityIdentifier("entry.add").disabled(model.isBusy)
        }
    }
    private var home: some View {
        List {
            if model.book.accounts.isEmpty {
                Section {
                    ContentUnavailableView("从第一个账户开始", systemImage: "wallet.bifold",
                                           description: Text("添加微信或银行卡，填写实际期初余额。"))
                    Button("添加账户") { showAccount = true }
                }
            } else {
                ForEach(Currency.allCases, id: \.self) { currency in
                    if model.book.accounts.contains(where: { $0.currency == currency && $0.includedInSummary }) {
                        Section(currency.rawValue + " · 当前余额") {
                            let totals = totals(currency)
                            LabeledContent("净资产", value: totals.net)
                            LabeledContent("总资产", value: totals.assets)
                            LabeledContent("总负债", value: totals.debt)
                        }.monospacedDigit()
                    }
                }
                Section("本月个人消费 · CNY") { Text(monthlyConsumption).font(.title2).monospacedDigit() }
            }
            if model.draft != nil {
                Section { Button("继续未完成的记账") { showEntry = true } }
            }
            if let error = model.draftError { Section { Text(error).foregroundStyle(.red) } }
            Section("最近流水") {
                if model.book.entries.isEmpty { Text("还没有流水").foregroundStyle(.secondary) }
                ForEach(sortedEntries.prefix(5)) { entry in
                    Button { selectedEntry = entry } label: { EntryRow(model: model, entry: entry) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("entry.row." + entry.id.uuidString.lowercased())
                }
            }
        }
    }
    private var sortedEntries: [LedgerEntry] {
        model.book.entries.sorted {
            $0.occurredAt == $1.occurredAt ? $0.createdAt > $1.createdAt : $0.occurredAt > $1.occurredAt
        }
    }
    private var monthlyConsumption: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        guard let interval = calendar.dateInterval(of: .month, for: Date()),
              let value = try? LedgerEngine.consumption(in: model.book, from: interval.start, to: interval.end, currency: .cny)
        else { return "暂不可用" }
        return value.decimalString
    }
    private func totals(_ currency: Currency) -> (assets: String, debt: String, net: String) {
        do {
            var assets = Money(minorUnits: 0, currency: currency), debt = assets
            for account in model.book.accounts where account.currency == currency && account.includedInSummary {
                let value = try LedgerEngine.balance(of: account.id, in: model.book)
                if account.nature == .asset { assets = try assets.adding(value) }
                else { debt = try debt.adding(value) }
            }
            return (assets.decimalString, debt.decimalString, try assets.subtracting(debt).decimalString)
        } catch { return ("暂不可用", "暂不可用", "暂不可用") }
    }
}

struct EntryRow: View {
    var model: LedgerAppModel
    var entry: LedgerEntry
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(entry.kind == .income ? .green : .orange).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.displayTitle(entry)).foregroundStyle(.primary).lineLimit(1)
                Text(metadata).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(amount).monospacedDigit().foregroundStyle(entry.kind == .expense ? Color.red : .primary)
                .fixedSize(horizontal: true, vertical: false)
        }.padding(.vertical, 4)
    }
    private var symbol: String {
        if entry.kind == .transfer { return "arrow.left.arrow.right" }
        return model.book.categories.first(where: { $0.id == entry.categoryID })?.symbol ?? "tag"
    }
    private var metadata: String {
        let account = entry.kind == .transfer ? model.accountName(entry.accountID) + " → " + model.accountName(entry.destinationAccountID) : model.accountName(entry.accountID)
        return account + " · " + model.subjectName(entry.subjectID) + " · " + BookDate.dateTime(entry.occurredAt)
    }
    private var amount: String {
        (entry.kind == .expense ? "−" : entry.kind == .income ? "+" : "") + entry.amount.decimalString + " " + entry.amount.currency.rawValue
    }
}
