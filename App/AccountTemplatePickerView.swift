import SwiftUI
import LedgerCore

/// Picking changes only the caller's form draft; saving remains an explicit action.
struct AccountTemplatePickerView: View {
    let selectedTemplateID: String?
    var account: Account? = nil
    let onSelect: @MainActor (AccountTemplate?) -> Void
    @State private var query = ""
    @State private var group: AccountTemplateGroup?
    @Environment(\.dismiss) private var dismiss

    private var matches: [AccountTemplate] {
        AccountTemplateCatalog.search(query, group: group).filter { template in
            account.map { template.isCompatible(with: $0) } ?? true
        }
    }

    var body: some View {
        let templates = matches
        List {
            Section {
                Button {
                    choose(nil)
                } label: {
                    Label(account == nil ? "自定义账户" : "使用通用图标", systemImage: "square.and.pencil")
                        .foregroundStyle(.primary)
                }
                .accessibilityIdentifier("account.template.custom")
                Picker("类型", selection: $group) {
                    Text("全部").tag(Optional<AccountTemplateGroup>.none)
                    ForEach(AccountTemplateGroup.allCases, id: \.self) {
                        Text($0.title).tag(Optional($0))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("account.template.group")
            } footer: {
                if account != nil {
                    Text("仅显示与当前账户类型和币种相同的选项。更换图标不会改变名称、余额、历史或汇总设置。")
                }
            }
            if templates.isEmpty {
                ContentUnavailableView("没有匹配的模板", systemImage: "magnifyingglass",
                                       description: Text(account == nil
                                           ? "换个关键词，或选择自定义账户。"
                                           : "可以保留当前图标，或使用通用图标。"))
                    .accessibilityIdentifier("account.template.empty")
            }
            ForEach(AccountTemplateGroup.allCases, id: \.self) { section in
                let values = templates.filter { $0.group == section }
                if !values.isEmpty {
                    Section(section.title) {
                        ForEach(values) { template in
                            Button { choose(template) } label: {
                                HStack(spacing: 12) {
                                    AccountIconView(iconID: template.iconID, kind: template.kind)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(template.name).foregroundStyle(.primary)
                                        Text(description(template)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    if template.id == selectedTemplateID {
                                        Image(systemName: "checkmark").foregroundStyle(.primary)
                                            .accessibilityLabel("已选择")
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("account.template.option." + template.id)
                        }
                    }
                }
            }
        }
        .navigationTitle(account == nil ? "账户模板" : "机构与图标")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "名称、简称或英文别名")
    }

    private func description(_ template: AccountTemplate) -> String {
        if account != nil { return template.currency.rawValue }
        let amount = template.nature == .liability ? "期初填尚欠金额" : "期初填账户余额"
        let summary = template.includedInSummary ? "" : " · 默认不计入汇总"
        return template.currency.rawValue + " · " + amount + summary
    }

    private func choose(_ template: AccountTemplate?) {
        onSelect(template)
        dismiss()
    }
}
