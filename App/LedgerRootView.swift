import SwiftUI
import UIKit
import LedgerCore

struct LedgerRootView: View {
    @Bindable var model: LedgerAppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showEntry = false
    @State private var showAccount = false
    @State private var selectedEntry: LedgerEntry?
    @State private var showShortcut = false
    @State private var timeChangeGeneration: UInt64 = 0
    @State private var homeDisplayDate = Date()
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
        .sheet(isPresented: $showEntry, onDismiss: presentShortcutIfPossible) { EntryEditor(model: model) }
        .sheet(isPresented: $showAccount, onDismiss: presentShortcutIfPossible) { AddAccountView(model: model) }
        .sheet(item: $selectedEntry, onDismiss: presentShortcutIfPossible) { entry in EntryDetailView(model: model, entryID: entry.id) }
        .sheet(isPresented: $showShortcut, onDismiss: { model.pendingShortcut = nil }) {
            if let request = model.pendingShortcut { ShortcutReviewView(model: model, request: request) }
        }
        .onChange(of: model.pendingShortcut) { _, _ in presentShortcutIfPossible() }
        .onChange(of: model.isBusy) { _, _ in presentShortcutIfPossible() }
        .onChange(of: model.isLoaded) { _, _ in presentShortcutIfPossible() }
        .onChange(of: model.shortcutBlockingSheets) { _, _ in presentShortcutIfPossible() }
        .onAppear { presentShortcutIfPossible() }
        .task(id: HomeRefreshID(isActive: scenePhase == .active, isLoaded: model.isLoaded,
                               isBusy: model.isBusy, timeChangeGeneration: timeChangeGeneration)) {
            await maintainHomeOverview()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            timeChangeGeneration &+= 1
        }
        .tint(.primary)
    }
    private func presentShortcutIfPossible() {
        guard model.isLoaded, !model.isBusy, model.pendingShortcut != nil,
              model.shortcutBlockingSheets.isEmpty,
              !showEntry, !showAccount, selectedEntry == nil, !showShortcut else { return }
        showShortcut = true
    }
    @ToolbarContentBuilder private var recordToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showEntry = true } label: { Image(systemName: "plus.circle.fill") }
                .accessibilityLabel("记一笔").accessibilityIdentifier("entry.add").disabled(model.isBusy)
        }
    }
    private var home: some View {
        let overview = model.home
        let summary = overview?.summary
        let monthlyConsumption = overview?.isCurrent(at: homeDisplayDate) == true
            ? summary?.monthlyConsumption?.decimalString : nil
        return List {
            if model.pendingShortcut != nil, !showShortcut {
                Section { Text("快捷指令记账已准备好，关闭当前页面后继续确认。") }
            }
            if model.book.accounts.isEmpty {
                Section {
                    ContentUnavailableView("从第一个账户开始", systemImage: "wallet.bifold",
                                           description: Text("添加微信或银行卡，填写实际期初余额。"))
                    Button("添加账户") { showAccount = true }
                }
            } else {
                if let summary {
                    ForEach(summary.currencySummaries, id: \.currency) { currency in
                        Section(currency.currency.rawValue + " · 当前余额") {
                            LabeledContent("净资产", value: currency.totals?.netAsset.decimalString ?? "暂不可用")
                            LabeledContent("总资产", value: currency.totals?.assets.decimalString ?? "暂不可用")
                            LabeledContent("总负债", value: currency.totals?.liabilities.decimalString ?? "暂不可用")
                        }.monospacedDigit()
                    }
                } else {
                    Section("当前余额") { Text("暂不可用") }
                }
                Section("本月个人消费 · CNY") { Text(monthlyConsumption ?? "暂不可用").font(.title2).monospacedDigit() }
            }
            if model.draft != nil {
                Section { Button("继续未完成的记账") { showEntry = true } }
            }
            if let error = model.draftError { Section { Text(error).foregroundStyle(.red) } }
            Section("最近流水") {
                if let summary {
                    if summary.recentEntries.isEmpty { Text("还没有流水").foregroundStyle(.secondary) }
                } else {
                    Text("暂不可用").foregroundStyle(.secondary)
                }
                ForEach(summary?.recentEntries ?? []) { entry in
                    Button { selectedEntry = entry } label: { EntryRow(model: model, entry: entry) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("entry.row." + entry.id.uuidString.lowercased())
                }
            }
        }
    }

    private struct HomeRefreshID: Equatable {
        let isActive: Bool
        let isLoaded: Bool
        let isBusy: Bool
        let timeChangeGeneration: UInt64
    }

    @MainActor private func maintainHomeOverview() async {
        guard scenePhase == .active, model.isLoaded else { return }
        while !Task.isCancelled {
            // Hide the previous month's amount before waiting for a fresh snapshot.
            homeDisplayDate = Date()
            await model.refreshHomeIfNeeded()
            guard !Task.isCancelled else { return }
            let now = Date()
            // The read itself may have crossed midnight into a different month.
            homeDisplayDate = now
            let delay: TimeInterval
            if model.home?.isCurrent(at: now) == true, let month = BookDate.month(containing: now) {
                delay = max(1, month.end.timeIntervalSince(now))
            } else {
                // Read failures or an invalid clock must not turn into a busy retry loop.
                delay = 60
            }
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
        }
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
        if entry.kind.isRecovery { return "arrow.uturn.backward" }
        return model.book.categories.first(where: { $0.id == entry.categoryID })?.symbol ?? "tag"
    }
    private var metadata: String {
        let account = entry.kind == .transfer ? model.accountName(entry.accountID) + " → " + model.accountName(entry.destinationAccountID) : model.accountName(entry.accountID)
        let marker = model.recoveries[entry.id] == nil ? "" : "已回收 · "
        return marker + account + " · " + model.subjectName(entry.subjectID) + " · " + BookDate.dateTime(entry.occurredAt)
    }
    private var amount: String {
        (entry.kind == .expense ? "−" : entry.kind == .income || entry.kind.isRecovery ? "+" : "") + entry.amount.decimalString + " " + entry.amount.currency.rawValue
    }
}
