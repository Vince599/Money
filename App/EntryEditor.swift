import SwiftUI
import LedgerCore

struct EntryEditor: View {
    @Bindable var model: LedgerAppModel
    let editing: LedgerEntry?
    @State private var draft: EntryDraft
    @State private var validationMessage: String?
    @State private var discard = false
    @State private var calculator = false
    @Environment(\.dismiss) private var dismiss
    init(model: LedgerAppModel, editing: LedgerEntry? = nil) {
        self.model = model; self.editing = editing
        if let entry = editing {
            var value = EntryDraft(entryID: entry.id, operationID: UUID(), kind: entry.kind,
                                   amountText: entry.amount.decimalString, accountID: entry.accountID,
                                   destinationAccountID: entry.destinationAccountID, subjectID: entry.subjectID,
                                   occurredAt: entry.occurredAt, title: entry.title, note: entry.note,
                                   originalEntryID: entry.originalEntryID, allowsNetRecovery: entry.allowsNetRecovery,
                                   tagIDs: entry.tagIDs, projectID: entry.projectID)
            value.categoryID = entry.categoryID
            _draft = State(initialValue: value)
        } else { _draft = State(initialValue: model.newDraft()) }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if draft.kind.isRecovery {
                        Picker("类型", selection: $draft.kind) {
                            ForEach(EntryKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }.accessibilityIdentifier("entry.kind")
                    } else {
                        Picker("类型", selection: $draft.kind) {
                            Text("支出").tag(EntryKind.expense); Text("收入").tag(EntryKind.income); Text("转账").tag(EntryKind.transfer)
                        }.pickerStyle(.segmented).accessibilityIdentifier("entry.kind")
                        Menu("更多类型") {
                            Button("退款") { draft.kind = .refund }
                            Button("出售回收") { draft.kind = .recovery }
                        }.accessibilityIdentifier("entry.moreTypes")
                    }
                    HStack {
                        TextField("金额", text: $draft.amountText).keyboardType(.decimalPad).font(.title2).monospacedDigit()
                            .accessibilityIdentifier("entry.amount")
                        Button { calculator = true } label: { Image(systemName: "plus.forwardslash.minus") }
                            .buttonStyle(.borderless).accessibilityLabel("金额计算器").accessibilityIdentifier("entry.calculator")
                    }
                    if let amountExplanation {
                        Text(amountExplanation)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if draft.kind.needsCategory {
                        Picker("分类", selection: $draft.categoryID) {
                            Text("请选择分类").tag(Optional<UUID>.none)
                            ForEach(selectableCategories) { category in
                                // Native menu pickers require a primitive Label for title/image extraction.
                                Label(categoryTitle(category), systemImage: CategorySymbolPresentation.resolved(category.symbol))
                                    .tag(Optional(category.id))
                                    .accessibilityIdentifier("entry.category.option." + category.id.uuidString.lowercased())
                            }
                        }.accessibilityIdentifier("entry.category")
                    }
                }
                if draft.kind.isRecovery {
                    Section {
                        Picker("原购买", selection: $draft.originalEntryID) {
                            Text("请选择原支出").tag(Optional<UUID>.none)
                            ForEach(originalPurchases) { original in
                                Text(originalTitle(original))
                                    .tag(Optional(original.id))
                            }
                        }.accessibilityIdentifier("entry.original")
                    } footer: {
                        Text("仅关联已有支出；款项进入所选收款账户，单列为回收，不算普通收入，原消费金额保持不变。记账前购买的二手出售，可自行选择普通收入。")
                    }
                }
                Section {
                    accountPicker(sourceAccountTitle, selection: $draft.accountID)
                        .accessibilityIdentifier("entry.account")
                    if draft.kind == .transfer { accountPicker("转入账户", selection: $draft.destinationAccountID) }
                    if draft.kind.isRecovery {
                        LabeledContent("主体（跟随原购买）", value: model.subjectName(draft.subjectID))
                    } else {
                        Picker("主体", selection: $draft.subjectID) {
                            ForEach(model.book.subjects.filter { $0.isActive || $0.id == editing?.subjectID }) { subject in Text(subject.name).tag(subject.id) }
                        }.accessibilityIdentifier("entry.subject")
                    }
                    DatePicker("日期", selection: $draft.occurredAt, in: ...Date()).environment(\.timeZone, BookDate.timeZone)
                }
                Section {
                    DisclosureGroup {
                        NavigationLink {
                            EntryLabelsSelectionView(book: model.book, tagIDs: $draft.tagIDs, projectID: $draft.projectID,
                                                     retainedTagIDs: Set(editing?.tagIDs ?? []), retainedProjectID: editing?.projectID)
                        } label: {
                            LabeledContent("标签／项目", value: EntryLabelsSelectionView.summary(book: model.book, tags: draft.tagIDs, project: draft.projectID))
                        }.accessibilityIdentifier("entry.labels")
                        TextField("标题（可空）", text: $draft.title).accessibilityIdentifier("entry.title")
                        TextField("备注", text: $draft.note, axis: .vertical).lineLimit(3...8)
                        if draft.kind == .expense && editing != nil {
                            Toggle("允许净回收", isOn: Binding(get: { draft.allowsNetRecovery == true },
                                                               set: { draft.allowsNetRecovery = $0 ? true : nil }))
                                .accessibilityIdentifier("entry.allowNetRecovery")
                            Text("默认关闭。开启即确认这笔购买允许累计回收超过原金额，超出部分显示为净回收；不会转为普通收入。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } label: {
                        Text("更多信息").accessibilityIdentifier("entry.more")
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
            .sheet(isPresented: $calculator) {
                AmountCalculatorView(expression: $draft.amountText, currency: currency, errorMessage: model.message(for:))
            }
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
            .onChange(of: draft.originalEntryID) { _, _ in followOriginalSubject() }
            .onChange(of: draft.kind) { _, _ in followOriginalSubject() }
            .onAppear { if editing == nil { model.updateDraft(draft) } }
        }
    }
    private var currency: Currency {
        model.book.accounts.first { $0.id == draft.accountID }?.currency ?? .cny
    }
    private var amountExplanation: String? {
        guard !draft.amountText.isEmpty, let value = try? AmountExpression.evaluate(draft.amountText, currency: currency) else { return nil }
        let suffix = value.wasRounded ? "（已四舍五入到两位小数）" : ""
        return "入账金额：\(value.money.decimalString) \(currency.rawValue)\(suffix)"
    }
    private var sourceAccountTitle: String {
        if draft.kind == .income || draft.kind.isRecovery { return "收款账户" }
        return draft.kind == .transfer ? "转出账户" : "付款账户"
    }
    private var originalPurchases: [LedgerEntry] {
        model.book.entries.filter { $0.kind == .expense && $0.id != editing?.id }.sorted { $0.occurredAt > $1.occurredAt }
    }
    private func originalTitle(_ original: LedgerEntry) -> String {
        "\(model.displayTitle(original)) · \(original.amount.decimalString) \(original.amount.currency.rawValue) · \(BookDate.day(original.occurredAt))"
    }
    private func followOriginalSubject() {
        if draft.kind.isRecovery, let original = model.book.entries.first(where: { $0.id == draft.originalEntryID }) {
            draft.subjectID = original.subjectID
        }
    }
    private func accountPicker(_ title: String, selection: Binding<UUID?>) -> some View {
        Picker(title, selection: selection) {
            Text("请选择账户").tag(Optional<UUID>.none)
            ForEach(model.book.accounts.filter { $0.isActive || $0.id == editing?.accountID || $0.id == editing?.destinationAccountID }) { account in Text(account.name + " · " + account.currency.rawValue).tag(Optional(account.id)) }
        }
    }
    private var selectableCategories: [LedgerCore.Category] {
        model.book.categories.filter { category in
            guard let parentID = category.parentID, category.direction == draft.kind else { return false }
            return category.id == editing?.categoryID || (category.isActive && model.book.categories.first(where: { $0.id == parentID })?.isActive == true)
        }
    }
    private func categoryTitle(_ category: LedgerCore.Category) -> String {
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
    @State private var copyEditor = false
    @State private var confirmCopy = false
    @State private var preparingCopy = false
    @State private var recoveryKind: EntryKind?
    @State private var linkedEntry: LedgerEntry?
    @Environment(\.dismiss) private var dismiss
    private var entry: LedgerEntry? { model.book.entries.first { $0.id == entryID } }
    var body: some View {
        NavigationStack {
            if let entry {
                List {
                    Section {
                        Text(entry.amount.decimalString + " " + entry.amount.currency.rawValue).font(.title).monospacedDigit()
                        LabeledContent("类型", value: entry.kind.displayName)
                        LabeledContent("标题", value: model.displayTitle(entry))
                        LabeledContent("账户", value: model.accountName(entry.accountID))
                        if entry.kind == .transfer { LabeledContent("转入", value: model.accountName(entry.destinationAccountID)) }
                        LabeledContent("主体", value: model.subjectName(entry.subjectID))
                        LabeledContent("日期", value: BookDate.dateTime(entry.occurredAt))
                    }
                    if !entry.tagIDs.isEmpty || entry.projectID != nil {
                        Section("标签／项目") {
                            if let project = model.book.projects.first(where: { $0.id == entry.projectID }) {
                                LabeledContent("项目", value: project.name + (project.isArchived ? "（已归档）" : ""))
                            }
                            ForEach(entry.tagIDs, id: \.self) { id in
                                if let tag = model.book.tags.first(where: { $0.id == id }) {
                                    Label(tag.name + (tag.isActive ? "" : "（已停用）"), systemImage: "tag")
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                    if !entry.note.isEmpty || model.recoveries[entry.id] != nil {
                        Section("备注信息") {
                            if let recovery = model.recoveries[entry.id] {
                                LabeledContent("已回收", value: recovery.recovered.decimalString + " " + entry.amount.currency.rawValue)
                                LabeledContent(recovery.netCost.minorUnits < 0 ? "净回收" : "净花费",
                                               value: recovery.netCost.decimalString.replacingOccurrences(of: "-", with: "") + " " + entry.amount.currency.rawValue)
                                    .font(.headline).accessibilityIdentifier("entry.netCost")
                                Text("原购买仍按原额计入消费；回收单独记录，净花费仅供参考。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            if !entry.note.isEmpty { Text(entry.note) }
                        }
                    }
                    if entry.kind == .expense {
                        Section("退款与回收") {
                            Button("记录退款") { prepareRecovery(.refund, entry: entry) }.accessibilityIdentifier("entry.refund")
                            Button("记录出售回收") { prepareRecovery(.recovery, entry: entry) }.accessibilityIdentifier("entry.recovery")
                            ForEach(model.book.entries.filter { $0.originalEntryID == entry.id }) { child in
                                Button { linkedEntry = child } label: {
                                    LabeledContent(child.kind.displayName, value: child.amount.decimalString + " · " + BookDate.day(child.occurredAt))
                                }
                            }
                        }
                    } else if let original = model.book.entries.first(where: { $0.id == entry.originalEntryID }) {
                        Section("关联购买") {
                            Button(model.displayTitle(original)) { linkedEntry = original }
                            Text("如需保留收款并解除关联，请编辑为普通收入并选择分类；也可编辑为另一笔购买的回收。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Button("编辑") { edit = true }
                        Button("复制为新流水") {
                            recoveryKind = nil
                            if model.draft != nil { confirmCopy = true } else { copy(entry) }
                        }.accessibilityIdentifier("entry.copy")
                        Button("删除", role: .destructive) { delete = true }
                    }
                    if let message = model.errorMessage { Text(message).foregroundStyle(.red) }
                }
                .navigationTitle("流水详情").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("entry.detail.done") } }
                .sheet(isPresented: $edit) { EntryEditor(model: model, editing: entry) }
                .sheet(isPresented: $copyEditor) { EntryEditor(model: model) }
                .sheet(item: $linkedEntry) { EntryDetailView(model: model, entryID: $0.id) }
                .sheet(isPresented: $delete) { EntryDeletionView(model: model, entryID: entry.id, didDelete: { dismiss() }) }
                .confirmationDialog("替换已有的未完成记账草稿？", isPresented: $confirmCopy, titleVisibility: .visible) {
                    Button("替换草稿并继续", role: .destructive) { copy(entry) }
                } message: { Text("将建立新草稿，日期设为现在，确认保存后才入账。") }
                .disabled(model.isBusy || preparingCopy)
            } else { ContentUnavailableView("记录已删除", systemImage: "doc") }
        }.presentationDetents([.medium, .large])
    }
    private func copy(_ entry: LedgerEntry) {
        do {
            let value: EntryDraft
            if let recoveryKind {
                value = EntryDraft(kind: recoveryKind, accountID: model.book.accounts.first(where: { $0.id == entry.accountID && $0.isActive })?.id,
                                   subjectID: entry.subjectID, originalEntryID: entry.id)
            } else { value = try EntryDraft.copying(entry, in: model.book, settings: model.settings) }
            preparingCopy = true
            Task {
                await model.updateDraft(value).value
                preparingCopy = false
                if model.draftError == nil { copyEditor = true }
                else { model.errorMessage = model.draftError }
            }
        } catch { model.errorMessage = model.message(for: error) }
    }
    private func prepareRecovery(_ kind: EntryKind, entry: LedgerEntry) {
        recoveryKind = kind
        if model.draft != nil { confirmCopy = true } else { copy(entry) }
    }
}
