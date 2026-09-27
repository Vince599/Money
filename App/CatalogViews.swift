import SwiftUI
import LedgerCore

struct LedgerSettingsView: View {
    @Bindable var model: LedgerAppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("记账资料") {
                    NavigationLink("分类管理") { CategoryListView(model: model) }.accessibilityIdentifier("settings.categories")
                    NavigationLink("主体管理") { SubjectListView(model: model) }
                }
                Section("数据") {
                    NavigationLink("完整备份与恢复") { BackupView(model: model) }.accessibilityIdentifier("settings.backup")
                }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(model.isBusy) } }
        }.interactiveDismissDisabled(model.isBusy)
    }
}

struct EditAccountView: View {
    @Bindable var model: LedgerAppModel
    @State private var account: Account
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss
    init(model: LedgerAppModel, account: Account) {
        self.model = model; _account = State(initialValue: account)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        AccountTemplatePickerView(selectedTemplateID: account.templateID, account: account) { template in
                            account.institutionID = template?.institutionID
                            account.templateID = template?.id
                            account.iconID = template?.iconID
                        }
                        .disabled(model.isBusy)
                    } label: {
                        HStack(spacing: 12) {
                            AccountIconView(iconID: account.iconID, kind: account.kind)
                            LabeledContent("机构与图标", value: appearanceName)
                        }
                    }
                    .accessibilityIdentifier("account.edit.template")
                    TextField("账户名称", text: $account.name).accessibilityIdentifier("account.edit.name")
                    Toggle("计入资产负债汇总", isOn: $account.includedInSummary)
                    Toggle("启用账户", isOn: $account.isActive)
                } footer: {
                    Text("停用后仍保留余额和历史，新增记账不再显示此账户。是否计入汇总由上方开关独立控制；停用默认账户后需另选默认账户。")
                }
                Section {
                    LabeledContent("币种", value: account.currency.rawValue)
                    Text("余额有差异时，请在账户详情中使用“手动更正余额”。").foregroundStyle(.secondary)
                }
                if let message { Text(message).foregroundStyle(.red) }
                Button("保存") {
                    var value = account
                    value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { if await model.saveAccount(value) { dismiss() } else { message = model.errorMessage } }
                }.accessibilityIdentifier("account.edit.save")
            }
            .navigationTitle("编辑账户").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .disabled(model.isBusy).interactiveDismissDisabled(model.isBusy)
        }
    }
    private var appearanceName: String {
        if let id = account.templateID, let template = AccountTemplateCatalog.template(id: id) { return template.name }
        if let id = account.institutionID, let institution = AccountTemplateCatalog.institution(id: id) { return institution.name }
        if let id = account.iconID, let icon = AccountTemplateCatalog.icon(id: id) { return icon.accessibilityName }
        return "通用图标"
    }
}

struct CategoryListView: View {
    @Bindable var model: LedgerAppModel
    @State private var direction = EntryKind.expense
    @State private var selected: LedgerCore.Category?
    @State private var add = false
    var body: some View {
        List {
            Picker("分类方向", selection: $direction) {
                Text("支出").tag(EntryKind.expense); Text("收入").tag(EntryKind.income)
            }.pickerStyle(.segmented)
            ForEach(model.book.categories.filter { $0.parentID == nil && $0.direction == direction }) { parent in
                Section {
                    Button { selected = parent } label: { categoryLabel(parent) }
                        .accessibilityIdentifier("category.row." + parent.id.uuidString.lowercased())
                    ForEach(model.book.categories.filter { $0.parentID == parent.id }) { child in
                        Button { selected = child } label: { categoryLabel(child).padding(.leading, 20) }
                            .accessibilityIdentifier("category.row." + child.id.uuidString.lowercased())
                    }
                }
            }
        }
        .navigationTitle("分类管理")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("添加") { add = true } } }
        .sheet(isPresented: $add) { CategoryEditorView(model: model, direction: direction) }
        .sheet(item: $selected) { CategoryEditorView(model: model, category: $0) }
    }
    private func categoryLabel(_ category: LedgerCore.Category) -> some View {
        HStack {
            Label { Text(category.name) } icon: { CategorySymbolView(symbol: category.symbol) }
                .foregroundStyle(.primary)
            Spacer()
            if !category.isActive { Text("已停用").font(.caption).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct CategoryEditorView: View {
    @Bindable var model: LedgerAppModel
    @State private var category: LedgerCore.Category
    private let isNew: Bool
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss
    init(model: LedgerAppModel, category: LedgerCore.Category? = nil, direction: EntryKind = .expense) {
        self.model = model; isNew = category == nil
        _category = State(initialValue: category ?? LedgerCore.Category(name: "", direction: direction))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("分类名称", text: $category.name).accessibilityIdentifier("category.edit.name")
                    if isNew {
                        Picker("方向", selection: $category.direction) {
                            Text("支出").tag(EntryKind.expense); Text("收入").tag(EntryKind.income)
                        }
                        Picker("所属一级", selection: $category.parentID) {
                            Text("创建为一级分类").tag(Optional<UUID>.none)
                            ForEach(model.book.categories.filter { $0.parentID == nil && $0.direction == category.direction && $0.isActive }) {
                                Text($0.name).tag(Optional($0.id))
                            }
                        }
                    } else {
                        LabeledContent("层级", value: category.parentID == nil ? "一级分类" : "二级分类")
                    }
                    NavigationLink {
                        CategorySymbolPicker(symbol: category.symbol, categoryName: category.name) { category.symbol = $0 }
                    } label: {
                        HStack {
                            CategorySymbolView(symbol: category.symbol)
                            LabeledContent("图标", value: CategorySymbolPresentation.name(category.symbol))
                        }
                    }.accessibilityIdentifier("category.edit.icon")
                    Button("恢复默认图标") { category.symbol = CategorySymbolCatalog.defaultSymbol(for: category.id) }
                        .disabled(category.symbol == CategorySymbolCatalog.defaultSymbol(for: category.id))
                        .accessibilityIdentifier("category.edit.resetIcon")
                    Toggle("启用分类", isOn: $category.isActive)
                } footer: {
                    Text("普通收支选择二级分类。停用一级分类后，其下分类不再供新记账选择，历史记录保留。")
                }
                if let message { Text(message).foregroundStyle(.red) }
                Button("保存") {
                    var value = category
                    value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { if await model.saveCategory(value) { dismiss() } else { message = model.errorMessage } }
                }.accessibilityIdentifier("category.edit.save")
            }
            .navigationTitle(isNew ? "添加分类" : "编辑分类").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.accessibilityIdentifier("category.edit.cancel") } }
            .onChange(of: category.direction) { _, _ in if isNew { category.parentID = nil } }
            .disabled(model.isBusy).interactiveDismissDisabled(model.isBusy)
        }
    }
}

struct SubjectListView: View {
    @Bindable var model: LedgerAppModel
    @State private var selected: LedgerCore.Subject?
    @State private var add = false
    var body: some View {
        List {
            ForEach(model.book.subjects) { subject in
                Button { selected = subject } label: {
                    HStack {
                        Text(subject.name).foregroundStyle(.primary)
                        Spacer()
                        if model.settings.defaultSubjectID == subject.id { Text("默认").foregroundStyle(.secondary) }
                        if !subject.isActive { Text("已停用").foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .navigationTitle("主体管理")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("添加") { add = true } } }
        .sheet(isPresented: $add) { SubjectEditorView(model: model) }
        .sheet(item: $selected) { SubjectEditorView(model: model, subject: $0) }
    }
}

struct SubjectEditorView: View {
    @Bindable var model: LedgerAppModel
    @State private var subject: LedgerCore.Subject
    private let isNew: Bool
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss
    init(model: LedgerAppModel, subject: LedgerCore.Subject? = nil) {
        self.model = model; isNew = subject == nil
        _subject = State(initialValue: subject ?? LedgerCore.Subject(name: ""))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("主体名称", text: $subject.name)
                    Toggle("启用主体", isOn: $subject.isActive)
                } footer: { Text("主体表示这笔消费属于谁，与收款人、付款账户分开。停用不会删除历史记录。") }
                if !isNew, subject.isActive, model.settings.defaultSubjectID != subject.id {
                    Button("设为默认主体") {
                        Task { if await model.setDefaultSubject(subject.id) { message = "已设为默认主体" } else { message = model.errorMessage } }
                    }
                }
                if let message { Text(message) }
                Button("保存") {
                    var value = subject
                    value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { if await model.saveSubject(value) { dismiss() } else { message = model.errorMessage } }
                }
            }
            .navigationTitle(isNew ? "添加主体" : "编辑主体").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .disabled(model.isBusy).interactiveDismissDisabled(model.isBusy)
        }
    }
}
