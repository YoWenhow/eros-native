import Foundation
import CSQLite
import ErosCore

public enum PersistenceError: Error, Equatable, Sendable {
    case sqlite(Int32)
    case unsupportedSchema
    case corruptRecord
    case closed
    case checkpointBusy
    case missingGalleryPageCount
}

enum SQLValue { case text(String), integer(Int64), blob(Data), null }
struct Migration: Sendable {
    let version: Int
    let statements: [String]
    let apply: @Sendable (SQLiteConnection) throws -> Void

    init(version: Int, statements: [String], apply: @escaping @Sendable (SQLiteConnection) throws -> Void = { _ in }) {
        self.version = version
        self.statements = statements
        self.apply = apply
    }
}

/// Accessible only from the owning database actor (or isolated temporary-database tests).
/// The wrapper is Sendable solely to permit actor initialization/deinitialization ownership.
final class SQLiteConnection: @unchecked Sendable {
    enum JournalMode { case wal, delete }

    private var handle: OpaquePointer?
    private var storageLease: StorageLease?
    private var inTransaction = false
    #if DEBUG
    var diagnosticStatementCount=0
    var diagnosticSingleGalleryReads=0
    #endif
    private init(path: String, flags: Int32) throws {
        let code = sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK else {
            if let handle { sqlite3_close_v2(handle) }; handle = nil
            throw PersistenceError.sqlite(code)
        }
        sqlite3_busy_timeout(handle, 3000)
    }

    convenience init(path: String, migrations: [Migration] = Schema.migrations, snapshotDirectory: URL? = nil,
                     storageLease: StorageLease? = nil, journalMode: JournalMode = .wal) throws {
        try storageLease?.check()
        try self.init(path: path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        do {
            try execute("PRAGMA foreign_keys=ON")
            if journalMode == .delete { try useDeleteJournal() }
            try migrate(migrations, path: path, snapshotDirectory: snapshotDirectory)
            if journalMode == .wal { try execute("PRAGMA journal_mode=WAL") }
            try execute("PRAGMA synchronous=FULL")
            try storageLease?.check()
            self.storageLease = storageLease
        } catch { close(); throw error }
    }
    deinit { close() }
    func close() { if let handle { sqlite3_close_v2(handle) }; handle = nil }
    private func useDeleteJournal() throws {
        guard let mode = try rows("PRAGMA journal_mode=DELETE").first,
              case .text("delete") = mode[0] else { throw PersistenceError.corruptRecord }
    }

    var acceptsWork: Bool { handle != nil && storageLease?.isActive != false }
    func checkpointAndClose() throws {
        guard let handle else { return }
        let checkpoint = sqlite3_wal_checkpoint_v2(handle, "main", SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        if checkpoint == SQLITE_BUSY || checkpoint == SQLITE_LOCKED { throw PersistenceError.checkpointBusy }
        guard checkpoint == SQLITE_OK else { try fail(checkpoint) }
        let closed = sqlite3_close(handle)
        guard closed == SQLITE_OK else { try fail(closed) }
        self.handle = nil
    }
    private func fail(_ code: Int32) throws -> Never {
        if code & 255 == SQLITE_FULL { throw AppError.storageFull }
        throw PersistenceError.sqlite(code)
    }
    func execute(_ sql: String, _ values: [SQLValue] = []) throws { _ = try rows(sql, values) }
    func rows(_ sql: String, _ values: [SQLValue] = []) throws -> [[SQLValue]] {
        guard let handle else { throw PersistenceError.closed }
        if !inTransaction { try storageLease?.check() }
        #if DEBUG
        diagnosticStatementCount += 1
        if sql.hasPrefix("SELECT payload FROM galleries WHERE") { diagnosticSingleGalleryReads += 1 }
        #endif
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { try fail(code) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_parameter_count(statement) == values.count else { throw AppError.invalidInput }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1), code: Int32
            switch value {
            case .text(let text): code = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            case .integer(let n): code = sqlite3_bind_int64(statement, index, n)
            case .blob(let data): code = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            case .null: code = sqlite3_bind_null(statement, index)
            }
            guard code == SQLITE_OK else { try fail(code) }
        }
        var result: [[SQLValue]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { try fail(step) }
            var row: [SQLValue] = []
            for i in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, i)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(statement, i))))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, i))
                    row.append(.blob(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, i)!, count: count)))
                default: row.append(.null)
                }
            }
            result.append(row)
        }
    }
    func transaction<T>(_ work: () throws -> T) throws -> T {
        try storageLease?.check()
        let alreadyInTransaction = inTransaction
        inTransaction = true
        defer { inTransaction = alreadyInTransaction }
        try execute("BEGIN IMMEDIATE")
        do { let result = try work(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func snapshot(path: String, directory: URL, version: Int) throws {
        let name = "schema-\(version)-\(UUID().uuidString).sqlite"
        // BEGIN IMMEDIATE protects the upgrade; the read handle backs up the committed view.
        try Self.makeSnapshot(from: URL(fileURLWithPath: path), to: directory.appendingPathComponent(name),
                              version: version, backupPolicy: .excluded)
    }

    /// Copy SQLite's committed view, including WAL, into a standalone private file.
    static func makeSnapshot(from input: URL, to published: URL, version: Int,
                             backupPolicy: StorageBackupPolicy? = nil) throws {
        try Task.checkCancellation()
        let files = FileManager.default
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        let directory = published.deletingLastPathComponent()
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
        try backupPolicy?.apply(toDirectory: directory)
        attributes[.posixPermissions] = 0o600
        let partial = published.appendingPathExtension("partial")
        // The name is private to this snapshot. Discard interrupted SQLite scratch files.
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let stale = partial.path + suffix
            do { try files.removeItem(atPath: stale) }
            catch CocoaError.fileNoSuchFile {}
        }
        guard files.createFile(atPath: partial.path, contents: nil, attributes: attributes) else {
            throw AppError.accessDenied
        }
        defer { try? files.removeItem(at: partial) }

        let source = try Self(path: input.path, flags: SQLITE_OPEN_READONLY)
        defer { source.close() }
        let destination = try Self(path: partial.path, flags: SQLITE_OPEN_READWRITE)
        defer { destination.close() }
        guard let copy = sqlite3_backup_init(destination.handle, "main", source.handle, "main") else {
            try destination.fail(sqlite3_errcode(destination.handle))
        }
        let result = sqlite3_backup_step(copy, -1)
        let finish = sqlite3_backup_finish(copy)
        guard result == SQLITE_DONE else { try destination.fail(result) }
        guard finish == SQLITE_OK else { try destination.fail(finish) }

        try destination.useDeleteJournal()
        try destination.checkSnapshot(version: version)
        destination.close()
        try Task.checkCancellation()
        try files.moveItem(at: partial, to: published)
    }

    static func readSnapshot(at url: URL, version: Int) throws -> SQLiteConnection {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw PersistenceError.corruptRecord }
        let snapshot = try Self(path: url.path, flags: SQLITE_OPEN_READONLY)
        try snapshot.checkSnapshot(version: version)
        return snapshot
    }

    static func openForMaintenance(at url: URL, version: Int) throws -> SQLiteConnection {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true else { throw PersistenceError.corruptRecord }
        let database = try Self(path: url.path, flags: SQLITE_OPEN_READWRITE)
        try database.checkSnapshot(version: version)
        try database.execute("PRAGMA foreign_keys=ON")
        try database.execute("PRAGMA synchronous=FULL")
        return database
    }

    private func checkSnapshot(version: Int) throws {
        let integrity = try rows("PRAGMA integrity_check")
        guard integrity.count == 1, case .text("ok") = integrity[0][0],
              try rows("PRAGMA foreign_key_check").isEmpty else { throw PersistenceError.corruptRecord }
        let versions = try rows("SELECT version FROM schema_migrations ORDER BY version")
        guard versions.count == version,
              versions.enumerated().allSatisfy({ index, row in
                  guard case .integer(let actual) = row[0] else { return false }
                  return actual == index + 1
              }) else { throw PersistenceError.unsupportedSchema }
    }

    private func migrate(_ migrations: [Migration], path: String, snapshotDirectory: URL?) throws {
        try transaction {
            let hasVersionTable = try !rows("SELECT 1 FROM sqlite_schema WHERE type='table' AND name='schema_migrations'").isEmpty
            let rows = hasVersionTable ? try rows("SELECT version FROM schema_migrations ORDER BY version") : []
            let versions = try rows.map { row -> Int in
                guard case .integer(let n) = row[0] else { throw PersistenceError.unsupportedSchema }; return Int(n)
            }
            guard migrations.map(\.version) == Array(1...migrations.count), versions == Array(migrations.prefix(versions.count).map(\.version)) else { throw PersistenceError.unsupportedSchema }
            if let snapshotDirectory, let previous = versions.last, previous < migrations.count {
                try snapshot(path: path, directory: snapshotDirectory, version: previous)
            }
            if !hasVersionTable {
                try execute("CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, appliedAt TEXT NOT NULL)")
            }
            for migration in migrations.dropFirst(versions.count) {
                try Task.checkCancellation()
                for sql in migration.statements { try execute(sql) }
                try migration.apply(self)
                try execute("INSERT INTO schema_migrations(version,appliedAt) VALUES (?,?)", [.integer(Int64(migration.version)), .text(ISO8601DateFormatter().string(from: Date()))])
            }
        }
    }
}

enum Schema {
    static let migrations = [Migration(version: 1, statements: [
        "CREATE TABLE galleries(account TEXT NOT NULL, site TEXT NOT NULL CHECK(site IN ('eh','ex')), gid INTEGER NOT NULL CHECK(gid>0), pageCount INTEGER CHECK(pageCount>=0), payload BLOB, PRIMARY KEY(account,site,gid))",
        "CREATE TABLE reading_progress(account TEXT NOT NULL, site TEXT NOT NULL, gid INTEGER NOT NULL, pageIndex INTEGER NOT NULL CHECK(pageIndex>=0), updatedAt TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(account,site,gid), FOREIGN KEY(account,site,gid) REFERENCES galleries(account,site,gid))",
        "CREATE TRIGGER progress_bounds_insert BEFORE INSERT ON reading_progress WHEN NOT EXISTS(SELECT 1 FROM galleries WHERE account=NEW.account AND site=NEW.site AND gid=NEW.gid AND pageCount>NEW.pageIndex) BEGIN SELECT RAISE(ABORT,'page bounds'); END",
        "CREATE TRIGGER progress_bounds_update BEFORE UPDATE ON reading_progress WHEN NOT EXISTS(SELECT 1 FROM galleries WHERE account=NEW.account AND site=NEW.site AND gid=NEW.gid AND pageCount>NEW.pageIndex) BEGIN SELECT RAISE(ABORT,'page bounds'); END",
        "CREATE TRIGGER gallery_bounds_update BEFORE UPDATE OF pageCount ON galleries WHEN EXISTS(SELECT 1 FROM reading_progress WHERE account=NEW.account AND site=NEW.site AND gid=NEW.gid AND (NEW.pageCount IS NULL OR pageIndex>=NEW.pageCount)) BEGIN SELECT RAISE(ABORT,'page bounds'); END",
        "CREATE TABLE local_favorites(account TEXT NOT NULL, site TEXT NOT NULL, gid INTEGER NOT NULL, createdAt TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(account,site,gid), FOREIGN KEY(account,site,gid) REFERENCES galleries(account,site,gid))",
        "CREATE TABLE download_jobs(id TEXT PRIMARY KEY, account TEXT NOT NULL, site TEXT NOT NULL, gid INTEGER NOT NULL, state TEXT NOT NULL, generation TEXT NOT NULL, totalPages INTEGER NOT NULL CHECK(totalPages>=0), payload BLOB NOT NULL, FOREIGN KEY(account,site,gid) REFERENCES galleries(account,site,gid))",
        "CREATE INDEX download_scope ON download_jobs(account,site,state)",
        "CREATE TABLE download_pages(jobID TEXT NOT NULL, pageIndex INTEGER NOT NULL CHECK(pageIndex>=0), state TEXT NOT NULL, relativePath TEXT CHECK(relativePath IS NULL OR (relativePath NOT LIKE '/%' AND instr(relativePath,':')=0 AND relativePath!='..' AND relativePath NOT LIKE '../%' AND relativePath NOT LIKE '%/../%' AND relativePath NOT LIKE '%/..')), byteCount INTEGER CHECK(byteCount>=0), taskID INTEGER CHECK(taskID>=0), payload BLOB NOT NULL, PRIMARY KEY(jobID,pageIndex), FOREIGN KEY(jobID) REFERENCES download_jobs(id) ON DELETE CASCADE)",
        "CREATE TRIGGER download_page_bounds BEFORE INSERT ON download_pages WHEN NOT EXISTS(SELECT 1 FROM download_jobs WHERE id=NEW.jobID AND totalPages>NEW.pageIndex) BEGIN SELECT RAISE(ABORT,'page bounds'); END"
    ]), Migration(version: 2, statements: [
        "CREATE UNIQUE INDEX download_jobs_account_id ON download_jobs(account,id)",
        "CREATE TABLE download_folders(account TEXT NOT NULL, id TEXT NOT NULL, displayName TEXT NOT NULL CHECK(length(displayName)>0), normalizedName TEXT NOT NULL CHECK(length(normalizedName)>0), position INTEGER NOT NULL CHECK(typeof(position)='integer' AND position>=0), createdAtMs INTEGER NOT NULL CHECK(typeof(createdAtMs)='integer'), updatedAtMs INTEGER NOT NULL CHECK(typeof(updatedAtMs)='integer'), revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>0), PRIMARY KEY(account,id), UNIQUE(account,normalizedName))",
        "CREATE TABLE download_library_items(jobID TEXT NOT NULL PRIMARY KEY, account TEXT NOT NULL, folderID TEXT, addedAtMs INTEGER CHECK(addedAtMs IS NULL OR typeof(addedAtMs)='integer'), firstCompletedAtMs INTEGER CHECK(firstCompletedAtMs IS NULL OR typeof(firstCompletedAtMs)='integer'), completionTimePolicy TEXT NOT NULL CHECK(completionTimePolicy IN ('preserveLegacyUnknown','recordFirstObserved')), completionTimeOrigin TEXT NOT NULL CHECK(completionTimeOrigin IN ('unknown','nativeObserved')), metadataState TEXT NOT NULL CHECK(metadataState IN ('unknown','complete')), artistsPayload BLOB NOT NULL CHECK(typeof(artistsPayload)='blob'), groupsPayload BLOB NOT NULL CHECK(typeof(groupsPayload)='blob'), metadataSite TEXT CHECK(metadataSite IS NULL OR metadataSite IN ('eh','ex')), metadataFetchedAtMs INTEGER CHECK(metadataFetchedAtMs IS NULL OR typeof(metadataFetchedAtMs)='integer'), membershipRevision INTEGER NOT NULL CHECK(typeof(membershipRevision)='integer' AND membershipRevision>0), metadataRevision INTEGER NOT NULL CHECK(typeof(metadataRevision)='integer' AND metadataRevision>0), FOREIGN KEY(account,jobID) REFERENCES download_jobs(account,id) ON DELETE CASCADE, FOREIGN KEY(account,folderID) REFERENCES download_folders(account,id) ON DELETE RESTRICT, CHECK((firstCompletedAtMs IS NULL AND completionTimeOrigin='unknown') OR (firstCompletedAtMs IS NOT NULL AND completionTimeOrigin='nativeObserved')), CHECK(completionTimePolicy!='preserveLegacyUnknown' OR firstCompletedAtMs IS NULL), CHECK((metadataState='unknown' AND metadataSite IS NULL AND metadataFetchedAtMs IS NULL AND artistsPayload=CAST('{\"version\":1,\"values\":[]}' AS BLOB) AND groupsPayload=CAST('{\"version\":1,\"values\":[]}' AS BLOB)) OR (metadataState='complete' AND metadataSite IS NOT NULL AND metadataFetchedAtMs IS NOT NULL)))",
        "CREATE TABLE download_library_view_preferences(account TEXT NOT NULL, targetKey TEXT NOT NULL CHECK(targetKey IN ('all','unfiled') OR (length(targetKey)=43 AND substr(targetKey,1,7)='folder:' AND substr(targetKey,16,1)='-' AND substr(targetKey,21,1)='-' AND substr(targetKey,26,1)='-' AND substr(targetKey,31,1)='-' AND length(replace(substr(targetKey,8),'-',''))=32 AND replace(substr(targetKey,8),'-','') NOT GLOB '*[^0-9A-F]*')), sortField TEXT NOT NULL CHECK(sortField IN ('artist','group','addedAt')), direction TEXT NOT NULL CHECK(direction IN ('ascending','descending')), PRIMARY KEY(account,targetKey))",
        "CREATE TABLE download_library_settings(account TEXT NOT NULL PRIMARY KEY, defaultFolderID TEXT, FOREIGN KEY(account,defaultFolderID) REFERENCES download_folders(account,id) ON DELETE RESTRICT)",
        "CREATE INDEX download_library_folder ON download_library_items(account,folderID)",
        "CREATE INDEX download_library_added ON download_library_items(account,addedAtMs,jobID)",
        "CREATE INDEX download_folder_position ON download_folders(account,position,id)",
        "INSERT INTO download_library_items(jobID,account,folderID,addedAtMs,firstCompletedAtMs,completionTimePolicy,completionTimeOrigin,metadataState,artistsPayload,groupsPayload,metadataSite,metadataFetchedAtMs,membershipRevision,metadataRevision) SELECT id,account,NULL,NULL,NULL,CASE WHEN state='completed' THEN 'preserveLegacyUnknown' ELSE 'recordFirstObserved' END,'unknown','unknown',CAST('{\"version\":1,\"values\":[]}' AS BLOB),CAST('{\"version\":1,\"values\":[]}' AS BLOB),NULL,NULL,1,1 FROM download_jobs"
    ]), Migration(version: 3, statements: [
        "ALTER TABLE download_jobs ADD COLUMN sourceKind TEXT NOT NULL DEFAULT 'pages' CHECK(sourceKind IN ('pages','archive'))",
        "ALTER TABLE download_jobs ADD COLUMN variant TEXT NOT NULL DEFAULT 'display' CHECK(variant IN ('display','original'))",
        "CREATE INDEX download_content_identity ON download_jobs(account,gid,sourceKind,variant,id)",
        "CREATE TRIGGER download_identity_immutable BEFORE UPDATE OF account,site,gid,sourceKind,variant ON download_jobs WHEN OLD.account!=NEW.account OR OLD.site!=NEW.site OR OLD.gid!=NEW.gid OR OLD.sourceKind!=NEW.sourceKind OR OLD.variant!=NEW.variant BEGIN SELECT RAISE(ABORT,'immutable download identity'); END"
    ])]
}
