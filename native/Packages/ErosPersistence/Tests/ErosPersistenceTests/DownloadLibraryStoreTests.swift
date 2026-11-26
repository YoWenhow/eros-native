import Foundation
import XCTest
import ErosCore
@testable import ErosPersistence

@MainActor final class DownloadLibraryStoreTests: XCTestCase {
    var directory: URL!
    var url: URL { directory.appendingPathComponent("synthetic.sqlite") }
    var db: SQLiteDatabase!
    var fixture: D01V1Fixture.Expected!
    let account = D01V1Fixture.scopes[0].accountID
    let other = D01V1Fixture.scopes[2].accountID
    let one = try! DownloadLibraryRevision(1)
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("D04-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fixture = try D01V1Fixture.create(at: url)
        db = try SQLiteDatabase(url: url, libraryNow: { DownloadLibraryTimestamp(1234) })
    }
    override func tearDown() async throws { await db.close(); try FileManager.default.removeItem(at: directory) }
    func fails(_ error: DownloadLibraryError, _ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Expected \(error)") } catch let actual { XCTAssertEqual(actual as? DownloadLibraryError, error) }
    }
    func raw(_ work: (SQLiteConnection) throws -> Void) throws {
        let connection = try SQLiteConnection(path: url.path); defer { connection.close() }; try work(connection)
    }
    func testGalleryDownloadStateReadsScalarStateWithAccountIsolation() async throws {
        let job=try XCTUnwrap(fixture.jobs.first{$0.job.scope.accountID == account}).job
        let value=try await db.galleryDownloadState(galleryID:job.reference.key.galleryID,account:account)
        XCTAssertNotNil(value)
        let missing=try await db.galleryDownloadState(galleryID:job.reference.key.galleryID,account:AccountID(UUID()))
        XCTAssertNil(missing)
        try raw { connection in
            try connection.execute("UPDATE download_jobs SET state='paused' WHERE account=? AND gid=?",[.text(account.value.uuidString),.integer(job.reference.key.galleryID.value)])
        }
        let updated=try await db.galleryDownloadState(galleryID:job.reference.key.galleryID,account:account)
        XCTAssertEqual(updated,.paused)
    }
    func testFoldersNamesOrderCASAndEmptyGroups() async throws {
        let store: any DownloadLibraryStore = db
        let a = try await store.createFolder(name: DownloadFolderName(" Alpha "), account: account)
        let b = try await store.createFolder(name: DownloadFolderName("Beta"), account: account)
        XCTAssertEqual(a.createdAt.value, 1234); XCTAssertEqual(b.position.value, 1)
        let empty = try await store.listItems(target: .folder(a.id), account: account); XCTAssertTrue(empty.isEmpty)
        _ = try await store.createFolder(name: DownloadFolderName("alpha"), account: other)
        await fails(.duplicateFolderName) { _ = try await store.createFolder(name: DownloadFolderName("ALPHA"), account: self.account) }
        await fails(.duplicateFolderName) { try await store.renameFolder(id: b.id, name: DownloadFolderName("alpha"), expectedRevision: self.one, account: self.account) }
        await fails(.conflict) { try await store.reorderFolders(ids: [a.id,a.id], account: self.account) }
        await fails(.conflict) { try await store.reorderFolders(ids: [a.id], account: self.account) }
        try await store.reorderFolders(ids: [b.id,a.id], account: account)
        let ordered = try await store.listFolders(account: account)
        XCTAssertEqual(ordered.map(\.id), [b.id,a.id]); XCTAssertEqual(ordered.map(\.position.value), [0,1])
        await fails(.conflict) { try await store.renameFolder(id: a.id, name: DownloadFolderName("new"), expectedRevision: self.one, account: self.account) }
        try await store.renameFolder(id: a.id, name: DownloadFolderName("new"), expectedRevision: ordered[1].revision, account: account)
        let renamed = try await store.listFolders(account: account)
        XCTAssertEqual(renamed[1].displayName.value,"new"); XCTAssertEqual(renamed[1].revision.value,3)
    }
    func testEveryForeignFolderOperationAndForeignJobsAreRejected() async throws {
        let folder = try await db.createFolder(name: DownloadFolderName("private"), account: other)
        let foreignJob = fixture.jobs.first { $0.job.scope.accountID == other }!.job.id
        await fails(.folderNotFound) { try await self.db.renameFolder(id: folder.id, name: DownloadFolderName("bad"), expectedRevision: self.one, account: self.account) }
        await fails(.folderNotFound) { try await self.db.deleteFolderAndUnfile(id: folder.id, expectedRevision: self.one, account: self.account) }
        await fails(.folderNotFound) { _ = try await self.db.listItems(target: .folder(folder.id), account: self.account) }
        await fails(.folderNotFound) { _ = try await self.db.loadSort(target: .folder(folder.id), account: self.account) }
        await fails(.folderNotFound) { try await self.db.saveSort(target: .folder(folder.id), sort: DownloadSort(), account: self.account) }
        await fails(.folderNotFound) { try await self.db.saveDefaultFolder(folderID: folder.id, account: self.account) }
        await fails(.folderNotFound) { try await self.db.moveItems(expectedMembershipRevisions: [self.fixture.jobs[0].job.id:self.one], destinationFolderID: folder.id, account: self.account) }
        await fails(.conflict) { try await self.db.reorderFolders(ids: [folder.id], account: self.account) }
        await fails(.jobNotFound) { try await self.db.moveItems(expectedMembershipRevisions: [foreignJob:self.one], destinationFolderID: nil, account: self.account) }
        await fails(.jobNotFound) { try await self.db.updateMetadata(jobID: foreignJob, metadata: .unknown, expectedMetadataRevision: self.one, account: self.account) }
        let local = try await db.listFolders(account: account); XCTAssertTrue(local.isEmpty)
        let defaults = try await db.loadDefaultFolder(account: account); XCTAssertNil(defaults)
    }
    func testMovingToSameFolderDoesNotAdvanceMembershipRevision() async throws {
        let items=try await db.listItems(target:.all,account:account)
        let item=try XCTUnwrap(items.first)
        try await db.moveItems(expectedMembershipRevisions:[item.jobID:item.membershipRevision],destinationFolderID:nil,account:account)
        let unchanged=try await db.listItems(target:.all,account:account)
        XCTAssertEqual(unchanged,items)
        let folder=try await db.createFolder(name:DownloadFolderName("same"),account:account)
        try await db.moveItems(expectedMembershipRevisions:[item.jobID:item.membershipRevision],destinationFolderID:folder.id,account:account)
        let moved=try await db.listItems(target:.folder(folder.id),account:account)
        let current=try XCTUnwrap(moved.first)
        for _ in 0..<2 { try await db.moveItems(expectedMembershipRevisions:[current.jobID:current.membershipRevision],destinationFolderID:folder.id,account:account) }
        let after=try await db.listItems(target:.folder(folder.id),account:account)
        XCTAssertEqual(after,moved)
    }
    func testMoveMetadataAndProgressHaveIndependentRevisions() async throws {
        let folder = try await db.createFolder(name: DownloadFolderName("folder"), account: account)
        let snapshots = fixture.jobs.filter { $0.job.scope.accountID == account }
        let ids = [snapshots[0].job.id,snapshots[9].job.id] // EH and EX, same account
        try await db.moveItems(expectedMembershipRevisions: Dictionary(uniqueKeysWithValues: ids.map { ($0,one) }), destinationFolderID: folder.id, account: account)
        let metadata = try DownloadLibraryMetadata(artists: ["作者"], groups: [], state: .complete, sourceSite: .ex, fetchedAt: DownloadLibraryTimestamp(-2))
        try await db.updateMetadata(jobID: ids[0], metadata: metadata, expectedMetadataRevision: one, account: account)
        try await db.saveDownload(snapshots[0])
        let moved = try await db.listItems(target: .folder(folder.id), account: account)
        XCTAssertEqual(moved.count,2); XCTAssertEqual(moved[0].metadata,metadata)
        XCTAssertEqual(moved[0].membershipRevision.value,2); XCTAssertEqual(moved[0].metadataRevision.value,2)
        XCTAssertEqual(moved[1].metadataRevision.value,1)
        await fails(.conflict) { try await self.db.updateMetadata(jobID: ids[0], metadata: .unknown, expectedMetadataRevision: self.one, account: self.account) }
        await fails(.conflict) { try await self.db.moveItems(expectedMembershipRevisions: [ids[0]:self.one,ids[1]:self.one], destinationFolderID: nil, account: self.account) }
        await fails(.jobNotFound) { try await self.db.moveItems(expectedMembershipRevisions: [ids[0]:DownloadLibraryRevision(2),UUID():self.one], destinationFolderID: nil, account: self.account) }
        let after = try await db.listItems(target: .folder(folder.id), account: account); XCTAssertEqual(after,moved)
        let snapshot = try await db.download(jobID: ids[0], scope: snapshots[0].job.scope); XCTAssertEqual(snapshot,snapshots[0])
        try await db.moveItems(expectedMembershipRevisions: [:], destinationFolderID: DownloadFolderID(UUID()), account: account)
    }
    func testDeleteUnfilesClearsDefaultAndPreferencesPreservesSnapshots() async throws {
        let folder = try await db.createFolder(name: DownloadFolderName("delete"), account: account)
        let id = fixture.jobs[0].job.id
        try await db.moveItems(expectedMembershipRevisions: [id:one], destinationFolderID: folder.id, account: account)
        try await db.saveDefaultFolder(folderID: folder.id, account: account)
        try await db.saveSort(target: .folder(folder.id), sort: DownloadSort(field: .artist), account: account)
        await fails(.conflict) { try await self.db.deleteFolderAndUnfile(id: folder.id, expectedRevision: DownloadLibraryRevision(2), account: self.account) }
        try await db.deleteFolderAndUnfile(id: folder.id, expectedRevision: one, account: account)
        let items = try await db.listItems(target: .unfiled, account: account)
        XCTAssertEqual(items.count,18); XCTAssertEqual(items.first { $0.jobID == id }!.membershipRevision.value,3)
        let defaultID = try await db.loadDefaultFolder(account: account); XCTAssertNil(defaultID)
        try raw { c in XCTAssertTrue(try c.rows("SELECT * FROM download_library_view_preferences").isEmpty) }
        for snapshot in fixture.jobs {
            let actual = try await db.download(jobID: snapshot.job.id, scope: snapshot.job.scope); XCTAssertEqual(actual,snapshot)
        }
        try await db.removeDownload(jobID: id, scope: fixture.jobs[0].job.scope)
        await fails(.jobNotFound) { try await self.db.updateMetadata(jobID: id, metadata: .unknown, expectedMetadataRevision: self.one, account: self.account) }
        let remaining = try await db.listItems(target: .all, account: account); XCTAssertEqual(remaining.count,17)
    }
    func testPreferencesColdReopenAndAccountIsolation() async throws {
        let f = try await db.createFolder(name: DownloadFolderName("persist"), account: account)
        for (target,sort) in [(DownloadLibraryTarget.all,DownloadSort(field:.artist)),(.unfiled,DownloadSort(field:.group,direction:.descending)),(.folder(f.id),DownloadSort(field:.addedAt,direction:.ascending))] {
            try await db.saveSort(target: target, sort: sort, account: account)
        }
        try await db.saveDefaultFolder(folderID:f.id,account:account)
        await db.close(); db = try SQLiteDatabase(url:url)
        let a = try await db.loadSort(target:.all,account:account)
        let u = try await db.loadSort(target:.unfiled,account:account)
        let g = try await db.loadSort(target:.folder(f.id),account:account)
        let o = try await db.loadSort(target:.all,account:other)
        let d = try await db.loadDefaultFolder(account:account)
        XCTAssertEqual(a,DownloadSort(field:.artist)); XCTAssertEqual(u,DownloadSort(field:.group,direction:.descending)); XCTAssertEqual(g,DownloadSort(field:.addedAt,direction:.ascending)); XCTAssertEqual(o,DownloadSort()); XCTAssertEqual(d,f.id)
    }
    func testInjectedMidBatchAndDeleteFailureRollBackEverything() async throws {
        let f = try await db.createFolder(name: DownloadFolderName("atomic"), account: account)
        let ids = [fixture.jobs[0].job.id,fixture.jobs[1].job.id]
        let before = try await db.listItems(target:.all,account:account)
        try raw { c in try c.execute("CREATE TRIGGER d04_fail_move BEFORE UPDATE ON download_library_items WHEN NEW.jobID='\(ids[1].uuidString)' BEGIN SELECT RAISE(ABORT,'injected'); END") }
        do { try await db.moveItems(expectedMembershipRevisions:[ids[0]:one,ids[1]:one],destinationFolderID:f.id,account:account); XCTFail() } catch { XCTAssertNotNil(error as? PersistenceError) }
        let after = try await db.listItems(target:.all,account:account); XCTAssertEqual(after,before)
        try raw { c in try c.execute("DROP TRIGGER d04_fail_move") }
        try await db.moveItems(expectedMembershipRevisions:[ids[0]:one],destinationFolderID:f.id,account:account)
        try await db.saveDefaultFolder(folderID:f.id,account:account)
        try await db.saveSort(target:.folder(f.id),sort:DownloadSort(field:.group),account:account)
        try raw { c in try c.execute("CREATE TRIGGER d04_fail_delete BEFORE DELETE ON download_folders BEGIN SELECT RAISE(ABORT,'injected'); END") }
        do { try await db.deleteFolderAndUnfile(id:f.id,expectedRevision:one,account:account); XCTFail() } catch { XCTAssertNotNil(error as? PersistenceError) }
        let members = try await db.listItems(target:.folder(f.id),account:account)
        let defaultID = try await db.loadDefaultFolder(account:account)
        let sort = try await db.loadSort(target:.folder(f.id),account:account)
        XCTAssertEqual(members.count,1); XCTAssertEqual(members[0].membershipRevision.value,2); XCTAssertEqual(defaultID,f.id); XCTAssertEqual(sort.field,.group)
    }
    func testConcurrentCASOnlyOneWriterAndCancelledWriteDoesNothing() async throws {
        let f = try await db.createFolder(name:DownloadFolderName("race"),account:account)
        let database = db!, owner = account, revision = one
        let successes = await withTaskGroup(of: Bool.self) { group in
            for n in 0..<2 { group.addTask {
                do { try await database.renameFolder(id:f.id,name:DownloadFolderName("winner\(n)"),expectedRevision:revision,account:owner); return true }
                catch { return false }
            } }
            var count=0; for await success in group { if success { count += 1 } }; return count
        }
        XCTAssertEqual(successes,1)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await database.createFolder(name:DownloadFolderName("cancelled"),account:owner)
        }
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let folders = try await db.listFolders(account:account); XCTAssertEqual(folders.count,1); XCTAssertEqual(folders[0].revision.value,2)
    }
    func testProjectionAvoidsPagePayloadsAndReportsCorruptMetadataAndClosedDB() async throws {
        let before = try await db.listItems(target:.all,account:account)
        try raw { c in try c.execute("UPDATE download_pages SET payload=X'00'"); try c.execute("UPDATE download_jobs SET payload=X'00'") }
        let after = try await db.listItems(target:.all,account:account); XCTAssertEqual(after,before)
        try raw { c in try c.execute("UPDATE download_library_items SET metadataState='complete',metadataSite='eh',metadataFetchedAtMs=1,artistsPayload=X'00'") }
        do { _ = try await db.listItems(target:.all,account:account); XCTFail() } catch { XCTAssertEqual(error as? PersistenceError,.corruptRecord) }
        await db.close()
        do { _ = try await db.listFolders(account:account); XCTFail() } catch { XCTAssertEqual(error as? PersistenceError,.closed) }
    }
    func testRevisionOverflowAndReorderFailureRollback() async throws {
        let a = try await db.createFolder(name: DownloadFolderName("A"), account: account)
        let b = try await db.createFolder(name: DownloadFolderName("B"), account: account)
        let before = try await db.listFolders(account: account)
        try raw { c in try c.execute("CREATE TRIGGER d04_fail_reorder BEFORE UPDATE ON download_folders WHEN NEW.id='\(a.id.value.uuidString)' BEGIN SELECT RAISE(ABORT,'injected'); END") }
        do { try await db.reorderFolders(ids: [b.id,a.id], account: account); XCTFail() } catch { XCTAssertNotNil(error as? PersistenceError) }
        let after = try await db.listFolders(account: account); XCTAssertEqual(after,before)
        try raw { c in
            try c.execute("DROP TRIGGER d04_fail_reorder")
            try c.execute("UPDATE download_folders SET position=9223372036854775807,revision=9223372036854775807 WHERE id=?", [.text(a.id.value.uuidString)])
        }
        await fails(.conflict) { _ = try await self.db.createFolder(name: DownloadFolderName("C"), account: self.account) }
        await fails(.conflict) { try await self.db.renameFolder(id: a.id, name: DownloadFolderName("C"), expectedRevision: DownloadLibraryRevision(Int64.max), account: self.account) }
        let id = fixture.jobs[0].job.id
        try await db.updateMetadata(jobID: id, metadata: .unknown, expectedMetadataRevision: one, account: account)
        let item = try await db.listItems(target: .all, account: account).first { $0.jobID == id }!
        XCTAssertEqual(item.metadata, .unknown); XCTAssertEqual(item.metadataRevision.value, 2)
        try raw { c in try c.execute("UPDATE download_library_items SET membershipRevision=9223372036854775807 WHERE jobID=?", [.text(id.uuidString)]) }
        await fails(.conflict) { try await self.db.moveItems(expectedMembershipRevisions: [id:DownloadLibraryRevision(Int64.max)], destinationFolderID: b.id, account: self.account) }
        let empty = try await db.listItems(target: .folder(b.id), account: account); XCTAssertTrue(empty.isEmpty)
    }

}