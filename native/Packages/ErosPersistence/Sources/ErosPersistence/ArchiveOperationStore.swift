import Foundation
import ErosCore

/// Separate journal; does not migrate the existing download database or persist live server credentials.
public actor ArchiveOperationStore {
    private let connection: SQLiteConnection
    public init(url: URL, storageLease: StorageLease? = nil) throws {
        try storageLease?.check()
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        connection = try SQLiteConnection(path:url.path,migrations:[Migration(version:1,statements:[
            "CREATE TABLE archive_operations(owner TEXT NOT NULL,gallery INTEGER NOT NULL,variant TEXT NOT NULL,id TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(owner,gallery,variant),UNIQUE(id))"
        ])], storageLease: storageLease)
    }
    public func checkpointAndClose() throws { try connection.checkpointAndClose() }
    public func operation(key: DownloadContentKey) throws -> ArchiveOperation? {
        guard key.sourceKind == .archive else { throw AppError.invalidInput }
        guard let row=try connection.rows("SELECT payload FROM archive_operations WHERE owner=? AND gallery=? AND variant=?",
            [.text(key.account.value.uuidString),.integer(key.gallery.value),.text(key.variant.rawValue)]).first else { return nil }
        guard case .blob(let data)=row[0] else { throw PersistenceError.corruptRecord }
        let op=try JSONDecoder().decode(ArchiveOperation.self,from:data)
        guard op.contentKey == key else { throw PersistenceError.corruptRecord }
        return op
    }
    /// Duplicate requests reuse the same permanent operation, even after a local cancellation.
    /// A cancelled possibly-paid operation is never silently replaced by a new purchase.
    public func insert(_ operation: ArchiveOperation) throws -> ArchiveOperation {
        guard operation.state == .idle, !operation.purchaseAttempted else { throw AppError.invalidInput }
        try Task.checkCancellation()
        return try connection.transaction {
            if let existing=try self.operation(key:operation.contentKey) { return existing }
            try connection.execute("INSERT INTO archive_operations(owner,gallery,variant,id,payload) VALUES(?,?,?,?,?)",
                [.text(operation.owner.value.uuidString),.integer(operation.gallery.value),.text(operation.variant.rawValue),
                 .text(operation.id.uuidString),.blob(try JSONEncoder().encode(operation))])
            return operation
        }
    }
    /// Compare-and-swap prevents a stale view or parallel request overwriting the creating journal.
    public func replace(_ updated: ArchiveOperation, expected: ArchiveOperation) throws {
        guard updated.id == expected.id, updated.contentKey == expected.contentKey, updated.addedAt == expected.addedAt,
              !expected.purchaseAttempted || updated.purchaseAttempted else { throw AppError.invalidInput }
        try Task.checkCancellation()
        try connection.transaction {
            guard try operation(key:expected.contentKey) == expected else { throw AppError.staleSession }
            try connection.execute("UPDATE archive_operations SET payload=? WHERE id=? AND owner=?",
                [.blob(try JSONEncoder().encode(updated)),.text(updated.id.uuidString),.text(updated.owner.value.uuidString)])
        }
    }
}
