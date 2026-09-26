import SwiftUI
import LedgerCore

struct EntryEditor: View {
    @Bindable var model: LedgerAppModel
    let editing: LedgerEntry?
    @State private var draft: EntryDraft
    @State private var validationMessage: String?
    @State private var discard = false
    @Environment(\.dismiss) private var dismiss
    init(model: LedgerAppModel, editing: LedgerEntry? = nil) {
        self.model = model; self.editing = editing
        if let entry = editing {
            var value = EntryDraft(entryID: entry.id, operationID: UUID(), kind: entry.kind,
                                   amountText: entry.amount.decimalString, accountID: entry.accountID,
                                   destinationAccountID: entry.destinationAccountID, subjectID: entry.subjectID,
                                   occurredAt: entry.occurredAt, title: entry.title, note: entry.note)
            value.categoryID = entry.categoryID
            _draft = State(initialValue: value)
        } else { _draft = State(initialValue: model.newDraft()) }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("类型", selection: $draft.kind) {
                        Text("支出").tag(EntryKind.expense); Text("收入").tag(EntryKind.income); Text("转账").tag(EntryKind.transfer)
                    }.pickerStyle(.segmented)
                    TextField("金额", text: $draft.amountText).keyboardType(.decimalPad).font(.title2).monospacedDigit()
                        .accessibilityIdentifier("entry.amount")
                    if draft.kind != .transfer {
                        Picker("分类", selection: $draft.categoryID) {
                            Text("请选择分类").tag(Optional<UUID>.none)
                            ForEach(selectableCategories) { category in
                                Label(categoryTitle(category), systemImage: category.symbol).tag(Optional(category.id))
                            }
                        }
                    }
                }
                Section {
                    accountPicker(draft.kind == .income ? "收款账户" : draft.kind == .transfer ? "转出账户" : "付款账户", selection: $draft.accountID)
                    if draft.kind == .transfer { accountPicker("转入账户", selection: $draft.destinationAccountID) }
                    Picker("主体", selection: $draft.subjectID) {
                        ForEach(model.book.subjects.filter { $0.isActive || $0.id == editing?.subjectID }) { subject in Text(subject.name).tag(subject.id) }
                    }
                    DatePicker("日期", selection: $draft.occurredAt, in: ...Date())
                }
                Section {
                    DisclosureGroup("更多信息") {
                        TextField("标题（可空）", text: $draft.title)
                        TextField("备注", text: $draft.note, axis: .vertical).lineLimit(3...8)
                    }
                }
                if let validationMessage { Section { Text(validationMessage).foregroundStyle(.red) } }
                if let error = model.draftError, editing == nil { Section { Text(error).foregroundStyle(.red) } }
                if model.book.accounts.isEmpty {
                    Section { Text("先到“账户”添加微信或银行卡，草稿会保留。").foregroundStyle(.secondary) }
                }
                Section {
                    Button("保存") { save(continueEntry: false) }.accessibilityIdentifier("entry.save")
                    if editing == nil { Button("保存并继续") { save(continueEntry: true) } }
                }.disabled(model.isBusy || model.book.accounts.isEmpty)
                Section { Button(editing == nil ? "放弃这份草稿" : "放弃修改", role: .destructive) { discard = true } }
            }
            .navigationTitle(editing == nil ? "记一笔" : "编辑流水").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("关闭") {
                    if editing == nil { closeKeepingDraft() } else { discard = true }
                }.disabled(model.isBusy)
            } }
            .disabled(model.isBusy)
            .interactiveDismissDisabled(model.isBusy || editing != nil)
            .confirmationDialog("放弃未保存的输入？", isPresented: $discard, titleVisibility: .visible) {
                Button("放弃", role: .destructive) {
                    Task {
                        if editing == nil {
                            await model.updateDraft(nil).value
                            if model.draftError != nil { return }
                        }
                        dismiss()
                    }
                }
            }
            .onChange(of: draft) { _, value in if editing == nil { model.updateDraft(value) } }
            .onAppear { if editing == nil { model.updateDraft(draft) } }
        }
    }
    private func accountPicker(_ title: String, selection: Binding<UUID?>) -> some View {
        Picker(title, selection: selection) {
            Text("请选择账户").tag(Optional<UUID>.none)
            ForEach(model.book.accounts.filter { $0.isActive || $0.id == editing?.accountID || $0.id == editing?.destinationAccountID }) { account in Text(account.name + " · " + account.currency.rawValue).tag(Optional(account.id)) }
        }
    }
    private var selectableCategories: [Category] {
        model.book.categories.filter { category in
            guard let parentID = category.parentID, category.direction == draft.kind else { return false }
            return category.id == editing?.categoryID || (category.isActive && model.book.categories.first(where: { $0.id == parentID })?.isActive == true)
        }
    }
    private func categoryTitle(_ category: Category) -> String {
        let parent = model.book.categories.first { $0.id == category.parentID }?.name ?? ""
        return parent + " / " + category.name
    }
    private func closeKeepingDraft() {
        Task { await model.updateDraft(draft).value; if model.draftError == nil { dismiss() } }
    }
    private func save(continueEntry: Bool) {
        do {
            var entry = try draft.entry(in: model.book, createdAt: editing?.createdAt ?? Date())
            if let editing { entry.version = editing.version }
            let next = continueEntry ? draft.nextEntry() : nil
            Task {
                if await model.save(entry, expectedVersion: editing?.version, nextDraft: next) {
                    validationMessage = nil
                    if let next { draft = next } else { dismiss() }
                } else { validationMessage = model.errorMessage }
            }
        } catch { validationMessage = model.message(for: error) }
    }
}

struct EntryDetailView: View {
    @Bindable var model: LedgerAppModel
    var entryID: UUID
    @State private var edit = false
    @State private var delete = false
    @Environment(\.dismiss) private var dismiss
    private var entry: LedgerEntry? { model.book.entries.first { $0.id == entryID } }
    var body: some View {
        NavigationStack {
            if let entry {
                List {
                    Section {
                        Text(entry.amount.decimalString + " " + entry.amount.currency.rawValue).font(.title).monospacedDigit()
                        LabeledContent("类型", value: entry.kind == .expense ? "支出" : entry.kind == .income ? "收入" : "转账")
                        LabeledContent("标题", value: model.displayTitle(entry))
                        LabeledContent("账户", value: model.accountName(entry.accountID))
                        if entry.kind == .transfer { LabeledContent("转入", value: model.accountName(entry.destinationAccountID)) }
                        LabeledContent("主体", value: model.subjectName(entry.subjectID))
                        LabeledContent("日期", value: entry.occurredAt.formatted(date: .abbreviated, time: .shortened))
                        if !entry.note.isEmpty { Text(entry.note) }
                    }
                    Section { Button("编辑") { edit = true }; Button("删除", role: .destructive) { delete = true } }
                    if let message = model.errorMessage { Text(message).foregroundStyle(.red) }
                }
                .navigationTitle("流水详情").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .sheet(isPresented: $edit) { EntryEditor(model: model, editing: entry) }
                .confirmationDialog("删除后将撤销对应账户变化，无回收站。", isPresented: $delete, titleVisibility: .visible) {
                    Button("删除流水", role: .destructive) { Task { if await model.delete(entry.id) { dismiss() } } }
                }
                .disabled(model.isBusy)
            } else { ContentUnavailableView("记录已删除", systemImage: "doc") }
        }.presentationDetents([.medium, .large])
    }
}
