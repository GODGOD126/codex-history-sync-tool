import Foundation
import SQLite3

final class SQLiteDatabase {
    private let handle: OpaquePointer

    init(path: URL, readOnly: Bool = false, timeoutSeconds: Double = 30.0) throws {
        var db: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(path.path, &db, flags, nil) == SQLITE_OK, let db else {
            throw CodexHistorySyncError.sqlite("无法打开数据库: \(path.path)")
        }
        handle = db
        try executeRaw("PRAGMA busy_timeout = \(max(1, Int(timeoutSeconds * 1000)))")
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String, parameters: [SQLiteValue] = []) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(parameters, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw CodexHistorySyncError.sqlite(lastError)
        }
        return Int(sqlite3_changes(handle))
    }

    func query(_ sql: String, parameters: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(parameters, to: statement)

        var rows: [[String: SQLiteValue]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                break
            }
            guard result == SQLITE_ROW else {
                throw CodexHistorySyncError.sqlite(lastError)
            }

            var row: [String: SQLiteValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                row[name] = SQLiteValue(statement: statement, column: index)
            }
            rows.append(row)
        }
        return rows
    }

    func scalarInt(_ sql: String, parameters: [SQLiteValue] = []) throws -> Int {
        try query(sql, parameters: parameters).first?.values.first?.intValue ?? 0
    }

    func columns(in table: String) throws -> Set<String> {
        let rows = try query("PRAGMA table_info(\(table))")
        return Set(rows.compactMap { $0["name"]?.stringValue })
    }

    func checkpoint(mode: String) throws -> CheckpointInfo {
        let rows = try query("PRAGMA wal_checkpoint(\(mode))")
        guard let row = rows.first else {
            return CheckpointInfo(mode: mode, busy: 0, logFrames: 0, checkpointedFrames: 0)
        }
        return CheckpointInfo(
            mode: mode,
            busy: row["busy"]?.intValue ?? 0,
            logFrames: row["log"]?.intValue ?? 0,
            checkpointedFrames: row["checkpointed"]?.intValue ?? 0
        )
    }

    var lastError: String {
        String(cString: sqlite3_errmsg(handle))
    }

    private func executeRaw(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? lastError
            sqlite3_free(error)
            throw CodexHistorySyncError.sqlite(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CodexHistorySyncError.sqlite(lastError)
        }
        return statement
    }

    private func bind(_ parameters: [SQLiteValue], to statement: OpaquePointer) throws {
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case .int(let value):
                result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
            case .text(let value):
                result = sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            }
            guard result == SQLITE_OK else {
                throw CodexHistorySyncError.sqlite(lastError)
            }
        }
    }

    static func backup(from sourcePath: URL, to targetPath: URL) throws {
        let source = try SQLiteDatabase(path: sourcePath, readOnly: true)
        let target = try SQLiteDatabase(path: targetPath, readOnly: false)
        guard let backup = sqlite3_backup_init(target.handle, "main", source.handle, "main") else {
            throw CodexHistorySyncError.sqlite(target.lastError)
        }
        let result = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw CodexHistorySyncError.sqlite(target.lastError)
        }
    }
}

enum SQLiteValue: Equatable {
    case null
    case int(Int)
    case text(String)

    init(statement: OpaquePointer, column: Int32) {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
            self = .int(Int(sqlite3_column_int64(statement, column)))
        case SQLITE_TEXT:
            self = .text(String(cString: sqlite3_column_text(statement, column)))
        default:
            self = .null
        }
    }

    var stringValue: String? {
        switch self {
        case .null:
            return nil
        case .int(let value):
            return String(value)
        case .text(let value):
            return value
        }
    }

    var countKey: String {
        guard let value = stringValue, !value.isEmpty else {
            return "(empty)"
        }
        return value
    }

    var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .text(let value):
            return Int(value)
        case .null:
            return nil
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
