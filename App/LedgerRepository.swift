import Foundation
import LedgerCore
import LedgerStore

struct LedgerSnapshot: Sendable {
    var book: LedgerBook
    var draft: EntryDraft?
    var settings: LedgerSettings
    var draftRevision: UInt64
    // Derived presentation data, never serialized into the backup or database.
    var home: HomeOverview? = nil
    var recoveries: [UUID: RecoverySummary] = [:]
}

/// All disk work runs outside the main actor; mutation decisions use the latest persisted book.
actor LedgerRepository {
    private let store: SQLiteLedgerStore
    private var draftRevision: UInt64 = 0
    private let safetyDirectory: URL
    private var pendingRestore: (id: UUID, value: LedgerBackupSnapshot)?
    init(path: String) throws {
        store = try LedgerPerformance.measure("Store.Open") { try SQLiteLedgerStore(path: path) }
        safetyDirectory = URL(fileURLWithPath: path).deletingLastPathComponent()
            .appendingPathComponent("RecoveryBackups", isDirectory: true)
    }

    private init(store: SQLiteLedgerStore, path: String) {
        self.store = store
        safetyDirectory = URL(fileURLWithPath: path).deletingLastPathComponent()
            .appendingPathComponent("RecoveryBackups", isDirectory: true)
    }

    /// The caller receives the already validated opening snapshot, without a
    /// second full read. No snapshot is retained as a cache by the repository.
    static func open(path: String) throws -> (repository: LedgerRepository, snapshot: LedgerSnapshot) {
        let opened = try LedgerPerformance.measure("Store.Open") { try SQLiteLedgerStore.open(path: path) }
        return (LedgerRepository(store: opened.store, path: path),
                withHome(LedgerSnapshot(book: opened.snapshot.book, draft: opened.snapshot.draft,
                                       settings: opened.snapshot.settings, draftRevision: 0)))
    }

    func snapshot(at date: Date? = nil) throws -> LedgerSnapshot {
        try LedgerPerformance.measure("Repository.Snapshot") {
            Self.withHome(try readSnapshot(), at: date)
        }
    }

    func historyPage(matching filter: EntryFilter, after cursor: EntryPageCursor? = nil,
                     limit: Int = 50) throws -> HistoryPage {
        try Task.checkCancellation()
        let page = try LedgerPerformance.measure("History.SQLPage") {
            try store.entryPage(matching: filter, after: cursor, limit: limit)
        }
        return LedgerPerformance.measure("History.PageGrouping") { HistoryPage.make(page) }
    }

    // Internal reads do not build unused home data before another mutation.
    private func readSnapshot() throws -> LedgerSnapshot {
        let value = try store.loadSnapshot()
        return LedgerSnapshot(book: value.book, draft: value.draft, settings: value.settings,
                              draftRevision: draftRevision)
    }

    private nonisolated static func withHome(_ value: LedgerSnapshot, at date: Date? = nil) -> LedgerSnapshot {
        var result = value
        // Capture the month after entering the repository, not before actor queuing.
        // Derivation cannot throw after an already successful disk commit.
        result.home = HomeOverview.make(book: value.book, at: date ?? Date())
        result.recoveries = (try? RecoveryRules.summaries(in: value.book)) ?? [:]
        return result
    }
    func saveDraft(_ draft: EntryDraft?, revision: UInt64) throws {
        guard revision >= draftRevision else { return }
        try store.saveDraft(draft)
        draftRevision = revision
    }
    func addAccount(_ account: Account, makeDefault: Bool) throws -> LedgerSnapshot {
        var current = try readSnapshot()
        guard !current.book.accounts.contains(where: { $0.id == account.id }) else { throw LedgerError.duplicateID }
        current.book.accounts.append(account)
        if makeDefault { current.settings.defaultAccountID = account.id }
        try store.commit(current.book, draft: current.draft, settings: current.settings)
        return try snapshot()
    }
    func saveEntry(_ entry: LedgerEntry, expectedVersion: Int?, nextDraft: EntryDraft?, revision: UInt64) throws -> LedgerSnapshot {
        let interval = LedgerPerformance.begin("Repository.SaveEntry")
        var outcome = LedgerPerformance.Outcome.threw
        defer { LedgerPerformance.end(interval, outcome: outcome) }
        // Read the preserved draft inside the same database transaction, never
        // copy an earlier snapshot over newer persisted input.
        let draftUpdate: EntryDraftUpdate = expectedVersion == nil && revision >= draftRevision
            ? .replace(nextDraft) : .preserve
        let saved = try LedgerPerformance.measure("Entry.Commit") {
            try store.saveEntry(entry, expectedVersion: expectedVersion, draftUpdate: draftUpdate)
        }
        if expectedVersion == nil {
            draftRevision = max(draftRevision, revision)
        }
        let result = Self.withHome(LedgerSnapshot(book: saved.book, draft: saved.draft, settings: saved.settings,
                                                draftRevision: draftRevision))
        outcome = .completed
        return result
    }
    /// Shortcuts create independent entries without consuming the manual editor's draft.
    func saveShortcutEntry(_ entry: LedgerEntry) throws -> LedgerSnapshot {
        let interval = LedgerPerformance.begin("Repository.SaveShortcutEntry")
        var outcome = LedgerPerformance.Outcome.threw
        defer { LedgerPerformance.end(interval, outcome: outcome) }
        let saved = try LedgerPerformance.measure("Entry.Commit") {
            try store.saveEntry(entry, expectedVersion: nil, draftUpdate: .preserve)
        }
        // The editor owns its revision fence; a shortcut must never advance it.
        let result = Self.withHome(LedgerSnapshot(book: saved.book, draft: saved.draft, settings: saved.settings,
                                                draftRevision: draftRevision))
        outcome = .completed
        return result
    }
    func deleteEntry(_ id: UUID) throws -> LedgerSnapshot {
        let current = try readSnapshot()
        let updated = try LedgerEngine.delete(entryID: id, in: current.book)
        try store.commit(updated, draft: current.draft)
        return try snapshot()
    }
    func deleteEntries(_ plan: EntryDeletionPlan) throws -> LedgerSnapshot {
        let saved = try store.deleteEntries(plan)
        return Self.withHome(LedgerSnapshot(book: saved.book, draft: saved.draft, settings: saved.settings,
                                            draftRevision: draftRevision))
    }
    func deletionPreview(_ id: UUID) throws -> (snapshot: LedgerSnapshot, plan: EntryDeletionPlan) {
        let value = Self.withHome(try readSnapshot())
        return (value, try LedgerEngine.deletionPlan(entryID: id, includingRecoveries: true, in: value.book))
    }
    func adjustAccount(_ id: UUID, target: Money, note: String, operationID: UUID) throws -> LedgerSnapshot {
        let current = try readSnapshot()
        let occurredAt = current.book.adjustments.first(where: { $0.operationID == operationID })?.occurredAt ?? Date()
        let updated = try LedgerEngine.adjustBalance(accountID: id, to: target, operationID: operationID,
                                                      at: occurredAt, note: note, in: current.book)
        try store.commit(updated, draft: current.draft)
        return try snapshot()
    }
    func setDefaultAccount(_ id: UUID?) throws -> LedgerSnapshot {
        var current = try readSnapshot()
        if let id {
            guard current.book.accounts.contains(where: { $0.id == id && $0.isActive }) else { throw LedgerError.accountNotFound }
        }
        current.settings.defaultAccountID = id
        try store.commit(current.book, draft: current.draft, settings: current.settings)
        return try snapshot()
    }

    func saveAccount(_ account: Account) throws -> LedgerSnapshot {
        var current = try readSnapshot()
        current.book = try CatalogEditor.saveAccount(account, in: current.book)
        if !account.isActive, current.settings.defaultAccountID == account.id {
            current.settings.defaultAccountID = nil
        }
        try store.commit(current.book, draft: current.draft, settings: current.settings)
        return try snapshot()
    }

    func saveCategory(_ category: LedgerCore.Category) throws -> LedgerSnapshot {
        var current = try readSnapshot()
        current.book = try CatalogEditor.saveCategory(category, in: current.book)
        try store.commit(current.book, draft: current.draft)
        return try snapshot()
    }

    func saveTag(_ tag: EntryTag) throws -> LedgerSnapshot {
        var current = try readSnapshot()
        current.book = try CatalogEditor.saveTag(tag, in: current.book)
        try store.commit(current.book, draft: current.draft)
        return try snapshot()
    }

    func saveProject(_ project: EntryProject) throws -> LedgerSnapshot {
        var current = try readSnapshot()
        current.book = try CatalogEditor.saveProject(project, in: current.book)
        try store.commit(current.book, draft: current.draft)
        return try snapshot()
    }

    func saveSubject(_ subject: LedgerCore.Subject) throws -> LedgerSnapshot {
        var current = try readSnapshot()
        guard subject.isActive || current.settings.defaultSubjectID != subject.id else {
            throw RepositoryError.defaultSubjectMustRemainActive
        }
        current.book = try CatalogEditor.saveSubject(subject, in: current.book)
        try store.commit(current.book, draft: current.draft)
        return try snapshot()
    }

    func setDefaultSubject(_ id: UUID) throws -> LedgerSnapshot {
        var current = try readSnapshot()
        guard current.book.subjects.contains(where: { $0.id == id && $0.isActive }) else {
            throw LedgerError.invalidSubject
        }
        current.settings.defaultSubjectID = id
        try store.commit(current.book, draft: current.draft, settings: current.settings)
        return try snapshot()
    }

    func importCSV(from url: URL, namespace: String) throws -> LedgerSnapshot {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?, result: Result<Data, any Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            result = Result {
                let handle = try FileHandle(forReadingFrom: readableURL)
                defer { try? handle.close() }
                var data = Data()
                while let chunk = try handle.read(upToCount: min(1_048_576, ImportCSV.maximumBytes + 1 - data.count)), !chunk.isEmpty {
                    data.append(chunk)
                    guard data.count <= ImportCSV.maximumBytes else { throw ImportError.invalidFile("CSV 超过 16 MiB。") }
                }
                return data
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ImportError.invalidState }
        let current = try readSnapshot()
        let batch = try ImportCSV.parse(result.get(), name: url.lastPathComponent, namespace: namespace,
                                        subjectID: current.settings.defaultSubjectID)
        return try saveImport(batch)
    }

    func saveImport(_ batch: ImportBatch, expectedVersion: Int? = nil) throws -> LedgerSnapshot {
        let value = try store.saveImport(batch, expectedVersion: expectedVersion)
        return Self.withHome(LedgerSnapshot(book: value.book, draft: value.draft, settings: value.settings, draftRevision: draftRevision))
    }

    func saveImportRule(_ rule: ImportRule, expectedVersion: Int? = nil) throws -> LedgerSnapshot {
        let value = try store.saveImportRule(rule, expectedVersion: expectedVersion)
        return Self.withHome(LedgerSnapshot(book: value.book, draft: value.draft, settings: value.settings, draftRevision: draftRevision))
    }
    func reviewImportRules(batchID: UUID, rowID: UUID) throws -> ImportRuleReview {
        try ImportRuleEngine.review(batchID: batchID, rowID: rowID, in: readSnapshot().book)
    }
    func applyImportRule(_ plan: ImportRuleApplyPlan) throws -> LedgerSnapshot {
        let value = try store.applyImportRule(plan)
        return Self.withHome(LedgerSnapshot(book: value.book, draft: value.draft, settings: value.settings, draftRevision: draftRevision))
    }
    func reviewImportUndo(batchID: UUID) throws -> ImportUndoReview {
        try ImportEngine.reviewUndo(batchID: batchID, in: readSnapshot().book)
    }
    func undoImport(_ plan: ImportUndoPlan) throws -> LedgerSnapshot {
        let value = try store.undoImport(plan)
        return Self.withHome(LedgerSnapshot(book: value.book, draft: value.draft, settings: value.settings, draftRevision: draftRevision))
    }
    func prepareImportLabels(batchID: UUID, rowIDs: Set<UUID>, tags: ImportTagChange, project: ImportProjectChange) throws -> ImportLabelsPlan {
        try ImportEngine.prepareLabels(batchID: batchID, rowIDs: rowIDs, tags: tags, project: project, in: readSnapshot().book)
    }
    func commitImportLabels(_ plan: ImportLabelsPlan) throws -> LedgerSnapshot {
        let value = try store.commitImportLabels(plan)
        return Self.withHome(LedgerSnapshot(book: value.book, draft: value.draft, settings: value.settings, draftRevision: draftRevision))
    }

    func importReviews(batchID: UUID, rowIDs: Set<UUID>) throws -> [UUID: ImportRowReview] {
        let value = try readSnapshot()
        guard let batch = value.book.importBatches.first(where: { $0.id == batchID }) else { throw ImportError.unavailableRow }
        try Task.checkCancellation()
        let result = ImportEngine.reviews(batch: batch, rowIDs: rowIDs, in: value.book)
        try Task.checkCancellation()
        return result
    }

    func reviewImportRow(_ row: ImportRow, batch: ImportBatch) throws -> ImportRowInspection {
        let current = try readSnapshot()
        guard current.book.importBatches.first(where: { $0.id == batch.id })?.version == batch.version else { throw ImportError.stalePreview }
        let now = Date()
        let review = ImportEngine.review(row, batch: batch, in: current.book, now: now)
        let entry = try? ImportEngine.candidate(row, batch: batch, in: current.book, now: now)
        return ImportRowInspection(review: review, similar: entry.map { ImportEngine.similarEntries(to: $0, batch: batch, in: current.book, now: now) } ?? [])
    }

    func prepareImport(batchID: UUID, importIDs: Set<UUID>, skipIDs: Set<UUID>) throws -> ImportCommitPreview {
        let current = try readSnapshot()
        let now = Date()
        let plan = try ImportEngine.prepare(batchID: batchID, importIDs: importIDs, skipIDs: skipIDs, in: current.book, now: now)
        let after = try ImportEngine.commit(plan, in: current.book, now: now)
        let entries = after.entries.filter { importIDs.contains($0.id) }
        let affected = Set(entries.flatMap { [$0.accountID, $0.destinationAccountID].compactMap { $0 } })
        let effects = try after.accounts.filter { affected.contains($0.id) }.map { account in
            ImportAccountEffect(id: account.id, name: account.name, isNew: plan.newAccountIDs.contains(account.id),
                                before: current.book.accounts.contains { $0.id == account.id } ? try LedgerEngine.balance(of: account.id, in: current.book) : Money(minorUnits: account.openingMinor, currency: account.currency),
                                after: try LedgerEngine.balance(of: account.id, in: after))
        }
        return ImportCommitPreview(id: UUID(), plan: plan, effects: effects)
    }

    func commitImport(_ plan: ImportPlan) throws -> LedgerSnapshot {
        let value = try store.commitImport(plan)
        return Self.withHome(LedgerSnapshot(book: value.book, draft: value.draft, settings: value.settings, draftRevision: draftRevision))
    }

    func exportBackup() throws -> Data {
        try archive(readSnapshot())
    }

    private func archive(_ value: LedgerSnapshot) throws -> Data {
        try BackupArchive.encode(BackupCodec.encode(LedgerBackupSnapshot(
            book: value.book, draft: value.draft, settings: value.settings)))
    }

    func prepareRestore(_ data: Data) throws -> BackupRestorePreview {
        // An invalid new selection must not leave a previous selection restorable.
        pendingRestore = nil
        let value = try BackupCodec.decode(BackupArchive.decode(data))
        let id = UUID()
        pendingRestore = (id, value)
        return BackupRestorePreview(id: id, accountCount: value.book.accounts.count,
                                    entryCount: value.book.entries.count, adjustmentCount: value.book.adjustments.count,
                                    categoryCount: value.book.categories.count, subjectCount: value.book.subjects.count,
                                    tagCount: value.book.tags.count, projectCount: value.book.projects.count, importBatchCount: value.book.importBatches.count,
                                    importRuleCount: value.book.importRules.count, hasDraft: value.draft != nil)
    }

    func prepareRestore(from url: URL) throws -> BackupRestorePreview {
        pendingRestore = nil
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        // Coordinate File Provider / iCloud reads while the temporary access is valid.
        var coordinationError: NSError?
        var readResult: Result<Data, any Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            readResult = Result { try Self.readBackupFile(readableURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let readResult else { throw CocoaError(.fileReadUnknown) }
        return try prepareRestore(readResult.get())
    }

    func restore(previewID: UUID, revision: UInt64) throws -> LedgerSnapshot {
        guard let pendingRestore, pendingRestore.id == previewID else { throw RepositoryError.restorePreviewExpired }
        // The snapshot is already fully decoded and validated. Preserve the latest
        // current state, then replace every authoritative table in one SQLite transaction.
        let current = try readSnapshot()
        let safetyData = try archive(current)
        let safetyURL = safetyDirectory.appendingPathComponent("before-restore-\(UUID().uuidString.lowercased()).zip")
        do {
            try FileManager.default.createDirectory(at: safetyDirectory, withIntermediateDirectories: true)
            try safetyData.write(to: safetyURL, options: .atomic)
            let handle = try FileHandle(forWritingTo: safetyURL)
            defer { try? handle.close() }
            try handle.synchronize()
            guard try Self.readBackupFile(safetyURL) == safetyData else { throw RepositoryError.safetyBackupFailed }
        } catch { throw RepositoryError.safetyBackupFailed }
        let value = pendingRestore.value
        try store.commit(value.book, draft: value.draft, settings: value.settings)
        // In-flight autosaves from the old book must not enter the restored book.
        draftRevision = max(revision, draftRevision)
        self.pendingRestore = nil
        // No fallible read after the commit: a read failure must not be reported
        // as a failed restore while the disk already contains the restored book.
        return Self.withHome(LedgerSnapshot(book: value.book, draft: value.draft, settings: value.settings,
                                          draftRevision: draftRevision))
    }

    func safetyBackups() throws -> [SafetyBackup] {
        guard FileManager.default.fileExists(atPath: safetyDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: safetyDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey]).compactMap { url in
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey])
                guard url.pathExtension == "zip", values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
                return SafetyBackup(url: url, createdAt: values.creationDate ?? .distantPast)
            }.sorted { $0.createdAt > $1.createdAt }
    }

    private nonisolated static func readBackupFile(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // ZIP adds small headers to at most 64 MiB of CSV payload.
        let limit = 65 * 1_024 * 1_024
        var data = Data()
        while let part = try handle.read(upToCount: min(1_024 * 1_024, limit + 1 - data.count)), !part.isEmpty {
            data.append(part)
            guard data.count <= limit else { throw RepositoryError.backupTooLarge }
        }
        return data
    }
}
