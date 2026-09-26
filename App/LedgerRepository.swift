import Foundation
import LedgerCore
import LedgerStore

struct LedgerSnapshot: Sendable {
    var book: LedgerBook
    var draft: EntryDraft?
    var settings: LedgerSettings
    var draftRevision: UInt64
}

/// All disk work runs outside the main actor; mutation decisions use the latest persisted book.
actor LedgerRepository {
    private let store: SQLiteLedgerStore
    private var draftRevision: UInt64 = 0
    private let safetyDirectory: URL
    private var pendingRestore: (id: UUID, value: LedgerBackupSnapshot)?
    init(path: String) throws {
        store = try SQLiteLedgerStore(path: path)
        safetyDirectory = URL(fileURLWithPath: path).deletingLastPathComponent()
            .appendingPathComponent("RecoveryBackups", isDirectory: true)
    }
    func snapshot() throws -> LedgerSnapshot {
        LedgerSnapshot(book: try store.loadBook(), draft: try store.loadDraft(), settings: try store.loadSettings(),
                       draftRevision: draftRevision)
    }
    func saveDraft(_ draft: EntryDraft?, revision: UInt64) throws {
        guard revision >= draftRevision else { return }
        try store.saveDraft(draft)
        draftRevision = revision
    }
    func addAccount(_ account: Account, makeDefault: Bool) throws -> LedgerSnapshot {
        var current = try snapshot()
        guard !current.book.accounts.contains(where: { $0.id == account.id }) else { throw LedgerError.duplicateID }
        current.book.accounts.append(account)
        if makeDefault { current.settings.defaultAccountID = account.id }
        try store.commit(current.book, draft: current.draft, settings: current.settings)
        return try snapshot()
    }
    func saveEntry(_ entry: LedgerEntry, expectedVersion: Int?, nextDraft: EntryDraft?, revision: UInt64) throws -> LedgerSnapshot {
        let current = try snapshot()
        let updated: LedgerBook
        if let expectedVersion {
            updated = try LedgerEngine.replace(entry, expectedVersion: expectedVersion, in: current.book)
            // Editing an existing event must not erase an unrelated new-entry draft.
            try store.commit(updated, draft: current.draft)
        } else {
            updated = try LedgerEngine.record(entry, in: current.book)
            // A delayed commit may finish the event, but cannot erase a newer draft.
            try store.commit(updated, draft: revision >= draftRevision ? nextDraft : current.draft)
            draftRevision = max(draftRevision, revision)
        }
        return try snapshot()
    }
    func deleteEntry(_ id: UUID) throws -> LedgerSnapshot {
        let current = try snapshot()
        let updated = try LedgerEngine.delete(entryID: id, in: current.book)
        try store.commit(updated, draft: current.draft)
        return try snapshot()
    }
    func adjustAccount(_ id: UUID, target: Money, note: String, operationID: UUID) throws -> LedgerSnapshot {
        let current = try snapshot()
        let occurredAt = current.book.adjustments.first(where: { $0.operationID == operationID })?.occurredAt ?? Date()
        let updated = try LedgerEngine.adjustBalance(accountID: id, to: target, operationID: operationID,
                                                      at: occurredAt, note: note, in: current.book)
        try store.commit(updated, draft: current.draft)
        return try snapshot()
    }
    func setDefaultAccount(_ id: UUID?) throws -> LedgerSnapshot {
        var current = try snapshot()
        if let id {
            guard current.book.accounts.contains(where: { $0.id == id && $0.isActive }) else { throw LedgerError.accountNotFound }
        }
        current.settings.defaultAccountID = id
        try store.commit(current.book, draft: current.draft, settings: current.settings)
        return try snapshot()
    }

    func saveAccount(_ account: Account) throws -> LedgerSnapshot {
        var current = try snapshot()
        current.book = try CatalogEditor.saveAccount(account, in: current.book)
        if !account.isActive, current.settings.defaultAccountID == account.id {
            current.settings.defaultAccountID = nil
        }
        try store.commit(current.book, draft: current.draft, settings: current.settings)
        return try snapshot()
    }

    func saveCategory(_ category: LedgerCore.Category) throws -> LedgerSnapshot {
        var current = try snapshot()
        current.book = try CatalogEditor.saveCategory(category, in: current.book)
        try store.commit(current.book, draft: current.draft)
        return try snapshot()
    }

    func saveSubject(_ subject: LedgerCore.Subject) throws -> LedgerSnapshot {
        var current = try snapshot()
        guard subject.isActive || current.settings.defaultSubjectID != subject.id else {
            throw RepositoryError.defaultSubjectMustRemainActive
        }
        current.book = try CatalogEditor.saveSubject(subject, in: current.book)
        try store.commit(current.book, draft: current.draft)
        return try snapshot()
    }

    func setDefaultSubject(_ id: UUID) throws -> LedgerSnapshot {
        var current = try snapshot()
        guard current.book.subjects.contains(where: { $0.id == id && $0.isActive }) else {
            throw LedgerError.invalidSubject
        }
        current.settings.defaultSubjectID = id
        try store.commit(current.book, draft: current.draft, settings: current.settings)
        return try snapshot()
    }

    func exportBackup() throws -> Data {
        try archive(snapshot())
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
                                    hasDraft: value.draft != nil)
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
        let current = try snapshot()
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
        return LedgerSnapshot(book: value.book, draft: value.draft, settings: value.settings,
                              draftRevision: draftRevision)
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
