import SwiftUI
import LedgerCore

/// Each editor receives a fresh version only when the user deliberately changes rows.
struct ImportReviewView: View {
    @Bindable var model: LedgerAppModel
    let batchID: UUID
    let rowIDs: [UUID]?
    @State private var rowID: UUID
    init(model: LedgerAppModel, batchID: UUID, initialRowID: UUID, rowIDs: [UUID]? = nil) {
        self.model = model; self.batchID = batchID; self.rowIDs = rowIDs
        _rowID = State(initialValue: initialRowID)
    }
    var body: some View {
        if let batch = model.book.importBatches.first(where: { $0.id == batchID }) {
            let allowed = rowIDs.map(Set.init)
            let rows = batch.rows.filter { allowed?.contains($0.id) ?? true }
            if let index = rows.firstIndex(where: { $0.id == rowID }) {
                ImportRowEditor(model: model, batch: batch,
                                previousID: index > 0 ? rows[index - 1].id : nil,
                                nextID: index + 1 < rows.count ? rows[index + 1].id : nil,
                                position: "第 \(index + 1) / \(rows.count) 笔 · " + (rowIDs == nil ? "按文件顺序" : "本次筛选，按文件顺序"),
                                move: { rowID = $0 }, row: rows[index])
                    .id(rowID)
            } else { unavailable }
        } else { unavailable }
    }
    private var unavailable: some View {
        ContentUnavailableView("导入批次已变化", systemImage: "doc", description: Text("关闭后重新打开导入批次。"))
    }
}

private enum TagEditMode: String, CaseIterable {
    case keep = "保持原标签", add = "追加标签", remove = "移除指定标签", replace = "替换全部标签", clear = "清空标签"
}
private enum ProjectEditMode: String, CaseIterable {
    case keep = "保持原项目", set = "设置项目", clear = "清除项目"
}

struct ImportLabelsView: View {
    @Bindable var model: LedgerAppModel
    let batch: ImportBatch
    let rowIDs: Set<UUID>
    @State private var tagMode = TagEditMode.keep
    @State private var projectMode = ProjectEditMode.keep
    @State private var selectedTags: [UUID] = []
    @State private var projectID: UUID?
    @State private var preview: ImportLabelsPlan?
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss
    private var tagChoices: [UUID] {
        if tagMode == .remove {
            var seen = Set<UUID>()
            return batch.rows.filter { rowIDs.contains($0.id) }.flatMap(\.tagIDs).filter { seen.insert($0).inserted }
        }
        return model.book.tags.filter(\.isActive).map(\.id)
    }
    private var tagAction: ImportTagChange {
        switch tagMode {
        case .keep: .keep
        case .add: .add(selectedTags)
        case .remove: .remove(selectedTags)
        case .replace: .replace(selectedTags)
        case .clear: .clear
        }
    }
    private var projectAction: ImportProjectChange {
        if projectMode == .clear { return .clear }
        if projectMode == .set, let projectID { return .set(projectID) }
        return .keep
    }
    private var canPreview: Bool {
        (tagMode != .keep || projectMode != .keep)
            && (!(tagMode == .add || tagMode == .remove || tagMode == .replace) || !selectedTags.isEmpty)
            && (projectMode != .set || projectID != nil)
    }
    var body: some View {
        NavigationStack {
            Form {
                if let preview { previewSections(preview) }
                else { tagSection; projectSection; previewButton }
                if let message { Text(message).foregroundStyle(.red) }
            }
            .navigationTitle("本批标签／项目").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .onChange(of: tagMode) { _, _ in selectedTags = [] }
            .disabled(model.isBusy).interactiveDismissDisabled(model.isBusy)
        }
    }
    @ViewBuilder private func previewSections(_ plan: ImportLabelsPlan) -> some View {
        Section("仅修改所选 \(plan.rowIDs.count) 行") {
            Text("\(tagMode.rawValue) · \(projectMode.rawValue)")
            Text("只保存本批草稿；正式入账仍需单独确认，不建立长期规则。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(plan.batch.rows.filter { plan.rowIDs.contains($0.id) }) { after in
            if let before = plan.expectedBook.importBatches.first(where: { $0.id == batch.id })?.rows.first(where: { $0.id == after.id }) {
                rowPreview(before: before, after: after, book: plan.expectedBook)
            }
        }
        Button("确认仅修改这些草稿行") {
            Task { if await model.commitImportLabels(plan) { dismiss() } else { message = model.errorMessage } }
        }.accessibilityIdentifier("import.labels.confirm")
        Button("返回调整") { preview = nil; message = nil }
    }
    private func rowPreview(before: ImportRow, after: ImportRow, book: LedgerBook) -> some View {
        Section(after.title.isEmpty ? after.sourceID : after.title) {
            Text(after.raw[3] + " " + after.raw[4] + " · " + after.raw[1]).font(.caption).foregroundStyle(.secondary)
            LabeledContent("原标签", value: tagsText(before.tagIDs, book: book))
            LabeledContent("修改后标签", value: tagsText(after.tagIDs, book: book))
            LabeledContent("原项目", value: projectText(before.projectID, book: book))
            LabeledContent("修改后项目", value: projectText(after.projectID, book: book))
        }
    }
    private var tagSection: some View {
        Section {
            Picker("修改方式", selection: $tagMode) {
                ForEach(TagEditMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if tagMode == .add || tagMode == .remove || tagMode == .replace {
                ForEach(tagChoices, id: \.self) { id in
                    Toggle(tagText(id, book: model.book), isOn: Binding(get: { selectedTags.contains(id) }, set: { value in
                        if value { if !selectedTags.contains(id) { selectedTags.append(id) } }
                        else { selectedTags.removeAll { $0 == id } }
                    }))
                }
            }
        } header: { Text("标签") } footer: { Text("追加保留原标签，替换覆盖全部原标签。移除可清理已停用或缺失的标签。") }
    }
    private var projectSection: some View {
        Section("项目") {
            Picker("修改方式", selection: $projectMode) {
                ForEach(ProjectEditMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            if projectMode == .set {
                Picker("项目", selection: $projectID) {
                    Text("请选择项目").tag(Optional<UUID>.none)
                    ForEach(model.book.projects.filter { !$0.isArchived }) { Text($0.name).tag(Optional($0.id)) }
                }
            }
        }
    }
    private var previewButton: some View {
        Button("预览所选 \(rowIDs.count) 行") {
            Task {
                do {
                    let plan = try await model.prepareImportLabels(batchID: batch.id, rowIDs: rowIDs, tags: tagAction, project: projectAction)
                    guard plan.expectedBook.importBatches.first(where: { $0.id == batch.id }) == batch else { throw ImportError.stalePreview }
                    preview = plan; message = nil
                } catch { message = model.message(for: error) }
            }
        }.disabled(!canPreview).accessibilityIdentifier("import.labels.preview")
    }
    private func tagText(_ id: UUID, book: LedgerBook) -> String {
        guard let tag = book.tags.first(where: { $0.id == id }) else { return "缺失标签 " + String(id.uuidString.prefix(8)) }
        return tag.name + (tag.isActive ? "" : "（已停用）")
    }
    private func tagsText(_ ids: [UUID], book: LedgerBook) -> String { ids.isEmpty ? "无" : ids.map { tagText($0, book: book) }.joined(separator: "、") }
    private func projectText(_ id: UUID?, book: LedgerBook) -> String {
        guard let id else { return "无" }
        guard let project = book.projects.first(where: { $0.id == id }) else { return "项目已缺失" }
        return project.name + (project.isArchived ? "（已归档）" : "")
    }
}
