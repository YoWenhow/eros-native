import Foundation
import XCTest
import ErosCore
@testable import ErosPersistence

@MainActor final class DownloadLibraryMigrationTests: XCTestCase {
    var directory: URL!
    var url: URL { directory.appendingPathComponent("synthetic.sqlite") }
    let tables = ["galleries", "reading_progress", "local_favorites", "download_jobs", "download_pages"]
    let libraryTables = ["download_folders", "download_library_items", "download_library_view_preferences", "download_library_settings"]
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("D03-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try FileManager.default.removeItem(at: directory) }
    func serialized(_ rows: [[SQLValue]]) -> [[String]] {
        rows.map { $0.map { value in
            switch value {
            case .text(let s): "text:" + s
            case .integer(let n): "integer:\(n)"
            case .blob(let d): "blob:" + d.base64EncodedString()
            case .null: "null"
            }
        } }
    }
    func oldRows(_ db: SQLiteConnection) throws -> [[[String]]] {
        try tables.map { table in
            // Compare every PREEXISTING column byte-for-byte; schema 3 adds two scalar columns.
            let columns = table == "download_jobs" ? "id,account,site,gid,state,generation,totalPages,payload" : "*"
            return serialized(try db.rows("SELECT \(columns) FROM \(table) ORDER BY 1,2,3"))
        }
    }
    func folder(_ db: SQLiteConnection, account: String, id: String, name: String = "folder") throws {
        try db.execute("INSERT INTO download_folders(account,id,displayName,normalizedName,position,createdAtMs,updatedAtMs,revision) VALUES(?,?,?,?,0,100,100,1)", [.text(account), .text(id), .text(name), .text(name)])
    }

    func testD13MigratedV1CompletedPagesRemainReadableAfterReopen() async throws {
        let fixture=try D01V1Fixture.create(at:url)
        let sample=try XCTUnwrap(fixture.jobs.first { $0.job.state == .completed })
        for page in sample.pages {
            let path=try XCTUnwrap(page.relativePath)
            let file=directory.appendingPathComponent(path.value)
            try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data("page".utf8).write(to:file)
        }
        let migrated=try SQLiteDatabase(url:url)
        await migrated.close()
        let reopened=try SQLiteDatabase(url:url)
        let items=try await reopened.listItems(target:.all,account:sample.job.scope.accountID)
        let item=try XCTUnwrap(items.first{$0.jobID == sample.job.id})
        XCTAssertNil(item.addedAt);XCTAssertNil(item.firstCompletedAt);XCTAssertNil(item.folderID)
        XCTAssertEqual(item.metadata.state,.unknown)
        for page in sample.pages {
            let stored=try await reopened.completedReaderPage(galleryID:sample.job.reference.key.galleryID,index:page.index,scope:sample.job.scope)
            let path=try XCTUnwrap(stored?.relativePath)
            XCTAssertEqual(path,page.relativePath)
            XCTAssertEqual(try Data(contentsOf:directory.appendingPathComponent(path.value)),Data("page".utf8))
        }
        await reopened.close()
    }
    func testV1DefinitionIsFrozenAndPopulatedMigrationPreservesEveryOldColumn() throws {
        XCTAssertEqual(Schema.migrations[0].statements, FrozenD01Schema.migrations[0].statements)
        _ = try D01V1Fixture.create(at: url)
        let old = try SQLiteConnection(path: url.path, migrations: FrozenD01Schema.migrations)
        let before = try oldRows(old); old.close()
        let db = try SQLiteConnection(path: url.path)
        XCTAssertEqual(try oldRows(db), before)
        XCTAssertEqual(serialized(try db.rows("SELECT version FROM schema_migrations ORDER BY version")), Schema.migrations.map { ["integer:\($0.version)"] })
        XCTAssertEqual(try db.rows("SELECT * FROM download_library_items").count, 36)
        XCTAssertEqual(try db.rows("SELECT * FROM download_library_items WHERE completionTimePolicy='preserveLegacyUnknown'").count, 4)
        XCTAssertEqual(try db.rows("SELECT * FROM download_library_items WHERE completionTimePolicy='recordFirstObserved'").count, 32)
        XCTAssertEqual(try db.rows("SELECT * FROM download_library_items WHERE folderID IS NULL AND addedAtMs IS NULL AND firstCompletedAtMs IS NULL AND completionTimeOrigin='unknown' AND metadataState='unknown' AND metadataSite IS NULL AND metadataFetchedAtMs IS NULL AND membershipRevision=1 AND metadataRevision=1").count, 36)
        for row in try db.rows("SELECT artistsPayload,groupsPayload FROM download_library_items") {
            for column in row {
                guard case .blob(let bytes) = column else { return XCTFail("Expected versioned JSON BLOB") }
                let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                XCTAssertEqual(object["version"] as? Int, 1)
                XCTAssertEqual(object["values"] as? [String], [])
            }
        }
        XCTAssertTrue(try db.rows("PRAGMA foreign_key_check").isEmpty)
        // Both sites and identical gids across accounts survived, with no new account/gid uniqueness.
        XCTAssertEqual(try db.rows("SELECT * FROM download_jobs WHERE gid=100").count, 4)
        db.close()
    }
    func testFreshDatabaseAndEmptyV1ReachCurrentSchema() throws {
        for name in ["fresh.sqlite", "empty-v1.sqlite"] {
            let path = directory.appendingPathComponent(name)
            if name.hasPrefix("empty") { _ = try D01V1Fixture.create(at: path, empty: true) }
            let db = try SQLiteConnection(path: path.path)
            XCTAssertEqual(serialized(try db.rows("SELECT MAX(version) FROM schema_migrations")), [["integer:\(Schema.migrations.count)"]])
            for table in libraryTables { XCTAssertTrue(try db.rows("SELECT * FROM \(table)").isEmpty) }
            db.close()
        }
    }
    func testReopeningDoesNotRefillOrOverwriteLibraryEdits() throws {
        let fixture = try D01V1Fixture.create(at: url), job = fixture.jobs[0].job
        let account = job.scope.accountID.value.uuidString, id = UUID().uuidString
        let db = try SQLiteConnection(path: url.path)
        try folder(db, account: account, id: id)
        try db.execute("UPDATE download_library_items SET folderID=?,addedAtMs=123,membershipRevision=2 WHERE jobID=?", [.text(id),.text(job.id.uuidString)])
        let before = serialized(try db.rows("SELECT * FROM download_library_items ORDER BY jobID"))
        db.close()
        for _ in 0..<2 {
            let reopened = try SQLiteConnection(path: url.path)
            XCTAssertEqual(serialized(try reopened.rows("SELECT * FROM download_library_items ORDER BY jobID")), before)
            XCTAssertEqual(try reopened.rows("SELECT version FROM schema_migrations").count, Schema.migrations.count)
            reopened.close()
        }
    }
    func testBrokenSQLAfterBackfillRollsBackToReadableV1() throws {
        _ = try D01V1Fixture.create(at: url)
        let old = try SQLiteConnection(path: url.path, migrations: FrozenD01Schema.migrations)
        let before = try oldRows(old); old.close()
        let bad = [Schema.migrations[0], Migration(version: 2, statements: Schema.migrations[1].statements + ["INSERT INTO missing_d03_table VALUES(1)"])]
        XCTAssertThrowsError(try SQLiteConnection(path: url.path, migrations: bad))
        let retained = try SQLiteConnection(path: url.path, migrations: FrozenD01Schema.migrations)
        XCTAssertEqual(try oldRows(retained), before)
        XCTAssertEqual(try retained.rows("SELECT version FROM schema_migrations").count, 1)
        for table in libraryTables { XCTAssertTrue(try retained.rows("SELECT name FROM sqlite_master WHERE name=?", [.text(table)]).isEmpty) }
        XCTAssertTrue(try retained.rows("SELECT name FROM sqlite_master WHERE name='download_jobs_account_id'").isEmpty)
        retained.close()
        let retry = try SQLiteConnection(path: url.path); XCTAssertEqual(try retry.rows("SELECT * FROM download_library_items").count, 36); retry.close()
    }
    func testSQLiteFullDuringMigrationRollsBackWithoutFillingDisk() throws {
        _ = try D01V1Fixture.create(at: url)
        let old = try SQLiteConnection(path: url.path, migrations: FrozenD01Schema.migrations)
        let before = try oldRows(old)
        guard case .integer(let count) = try old.rows("PRAGMA page_count")[0][0] else { return XCTFail() }
        old.close()
        // SQLite connection page quota only: at most ~1 MiB attempted; never fill user disk.
        let bounded = [Schema.migrations[0], Migration(version: 2, statements:
            ["PRAGMA max_page_count=\(count + 32)"] + Schema.migrations[1].statements +
            ["CREATE TABLE d03_space_probe(bytes BLOB)", "INSERT INTO d03_space_probe VALUES(zeroblob(1048576))"])]
        XCTAssertThrowsError(try SQLiteConnection(path: url.path, migrations: bounded)) { XCTAssertEqual($0 as? AppError, .storageFull) }
        let retained = try SQLiteConnection(path: url.path, migrations: FrozenD01Schema.migrations)
        XCTAssertEqual(try oldRows(retained), before)
        XCTAssertEqual(try retained.rows("SELECT version FROM schema_migrations").count, 1)
        for name in libraryTables + ["d03_space_probe"] { XCTAssertTrue(try retained.rows("SELECT name FROM sqlite_master WHERE name=?", [.text(name)]).isEmpty) }
        retained.close()
        let retry = try SQLiteConnection(path: url.path); XCTAssertEqual(try retry.rows("SELECT * FROM download_library_items").count, 36); retry.close()
    }
    func testCompositeOwnershipForeignKeysRestrictFoldersAndCascadeJobs() throws {
        let fixture = try D01V1Fixture.create(at: url)
        let first = fixture.jobs[0].job
        let account = first.scope.accountID.value.uuidString
        let other = D01V1Fixture.scopes.first { $0.accountID != first.scope.accountID }!.accountID.value.uuidString
        let id = UUID().uuidString, otherID = UUID().uuidString
        let db = try SQLiteConnection(path: url.path)
        try folder(db, account: account, id: id)
        try folder(db, account: other, id: otherID) // same normalized name allowed in another owner
        XCTAssertThrowsError(try folder(db, account: account, id: UUID().uuidString))
        XCTAssertThrowsError(try db.execute("UPDATE download_library_items SET account=? WHERE jobID=?", [.text(other), .text(first.id.uuidString)]))
        XCTAssertThrowsError(try db.execute("UPDATE download_library_items SET folderID=? WHERE jobID=?", [.text(otherID), .text(first.id.uuidString)]))
        try db.execute("UPDATE download_library_items SET folderID=? WHERE jobID=?", [.text(id),.text(first.id.uuidString)])
        XCTAssertThrowsError(try db.execute("DELETE FROM download_folders WHERE account=? AND id=?", [.text(account),.text(id)]))
        XCTAssertThrowsError(try db.execute("INSERT INTO download_library_settings VALUES(?,?)", [.text(account),.text(otherID)]))
        try db.execute("INSERT INTO download_library_settings VALUES(?,?)", [.text(account),.text(id)])
        // Explicit unfile before deleting a folder; neither account column becomes NULL.
        try db.transaction {
            try db.execute("UPDATE download_library_items SET folderID=NULL WHERE account=?", [.text(account)])
            try db.execute("UPDATE download_library_settings SET defaultFolderID=NULL WHERE account=?", [.text(account)])
            try db.execute("DELETE FROM download_folders WHERE account=? AND id=?", [.text(account),.text(id)])
        }
        XCTAssertEqual(try db.rows("SELECT * FROM download_jobs").count, 36)
        try db.execute("DELETE FROM download_jobs WHERE id=?", [.text(first.id.uuidString)])
        XCTAssertTrue(try db.rows("SELECT * FROM download_library_items WHERE jobID=?", [.text(first.id.uuidString)]).isEmpty)
        XCTAssertTrue(try db.rows("SELECT * FROM download_pages WHERE jobID=?", [.text(first.id.uuidString)]).isEmpty)
        XCTAssertTrue(try db.rows("PRAGMA foreign_key_check").isEmpty); db.close()
    }
    func testRequiredFieldsEnumsTimeMetadataAndTargetConstraints() throws {
        _ = try D01V1Fixture.create(at: url)
        let db = try SQLiteConnection(path: url.path)
        for statement in [
            "UPDATE download_library_items SET account=NULL", "UPDATE download_library_items SET jobID=NULL",
            "UPDATE download_library_items SET membershipRevision=0", "UPDATE download_library_items SET metadataRevision=-1",
            "UPDATE download_library_items SET membershipRevision=1.5", "UPDATE download_library_items SET addedAtMs='bad'",
            "UPDATE download_library_items SET completionTimeOrigin='other'", "UPDATE download_library_items SET completionTimePolicy='other'",
            "UPDATE download_library_items SET firstCompletedAtMs=123", "UPDATE download_library_items SET completionTimeOrigin='nativeObserved'",
            "UPDATE download_library_items SET firstCompletedAtMs=123,completionTimeOrigin='nativeObserved' WHERE completionTimePolicy='preserveLegacyUnknown'",
            "UPDATE download_library_items SET metadataState='other'", "UPDATE download_library_items SET metadataState='complete'",
            "UPDATE download_library_items SET artistsPayload=NULL", "UPDATE download_library_items SET artistsPayload='[]'",
            "UPDATE download_library_items SET metadataSite='wrong'", "UPDATE download_library_items SET metadataFetchedAtMs=123"
        ] { XCTAssertThrowsError(try db.execute(statement), statement) }
        try db.execute("UPDATE download_library_items SET firstCompletedAtMs=123,completionTimeOrigin='nativeObserved' WHERE completionTimePolicy='recordFirstObserved'")
        try db.execute("UPDATE download_library_items SET metadataState='complete',metadataSite='eh',metadataFetchedAtMs=0")
        for key in ["all", "unfiled", "folder:" + UUID().uuidString] {
            try db.execute("INSERT INTO download_library_view_preferences VALUES('owner',?,'artist','ascending')", [.text(key)])
        }
        for key in ["", "folder:bad", "folder:" + String(repeating: "Z", count: 36)] {
            XCTAssertThrowsError(try db.execute("INSERT INTO download_library_view_preferences VALUES('owner',?,'artist','ascending')", [.text(key)]))
        }
        XCTAssertThrowsError(try db.execute("UPDATE download_library_view_preferences SET direction='bad'"))
        XCTAssertThrowsError(try db.execute("UPDATE download_library_view_preferences SET sortField='bad'"))
        XCTAssertThrowsError(try db.execute("UPDATE download_library_view_preferences SET account=NULL"))
        XCTAssertThrowsError(try db.execute("INSERT INTO download_library_settings VALUES(NULL,NULL)"))
        XCTAssertThrowsError(try folder(db, account: "owner", id: "test", name: ""))
        db.close()
    }
    func testFutureSchemaAndOldAppRefusalPreserveClosedDatabaseBytes() throws {
        _ = try D01V1Fixture.create(at: url)
        let current = try SQLiteConnection(path: url.path); current.close()
        let v2Bytes = try Data(contentsOf: url)
        XCTAssertThrowsError(try SQLiteConnection(path: url.path, migrations: FrozenD01Schema.migrations)) { XCTAssertEqual($0 as? PersistenceError, .unsupportedSchema) }
        XCTAssertEqual(try Data(contentsOf: url), v2Bytes)
        let future = try SQLiteConnection(path: url.path, migrations: Schema.migrations + [Migration(version: Schema.migrations.count + 1, statements: ["CREATE TABLE future_sentinel(value TEXT)", "INSERT INTO future_sentinel VALUES('keep')"])])
        future.close()
        let bytes = try Data(contentsOf: url)
        XCTAssertThrowsError(try SQLiteConnection(path: url.path)) { XCTAssertEqual($0 as? PersistenceError, .unsupportedSchema) }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let reopened = try SQLiteConnection(path: url.path, migrations: Schema.migrations + [Migration(version: Schema.migrations.count + 1, statements: [])])
        XCTAssertEqual(serialized(try reopened.rows("SELECT value FROM future_sentinel")), [["text:keep"]]); reopened.close()
    }
}
