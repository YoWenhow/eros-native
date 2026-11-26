import Foundation
import ErosCore

public actor ImageBlockStore {
    private let connection: SQLiteConnection
    public init(url: URL, storageLease: StorageLease? = nil) throws {
        try storageLease?.check()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        connection = try SQLiteConnection(path: url.path, migrations: [Migration(version: 1, statements: [
            "CREATE TABLE image_blocks(owner TEXT NOT NULL,digest TEXT NOT NULL,id TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(owner,digest))"
        ])], storageLease: storageLease)
    }
    public func checkpointAndClose() throws { try connection.checkpointAndClose() }
    public func entries(owner: AccountID) throws -> [BlockImageEntry] {
        try connection.rows("SELECT payload,id,digest FROM image_blocks WHERE owner=? ORDER BY id", [.text(owner.value.uuidString)]).map {
            try decode($0, owner: owner)
        }.sorted { $0.createdAt > $1.createdAt }
    }
    public func match(digest: String, owner: AccountID) throws -> BlockImageEntry? {
        guard let row = try connection.rows("SELECT payload,id,digest FROM image_blocks WHERE owner=? AND digest=?",
            [.text(owner.value.uuidString), .text(digest)]).first else { return nil }
        return try decode(row, owner: owner)
    }
    public func insert(_ entry: BlockImageEntry) throws -> BlockImageEntry {
        try Task.checkCancellation()
        return try connection.transaction {
            try connection.execute("INSERT INTO image_blocks(owner,digest,id,payload) VALUES (?,?,?,?) ON CONFLICT(owner,digest) DO NOTHING",
                [.text(entry.owner.value.uuidString), .text(entry.digest), .text(entry.id.uuidString), .blob(try JSONEncoder().encode(entry))])
            try Task.checkCancellation()
            guard let result = try match(digest: entry.digest, owner: entry.owner) else { throw PersistenceError.corruptRecord }
            return result
        }
    }
    public func remove(_ entry: BlockImageEntry, owner: AccountID) throws {
        guard entry.owner == owner else { throw AppError.scopeMismatch }
        try Task.checkCancellation()
        try connection.transaction {
            try connection.execute("DELETE FROM image_blocks WHERE owner=? AND digest=? AND id=?",
                [.text(owner.value.uuidString), .text(entry.digest), .text(entry.id.uuidString)])
            try Task.checkCancellation()
        }
    }
    private func decode(_ row: [SQLValue], owner: AccountID) throws -> BlockImageEntry {
        guard case .blob(let data) = row[0], case .text(let id) = row[1], case .text(let digest) = row[2] else { throw PersistenceError.corruptRecord }
        let entry = try JSONDecoder().decode(BlockImageEntry.self, from: data)
        guard entry.owner == owner, entry.id.uuidString == id, entry.digest == digest else { throw PersistenceError.corruptRecord }
        return entry
    }
}
