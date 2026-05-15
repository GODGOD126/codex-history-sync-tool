import Foundation

public struct ProviderCount: Equatable, Identifiable, Sendable {
    public var id: String { provider }
    public let provider: String
    public let count: Int
}

public struct ModelCount: Equatable, Identifiable, Sendable {
    public var id: String { model }
    public let model: String
    public let count: Int
}

public struct ProviderModelCount: Equatable, Identifiable, Sendable {
    public var id: String { "\(provider)\u{1f}\(model)" }
    public let provider: String
    public let model: String
    public let count: Int
}

public struct CwdCount: Equatable, Identifiable, Sendable {
    public var id: String { cwd }
    public let cwd: String
    public let count: Int
}

public struct BackupInfo: Equatable, Identifiable, Sendable {
    public var id: URL { path }
    public let name: String
    public let path: URL
    public let modifiedAt: Date
}

public struct CodexStatus: Equatable, Sendable {
    public let codexHome: URL
    public let configPath: URL
    public let databasePath: URL
    public let sessionIndexPath: URL
    public let sessionsDirectory: URL
    public let backupDirectory: URL
    public let currentProvider: String
    public let currentModel: String?
    public let totalThreads: Int
    public let movableThreads: Int
    public let providerMovableThreads: Int
    public let modelMovableThreads: Int?
    public let movableDatabaseThreads: Int
    public let movableSessionThreads: Int
    public let missingSessionIndexEntries: Int
    public let indexedThreads: Int
    public let sessionFileCount: Int
    public let providerCounts: [ProviderCount]
    public let modelCounts: [ModelCount]
    public let providerModelCounts: [ProviderModelCount]
    public let cwdCounts: [CwdCount]
    public let sessionProviderCounts: [ProviderCount]
    public let sessionModelCounts: [ModelCount]
    public let backups: [BackupInfo]
}

public struct CheckpointInfo: Equatable, Sendable {
    public let mode: String
    public let busy: Int
    public let logFrames: Int
    public let checkpointedFrames: Int
}

public struct TimingInfo: Equatable, Sendable {
    public let backupMilliseconds: Int
    public let databaseMilliseconds: Int
    public let sessionMilliseconds: Int
    public let indexMilliseconds: Int
    public let totalMilliseconds: Int
}

public struct SyncResult: Equatable, Sendable {
    public let currentProvider: String
    public let currentModel: String?
    public let syncedFields: [String]
    public let updatedRows: Int
    public let updatedSessionFiles: Int
    public let providerMovableThreads: Int
    public let modelMovableThreads: Int?
    public let backupPath: URL
    public let beforeCounts: [ProviderCount]
    public let afterCounts: [ProviderCount]
    public let beforeModelCounts: [ModelCount]
    public let afterModelCounts: [ModelCount]
    public let sessionBeforeCounts: [ProviderCount]
    public let sessionAfterCounts: [ProviderCount]
    public let sessionBeforeModelCounts: [ModelCount]
    public let sessionAfterModelCounts: [ModelCount]
    public let checkpoint: CheckpointInfo
    public let lockWaitMilliseconds: Int
    public let lockAttempts: Int
    public let rewrittenIndexEntries: Int
    public let missingSessionIndexEntriesBefore: Int
    public let preservedIndexOnlyEntries: Int
    public let timing: TimingInfo
    public let status: CodexStatus
}

public struct MetadataRestoreInfo: Equatable, Sendable {
    public let sessionIndexRestored: Bool
    public let sessionFilesRestored: Int
    public let durationMilliseconds: Int
}

public struct RestoreTimingInfo: Equatable, Sendable {
    public let backupMilliseconds: Int
    public let databaseMilliseconds: Int
    public let metadataMilliseconds: Int
    public let indexMilliseconds: Int
    public let totalMilliseconds: Int
}

public struct RestoreResult: Equatable, Sendable {
    public let restoredFrom: URL
    public let safetyBackup: URL
    public let metadataRestore: MetadataRestoreInfo
    public let checkpoint: CheckpointInfo
    public let lockWaitMilliseconds: Int
    public let lockAttempts: Int
    public let rewrittenIndexEntries: Int
    public let timing: RestoreTimingInfo
    public let status: CodexStatus
}

public enum CodexHistorySyncError: LocalizedError, Equatable, Sendable {
    case missingConfig(URL)
    case missingDatabase(URL)
    case configMissingProvider(URL)
    case sqlite(String)
    case fileBusy(URL)
    case noBackups
    case backupMissing(URL)
    case invalidJSON(URL)
    case databaseBusy(String)

    public var errorDescription: String? {
        switch self {
        case .missingConfig(let url):
            return "缺少配置文件: \(url.path)"
        case .missingDatabase(let url):
            return "缺少数据库文件: \(url.path)"
        case .configMissingProvider(let url):
            return "无法在 config.toml 中读取 model_provider: \(url.path)"
        case .sqlite(let message):
            return "SQLite 操作失败: \(message)"
        case .fileBusy(let url):
            return "文件正忙，无法替换: \(url.path)"
        case .noBackups:
            return "没有找到可恢复的备份。"
        case .backupMissing(let url):
            return "备份文件不存在: \(url.path)"
        case .invalidJSON(let url):
            return "JSON 解析失败: \(url.path)"
        case .databaseBusy(let message):
            return message
        }
    }
}
