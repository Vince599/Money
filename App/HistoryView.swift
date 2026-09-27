import SwiftUI
import LedgerCore

struct HistoryView: View {
    @Bindable var model: LedgerAppModel
    let selectEntry: (LedgerEntry) -> Void
    @State private var keyword = ""
    @State private var filter = EntryFilter()
    @State private var showFilters = false
    private var activeFilter: EntryFilter {
        var value = filter; value.keyword = keyword; return value
    }
    @State private var history = HistoryPageModel()
    private var request: HistoryRequest {
        HistoryRequest(filter: activeFilter, revision: model.historyRevision, isLoaded: model.isLoaded)
    }
    var body: some View {
        List {
            if history.hasLoaded {
                if history.totalCount == 0 {
                    if model.book.entries.isEmpty {
                        ContentUnavailableView("还没有流水", systemImage: "list.bullet.rectangle")
                    } else {
                        ContentUnavailableView {
                            Label("没有符合条件的流水", systemImage: "line.3.horizontal.decrease")
                                .accessibilityIdentifier("history.empty")
                        } description: { Text("可以调整关键词或清除筛选。") } actions: {
                            Button("清除搜索与筛选") { keyword = ""; filter = EntryFilter() }
                                .accessibilityIdentifier("history.clear")
                        }
                    }
                } else {
                    Section {
                        Text(history.isLoading ? "正在更新流水…" : "共 \(history.totalCount) 笔")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(history.groups, id: \.day) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                Button { selectEntry(entry) } label: { EntryRow(model: model, entry: entry) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("entry.row." + entry.id.uuidString.lowercased())
                            }
                        } header: { Text(BookDate.day(group.day)) }
                    }
                }
            }
            if let message = history.errorMessage {
                Section {
                    Text(message).foregroundStyle(.secondary)
                    Button("重试") {
                        Task {
                            if history.hasLoaded { await history.loadMore(read: model.historyPage) }
                            else { await history.reload(request, force: true, read: model.historyPage) }
                        }
                    }.accessibilityIdentifier("history.retry")
                }
            } else if history.nextCursor != nil {
                Button {
                    Task { await history.loadMore(read: model.historyPage) }
                } label: {
                    HStack {
                        Text("加载更多流水")
                        Spacer()
                        if history.isLoading { ProgressView() }
                    }
                }
                .disabled(history.isLoading)
                .accessibilityIdentifier("history.more")
            }
            if history.isLoading && !history.hasLoaded {
                ProgressView("正在读取流水…").accessibilityIdentifier("history.loading")
            }
        }
        .task(id: request) { await history.reload(request, read: model.historyPage) }
        .searchable(text: $keyword, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索标题或备注")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showFilters = true } label: {
                    Label(filter == EntryFilter() ? "筛选" : "筛选中", systemImage: "line.3.horizontal.decrease")
                }.accessibilityIdentifier("history.filter")
            }
        }
        .sheet(isPresented: $showFilters, onDismiss: { model.shortcutBlockingSheets.remove("history.filters") }) {
            HistoryFilterView(book: model.book, filter: $filter)
        }
        .onChange(of: showFilters) { _, presented in
            if presented { model.shortcutBlockingSheets.insert("history.filters") }
        }
    }
}

struct HistoryFilterView: View {
    let book: LedgerBook
    @Binding var filter: EntryFilter
    @State private var value: EntryFilter
    @State private var useDates: Bool
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var minimum: String
    @State private var maximum: String
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss
    static var calendar: Calendar { BookDate.calendar }
    init(book: LedgerBook, filter: Binding<EntryFilter>) {
        self.book = book; self._filter = filter
        let current = filter.wrappedValue
        _value = State(initialValue: current)
        _useDates = State(initialValue: current.from != nil || current.to != nil)
        _startDate = State(initialValue: current.from ?? Self.calendar.dateInterval(of: .month, for: Date())!.start)
        _endDate = State(initialValue: current.to.map { $0.addingTimeInterval(-1) } ?? Date())
        _minimum = State(initialValue: current.minimumMinor.map { Money(minorUnits: $0).decimalString } ?? "")
        _maximum = State(initialValue: current.maximumMinor.map { Money(minorUnits: $0).decimalString } ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("方向", selection: $value.kind) {
                        Text("全部方向").tag(Optional<EntryKind>.none)
                        Text("支出").tag(Optional(EntryKind.expense))
                        Text("收入").tag(Optional(EntryKind.income))
                        Text("转账").tag(Optional(EntryKind.transfer))
                    }.accessibilityIdentifier("filter.kind")
                    Picker("账户", selection: $value.accountID) {
                        Text("全部账户").tag(Optional<UUID>.none)
                        ForEach(book.accounts) { account in
                            Text(account.name + " · " + account.currency.rawValue + (account.isActive ? "" : "（已停用）")).tag(Optional(account.id))
                        }
                    }.accessibilityIdentifier("filter.account")
                    Picker("分类", selection: $value.categoryID) {
                        Text("全部分类").tag(Optional<UUID>.none)
                        ForEach(book.categories) { category in
                            Text(categoryTitle(category)).tag(Optional(category.id))
                        }
                    }.accessibilityIdentifier("filter.category")
                    Picker("主体", selection: $value.subjectID) {
                        Text("全部主体").tag(Optional<UUID>.none)
                        ForEach(book.subjects) { subject in Text(subject.name + (subject.isActive ? "" : "（已停用）")).tag(Optional(subject.id)) }
                    }
                } footer: { Text("条件同时满足才会显示；转账可通过转出或转入账户找到，一级分类包含其二级分类。") }
                Section("发生日期") {
                    Toggle("限定日期范围", isOn: $useDates)
                    if useDates {
                        DatePicker("开始日期", selection: $startDate, displayedComponents: .date)
                        DatePicker("结束日期（含当天）", selection: $endDate, displayedComponents: .date)
                    }
                }.environment(\.timeZone, Self.calendar.timeZone)
                Section {
                    Picker("币种", selection: $value.currency) {
                        Text("全部币种").tag(Optional<Currency>.none)
                        ForEach(Currency.allCases, id: \.self) {
                            Text($0.rawValue).tag(Optional($0))
                                .accessibilityIdentifier("filter.currency.option." + $0.rawValue)
                        }
                    }.accessibilityIdentifier("filter.currency")
                    TextField("最低金额（可空）", text: $minimum).keyboardType(.decimalPad).accessibilityIdentifier("filter.minimum")
                    TextField("最高金额（可空）", text: $maximum).keyboardType(.decimalPad).accessibilityIdentifier("filter.maximum")
                } header: { Text("交易金额") } footer: { Text("按流水原金额筛选，包含上下限；填金额时需选择币种，避免混合比较。") }
                if let message { Text(message).foregroundStyle(.red) }
                Button("清除所有筛选") {
                    value = EntryFilter(); minimum = ""; maximum = ""; useDates = false; message = nil
                }.accessibilityIdentifier("filter.reset")
            }
            .navigationTitle("筛选流水").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("应用") { apply() }.accessibilityIdentifier("filter.apply") }
            }
        }
    }
    private func categoryTitle(_ category: LedgerCore.Category) -> String {
        let direction = category.direction == .expense ? "支出" : "收入"
        let parent = book.categories.first { $0.id == category.parentID }?.name
        return direction + " · " + (parent.map { $0 + " / " } ?? "") + category.name + (category.isActive ? "" : "（已停用）")
    }
    private func apply() {
        do {
            var updated = value
            let low = minimum.trimmingCharacters(in: .whitespacesAndNewlines)
            let high = maximum.trimmingCharacters(in: .whitespacesAndNewlines)
            if (!low.isEmpty || !high.isEmpty), updated.currency == nil {
                message = "按金额筛选时，请先选择币种。"; return
            }
            updated.minimumMinor = low.isEmpty ? nil : try Money.parse(low, currency: updated.currency ?? .cny).minorUnits
            updated.maximumMinor = high.isEmpty ? nil : try Money.parse(high, currency: updated.currency ?? .cny).minorUnits
            updated.from = useDates ? Self.calendar.startOfDay(for: startDate) : nil
            updated.to = useDates ? Self.calendar.date(byAdding: .day, value: 1, to: Self.calendar.startOfDay(for: endDate)) : nil
            try EntryQuery.validate(updated)
            filter = updated; dismiss()
        } catch let error as EntryQueryError {
            switch error {
            case .invalidDateRange: message = "开始日期不能晚于结束日期。"
            case .invalidAmountRange: message = "金额不能为负数，且最低金额不能大于最高金额。"
            case .amountCurrencyRequired: message = "按金额筛选时，请先选择币种。"
            }
        } catch { message = "请输入有效金额，最多两位小数，并检查金额范围。" }
    }
}
