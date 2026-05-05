import XCTest
import SQLite3
@testable import CodexHistoryCore

final class CodexHistoryCoreTests: XCTestCase {
    func testSyncUpdatesProviderAndModelForNewerCodexSchema() throws {
        let codexHome = try makeCodexHome()
        try writeConfig(codexHome, provider: "new_provider", model: "gpt-new")
        try createThreadsDB(codexHome, withModel: true)

        let status = try loadStatus(codexHome: codexHome)

        XCTAssertEqual(status.providerMovableThreads, 1)
        XCTAssertEqual(status.modelMovableThreads, 2)
        XCTAssertEqual(status.movableThreads, 2)

        let result = try syncToCurrentProvider(codexHome: codexHome)

        XCTAssertEqual(result.syncedFields, ["model_provider", "model"])
        XCTAssertEqual(result.updatedRows, 2)
        XCTAssertEqual(try groupedProviderModelRows(codexHome), [["new_provider", "gpt-new", "3"]])
    }

    func testSyncSupportsLegacySchemaWithoutModelColumn() throws {
        let codexHome = try makeCodexHome()
        try writeConfig(codexHome, provider: "new_provider", model: "gpt-new")
        try createThreadsDB(codexHome, withModel: false)

        let status = try loadStatus(codexHome: codexHome)

        XCTAssertEqual(status.providerMovableThreads, 1)
        XCTAssertNil(status.modelMovableThreads)
        XCTAssertEqual(status.movableThreads, 1)

        let result = try syncToCurrentProvider(codexHome: codexHome)

        XCTAssertEqual(result.syncedFields, ["model_provider"])
        XCTAssertEqual(result.updatedRows, 1)
        XCTAssertEqual(try groupedProviderRows(codexHome), [["new_provider", "2"]])
    }

    func testRestoreBackupRestoresPreviousDatabaseSnapshot() throws {
        let codexHome = try makeCodexHome()
        try writeConfig(codexHome, provider: "new_provider", model: "gpt-new")
        try createThreadsDB(codexHome, withModel: true)
        let backupPath = try makeBackup(codexHome: codexHome, label: "manual")

        _ = try syncToCurrentProvider(codexHome: codexHome)
        let result = try restoreBackup(codexHome: codexHome, backupPath: backupPath)

        XCTAssertEqual(result.restoredFrom, backupPath)
        XCTAssertEqual(
            try groupedProviderModelRows(codexHome),
            [
                ["new_provider", "gpt-new", "1"],
                ["new_provider", "gpt-old", "1"],
                ["old_provider", "gpt-old", "1"]
            ]
        )
    }

    func testSyncRebuildsMissingSessionIndexEntries() throws {
        let codexHome = try makeCodexHome()
        try writeConfig(codexHome, provider: "new_provider", model: "gpt-new")
        try createThreadsDB(codexHome, withModel: true, withIndexColumns: true)
        try writeSessionIndex(codexHome, entries: [
            ["id": "already-current", "thread_name": "Already", "updated_at": "2024-01-01T00:00:03Z"]
        ])

        let before = try loadStatus(codexHome: codexHome)
        XCTAssertEqual(before.missingSessionIndexEntries, 2)

        let result = try syncToCurrentProvider(codexHome: codexHome)

        XCTAssertEqual(result.missingSessionIndexEntriesBefore, 2)
        let entries = try readSessionIndex(codexHome)
        XCTAssertEqual(Set(entries.map { $0["id"] ?? "" }), ["old-provider-old-model", "new-provider-old-model", "already-current"])
    }

    func testSyncUpdatesSessionMetaFirstLineProviderAndModel() throws {
        let codexHome = try makeCodexHome()
        try writeConfig(codexHome, provider: "new_provider", model: "gpt-new")
        try createThreadsDB(codexHome, withModel: true)
        let sessionPath = try writeSessionFile(
            codexHome,
            threadID: "old-provider-old-model",
            provider: "old_provider",
            model: "gpt-old"
        )

        let result = try syncToCurrentProvider(codexHome: codexHome)

        XCTAssertEqual(result.updatedSessionFiles, 1)
        let meta = try firstLinePayload(sessionPath)
        XCTAssertEqual(meta["model_provider"] as? String, "new_provider")
        XCTAssertEqual(meta["model"] as? String, "gpt-new")
    }

    func testBackupAndRestorePreserveSessionIndexAndSessionMeta() throws {
        let codexHome = try makeCodexHome()
        try writeConfig(codexHome, provider: "new_provider", model: "gpt-new")
        try createThreadsDB(codexHome, withModel: true, withIndexColumns: true)
        let sessionPath = try writeSessionFile(
            codexHome,
            threadID: "old-provider-old-model",
            provider: "old_provider",
            model: "gpt-old"
        )
        try writeSessionIndex(codexHome, entries: [
            ["id": "old-provider-old-model", "thread_name": "Old", "updated_at": "2024-01-01T00:00:01Z"]
        ])
        let backupPath = try makeBackup(codexHome: codexHome, label: "manual")

        _ = try syncToCurrentProvider(codexHome: codexHome)
        _ = try restoreBackup(codexHome: codexHome, backupPath: backupPath)

        let meta = try firstLinePayload(sessionPath)
        XCTAssertEqual(meta["model_provider"] as? String, "old_provider")
        XCTAssertEqual(meta["model"] as? String, "gpt-old")
        let entries = try readSessionIndex(codexHome)
        XCTAssertEqual(entries.first?["thread_name"], "Old")
    }

    func testStatusInfersProviderFromLatestThreadMatchingCurrentModel() throws {
        let codexHome = try makeCodexHome()
        try writeConfigWithoutProvider(codexHome, model: "gpt-new")
        try createThreadsDBWithUpdatedAt(codexHome)

        let status = try loadStatus(codexHome: codexHome)

        XCTAssertEqual(status.currentProvider, "new_provider")
        XCTAssertEqual(status.currentModel, "gpt-new")
        XCTAssertEqual(status.providerMovableThreads, 2)
    }
}

private func makeCodexHome() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeConfig(_ codexHome: URL, provider: String, model: String) throws {
    let text = "model_provider = \"\(provider)\"\nmodel = \"\(model)\"\n"
    try text.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
}

private func writeConfigWithoutProvider(_ codexHome: URL, model: String) throws {
    let text = "model = \"\(model)\"\n"
    try text.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
}

private func createThreadsDB(_ codexHome: URL, withModel: Bool, withIndexColumns: Bool = false) throws {
    let db = try openDatabase(codexHome.appendingPathComponent("state_5.sqlite"))
    defer { sqlite3_close(db) }

    if withModel {
        let extraColumns = withIndexColumns ? ", title TEXT, updated_at INTEGER, archived INTEGER" : ""
        try exec(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT NOT NULL, model TEXT\(extraColumns))")
        if withIndexColumns {
            try exec(db, """
                INSERT INTO threads (id, model_provider, model, title, updated_at, archived) VALUES
                ('old-provider-old-model', 'old_provider', 'gpt-old', 'Old Provider', 1704067201, 0),
                ('new-provider-old-model', 'new_provider', 'gpt-old', 'Old Model', 1704067202, 0),
                ('already-current', 'new_provider', 'gpt-new', 'Already', 1704067203, 0)
                """)
        } else {
            try exec(db, """
                INSERT INTO threads (id, model_provider, model) VALUES
                ('old-provider-old-model', 'old_provider', 'gpt-old'),
                ('new-provider-old-model', 'new_provider', 'gpt-old'),
                ('already-current', 'new_provider', 'gpt-new')
                """)
        }
    } else {
        try exec(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT NOT NULL)")
        try exec(db, """
            INSERT INTO threads (id, model_provider) VALUES
            ('old-provider', 'old_provider'),
            ('already-current', 'new_provider')
            """)
    }
}

private func createThreadsDBWithUpdatedAt(_ codexHome: URL) throws {
    let db = try openDatabase(codexHome.appendingPathComponent("state_5.sqlite"))
    defer { sqlite3_close(db) }
    try exec(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT NOT NULL, model TEXT, updated_at INTEGER)")
    try exec(db, """
        INSERT INTO threads (id, model_provider, model, updated_at) VALUES
        ('old-current-model', 'old_provider', 'gpt-new', 10),
        ('latest-current-model', 'new_provider', 'gpt-new', 30),
        ('newer-other-model', 'other_provider', 'gpt-other', 40)
        """)
}

private func writeSessionFile(_ codexHome: URL, threadID: String, provider: String, model: String) throws -> URL {
    let sessionsDir = codexHome.appendingPathComponent("sessions/2024/01/01", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    let url = sessionsDir.appendingPathComponent("rollout-2024-01-01T00-00-00-\(threadID).jsonl")
    let firstLine = #"{"type":"session_meta","payload":{"id":"\#(threadID)","model_provider":"\#(provider)","model":"\#(model)"}}"#
    try (firstLine + "\n{\"type\":\"event\"}\n").write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func writeSessionIndex(_ codexHome: URL, entries: [[String: String]]) throws {
    let lines = try entries.map { entry in
        let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }.joined(separator: "\n")
    try (lines + "\n").write(to: codexHome.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
}

private func readSessionIndex(_ codexHome: URL) throws -> [[String: String]] {
    let url = codexHome.appendingPathComponent("session_index.jsonl")
    let text = try String(contentsOf: url, encoding: .utf8)
    return try text.split(separator: "\n").map { line in
        let data = Data(line.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
    }
}

private func firstLinePayload(_ url: URL) throws -> [String: Any] {
    let text = try String(contentsOf: url, encoding: .utf8)
    let firstLine = try XCTUnwrap(text.split(separator: "\n").first)
    let item = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any])
    return try XCTUnwrap(item["payload"] as? [String: Any])
}

private func groupedProviderModelRows(_ codexHome: URL) throws -> [[String]] {
    try rows(
        codexHome,
        query: "SELECT model_provider, model, COUNT(*) FROM threads GROUP BY model_provider, model ORDER BY model_provider, model"
    )
}

private func groupedProviderRows(_ codexHome: URL) throws -> [[String]] {
    try rows(
        codexHome,
        query: "SELECT model_provider, COUNT(*) FROM threads GROUP BY model_provider ORDER BY model_provider"
    )
}

private func rows(_ codexHome: URL, query: String) throws -> [[String]] {
    let db = try openDatabase(codexHome.appendingPathComponent("state_5.sqlite"))
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
        throw TestError.sqlite(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }

    var output: [[String]] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        var row: [String] = []
        for index in 0..<sqlite3_column_count(statement) {
            if let text = sqlite3_column_text(statement, index) {
                row.append(String(cString: text))
            } else {
                row.append("")
            }
        }
        output.append(row)
    }
    return output
}

private func openDatabase(_ url: URL) throws -> OpaquePointer {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        throw TestError.sqlite("Could not open database")
    }
    return db
}

private func exec(_ db: OpaquePointer, _ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
        let message = error.map { String(cString: $0) } ?? "unknown sqlite error"
        sqlite3_free(error)
        throw TestError.sqlite(message)
    }
}

private enum TestError: Error {
    case sqlite(String)
}
