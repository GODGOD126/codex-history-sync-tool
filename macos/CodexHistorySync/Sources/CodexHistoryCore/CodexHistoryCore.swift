import Foundation

private let defaultDatabaseTimeoutSeconds = 30.0
private let writeOperationTimeoutSeconds = 0.5
private let writeLockRetryLimit = 40
private let writeLockRetryDelaySeconds = 0.25
private let syncCheckpointMode = "PASSIVE"

private struct Paths {
    let codexHome: URL
    let configPath: URL
    let databasePath: URL
    let backupDirectory: URL
    let sessionIndexPath: URL
    let sessionsDirectory: URL
}

private struct SessionRecord: Equatable {
    let threadID: String
    let path: URL
    let modelProvider: String
    let model: String?
}

private struct IndexEntry: Equatable {
    let id: String
    let threadName: String
    let updatedAt: String
}

private struct DatabaseSyncSummary {
    let attempts: Int
    let lockWaitMilliseconds: Int
    let syncedFields: [String]
    let updatedRows: Int
    let beforeCounts: [ProviderCount]
    let afterCounts: [ProviderCount]
    let beforeModelCounts: [ModelCount]
    let afterModelCounts: [ModelCount]
    let checkpoint: CheckpointInfo
}

private struct SessionSyncSummary {
    let updatedSessionFiles: Int
    let beforeCounts: [ProviderCount]
    let afterCounts: [ProviderCount]
    let beforeModelCounts: [ModelCount]
    let afterModelCounts: [ModelCount]
    let durationMilliseconds: Int
}

private struct IndexSummary {
    let rewrittenEntries: Int
    let missingEntriesBefore: Int
    let preservedIndexOnlyEntries: Int
    let durationMilliseconds: Int
}

public func defaultCodexHome() -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
}

public func loadStatus(codexHome: URL = defaultCodexHome()) throws -> CodexStatus {
    let paths = resolvePaths(codexHome: codexHome)
    try ensureEnvironment(paths)
    let configText = try String(contentsOf: paths.configPath, encoding: .utf8)
    let configProvider = parseCurrentProvider(configText)
    let currentModel = parseCurrentModel(configText)
    let sessionRecords = try scanSessionRecords(paths)
    let shouldCheckIndex = FileManager.default.fileExists(atPath: paths.sessionIndexPath.path)
        || FileManager.default.fileExists(atPath: paths.sessionsDirectory.path)
    let indexEntries = try readSessionIndex(paths)

    let db = try SQLiteDatabase(path: paths.databasePath, readOnly: true, timeoutSeconds: defaultDatabaseTimeoutSeconds)
    let columns = try db.columns(in: "threads")
    let currentProvider = try configProvider ?? inferCurrentProvider(
        db,
        columns: columns,
        currentModel: currentModel,
        configURL: paths.configPath
    )
    let sessionMovableIDs = Set(sessionRecords.compactMap { record -> String? in
        let modelMatches = currentModel == nil || record.model == currentModel
        return record.modelProvider == currentProvider && modelMatches ? nil : record.threadID
    })
    let providerCounts = try queryProviderCounts(db)
    let modelCounts = columns.contains("model") ? try queryModelCounts(db) : []
    let providerModelCounts = columns.contains("model") ? try queryProviderModelCounts(db) : []
    let cwdCounts = columns.contains("cwd") ? try queryCwdCounts(db) : []
    let totalThreads = try db.scalarInt("SELECT COUNT(*) AS count FROM threads")
    let providerMovable = try countMismatched(db, column: "model_provider", expected: currentProvider) ?? 0
    let modelMovable = columns.contains("model") ? try countMismatched(db, column: "model", expected: currentModel) : nil
    let dbMovableIDs = try databaseMovableIDs(db, columns: columns, provider: currentProvider, model: currentModel)
    let dbThreadIDs = try databaseThreadIDs(db, columns: columns)
    let missingIndexIDs = shouldCheckIndex ? dbThreadIDs.subtracting(Set(indexEntries.keys)) : []
    let syncCandidateIDs = dbMovableIDs.union(sessionMovableIDs).union(missingIndexIDs)

    return CodexStatus(
        codexHome: paths.codexHome,
        configPath: paths.configPath,
        databasePath: paths.databasePath,
        sessionIndexPath: paths.sessionIndexPath,
        sessionsDirectory: paths.sessionsDirectory,
        backupDirectory: paths.backupDirectory,
        currentProvider: currentProvider,
        currentModel: currentModel,
        totalThreads: totalThreads,
        movableThreads: syncCandidateIDs.count,
        providerMovableThreads: providerMovable,
        modelMovableThreads: modelMovable,
        movableDatabaseThreads: dbMovableIDs.count,
        movableSessionThreads: sessionMovableIDs.count,
        missingSessionIndexEntries: missingIndexIDs.count,
        indexedThreads: indexEntries.count,
        sessionFileCount: sessionRecords.count,
        providerCounts: providerCounts,
        modelCounts: modelCounts,
        providerModelCounts: providerModelCounts,
        cwdCounts: cwdCounts,
        sessionProviderCounts: providerCountsFromValues(sessionRecords.map(\.modelProvider)),
        sessionModelCounts: modelCountsFromValues(sessionRecords.map { $0.model ?? "(empty)" }),
        backups: try listBackups(paths)
    )
}

@discardableResult
public func makeBackup(codexHome: URL = defaultCodexHome(), label: String) throws -> URL {
    let paths = resolvePaths(codexHome: codexHome)
    try ensureEnvironment(paths)
    try FileManager.default.createDirectory(at: paths.backupDirectory, withIntermediateDirectories: true)
    let timestamp = backupTimestamp(Date())
    let backupPath = paths.backupDirectory.appendingPathComponent("state_5.sqlite.\(label).\(timestamp).bak")
    try SQLiteDatabase.backup(from: paths.databasePath, to: backupPath)
    try snapshotMetadata(paths, backupPath: backupPath)
    return backupPath
}

public func syncToCurrentProvider(codexHome: URL = defaultCodexHome()) throws -> SyncResult {
    let totalStarted = Date()
    let paths = resolvePaths(codexHome: codexHome)
    let statusBefore = try loadStatus(codexHome: codexHome)
    let currentProvider = statusBefore.currentProvider
    let currentModel = statusBefore.currentModel

    let backupStarted = Date()
    let backupPath = try makeBackup(codexHome: codexHome, label: "pre-sync")
    let backupMilliseconds = elapsedMilliseconds(since: backupStarted)

    let dbSummary = try updateProviderAssignments(paths, currentProvider: currentProvider, currentModel: currentModel)
    let sessionSummary = try syncSessionRecords(paths, currentProvider: currentProvider, currentModel: currentModel)
    let readDB = try SQLiteDatabase(path: paths.databasePath, readOnly: true)
    let indexSummary = try rebuildSessionIndex(paths, db: readDB)
    let statusAfter = try loadStatus(codexHome: codexHome)

    return SyncResult(
        currentProvider: currentProvider,
        currentModel: currentModel,
        syncedFields: dbSummary.syncedFields,
        updatedRows: dbSummary.updatedRows,
        updatedSessionFiles: sessionSummary.updatedSessionFiles,
        providerMovableThreads: statusBefore.providerMovableThreads,
        modelMovableThreads: statusBefore.modelMovableThreads,
        backupPath: backupPath,
        beforeCounts: dbSummary.beforeCounts,
        afterCounts: dbSummary.afterCounts,
        beforeModelCounts: dbSummary.beforeModelCounts,
        afterModelCounts: dbSummary.afterModelCounts,
        sessionBeforeCounts: sessionSummary.beforeCounts,
        sessionAfterCounts: sessionSummary.afterCounts,
        sessionBeforeModelCounts: sessionSummary.beforeModelCounts,
        sessionAfterModelCounts: sessionSummary.afterModelCounts,
        checkpoint: dbSummary.checkpoint,
        lockWaitMilliseconds: dbSummary.lockWaitMilliseconds,
        lockAttempts: dbSummary.attempts,
        rewrittenIndexEntries: indexSummary.rewrittenEntries,
        missingSessionIndexEntriesBefore: indexSummary.missingEntriesBefore,
        preservedIndexOnlyEntries: indexSummary.preservedIndexOnlyEntries,
        timing: TimingInfo(
            backupMilliseconds: backupMilliseconds,
            databaseMilliseconds: dbSummary.lockWaitMilliseconds,
            sessionMilliseconds: sessionSummary.durationMilliseconds,
            indexMilliseconds: indexSummary.durationMilliseconds,
            totalMilliseconds: elapsedMilliseconds(since: totalStarted)
        ),
        status: statusAfter
    )
}

public func restoreBackup(codexHome: URL = defaultCodexHome(), backupPath: URL? = nil) throws -> RestoreResult {
    let totalStarted = Date()
    let paths = resolvePaths(codexHome: codexHome)
    try ensureEnvironment(paths)
    let chosenBackup = try resolveBackup(paths, requestedPath: backupPath)

    let backupStarted = Date()
    let safetyBackup = try makeBackup(codexHome: codexHome, label: "pre-restore")
    let backupMilliseconds = elapsedMilliseconds(since: backupStarted)

    let restoreStarted = Date()
    let restoreDBSummary = try restoreDatabaseWithRetry(paths, chosenBackup: chosenBackup)
    let restoreDBMilliseconds = elapsedMilliseconds(since: restoreStarted)
    let metadataRestore = try restoreMetadata(paths, backupPath: chosenBackup)
    let readDB = try SQLiteDatabase(path: paths.databasePath, readOnly: true)
    let indexSummary = try rebuildSessionIndex(paths, db: readDB)
    let statusAfter = try loadStatus(codexHome: codexHome)

    return RestoreResult(
        restoredFrom: chosenBackup,
        safetyBackup: safetyBackup,
        metadataRestore: metadataRestore,
        checkpoint: restoreDBSummary.checkpoint,
        lockWaitMilliseconds: restoreDBSummary.lockWaitMilliseconds,
        lockAttempts: restoreDBSummary.attempts,
        rewrittenIndexEntries: indexSummary.rewrittenEntries,
        timing: RestoreTimingInfo(
            backupMilliseconds: backupMilliseconds,
            databaseMilliseconds: restoreDBMilliseconds,
            metadataMilliseconds: metadataRestore.durationMilliseconds,
            indexMilliseconds: indexSummary.durationMilliseconds,
            totalMilliseconds: elapsedMilliseconds(since: totalStarted)
        ),
        status: statusAfter
    )
}

private func resolvePaths(codexHome: URL) -> Paths {
    let home = codexHome.standardizedFileURL
    return Paths(
        codexHome: home,
        configPath: home.appendingPathComponent("config.toml"),
        databasePath: home.appendingPathComponent("state_5.sqlite"),
        backupDirectory: home.appendingPathComponent("history_sync_backups", isDirectory: true),
        sessionIndexPath: home.appendingPathComponent("session_index.jsonl"),
        sessionsDirectory: home.appendingPathComponent("sessions", isDirectory: true)
    )
}

private func ensureEnvironment(_ paths: Paths) throws {
    if !FileManager.default.fileExists(atPath: paths.configPath.path) {
        throw CodexHistorySyncError.missingConfig(paths.configPath)
    }
    if !FileManager.default.fileExists(atPath: paths.databasePath.path) {
        throw CodexHistorySyncError.missingDatabase(paths.databasePath)
    }
}

private func parseCurrentProvider(_ text: String) -> String? {
    let pattern = #"(?m)^\s*model_provider\s*=\s*"([^"]+)""#
    guard let match = text.range(of: pattern, options: .regularExpression) else {
        return nil
    }
    let line = String(text[match])
    guard let valueRange = line.range(of: #""[^"]+""#, options: .regularExpression) else {
        return nil
    }
    return String(line[valueRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
}

private func inferCurrentProvider(
    _ db: SQLiteDatabase,
    columns: Set<String>,
    currentModel: String?,
    configURL: URL
) throws -> String {
    let orderSQL = providerInferenceOrderSQL(columns)

    if let currentModel, columns.contains("model") {
        let rows = try db.query("""
            SELECT model_provider
            FROM threads
            WHERE model = ?
              AND model_provider IS NOT NULL
              AND model_provider <> ''
            ORDER BY \(orderSQL)
            LIMIT 1
            """, parameters: [.text(currentModel)])
        if let provider = rows.first?["model_provider"]?.stringValue, !provider.isEmpty {
            return provider
        }
    }

    let rows = try db.query("""
        SELECT model_provider
        FROM threads
        WHERE model_provider IS NOT NULL
          AND model_provider <> ''
        ORDER BY \(orderSQL)
        LIMIT 1
        """)
    if let provider = rows.first?["model_provider"]?.stringValue, !provider.isEmpty {
        return provider
    }
    throw CodexHistorySyncError.configMissingProvider(configURL)
}

private func providerInferenceOrderSQL(_ columns: Set<String>) -> String {
    let timestampColumns = ["updated_at_ms", "updated_at", "created_at_ms", "created_at"]
        .filter { columns.contains($0) }
        .map { "\($0) DESC" }
    if timestampColumns.isEmpty {
        return "id DESC"
    }
    return (timestampColumns + ["id DESC"]).joined(separator: ", ")
}

private func parseCurrentModel(_ text: String) -> String? {
    let pattern = #"(?m)^\s*model\s*=\s*"([^"]+)""#
    guard let match = text.range(of: pattern, options: .regularExpression) else {
        return nil
    }
    let line = String(text[match])
    guard let valueRange = line.range(of: #""[^"]+""#, options: .regularExpression) else {
        return nil
    }
    return String(line[valueRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
}

private func queryProviderCounts(_ db: SQLiteDatabase) throws -> [ProviderCount] {
    let rows = try db.query("""
        SELECT model_provider, COUNT(*) AS count
        FROM threads
        GROUP BY model_provider
        ORDER BY COUNT(*) DESC, model_provider ASC
        """)
    return rows.map {
        ProviderCount(provider: ($0["model_provider"] ?? .null).countKey, count: $0["count"]?.intValue ?? 0)
    }
}

private func queryModelCounts(_ db: SQLiteDatabase) throws -> [ModelCount] {
    let rows = try db.query("""
        SELECT model, COUNT(*) AS count
        FROM threads
        GROUP BY model
        ORDER BY COUNT(*) DESC, model ASC
        """)
    return rows.map {
        ModelCount(model: ($0["model"] ?? .null).countKey, count: $0["count"]?.intValue ?? 0)
    }
}

private func queryProviderModelCounts(_ db: SQLiteDatabase) throws -> [ProviderModelCount] {
    let rows = try db.query("""
        SELECT model_provider, model, COUNT(*) AS count
        FROM threads
        GROUP BY model_provider, model
        ORDER BY COUNT(*) DESC, model_provider ASC, model ASC
        """)
    return rows.map {
        ProviderModelCount(
            provider: ($0["model_provider"] ?? .null).countKey,
            model: ($0["model"] ?? .null).countKey,
            count: $0["count"]?.intValue ?? 0
        )
    }
}

private func queryCwdCounts(_ db: SQLiteDatabase, limit: Int = 20) throws -> [CwdCount] {
    let rows = try db.query("""
        SELECT cwd, COUNT(*) AS count
        FROM threads
        GROUP BY cwd
        ORDER BY COUNT(*) DESC, cwd ASC
        LIMIT ?
        """, parameters: [.int(limit)])
    return rows.map {
        CwdCount(cwd: ($0["cwd"] ?? .null).countKey, count: $0["count"]?.intValue ?? 0)
    }
}

private func countMismatched(_ db: SQLiteDatabase, column: String, expected: String?) throws -> Int? {
    guard let expected else {
        return nil
    }
    return try db.scalarInt(
        "SELECT COUNT(*) AS count FROM threads WHERE \(column) IS NULL OR \(column) <> ?",
        parameters: [.text(expected)]
    )
}

private func databaseMovableIDs(
    _ db: SQLiteDatabase,
    columns: Set<String>,
    provider: String,
    model: String?
) throws -> Set<String> {
    var whereParts = ["model_provider IS NULL OR model_provider <> ?"]
    var parameters: [SQLiteValue] = [.text(provider)]
    if columns.contains("model"), let model {
        whereParts.append("model IS NULL OR model <> ?")
        parameters.append(.text(model))
    }
    let whereSQL = whereParts.map { "(\($0))" }.joined(separator: " OR ")
    let rows = try db.query("SELECT id FROM threads WHERE \(whereSQL)", parameters: parameters)
    return Set(rows.compactMap { $0["id"]?.stringValue })
}

private func databaseThreadIDs(_ db: SQLiteDatabase, columns: Set<String>) throws -> Set<String> {
    let query = columns.contains("archived")
        ? "SELECT id FROM threads WHERE archived = 0"
        : "SELECT id FROM threads"
    return Set(try db.query(query).compactMap { $0["id"]?.stringValue })
}

private func updateProviderAssignments(
    _ paths: Paths,
    currentProvider: String,
    currentModel: String?
) throws -> DatabaseSyncSummary {
    let started = Date()
    var lastSQLiteError: Error?

    for attempt in 1...writeLockRetryLimit {
        do {
            let db = try SQLiteDatabase(
                path: paths.databasePath,
                readOnly: false,
                timeoutSeconds: writeOperationTimeoutSeconds
            )
            _ = try db.execute("BEGIN IMMEDIATE")
            let columns = try db.columns(in: "threads")
            let beforeCounts = try queryProviderCounts(db)
            let beforeModelCounts = columns.contains("model") ? try queryModelCounts(db) : []
            var setParts = ["model_provider = ?"]
            var setParameters: [SQLiteValue] = [.text(currentProvider)]
            var whereParts = ["model_provider IS NULL OR model_provider <> ?"]
            var whereParameters: [SQLiteValue] = [.text(currentProvider)]
            var syncedFields = ["model_provider"]

            if columns.contains("model"), let currentModel {
                setParts.append("model = ?")
                setParameters.append(.text(currentModel))
                whereParts.append("model IS NULL OR model <> ?")
                whereParameters.append(.text(currentModel))
                syncedFields.append("model")
            }

            let updatedRows = try db.execute(
                "UPDATE threads SET \(setParts.joined(separator: ", ")) WHERE \(whereParts.map { "(\($0))" }.joined(separator: " OR "))",
                parameters: setParameters + whereParameters
            )
            _ = try db.execute("COMMIT")
            let afterCounts = try queryProviderCounts(db)
            let afterModelCounts = columns.contains("model") ? try queryModelCounts(db) : []
            let checkpoint = try db.checkpoint(mode: syncCheckpointMode)
            return DatabaseSyncSummary(
                attempts: attempt,
                lockWaitMilliseconds: elapsedMilliseconds(since: started),
                syncedFields: syncedFields,
                updatedRows: updatedRows,
                beforeCounts: beforeCounts,
                afterCounts: afterCounts,
                beforeModelCounts: beforeModelCounts,
                afterModelCounts: afterModelCounts,
                checkpoint: checkpoint
            )
        } catch {
            if !isLockedError(error) {
                throw error
            }
            lastSQLiteError = error
            if attempt == writeLockRetryLimit {
                let waited = Double(elapsedMilliseconds(since: started)) / 1000.0
                throw CodexHistorySyncError.databaseBusy(
                    "Codex 当前正在写入本地历史数据库，已等待 \(String(format: "%.1f", waited)) 秒仍未拿到写锁。请等当前回复、工具调用或自动保存结束后再试一次。"
                )
            }
            Thread.sleep(forTimeInterval: writeLockRetryDelaySeconds)
        }
    }
    throw lastSQLiteError ?? CodexHistorySyncError.sqlite("Database write lock retry loop ended unexpectedly.")
}

private func restoreDatabaseWithRetry(_ paths: Paths, chosenBackup: URL) throws -> (attempts: Int, lockWaitMilliseconds: Int, checkpoint: CheckpointInfo) {
    let started = Date()
    var lastSQLiteError: Error?
    for attempt in 1...writeLockRetryLimit {
        do {
            try SQLiteDatabase.backup(from: chosenBackup, to: paths.databasePath)
            let db = try SQLiteDatabase(path: paths.databasePath, readOnly: false, timeoutSeconds: writeOperationTimeoutSeconds)
            let checkpoint = try db.checkpoint(mode: syncCheckpointMode)
            return (attempt, elapsedMilliseconds(since: started), checkpoint)
        } catch {
            if !isLockedError(error) {
                throw error
            }
            lastSQLiteError = error
            if attempt == writeLockRetryLimit {
                let waited = Double(elapsedMilliseconds(since: started)) / 1000.0
                throw CodexHistorySyncError.databaseBusy(
                    "Codex 当前正在写入本地历史数据库，已等待 \(String(format: "%.1f", waited)) 秒仍无法完成还原。请等当前回复、工具调用或自动保存结束后再试一次。"
                )
            }
            Thread.sleep(forTimeInterval: writeLockRetryDelaySeconds)
        }
    }
    throw lastSQLiteError ?? CodexHistorySyncError.sqlite("Database restore retry loop ended unexpectedly.")
}

private func isLockedError(_ error: Error) -> Bool {
    let message = (error as? LocalizedError)?.errorDescription?.lowercased() ?? "\(error)".lowercased()
    return message.contains("database is locked")
        || message.contains("database table is locked")
        || message.contains("database is busy")
        || message.contains("destination database is in use")
}

private func scanSessionRecords(_ paths: Paths) throws -> [SessionRecord] {
    guard FileManager.default.fileExists(atPath: paths.sessionsDirectory.path),
          let enumerator = FileManager.default.enumerator(
            at: paths.sessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
          ) else {
        return []
    }

    var records: [SessionRecord] = []
    for case let url as URL in enumerator where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
        if let record = try parseSessionRecord(url) {
            records.append(record)
        }
    }
    return records.sorted { $0.path.path < $1.path.path }
}

private func parseSessionRecord(_ url: URL) throws -> SessionRecord? {
    guard let firstLine = try firstLine(url), !firstLine.isEmpty else {
        return nil
    }
    let item = try jsonObject(firstLine, url: url)
    guard item["type"] as? String == "session_meta",
          let payload = item["payload"] as? [String: Any],
          let threadID = payload["id"] as? String,
          !threadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    return SessionRecord(
        threadID: threadID,
        path: url,
        modelProvider: payload["model_provider"] as? String ?? "",
        model: payload["model"] as? String
    )
}

private func syncSessionRecords(_ paths: Paths, currentProvider: String, currentModel: String?) throws -> SessionSyncSummary {
    let started = Date()
    let beforeRecords = try scanSessionRecords(paths)
    var updatedSessionFiles = 0

    for record in beforeRecords {
        let modelMatches = currentModel == nil || record.model == currentModel
        if record.modelProvider == currentProvider, modelMatches {
            continue
        }
        let text = try String(contentsOf: record.path, encoding: .utf8)
        let parts = splitFirstLine(text)
        var item = try jsonObject(parts.firstLine, url: record.path)
        guard var payload = item["payload"] as? [String: Any] else {
            continue
        }
        payload["model_provider"] = currentProvider
        if let currentModel {
            payload["model"] = currentModel
        }
        item["payload"] = payload
        let newFirstLine = try compactJSONString(item)
        let newText = parts.ending.isEmpty ? newFirstLine : newFirstLine + parts.ending + parts.remainder
        try writeTextAtomically(newText, to: record.path)
        updatedSessionFiles += 1
    }

    let afterRecords = try scanSessionRecords(paths)
    return SessionSyncSummary(
        updatedSessionFiles: updatedSessionFiles,
        beforeCounts: providerCountsFromValues(beforeRecords.map(\.modelProvider)),
        afterCounts: providerCountsFromValues(afterRecords.map(\.modelProvider)),
        beforeModelCounts: modelCountsFromValues(beforeRecords.map { $0.model ?? "(empty)" }),
        afterModelCounts: modelCountsFromValues(afterRecords.map { $0.model ?? "(empty)" }),
        durationMilliseconds: elapsedMilliseconds(since: started)
    )
}

private func readSessionIndex(_ paths: Paths) throws -> [String: IndexEntry] {
    guard FileManager.default.fileExists(atPath: paths.sessionIndexPath.path) else {
        return [:]
    }
    let text = try String(contentsOf: paths.sessionIndexPath, encoding: .utf8)
    var entries: [String: IndexEntry] = [:]
    for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let data = Data(line.utf8)
        guard let item = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexHistorySyncError.invalidJSON(paths.sessionIndexPath)
        }
        guard let id = item["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            continue
        }
        entries[id] = IndexEntry(
            id: id,
            threadName: item["thread_name"] as? String ?? id,
            updatedAt: item["updated_at"] as? String ?? ""
        )
    }
    return entries
}

private func rebuildSessionIndex(_ paths: Paths, db: SQLiteDatabase) throws -> IndexSummary {
    let started = Date()
    let existingEntries = try readSessionIndex(paths)
    let columns = try db.columns(in: "threads")
    var selectParts = ["id"]
    if columns.contains("title") {
        selectParts.append("title")
    }
    if columns.contains("updated_at") {
        selectParts.append("updated_at")
    }
    let whereSQL = columns.contains("archived") ? "WHERE archived = 0" : ""
    let rows = try db.query("""
        SELECT \(selectParts.joined(separator: ", "))
        FROM threads
        \(whereSQL)
        ORDER BY id ASC
        """)
    let dbIDs = Set(rows.compactMap { $0["id"]?.stringValue })
    let existingIDs = Set(existingEntries.keys)
    var merged: [IndexEntry] = []

    for row in rows {
        guard let id = row["id"]?.stringValue else {
            continue
        }
        let existing = existingEntries[id]
        let title = row["title"]?.stringValue ?? id
        let updatedAt = row["updated_at"]?.intValue.map(isoUTCFromUnix) ?? "1970-01-01T00:00:00Z"
        merged.append(IndexEntry(
            id: id,
            threadName: existing?.threadName ?? title,
            updatedAt: updatedAt
        ))
    }

    for (id, entry) in existingEntries where !dbIDs.contains(id) {
        merged.append(entry)
    }

    merged.sort {
        let lhsDate = parseIndexDate($0.updatedAt)
        let rhsDate = parseIndexDate($1.updatedAt)
        if lhsDate == rhsDate {
            return $0.id < $1.id
        }
        return lhsDate < rhsDate
    }
    try writeSessionIndex(paths, entries: merged)
    return IndexSummary(
        rewrittenEntries: merged.count,
        missingEntriesBefore: dbIDs.subtracting(existingIDs).count,
        preservedIndexOnlyEntries: existingIDs.subtracting(dbIDs).count,
        durationMilliseconds: elapsedMilliseconds(since: started)
    )
}

private func writeSessionIndex(_ paths: Paths, entries: [IndexEntry]) throws {
    let lines = try entries.map { entry in
        try compactJSONString([
            "id": entry.id,
            "thread_name": entry.threadName,
            "updated_at": entry.updatedAt
        ])
    }
    let content = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    try writeTextAtomically(content, to: paths.sessionIndexPath)
}

private func snapshotMetadata(_ paths: Paths, backupPath: URL) throws {
    if FileManager.default.fileExists(atPath: paths.sessionIndexPath.path) {
        let text = try String(contentsOf: paths.sessionIndexPath, encoding: .utf8)
        try writeTextAtomically(text, to: sessionIndexBackupPath(backupPath))
    }

    let items = try scanSessionFiles(paths).compactMap { url -> [String: String]? in
        guard let firstLine = try firstLine(url), !firstLine.isEmpty else {
            return nil
        }
        return [
            "path": relativePath(url, to: paths.codexHome) ?? url.path,
            "first_line": firstLine
        ]
    }
    let data = try JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys])
    try writeDataAtomically(data + Data("\n".utf8), to: sessionMetaBackupPath(backupPath))
}

private func restoreMetadata(_ paths: Paths, backupPath: URL) throws -> MetadataRestoreInfo {
    let started = Date()
    var sessionIndexRestored = false
    var sessionFilesRestored = 0

    let indexBackup = sessionIndexBackupPath(backupPath)
    if FileManager.default.fileExists(atPath: indexBackup.path) {
        let text = try String(contentsOf: indexBackup, encoding: .utf8)
        try writeTextAtomically(text, to: paths.sessionIndexPath)
        sessionIndexRestored = true
    }

    let metaBackup = sessionMetaBackupPath(backupPath)
    if FileManager.default.fileExists(atPath: metaBackup.path) {
        let data = try Data(contentsOf: metaBackup)
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            throw CodexHistorySyncError.invalidJSON(metaBackup)
        }
        for item in items {
            guard let rawPath = item["path"], let firstLine = item["first_line"] else {
                continue
            }
            let url = rawPath.hasPrefix("/") ? URL(fileURLWithPath: rawPath) : paths.codexHome.appendingPathComponent(rawPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            try replaceFirstLine(url, with: firstLine)
            sessionFilesRestored += 1
        }
    }

    return MetadataRestoreInfo(
        sessionIndexRestored: sessionIndexRestored,
        sessionFilesRestored: sessionFilesRestored,
        durationMilliseconds: elapsedMilliseconds(since: started)
    )
}

private func resolveBackup(_ paths: Paths, requestedPath: URL?) throws -> URL {
    if let requestedPath {
        guard FileManager.default.fileExists(atPath: requestedPath.path) else {
            throw CodexHistorySyncError.backupMissing(requestedPath)
        }
        return requestedPath
    }
    guard let newest = try listBackups(paths, limit: 1).first else {
        throw CodexHistorySyncError.noBackups
    }
    return newest.path
}

private func listBackups(_ paths: Paths, limit: Int = 20) throws -> [BackupInfo] {
    guard FileManager.default.fileExists(atPath: paths.backupDirectory.path) else {
        return []
    }
    let urls = try FileManager.default.contentsOfDirectory(
        at: paths.backupDirectory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ).filter {
        $0.lastPathComponent.hasPrefix("state_5.sqlite.") && $0.lastPathComponent.hasSuffix(".bak")
    }
    let sorted = try urls.sorted {
        try modificationDate($0) > modificationDate($1)
    }
    return try sorted.prefix(limit).map {
        BackupInfo(name: $0.lastPathComponent, path: $0, modifiedAt: try modificationDate($0))
    }
}

private func scanSessionFiles(_ paths: Paths) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: paths.sessionsDirectory.path),
          let enumerator = FileManager.default.enumerator(
            at: paths.sessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
          ) else {
        return []
    }
    return enumerator.compactMap { item -> URL? in
        guard let url = item as? URL,
              url.lastPathComponent.hasPrefix("rollout-"),
              url.pathExtension == "jsonl" else {
            return nil
        }
        return url
    }.sorted { $0.path < $1.path }
}

private func providerCountsFromValues(_ values: [String]) -> [ProviderCount] {
    orderedCounts(values).map { ProviderCount(provider: $0.key, count: $0.value) }
}

private func modelCountsFromValues(_ values: [String]) -> [ModelCount] {
    orderedCounts(values).map { ModelCount(model: $0.key, count: $0.value) }
}

private func orderedCounts(_ values: [String]) -> [(key: String, value: Int)] {
    var counts: [String: Int] = [:]
    for value in values {
        counts[value.isEmpty ? "(empty)" : value, default: 0] += 1
    }
    return counts.sorted {
        if $0.value == $1.value {
            return $0.key < $1.key
        }
        return $0.value > $1.value
    }
}

private func sessionIndexBackupPath(_ backupPath: URL) -> URL {
    backupPath.deletingLastPathComponent()
        .appendingPathComponent("\(backupPath.lastPathComponent).session_index.jsonl")
}

private func sessionMetaBackupPath(_ backupPath: URL) -> URL {
    backupPath.deletingLastPathComponent()
        .appendingPathComponent("\(backupPath.lastPathComponent).session_meta.json")
}

private func firstLine(_ url: URL) throws -> String? {
    let text = try String(contentsOf: url, encoding: .utf8)
    return splitFirstLine(text).firstLine
}

private func splitFirstLine(_ text: String) -> (firstLine: String, ending: String, remainder: String) {
    for ending in ["\r\n", "\n", "\r"] {
        if let range = text.range(of: ending) {
            return (
                String(text[..<range.lowerBound]),
                ending,
                String(text[range.upperBound...])
            )
        }
    }
    return (text, "", "")
}

private func replaceFirstLine(_ url: URL, with firstLine: String) throws {
    let text = try String(contentsOf: url, encoding: .utf8)
    let parts = splitFirstLine(text)
    let newText: String
    if parts.ending.isEmpty {
        newText = text.isEmpty ? firstLine + "\n" : firstLine
    } else {
        newText = firstLine + parts.ending + parts.remainder
    }
    try writeTextAtomically(newText, to: url)
}

private func jsonObject(_ text: String, url: URL) throws -> [String: Any] {
    guard let item = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
        throw CodexHistorySyncError.invalidJSON(url)
    }
    return item
}

private func compactJSONString(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func writeTextAtomically(_ text: String, to url: URL) throws {
    try writeDataAtomically(Data(text.utf8), to: url)
}

private func writeDataAtomically(_ data: Data, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent).codex-sync-\(UUID().uuidString).tmp")
    try data.write(to: tempURL, options: [])
    do {
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
    } catch {
        try? FileManager.default.removeItem(at: tempURL)
        throw CodexHistorySyncError.fileBusy(url)
    }
}

private func relativePath(_ url: URL, to base: URL) -> String? {
    let basePath = base.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(basePath + "/") else {
        return nil
    }
    return String(path.dropFirst(basePath.count + 1))
}

private func modificationDate(_ url: URL) throws -> Date {
    let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
    return values.contentModificationDate ?? Date.distantPast
}

private func isoUTCFromUnix(_ timestamp: Int) -> String {
    makeISOFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
}

private func parseIndexDate(_ value: String) -> Date {
    if let date = makeISOFormatter().date(from: value) {
        return date
    }
    if let date = makeIndexFallbackFormatter().date(from: value) {
        return date
    }
    return Date(timeIntervalSince1970: 0)
}

private func elapsedMilliseconds(since start: Date) -> Int {
    Int(Date().timeIntervalSince(start) * 1000)
}

private func backupTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: date)
}

private func makeISOFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
}

private func makeIndexFallbackFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
    return formatter
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data {
        var data = lhs
        data.append(rhs)
        return data
    }
}
