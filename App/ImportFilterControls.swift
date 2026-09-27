import SwiftUI
import LedgerCore

extension ImportRowState {
    var filterName: String {
        switch self {
        case .pending: "待处理"
        case .imported: "已导入"
        case .skipped: "已跳过"
        case .reverted: "已撤销"
        case .merged: "已合并来源"
        case .unlinked: "已解除来源"
        }
    }
}
struct ImportFilterControls: View {
    @Binding var filter: ImportFilter
    var namespaces: [String]? = nil
    var body: some View {
        Section("查找导入记录") {
            TextField("搜索交易号、标题或备注", text: $filter.keyword)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("import.filter.keyword")
            if let namespaces {
                Picker("来源", selection: $filter.namespace) {
                    Text("全部来源").tag(String?.none)
                    ForEach(namespaces, id: \.self) { Text($0).tag(Optional($0)) }
                }.accessibilityIdentifier("import.filter.namespace")
                Picker("批次", selection: $filter.scope) {
                    Text("全部批次").tag(ImportBatchScope.all)
                    Text("未撤销").tag(ImportBatchScope.open)
                    Text("已撤销").tag(ImportBatchScope.reverted)
                }.accessibilityIdentifier("import.filter.scope")
            }
            Picker("行状态", selection: $filter.state) {
                Text("全部状态").tag(ImportRowState?.none)
                ForEach([ImportRowState.pending, .imported, .merged, .unlinked, .skipped, .reverted], id: \.self) {
                    Text($0.filterName).tag(Optional($0))
                }
            }.accessibilityIdentifier("import.filter.state")
            if filter != ImportFilter() { Button("清除筛选") { filter = ImportFilter() }.accessibilityIdentifier("import.filter.clear") }
        } footer: {
            Text("筛选只用于查找。已撤销批次中的待处理原行仍不可提交；切换筛选会清空勾选。")
        }
    }
}
