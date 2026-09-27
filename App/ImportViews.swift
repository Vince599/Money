import SwiftUI
import UniformTypeIdentifiers
import LedgerCore

struct ImportAccountEffect: Identifiable, Sendable {
    let id: UUID
    let name: String
    let isNew: Bool
    let before: Money
    let after: Money
}
struct ImportCommitPreview: Identifiable, Sendable {
    let id: UUID
    let plan: ImportPlan
    let effects: [ImportAccountEffect]
}
struct ImportRowInspection: Sendable {
    let review: ImportRowReview
    let similar: [LedgerEntry]
}

struct ImportTemplateDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var data = ImportCSV.template
    init() {}
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct ImportListView: View {
    @Bindable var model: LedgerAppModel
    @State private var namespace = ""
    @State private var chooseFile = false
    @State private var exportTemplate = false
    @State private var message: String?
    var body: some View {
        List {
            Section {
                Button("导出通用 CSV 模板") { exportTemplate = true }.accessibilityIdentifier("import.template")
                TextField("来源身份，例如：招商银行卡1234", text: $namespace).accessibilityIdentifier("import.namespace")
                Button("选择 CSV，保存为导入草稿") { chooseFile = true }
                    .disabled(namespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("import.choose")
            } footer: {
                Text("同一来源账户请一直使用相同身份，交易号在该身份内防重。模板只含合成示例，请替换；目前未直接适配钱迹、微信等原始表头。选择文件不会立即入账。")
            }
            Section("导入批次") {
                ForEach(model.book.importBatches.reversed()) { batch in
                    NavigationLink {
                        ImportBatchView(model: model, batchID: batch.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(batch.name).foregroundStyle(.primary)
                            Text("\(batch.namespace) · 待处理 \(batch.rows.filter { $0.state == .pending }.count) / \(batch.rows.count)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("import.batch." + batch.id.uuidString.lowercased())
                }
            }
            if model.isBusy { ProgressView("正在读取或保存…") }
            if let message { Text(message).foregroundStyle(.red) }
        }
        .navigationTitle("导入账单").disabled(model.isBusy)
        .fileImporter(isPresented: $chooseFile, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            switch result {
            case .success(let url): Task {
                message = nil
                if !(await model.importCSV(from: url, namespace: namespace)) { message = model.errorMessage }
            }
            case .failure(let error): message = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $exportTemplate, document: ImportTemplateDocument(), contentType: .commaSeparatedText,
                      defaultFilename: "Ledger-import-template") { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
    }
}

struct ImportBatchView: View {
    @Bindable var model: LedgerAppModel
    let batchID: UUID
    @State private var visibleCount = 50
    @State private var selected: Set<UUID> = []
    @State private var reviews: [UUID: ImportRowReview] = [:]
    @State private var reviewLoading = false
    @State private var editing: ImportRow?
    @State private var showMapping = false
    @State private var showClassification = false
    @State private var preview: ImportCommitPreview?
    @State private var message: String?
    private var batch: ImportBatch? { model.book.importBatches.first { $0.id == batchID } }
    private var visible: [ImportRow] { Array((batch?.rows ?? []).prefix(visibleCount)) }
    private var request: String { "\(model.historyRevision):\(visibleCount)" }
    var body: some View {
        List {
            if let batch {
                Section {
                    Text(batch.namespace)
                    Text("已导入 \(batch.rows.filter { $0.state == .imported }.count) · 已跳过 \(batch.rows.filter { $0.state == .skipped }.count) · 待处理 \(batch.rows.filter { $0.state == .pending }.count)")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("本批账户匹配／新建") { showMapping = true }.accessibilityIdentifier("import.accounts")
                    Button("选择当前已显示的可导入行") {
                        selected = Set(visible.filter { reviews[$0.id] == .ready }.prefix(200).map(\.id))
                    }.disabled(reviewLoading)
                    Button("清除选择") { selected = [] }
                    Button("修改所选行的分类／主体") { showClassification = true }
                        .disabled(selected.isEmpty || selected.count > 200)
                }
                ForEach(visible) { row in
                    HStack {
                        if row.state == .pending {
                            Toggle("选择此行", isOn: Binding(get: { selected.contains(row.id) }, set: {
                                if $0 { selected.insert(row.id) } else { selected.remove(row.id) }
                            })).labelsHidden().accessibilityLabel("选择 " + row.title).toggleStyle(.button)
                        }
                        Button { editing = row } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.title.isEmpty ? row.sourceID : row.title).foregroundStyle(.primary)
                                Text("\(row.raw[3]) \(row.raw[4]) · \(row.raw[1])").font(.caption).foregroundStyle(.secondary)
                                Text(row.state == .pending ? (reviews[row.id]?.explanation ?? "正在核对…") : (row.state == .imported ? "已导入" : "已跳过"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain).accessibilityIdentifier("import.row." + row.id.uuidString.lowercased())
                    }
                }
                if visibleCount < batch.rows.count { Button("显示更多") { visibleCount += 50 } }
                if reviewLoading { ProgressView("正在核对当前行…") }
                Section {
                    Button("预览导入所选 \(selected.count) 行") { prepare(skip: false) }.accessibilityIdentifier("import.preview")
                    Button("预览跳过所选 \(selected.count) 行") { prepare(skip: true) }
                } footer: { Text("每次最多 200 行。跳过也需确认，原始数据和处理结果会保留。未处理行可下次继续；历史流水正常影响当前余额。") }
                    .disabled(selected.isEmpty || reviewLoading)
                if let message { Text(message).foregroundStyle(.red) }
            }
        }
        .navigationTitle(batch?.name ?? "导入批次").navigationBarTitleDisplayMode(.inline).disabled(model.isBusy)
        .task(id: request) {
            reviewLoading = true
            do {
                let values = try await model.importReviews(batchID: batchID, rowIDs: Set(visible.map(\.id)))
                guard !Task.isCancelled else { return }
                reviews = values; reviewLoading = false
                selected.formIntersection(Set((batch?.rows ?? []).filter { $0.state == .pending }.map(\.id)))
            } catch { if !Task.isCancelled { message = model.message(for: error); reviewLoading = false } }
        }
        .sheet(item: $editing) { row in
            if let batch { ImportRowEditor(model: model, batch: batch, row: row) }
        }
        .sheet(isPresented: $showMapping) { if let batch { ImportAccountMappingView(model: model, batch: batch) } }
        .sheet(isPresented: $showClassification) { if let batch { ImportClassificationView(model: model, batch: batch, rowIDs: selected) } }
        .sheet(item: $preview) { value in ImportConfirmationView(model: model, preview: value) }
    }
    private func prepare(skip: Bool) {
        Task {
            do { preview = try await model.prepareImport(batchID: batchID, importIDs: skip ? [] : selected, skipIDs: skip ? selected : []); message = nil }
            catch { message = model.message(for: error) }
        }
    }
}

struct ImportConfirmationView: View {
    @Bindable var model: LedgerAppModel
    let preview: ImportCommitPreview
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("新增流水", value: String(preview.plan.importIDs.count))
                    LabeledContent("确认跳过", value: String(preview.plan.skipIDs.count))
                    LabeledContent("新建账户", value: String(preview.plan.newAccountIDs.count))
                }
                ForEach(preview.effects) { effect in
                    Section(effect.name + (effect.isNew ? "（草稿新账户）" : "")) {
                        LabeledContent(effect.isNew ? "设置的期初" : "当前余额", value: effect.before.decimalString + " " + effect.before.currency.rawValue)
                        LabeledContent("导入后余额", value: effect.after.decimalString + " " + effect.after.currency.rawValue)
                    }
                }
                Text("历史支出也会扣减账户余额。若与实际余额不符，之后可手动更正；消费仍归原发生日期。未选中行保留在草稿。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let message { Text(message).foregroundStyle(.red) }
                Button("确认提交") {
                    Task { if await model.commitImport(preview.plan) { dismiss() } else { message = model.errorMessage } }
                }.accessibilityIdentifier("import.confirm")
            }
            .navigationTitle("确认本次导入").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .disabled(model.isBusy).interactiveDismissDisabled(model.isBusy)
        }
    }
}

struct ImportRowEditor: View {
    @Bindable var model: LedgerAppModel
    let batch: ImportBatch
    @State var row: ImportRow
    @State private var message: String?
    @State private var inspection: ImportRowInspection?
    @State private var inspectedRequest = ""
    @Environment(\.dismiss) private var dismiss
    private var request: String {
        [row.accountID?.uuidString ?? "", row.destinationAccountID?.uuidString ?? "", row.categoryID?.uuidString ?? "",
         row.subjectID.uuidString, row.duplicateReviewToken ?? "", String(model.historyRevision)].joined(separator: ":")
    }
    private var review: ImportRowReview? { inspectedRequest == request ? inspection?.review : nil }
    private var accounts: [Account] { (model.book.accounts + batch.proposedAccounts).filter { $0.isActive && $0.currency.rawValue == row.raw[4] } }
    var body: some View {
        NavigationStack {
            Form {
                Section("本次映射") {
                    Picker("付款／收款账户", selection: $row.accountID) {
                        Text("暂缓选择").tag(Optional<UUID>.none)
                        ForEach(accounts) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if row.raw[2] == "transfer" {
                        Picker("转入账户", selection: $row.destinationAccountID) {
                            Text("暂缓选择").tag(Optional<UUID>.none)
                            ForEach(accounts) { Text($0.name).tag(Optional($0.id)) }
                        }
                    } else {
                        Picker("分类", selection: $row.categoryID) {
                            Text("暂缓选择").tag(Optional<UUID>.none)
                            ForEach(model.book.categories.filter { category in
                                category.isActive && category.parentID != nil && category.direction.rawValue == row.raw[2]
                                    && model.book.categories.contains { $0.id == category.parentID && $0.isActive }
                            }) { category in
                                Text((model.book.categories.first { $0.id == category.parentID }?.name ?? "") + " / " + category.name).tag(Optional(category.id))
                            }
                        }
                    }
                    Picker("主体", selection: $row.subjectID) {
                        ForEach(model.book.subjects.filter(\.isActive)) { Text($0.name).tag($0.id) }
                    }
                }.disabled(row.state != .pending)
                Section("核对") {
                    Text(review?.explanation ?? "正在核对…")
                    if inspectedRequest == request, let inspection {
                        ForEach(inspection.similar.prefix(20)) { similar in
                            Text("\(BookDate.dateTime(similar.occurredAt)) · \(similar.title) · \(similar.amount.decimalString) \(similar.amount.currency.rawValue)")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if !inspection.similar.isEmpty {
                            NavigationLink("查看全部 \(inspection.similar.count) 笔疑似流水") {
                                List(inspection.similar) { entry in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(entry.title.isEmpty ? entry.kind.displayName : entry.title)
                                        Text(entry.amount.decimalString + " " + entry.amount.currency.rawValue)
                                        Text(BookDate.dateTime(entry.occurredAt)).foregroundStyle(.secondary)
                                        Text(model.book.entries.contains { $0.id == entry.id } ? "已有流水" : "本批待导入")
                                            .font(.caption).foregroundStyle(.secondary)
                                        if !entry.note.isEmpty { Text(entry.note).font(.footnote) }
                                    }
                                }.navigationTitle("疑似重复流水")
                            }
                        }
                    }
                    if case .some(.similar(let token, _)) = review {
                        Button("已逐笔核对，保留为独立交易") { row.duplicateReviewToken = token }
                    }
                    if row.duplicateReviewToken != nil {
                        Button("撤回独立交易确认") { row.duplicateReviewToken = nil }
                    }
                }
                Section("来源原文（只读）") {
                    ForEach(Array(ImportCSV.header.enumerated()), id: \.offset) { index, field in
                        LabeledContent(field, value: row.raw[index].isEmpty ? "—" : row.raw[index])
                    }
                }
                if let message { Text(message).foregroundStyle(.red) }
                if row.state == .pending {
                    Button("保存本行核对") {
                        var updated = batch
                        if let index = updated.rows.firstIndex(where: { $0.id == row.id }) { updated.rows[index] = row }
                        Task { if await model.saveImport(updated, expectedVersion: batch.version) { dismiss() } else { message = model.errorMessage } }
                    }
                }
            }
            .navigationTitle("核对导入行").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .disabled(model.isBusy).interactiveDismissDisabled(model.isBusy)
            .task(id: request) {
                let key = request
                do {
                    let result = try await model.reviewImportRow(row, batch: batch)
                    guard !Task.isCancelled else { return }
                    inspection = result; inspectedRequest = key
                } catch { if !Task.isCancelled { message = model.message(for: error) } }
            }
        }
    }
}
