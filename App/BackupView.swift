import SwiftUI
import UniformTypeIdentifiers
import LedgerCore

struct BackupZipDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct BackupView: View {
    @Bindable var model: LedgerAppModel
    @State private var document: BackupZipDocument?
    @State private var export = false
    @State private var importFile = false
    @State private var preview: BackupRestorePreview?
    @State private var sourceName = ""
    @State private var confirmRestore = false
    @State private var message: String?
    @State private var safetyBackups: [SafetyBackup] = []
    var body: some View {
        Form {
            Section {
                Button("导出完整备份") {
                    Task {
                        do { document = BackupZipDocument(data: try await model.exportBackup()); export = true; message = nil }
                        catch { message = model.message(for: error) }
                    }
                }.accessibilityIdentifier("backup.export")
                Button("选择备份恢复") { preview = nil; importFile = true }.accessibilityIdentifier("backup.import")
            } footer: {
                Text("备份为 ZIP 内的一组 CSV，包含本版本全部账户、流水、余额更正、分类、主体、标签、项目、设置和草稿。恢复会整体替换当前账本。")
            }
            if let preview {
                Section("恢复预览") {
                    Text(sourceName).lineLimit(2)
                    LabeledContent("账户", value: String(preview.accountCount))
                    LabeledContent("流水", value: String(preview.entryCount))
                    LabeledContent("余额更正", value: String(preview.adjustmentCount))
                    LabeledContent("分类 / 主体", value: "\(preview.categoryCount) / \(preview.subjectCount)")
                    LabeledContent("标签 / 项目", value: "\(preview.tagCount) / \(preview.projectCount)")
                    LabeledContent("未完成草稿", value: preview.hasDraft ? "包含" : "无")
                    Text("文件与关联已检查。确认后先保存当前账本的安全备份，再恢复所选内容。").foregroundStyle(.secondary)
                    Button("恢复此备份", role: .destructive) { confirmRestore = true }
                    Button("取消预览") { self.preview = nil }
                }
            }
            if model.isBusy { Section { ProgressView("正在处理，请稍候") } }
            if let message { Section { Text(message) } }
            if !safetyBackups.isEmpty {
                Section {
                    ForEach(safetyBackups) { backup in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                                Button("查看恢复内容") { inspect(backup.url) }
                            }
                            Spacer()
                            ShareLink(item: backup.url) { Image(systemName: "square.and.arrow.up") }
                                .accessibilityLabel("导出恢复前安全备份")
                        }
                    }
                } header: { Text("恢复前安全备份") } footer: {
                    Text("这些副本保存在本机 App 内，可导出到“文件”。卸载 App 会移除本机副本。")
                }
            }
        }
        .navigationTitle("备份与恢复")
        .disabled(model.isBusy)
        .task { await refreshSafetyBackups() }
        .fileExporter(isPresented: $export, document: document, contentType: .zip,
                      defaultFilename: "Ledger-\(Date().ISO8601Format().prefix(10))") { result in
            switch result {
            case .success: message = "备份已导出。"
            case .failure: message = "导出未完成，请重试。"
            }
            document = nil
        }
        .fileImporter(isPresented: $importFile, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url): inspect(url)
            case .failure: message = "未能读取所选文件。"
            }
        }
        .confirmationDialog("用此备份替换当前账本？", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("保存安全备份并恢复", role: .destructive) {
                guard let preview else { return }
                Task {
                    if await model.restore(preview) {
                        self.preview = nil; message = "恢复完成，原账本已保留为安全备份。"
                    } else { message = model.errorMessage }
                    await refreshSafetyBackups()
                }
            }
        }
    }
    private func inspect(_ url: URL) {
        preview = nil; message = nil
        Task {
            do { preview = try await model.prepareRestore(from: url); sourceName = url.lastPathComponent }
            catch { message = model.message(for: error) }
        }
    }
    private func refreshSafetyBackups() async {
        do { safetyBackups = try await model.safetyBackups() }
        catch { message = "暂时无法列出本机安全备份，请稍后重试。" }
    }
}
