import SwiftUI
import UIKit
import LedgerCore

@MainActor
enum CategorySymbolPresentation {
    /// Check the running OS, including restored symbols outside the current picker catalog.
    /// Bound the cache because a backup can contain arbitrary user symbol strings.
    private static let cache: NSCache<NSString, NSString> = {
        let value = NSCache<NSString, NSString>()
        value.countLimit = 256
        return value
    }()
    static func resolved(_ symbol: String) -> String {
        if let value = cache.object(forKey: symbol as NSString) { return value as String }
        let result = UIImage(systemName: symbol) == nil ? CategorySymbolCatalog.fallback : symbol
        cache.setObject(result as NSString, forKey: symbol as NSString)
        return result
    }
    static let availableIDs = Set(CategorySymbolCatalog.all.filter { UIImage(systemName: $0.id) != nil }.map(\.id))
    static func name(_ symbol: String) -> String {
        if resolved(symbol) != symbol { return "暂用通用图标" }
        return CategorySymbolCatalog.symbol(symbol)?.name ?? "已保存的图标"
    }
}

struct CategorySymbolView: View {
    let symbol: String
    var body: some View {
        Image(systemName: CategorySymbolPresentation.resolved(symbol))
            .symbolRenderingMode(.monochrome)
            .environment(\.symbolVariants, .none)
            .font(.system(size: 20, weight: .regular))
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
    }
}

struct CategorySymbolPicker: View {
    let categoryName: String
    let onSelect: (String) -> Void
    @State private var selection: String
    @State private var query = ""
    @State private var theme: CategorySymbolTheme?
    @FocusState private var searching: Bool
    @Environment(\.dismiss) private var dismiss

    init(symbol: String, categoryName: String, onSelect: @escaping (String) -> Void) {
        self.categoryName = categoryName; self.onSelect = onSelect
        _selection = State(initialValue: symbol)
    }

    private var matches: [CategorySymbol] {
        CategorySymbolCatalog.search(query, theme: theme).filter { CategorySymbolPresentation.availableIDs.contains($0.id) }
    }

    var body: some View {
        let results = matches
        List {
            Section("预览") {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(categoryName.isEmpty ? "分类图标" : categoryName)
                        Text(CategorySymbolPresentation.name(selection)).font(.subheadline).foregroundStyle(.secondary)
                    }
                } icon: { CategorySymbolView(symbol: selection) }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("category.icon.preview")
            }
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("搜索图标，如咖啡、飞机、健身", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.search).focused($searching)
                        .onSubmit { searching = false }
                        .accessibilityIdentifier("category.icon.search")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).accessibilityLabel("清除搜索")
                    }
                }
                Picker("主题", selection: $theme) {
                    Text("全部主题").tag(Optional<CategorySymbolTheme>.none)
                    ForEach(CategorySymbolTheme.allCases, id: \.self) { Text($0.name).tag(Optional($0)) }
                }.accessibilityIdentifier("category.icon.theme")
            }
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ForEach(CategorySymbolTheme.allCases, id: \.self) { group in
                    let items = results.filter { $0.theme == group }
                    if !items.isEmpty {
                        Section(group.name) {
                            ForEach(items) { item in
                                Button { selection = item.id; searching = false } label: {
                                    HStack {
                                        Label { Text(item.name) } icon: { CategorySymbolView(symbol: item.id) }
                                        Spacer()
                                        if selection == item.id { Image(systemName: "checkmark").accessibilityHidden(true) }
                                    }.foregroundStyle(.primary)
                                }
                                .accessibilityValue(selection == item.id ? "已选中" : "未选中")
                                .accessibilityIdentifier("category.icon.option." + item.id)
                            }
                        }
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("选择图标").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }.accessibilityIdentifier("category.icon.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("使用图标") { onSelect(selection); dismiss() }.accessibilityIdentifier("category.icon.use")
            }
        }
    }
}
