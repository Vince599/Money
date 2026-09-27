import SwiftUI
import LedgerCore

enum ShortcutExecutionError: LocalizedError {
    case unavailable, busy, pendingReview, expiredReview, existingDraft, draftChanged
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "账本未能打开，请先在 Ledger 中检查后重试。"
        case .busy: return "账本正在保存或恢复，请完成后重新运行快捷指令。"
        case .pendingReview: return "已有一笔快捷指令记账等待确认，请先在 Ledger 中处理。"
        case .expiredReview: return "这次快捷指令已结束，请重新运行。"
        case .existingDraft: return "已有未完成的记账，请先确认是否替换草稿。"
        case .draftChanged: return "草稿刚刚发生变化，请检查后重新确认。"
        case .failed(let message): return message
        }
    }
}

/// Uses the regular editor only after the user has resolved the single-draft conflict.
struct ShortcutReviewView: View {
    @Bindable var model: LedgerAppModel
    let request: ShortcutEntryRequest
    @State private var installed = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if installed {
                EntryEditor(model: model)
            } else {
                NavigationStack {
                    Form {
                        if model.draft != nil {
                            Section {
                                Text("已有未完成的记账").font(.headline)
                                Text("继续将用快捷指令的内容替换现有草稿。确认保存后才会正式入账。")
                                Button("替换草稿并继续", role: .destructive) {
                                    Task { await install(replacingExisting: true) }
                                }.accessibilityIdentifier("shortcut.replaceDraft")
                                Button("保留草稿，取消本次操作") { dismiss() }
                                    .accessibilityIdentifier("shortcut.keepDraft")
                            }
                        } else if error == nil {
                            ProgressView("正在准备记账")
                        }
                        if let error {
                            Section {
                                Text(error).foregroundStyle(.red)
                                if model.draft == nil {
                                    Button("重试") { Task { await install(replacingExisting: false) } }
                                }
                            }
                        }
                    }
                    .navigationTitle("快捷指令记账")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { dismiss() }
                        }
                    }
                    .disabled(model.isBusy)
                }
            }
        }
        .interactiveDismissDisabled(model.isBusy)
        .task {
            if !installed, model.draft == nil { await install(replacingExisting: false) }
        }
    }

    private func install(replacingExisting: Bool) async {
        do {
            try await model.installShortcutDraft(request, replacingExisting: replacingExisting)
            error = nil
            installed = true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? model.message(for: error)
        }
    }
}
