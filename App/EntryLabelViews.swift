import SwiftUI
import LedgerCore

enum EntryLabelKind {
    case tag, project
    var title: String { self == .tag ? "标签" : "项目" }
}

struct EntryLabelListView: View {
    @Bindable var model: LedgerAppModel
    let kind: EntryLabelKind
    @State private var editor: LabelEditValue?
    var body: some View {
        List {
            Section {
                if kind == .tag {
                    ForEach(model.book.tags) { tag in
                        Button { editor = LabelEditValue(id: tag.id, name: tag.name, unavailable: !tag.isActive) } label: {
                            row(tag.name, unavailable: !tag.isActive)
                        }.accessibilityIdentifier("tag.row." + tag.id.uuidString.lowercased())
                    }
                } else {
                    ForEach(model.book.projects) { project in
                        Button { editor = LabelEditValue(id: project.id, name: project.name, unavailable: project.isArchived) } label: {
                            row(project.name, unavailable: project.isArchived)
                        }.accessibilityIdentifier("project.row." + project.id.uuidString.lowercased())
                    }
                }
            } footer: {
                Text(kind == .tag ? "一笔流水可有多个标签。停用后保留历史，新流水不再选用。" : "一笔流水可选一个项目。归档后保留历史关联和筛选，可随时取消归档。")
            }
            Button("添加" + kind.title) { editor = LabelEditValue(id: UUID(), name: "", unavailable: false) }
                .accessibilityIdentifier(kind == .tag ? "tag.add" : "project.add")
        }
        .navigationTitle(kind.title + "管理")
        .sheet(item: $editor) { value in EntryLabelEditorView(model: model, kind: kind, value: value) }
        .disabled(model.isBusy)
    }
    private func row(_ name: String, unavailable: Bool) -> some View {
        HStack {
            Label(name, systemImage: kind == .tag ? "tag" : "folder").foregroundStyle(.primary)
            Spacer()
            if unavailable { Text(kind == .tag ? "已停用" : "已归档").font(.caption).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct LabelEditValue: Identifiable {
    let id: UUID
    var name: String
    var unavailable: Bool
}

struct EntryLabelEditorView: View {
    @Bindable var model: LedgerAppModel
    let kind: EntryLabelKind
    @State var value: LabelEditValue
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextField(kind.title + "名称", text: $value.name).accessibilityIdentifier("label.name")
                Toggle(kind == .tag ? "停用标签" : "归档项目", isOn: $value.unavailable).accessibilityIdentifier("label.unavailable")
                ImportRuleReferencesSection(book: model.book, field: kind == .tag ? .tag : .project, id: value.id)
                if let message { Text(message).foregroundStyle(.red) }
                Button("保存") {
                    let name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        let saved: Bool
                        if kind == .tag {
                            saved = await model.saveTag(EntryTag(id: value.id, name: name, isActive: !value.unavailable))
                        } else {
                            saved = await model.saveProject(EntryProject(id: value.id, name: name, isArchived: value.unavailable))
                        }
                        if saved { dismiss() } else { message = model.errorMessage }
                    }
                }.accessibilityIdentifier("label.save")
            }
            .navigationTitle(kind.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .disabled(model.isBusy).interactiveDismissDisabled(model.isBusy)
        }
    }
}

/// Selection edits the owning draft. The posting command validates availability again at save time.
struct EntryLabelsSelectionView: View {
    let book: LedgerBook
    @Binding var tagIDs: [UUID]
    @Binding var projectID: UUID?
    let retainedTagIDs: Set<UUID>
    let retainedProjectID: UUID?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            Section {
                Picker("项目", selection: $projectID) {
                    Text("不关联项目").tag(Optional<UUID>.none)
                    ForEach(book.projects.filter { !$0.isArchived || $0.id == retainedProjectID || $0.id == projectID }) { project in
                        Text(project.name + (project.isArchived ? "（已归档）" : "")).tag(Optional(project.id))
                    }
                    if let id = projectID, !book.projects.contains(where: { $0.id == id }) {
                        Text("项目已缺失，请重选").tag(Optional(id))
                    }
                }.accessibilityIdentifier("entry.project")
            } footer: { Text("每笔最多关联一个项目，不改变原用途分类。") }
            Section {
                ForEach(book.tags.filter { $0.isActive || retainedTagIDs.contains($0.id) || tagIDs.contains($0.id) }) { tag in
                    Toggle(tag.name + (tag.isActive ? "" : "（已停用）"), isOn: Binding(
                        get: { tagIDs.contains(tag.id) },
                        set: { selected in
                            if selected { if !tagIDs.contains(tag.id) { tagIDs.append(tag.id) } }
                            else { tagIDs.removeAll { $0 == tag.id } }
                        }))
                        .accessibilityIdentifier("entry.tag." + tag.id.uuidString.lowercased())
                }
                if tagIDs.contains(where: { id in !book.tags.contains { $0.id == id } }) {
                    Button("移除已缺失的标签") { tagIDs.removeAll { id in !book.tags.contains { $0.id == id } } }
                }
                if !tagIDs.isEmpty { Button("清除所选标签") { tagIDs = [] } }
            } header: { Text("标签（可多选）") } footer: {
                Text("标签和项目可在“账户 → 设置”中添加或管理。")
            }
        }
        .navigationTitle("标签／项目").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) {
            Button("完成") { dismiss() }.accessibilityIdentifier("entry.labels.done")
        } }
    }
    static func summary(book: LedgerBook, tags: [UUID], project: UUID?) -> String {
        var parts: [String] = []
        if !tags.isEmpty { parts.append("\(tags.count) 个标签") }
        if let project { parts.append(book.projects.first { $0.id == project }?.name ?? "项目已缺失") }
        return parts.isEmpty ? "未选择" : parts.joined(separator: " · ")
    }
}
