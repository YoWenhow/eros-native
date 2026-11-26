#if DEBUG
import Foundation
import SQLite3

@MainActor
enum ProbeSQLite {
    static func run(allowCreate: Bool) {
        let store = ProbeStore.shared
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("T07Diagnostics/probe.sqlite").path
        let existed = FileManager.default.fileExists(atPath: path)
        guard allowCreate || existed else {
            store.mark("SQLite", "NOT_RUN", "尚无测试库；请先点击写入检查")
            return
        }
        var database: OpaquePointer?
        let flags = allowCreate ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
        let code = sqlite3_open_v2(path, &database, flags, nil)
        defer { if let database { sqlite3_close(database) } }
        guard code == SQLITE_OK, let database else {
            store.mark("SQLite", "FAIL", "打开数据库 code=\(code)")
            return
        }
        if allowCreate {
            let sql = "CREATE TABLE IF NOT EXISTS probe (id INTEGER PRIMARY KEY CHECK(id=1), value TEXT NOT NULL); INSERT OR IGNORE INTO probe(id,value) VALUES(1,'t07-sqlite-v1');"
            let write = sqlite3_exec(database, sql, nil, nil, nil)
            guard write == SQLITE_OK else {
                store.mark("SQLite", "FAIL", "建表/写入 code=\(write)")
                return
            }
        }
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(database, "SELECT value FROM probe WHERE id=1", -1, &statement, nil)
        defer { if let statement { sqlite3_finalize(statement) } }
        guard prepare == SQLITE_OK, let statement else {
            store.mark("SQLite", "FAIL", "查询准备 code=\(prepare)")
            return
        }
        let step = sqlite3_step(statement)
        let bytes = step == SQLITE_ROW ? sqlite3_column_text(statement, 0) : nil
        let value = bytes.map { String(cString: $0) }
        let valid = value == "t07-sqlite-v1"
        store.mark("SQLite", valid ? "PASS" : "FAIL", "\(allowCreate ? "写入检查（不覆盖已有行）" : "只读已有库，未写入")；step=\(step)，匹配=\(valid)；SQLite \(String(cString: sqlite3_libversion()))")
    }
}
#endif
