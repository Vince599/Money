import Foundation
import Observation
import LedgerCore
import LedgerStore

@Observable @MainActor
final class LedgerAppModel {
    // App Intents run in the app process and share the UI's repository and draft sequence.
    static let shared = LedgerAppModel()
    var book = LedgerBook()
    var home: HomeOverview?
    var draft: EntryDraft?
    var settings = LedgerSettings()
    var isLoaded = false
    private(set) var historyRevision: UInt64 = 0
    var isBusy = false
    var errorMessage: String?
    var draftError: String?
    var pendingShortcut: ShortcutEntryRequest?
    var shortcutBlockingSheets: Set<String> = []
    private var repository: LedgerRepository?
    private var revision: UInt64 = 0
    private var startupTask: Task<Void, Never>?

    private var homeRequestGeneration: UInt64 = 0
    private let now: @MainActor () -> Date
    private let homeSnapshot: @MainActor (LedgerRepository) async throws -> LedgerSnapshot

    init(repository: LedgerRepository? = nil,
         now: @escaping @MainActor () -> Date = { Date() },
         homeSnapshot: @escaping @MainActor (LedgerRepository) async throws -> LedgerSnapshot = { try await $0.snapshot() }) {
        self.repository = repository
        self.now = now
        self.homeSnapshot = homeSnapshot
    }

    func start() async {
        if let startupTask { await startupTask.value; return }
        guard !isLoaded else { return }
        let task = Task { await self.load() }
        startupTask = task
        await task.value
        startupTask = nil
    }

    private func load() async {
        let interval = LedgerPerformance.begin("App.StartToModel")
        var outcome = LedgerPerformance.Outcome.threw
        defer { LedgerPerformance.end(interval, outcome: outcome) }
        do {
            let initial: LedgerSnapshot
            if let repository {
                initial = try await repository.snapshot()
            } else {
                let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
                let directory = Self.storageDirectory(in: base)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let path = directory.appendingPathComponent("ledger.sqlite").path
                // Database creation/migration is also off the main actor.
                let opened = try await Task.detached { try LedgerRepository.open(path: path) }.value
                repository = opened.repository
                initial = opened.snapshot
            }
            apply(initial)
            isLoaded = true
            errorMessage = nil
            outcome = .completed
        } catch { errorMessage = message(for: error) }
    }
    private static func storageDirectory(in base: URL) -> URL {
        #if DEBUG
        // UI tests use a fresh, UUID-scoped real database and keep it on relaunch.
        // This branch is absent from the Release app and never resets a user's book.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "-ledger-ui-test-store"), arguments.indices.contains(index + 1),
           let id = UUID(uuidString: arguments[index + 1]) {
            return base.appendingPathComponent("LedgerUITests", isDirectory: true)
                .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        }
        #endif
        return base.appendingPathComponent("Ledger", isDirectory: true)
    }
    func newDraft() -> EntryDraft {
        draft ?? EntryDraft(accountID: settings.defaultAccountID, subjectID: settings.defaultSubjectID)
    }

    func historyPage(matching filter: EntryFilter, after cursor: EntryPageCursor?) async throws -> HistoryPage {
        guard isLoaded, let repository else { throw LedgerError.unsupportedOperation }
        let requestRevision = historyRevision
        let page = try await repository.historyPage(matching: filter, after: cursor)
        try Task.checkCancellation()
        guard requestRevision == historyRevision else { throw CancellationError() }
        return page
    }

    /// Called on foreground entry and at Shanghai month boundaries, never for
    /// draft keystrokes. A newer mutation or refresh invalidates this response.
    func refreshHomeIfNeeded() async {
        guard isLoaded, !isBusy, let repository, home?.isCurrent(at: now()) != true else { return }
        homeRequestGeneration += 1
        let request = homeRequestGeneration
        do {
            let value = try await homeSnapshot(repository)
            guard request == homeRequestGeneration, !isBusy, !Task.isCancelled,
                  value.home?.isCurrent(at: now()) == true else { return }
            apply(value)
        } catch {
            guard request == homeRequestGeneration, !isBusy, !Task.isCancelled else { return }
            errorMessage = message(for: error)
        }
    }
    func shortcutSnapshot() async throws -> LedgerSnapshot {
        await start()
        return try readyShortcutSnapshot()
    }

    private func readyShortcutSnapshot() throws -> LedgerSnapshot {
        guard isLoaded else { throw ShortcutExecutionError.unavailable }
        guard !isBusy else { throw ShortcutExecutionError.busy }
        return LedgerSnapshot(book: book, draft: draft, settings: settings, draftRevision: revision, home: home)
    }

    func prepareShortcut(_ request: ShortcutEntryRequest) async throws {
        await start()
        let current = try readyShortcutSnapshot()
        guard pendingShortcut == nil else { throw ShortcutExecutionError.pendingReview }
        _ = try request.makeDraft(in: current.book, settings: current.settings)
        pendingShortcut = request
    }

    /// Called only by the shortcut review sheet, after any existing editor has closed.
    func installShortcutDraft(_ request: ShortcutEntryRequest, replacingExisting: Bool) async throws {
        await start()
        let current = try readyShortcutSnapshot()
        guard pendingShortcut == request else { throw ShortcutExecutionError.expiredReview }
        guard current.draft == nil || replacingExisting else { throw ShortcutExecutionError.existingDraft }
        guard let repository else { throw ShortcutExecutionError.unavailable }
        let value = try request.makeDraft(in: current.book, settings: current.settings)
        isBusy = true
        defer { isBusy = false }
        revision += 1
        let sequence = revision
        // Persist first: failure leaves the user's previous draft in memory and on disk.
        try await repository.saveDraft(value, revision: sequence)
        guard revision == sequence else { throw ShortcutExecutionError.draftChanged }
        draft = value
        draftError = nil
    }

    func recordShortcut(_ request: ShortcutEntryRequest) async throws -> LedgerEntry {
        await start()
        let current = try readyShortcutSnapshot()
        guard let repository else { throw ShortcutExecutionError.unavailable }
        isBusy = true
        homeRequestGeneration += 1
        defer { isBusy = false }
        do {
            let value = try request.makeDraft(in: current.book, settings: current.settings)
            let entry = try value.entry(in: current.book)
            let saved = try await repository.saveShortcutEntry(entry)
            apply(saved)
            errorMessage = nil
            // A retry may return an already committed entry with its original creation date.
            return saved.book.entries.first(where: { $0.operationID == entry.operationID }) ?? entry
        } catch let error as ShortcutEntryError {
            throw error
        } catch {
            throw ShortcutExecutionError.failed(message(for: error))
        }
    }
    @discardableResult
    func updateDraft(_ value: EntryDraft?) -> Task<Void, Never> {
        revision += 1
        let currentRevision = revision
        draft = value
        return Task {
            guard let repository else { return }
            do {
                try await repository.saveDraft(value, revision: currentRevision)
                if currentRevision == revision { draftError = nil }
            } catch {
                if currentRevision == revision { draftError = "草稿尚未保存：" + message(for: error) }
            }
        }
    }
    func addAccount(_ account: Account, makeDefault: Bool) async -> Bool {
        await mutate { repo in try await repo.addAccount(account, makeDefault: makeDefault) }
    }
    func save(_ entry: LedgerEntry, expectedVersion: Int? = nil, nextDraft: EntryDraft? = nil) async -> Bool {
        let interval = LedgerPerformance.begin("Entry.SaveToModel")
        var outcome = LedgerPerformance.Outcome.notApplied
        defer { LedgerPerformance.end(interval, outcome: outcome) }
        revision += 1
        let sequence = revision
        let applied = await mutate { repo in
            try await repo.saveEntry(entry, expectedVersion: expectedVersion, nextDraft: nextDraft, revision: sequence)
        }
        if applied { outcome = .completed }
        return applied
    }
    func delete(_ entryID: UUID) async -> Bool {
        await mutate { repo in try await repo.deleteEntry(entryID) }
    }
    func adjust(_ accountID: UUID, target: Money, note: String, operationID: UUID) async -> Bool {
        await mutate { repo in try await repo.adjustAccount(accountID, target: target, note: note, operationID: operationID) }
    }
    func setDefault(_ id: UUID?) async -> Bool {
        await mutate { repo in try await repo.setDefaultAccount(id) }
    }
    func saveAccount(_ value: Account) async -> Bool {
        await mutate { repo in try await repo.saveAccount(value) }
    }
    func saveCategory(_ value: LedgerCore.Category) async -> Bool {
        await mutate { repo in try await repo.saveCategory(value) }
    }
    func saveSubject(_ value: LedgerCore.Subject) async -> Bool {
        await mutate { repo in try await repo.saveSubject(value) }
    }
    func setDefaultSubject(_ id: UUID) async -> Bool {
        await mutate { repo in try await repo.setDefaultSubject(id) }
    }
    func exportBackup() async throws -> Data {
        guard let repository, !isBusy else { throw LedgerError.unsupportedOperation }
        isBusy = true
        defer { isBusy = false }
        // Assign a revision now so a previously scheduled autosave cannot win later.
        revision += 1
        try await repository.saveDraft(draft, revision: revision)
        return try await repository.exportBackup()
    }
    func prepareRestore(from url: URL) async throws -> BackupRestorePreview {
        guard let repository, !isBusy else { throw LedgerError.unsupportedOperation }
        isBusy = true
        defer { isBusy = false }
        return try await repository.prepareRestore(from: url)
    }
    func restore(_ preview: BackupRestorePreview) async -> Bool {
        revision += 1
        let sequence = revision
        let currentDraft = draft
        return await mutate { repo in
            try await repo.saveDraft(currentDraft, revision: sequence)
            return try await repo.restore(previewID: preview.id, revision: sequence)
        }
    }
    func safetyBackups() async throws -> [SafetyBackup] {
        guard let repository else { return [] }
        return try await repository.safetyBackups()
    }
    func balance(_ account: Account) -> Money? { try? LedgerEngine.balance(of: account.id, in: book) }
    func displayTitle(_ entry: LedgerEntry) -> String {
        if !entry.title.isEmpty { return entry.title }
        if entry.kind == .transfer { return "转账" }
        return book.categories.first(where: { $0.id == entry.categoryID })?.name ?? "未找到分类"
    }
    func accountName(_ id: UUID?) -> String { book.accounts.first(where: { $0.id == id })?.name ?? "未选择账户" }
    func subjectName(_ id: UUID) -> String { book.subjects.first(where: { $0.id == id })?.name ?? "未找到主体" }
    func message(for error: any Error) -> String {
        if let error = error as? AmountExpressionError {
            switch error {
            case .invalidSyntax: return "算式尚未完整，请检查数字、运算符和括号。"
            case .divisionByZero: return "除数不能为零，请修改算式。"
            case .overflow: return "算式或结果超出可处理范围，请拆分计算。"
            case .tooComplex: return "算式过长或括号过多，请简化后再计算。"
            case .excessPrecision: return "直接输入金额时最多两位小数。"
            }
        }
        if let error = error as? BackupArchive.ArchiveError {
            switch error {
            case .unsupportedFeature: return "请选择 App 导出的原始 ZIP 备份；当前不支持重新压缩或加密的归档。"
            case .limitExceeded: return "备份超过当前支持的大小或文件数量。"
            default: return "备份文件不完整或校验失败，当前账本未改动。"
            }
        }
        if let error = error as? BackupError {
            switch error {
            case .unsupportedFormat: return "当前版本不支持这个备份格式，请使用与备份兼容的 App 版本。"
            case .invalidArchive: return "备份文件不完整或校验失败，当前账本未改动。"
            case .invalidSnapshot: return "账本存在不一致的数据，无法完成备份操作。"
            }
        }
        if let error = error as? CatalogError {
            switch error {
            case .immutableAccountFields: return "账户类型、币种和期初不能在此修改；请使用余额更正。"
            case .immutableCategoryStructure: return "分类层级和方向不能直接改变。"
            case .invalidCategoryParent: return "请选择同方向且已启用的一级分类。"
            case .lastActiveSubject: return "至少保留一个启用的主体。"
            }
        }
        if let error = error as? RepositoryError {
            switch error {
            case .defaultSubjectMustRemainActive: return "请先将其他主体设为默认，再停用此主体。"
            case .restorePreviewExpired: return "恢复预览已经失效，请重新选择备份。"
            case .backupTooLarge: return "备份超过当前支持的大小。"
            case .safetyBackupFailed: return "恢复前安全备份未能保存，当前账本保持不变。"
            }
        }
        guard let error = error as? LedgerError else { return "保存或读取失败，请重试。原账本不会被替换为空账本。" }
        switch error {
        case .invalidAmount: return "请输入有效金额，最多两位小数。"
        case .overflow: return "金额超出可处理范围。"
        case .currencyMismatch: return "币种不一致。跨币种交易尚需补充实际结算流程。"
        case .accountNotFound, .inactiveAccount: return "请选择有效的付款／收款账户。"
        case .sameAccountTransfer: return "转出与转入账户不能相同。"
        case .invalidCategory: return "请选择当前类型对应的二级分类。"
        case .invalidSubject: return "请选择有效主体。"
        case .invalidAccount: return "请检查账户名称、类型和期初金额。"
        case .entryNotFound: return "这条记录已经不存在，请返回刷新。"
        case .staleVersion: return "记录已被修改，请重新打开后编辑。"
        case .duplicateID, .operationConflict: return "这次操作已经处理或内容发生冲突，请返回查看结果。"
        case .unsupportedOperation: return "当前操作尚不支持。"
        }
    }
    private func apply(_ value: LedgerSnapshot) {
        homeRequestGeneration += 1
        historyRevision += 1
        book = value.book
        home = value.home
        settings = value.settings
        // Autosave can run while a mutation awaits the repository actor.
        if value.draftRevision >= revision {
            draft = value.draft
            revision = value.draftRevision
            draftError = nil
        }
    }
    private func mutate(_ work: (LedgerRepository) async throws -> LedgerSnapshot) async -> Bool {
        guard let repository, !isBusy else { return false }
        isBusy = true
        homeRequestGeneration += 1
        defer { isBusy = false }
        do { apply(try await work(repository)); errorMessage = nil; return true }
        catch { errorMessage = message(for: error); return false }
    }
}
