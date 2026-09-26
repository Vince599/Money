import Foundation

struct BackupRestorePreview: Identifiable, Sendable {
    let id: UUID
    let accountCount: Int
    let entryCount: Int
    let adjustmentCount: Int
    let categoryCount: Int
    let subjectCount: Int
    let hasDraft: Bool
}

struct SafetyBackup: Identifiable, Sendable {
    var id: URL { url }
    let url: URL
    let createdAt: Date
}

enum RepositoryError: Error, Equatable {
    case defaultSubjectMustRemainActive
    case restorePreviewExpired
    case backupTooLarge
    case safetyBackupFailed
}
