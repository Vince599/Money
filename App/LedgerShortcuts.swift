import AppIntents
import Foundation
import LedgerCore

enum ShortcutEntryKind: String, AppEnum {
    case expense, income, transfer

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "记账类型")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .expense: "支出", .income: "收入", .transfer: "转账"
    ]

    var entryKind: EntryKind {
        switch self {
        case .expense: .expense
        case .income: .income
        case .transfer: .transfer
        }
    }
}

struct LedgerAccountEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "账户")
    static let defaultQuery = LedgerAccountQuery()

    let id: UUID
    let name: String
    let currencyCode: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(currencyCode)")
    }
}

struct LedgerCategoryEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "二级分类")
    static let defaultQuery = LedgerCategoryQuery()

    let id: UUID
    let name: String
    let parentName: String
    let directionName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(parentName) / \(name)", subtitle: "\(directionName)")
    }
}

struct LedgerSubjectEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "记账主体")
    static let defaultQuery = LedgerSubjectQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

// Queries resolve persisted identifiers afresh, so renamed or disabled items do
// not silently turn into a different account, category, or subject.
struct LedgerAccountQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [LedgerAccountEntity] {
        let available = try await suggestedEntities()
        return identifiers.compactMap { id in available.first { $0.id == id } }
    }

    func entities(matching string: String) async throws -> [LedgerAccountEntity] {
        try await suggestedEntities().filter {
            string.isEmpty || $0.name.localizedStandardContains(string) || $0.currencyCode.localizedStandardContains(string)
        }
    }

    func suggestedEntities() async throws -> [LedgerAccountEntity] {
        let snapshot = try await LedgerAppModel.shared.shortcutSnapshot()
        return snapshot.book.accounts.filter(\.isActive).sorted {
            if ($0.id == snapshot.settings.defaultAccountID) != ($1.id == snapshot.settings.defaultAccountID) {
                return $0.id == snapshot.settings.defaultAccountID
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }.map { LedgerAccountEntity(id: $0.id, name: $0.name, currencyCode: $0.currency.rawValue) }
    }
}

struct LedgerCategoryQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [LedgerCategoryEntity] {
        let available = try await suggestedEntities()
        return identifiers.compactMap { id in available.first { $0.id == id } }
    }

    func entities(matching string: String) async throws -> [LedgerCategoryEntity] {
        try await suggestedEntities().filter {
            string.isEmpty || ($0.directionName + " " + $0.parentName + " / " + $0.name).localizedStandardContains(string)
        }
    }

    func suggestedEntities() async throws -> [LedgerCategoryEntity] {
        let snapshot = try await LedgerAppModel.shared.shortcutSnapshot()
        return snapshot.book.categories.compactMap { category -> LedgerCategoryEntity? in
            guard category.isActive, category.direction != .transfer,
                  let parentID = category.parentID,
                  !snapshot.book.categories.contains(where: { $0.parentID == category.id }),
                  let parent = snapshot.book.categories.first(where: {
                      $0.id == parentID && $0.parentID == nil && $0.isActive && $0.direction == category.direction
                  }) else { return nil }
            return LedgerCategoryEntity(id: category.id, name: category.name, parentName: parent.name,
                                        directionName: category.direction == .expense ? "支出" : "收入")
        }.sorted {
            ($0.directionName + $0.parentName + $0.name).localizedStandardCompare($1.directionName + $1.parentName + $1.name) == .orderedAscending
        }
    }
}

struct LedgerSubjectQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [LedgerSubjectEntity] {
        let available = try await suggestedEntities()
        return identifiers.compactMap { id in available.first { $0.id == id } }
    }

    func entities(matching string: String) async throws -> [LedgerSubjectEntity] {
        try await suggestedEntities().filter { string.isEmpty || $0.name.localizedStandardContains(string) }
    }

    func suggestedEntities() async throws -> [LedgerSubjectEntity] {
        let snapshot = try await LedgerAppModel.shared.shortcutSnapshot()
        return snapshot.book.subjects.filter(\.isActive).sorted {
            if ($0.id == snapshot.settings.defaultSubjectID) != ($1.id == snapshot.settings.defaultSubjectID) {
                return $0.id == snapshot.settings.defaultSubjectID
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }.map { LedgerSubjectEntity(id: $0.id, name: $0.name) }
    }
}

struct PrepareLedgerEntryIntent: AppIntent {
    static let title: LocalizedStringResource = "准备记一笔"
    static let description = IntentDescription("打开 Ledger 并预填支出、收入或转账，由你检查后保存。金额可以留空，或传入 28.50 这样的金额。不会直接入账。")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "类型", default: .expense) var kind: ShortcutEntryKind
    @Parameter(title: "金额", description: "例如 28.50；留空后可在 App 中填写。") var amount: String?
    @Parameter(title: "账户", description: "付款、收款或转出账户；留空使用默认账户。") var account: LedgerAccountEntity?
    @Parameter(title: "分类", description: "选择与支出或收入对应的二级分类；转账不需要分类。") var category: LedgerCategoryEntity?
    @Parameter(title: "转入账户", description: "仅转账时使用。") var destination: LedgerAccountEntity?
    @Parameter(title: "主体", description: "留空使用默认主体。") var subject: LedgerSubjectEntity?
    @Parameter(title: "日期", description: "留空使用运行快捷指令时的日期。") var occurredAt: Date?
    @Parameter(title: "标题") var entryTitle: String?
    @Parameter(title: "备注") var note: String?

    static var parameterSummary: some ParameterSummary {
        Summary("准备一笔\(\.$kind)") {
            \.$amount
            \.$account
            \.$category
            \.$destination
            \.$subject
            \.$occurredAt
            \.$entryTitle
            \.$note
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await LedgerAppModel.shared.prepareShortcut(ShortcutEntryRequest(
            kind: kind.entryKind, amountText: amount, accountID: account?.id,
            destinationAccountID: destination?.id, categoryID: category?.id, subjectID: subject?.id,
            occurredAt: occurredAt ?? Date(), title: entryTitle ?? "", note: note ?? ""))
        return .result()
    }
}

struct RecordLedgerEntryIntent: AppIntent {
    static let title: LocalizedStringResource = "直接记一笔"
    static let description = IntentDescription("在后台直接保存支出、收入或转账，不打开确认页面。金额必填，例如 28.50；支出和收入须指定二级分类，转账须指定转入账户。返回新流水的标识。")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "类型", default: .expense) var kind: ShortcutEntryKind
    @Parameter(title: "金额", description: "例如 28.50；必须为大于零的有效金额。") var amount: String
    @Parameter(title: "账户", description: "付款、收款或转出账户；留空使用默认账户。") var account: LedgerAccountEntity?
    @Parameter(title: "分类", description: "支出和收入必须选择对应的二级分类；转账不需要分类。") var category: LedgerCategoryEntity?
    @Parameter(title: "转入账户", description: "转账时必填，且必须与转出账户不同、币种相同。") var destination: LedgerAccountEntity?
    @Parameter(title: "主体", description: "留空使用默认主体。") var subject: LedgerSubjectEntity?
    @Parameter(title: "日期", description: "留空使用运行快捷指令时的日期。") var occurredAt: Date?
    @Parameter(title: "标题") var entryTitle: String?
    @Parameter(title: "备注") var note: String?

    static var parameterSummary: some ParameterSummary {
        Summary("直接记录\(\.$amount)的\(\.$kind)") {
            \.$account
            \.$category
            \.$destination
            \.$subject
            \.$occurredAt
            \.$entryTitle
            \.$note
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let snapshot = try await LedgerAppModel.shared.shortcutSnapshot()
        if account == nil, snapshot.settings.defaultAccountID == nil {
            throw $account.requestValue("请选择付款、收款或转出账户。")
        }
        if kind != .transfer, category == nil {
            throw $category.requestValue("请选择与收支类型对应的二级分类。")
        }
        if kind == .transfer, destination == nil {
            throw $destination.requestValue("请选择同币种的转入账户。")
        }
        let entry = try await LedgerAppModel.shared.recordShortcut(ShortcutEntryRequest(
            kind: kind.entryKind, amountText: amount, accountID: account?.id,
            destinationAccountID: destination?.id, categoryID: category?.id, subjectID: subject?.id,
            occurredAt: occurredAt ?? Date(), title: entryTitle ?? "", note: note ?? ""))
        return .result(value: entry.id.uuidString.lowercased(), dialog: "已保存记账记录。")
    }
}

struct LedgerAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RecordLedgerEntryIntent(),
                    phrases: ["用\(.applicationName)记一笔", "用\(.applicationName)直接记账"],
                    shortTitle: "直接记账", systemImageName: "plus.circle")
        AppShortcut(intent: PrepareLedgerEntryIntent(),
                    phrases: ["在\(.applicationName)准备记账"],
                    shortTitle: "预填并确认", systemImageName: "square.and.pencil")
    }

    static let shortcutTileColor: ShortcutTileColor = .orange
}
