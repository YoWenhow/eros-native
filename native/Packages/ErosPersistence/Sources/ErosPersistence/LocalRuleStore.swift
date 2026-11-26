import Foundation
import ErosCore

/// Account-scoped local preferences, separate from download/gallery storage.
public actor LocalRuleStore {
    private let connection: SQLiteConnection
    public init(url: URL, storageLease: StorageLease? = nil) throws {
        try storageLease?.check()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        connection = try SQLiteConnection(path: url.path, migrations: [Migration(version: 1, statements: [
            "CREATE TABLE local_rules(account TEXT NOT NULL,id TEXT NOT NULL,version INTEGER NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(account,id))"
        ])], storageLease: storageLease)
    }
    public func checkpointAndClose() throws { try connection.checkpointAndClose() }
    public func rules(account: AccountID) throws -> [LocalDisplayRule] {
        try Task.checkCancellation()
        return try connection.rows("SELECT payload,id,version FROM local_rules WHERE account=? ORDER BY id", [.text(account.value.uuidString)]).map { row in
            guard case .blob(let data) = row[0], case .text(let id) = row[1], case .integer(let version) = row[2] else { throw PersistenceError.corruptRecord }
            let value = try JSONDecoder().decode(LocalDisplayRule.self, from: data)
            guard value.account == account, value.id.uuidString == id, value.version == version else { throw PersistenceError.corruptRecord }
            return value
        }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }
    public func save(_ rule: LocalDisplayRule, expectedVersion: Int?) throws {
        try Task.checkCancellation()
        try connection.transaction {
            let key: [SQLValue] = [.text(rule.account.value.uuidString), .text(rule.id.uuidString)]
            let current = try connection.rows("SELECT version FROM local_rules WHERE account=? AND id=?", key).first
            if let expectedVersion {
                guard let current, case .integer(let version) = current[0], version == expectedVersion,
                      expectedVersion < Int.max, rule.version == expectedVersion + 1 else { throw AppError.invalidInput }
            } else {
                guard current == nil, rule.version == 1 else { throw AppError.invalidInput }
            }
            try connection.execute("INSERT INTO local_rules(account,id,version,payload) VALUES (?,?,?,?) ON CONFLICT(account,id) DO UPDATE SET version=excluded.version,payload=excluded.payload",
                                   key + [.integer(Int64(rule.version)), .blob(try JSONEncoder().encode(rule))])
            try Task.checkCancellation()
        }
    }
    public func delete(_ rule: LocalDisplayRule) throws {
        try Task.checkCancellation()
        try connection.transaction {
            let key: [SQLValue] = [.text(rule.account.value.uuidString), .text(rule.id.uuidString)]
            guard let row = try connection.rows("SELECT version FROM local_rules WHERE account=? AND id=?", key).first,
                  case .integer(let version) = row[0], version == rule.version else { throw AppError.invalidInput }
            try connection.execute("DELETE FROM local_rules WHERE account=? AND id=?", key)
            try Task.checkCancellation()
        }
    }
}
