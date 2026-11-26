import Foundation
import XCTest
import ErosCore
import ErosServices
import ErosPersistence

private actor D11Sessions: SessionProvider {
    var state: SessionState
    var held=false
    var gate: CheckedContinuation<Void,Never>?
    init(_ scope:SessionScope) { state=SessionState(scope:scope,authentication:.authenticated) }
    func hold() { held=true }
    func waiting() -> Bool { gate != nil }
    func release() { gate?.resume(); gate=nil }
    func update(_ scope:SessionScope) { state=SessionState(scope:scope,authentication:.authenticated) }
    func current() async -> SessionState {
        if held { held=false; await withCheckedContinuation { gate=$0 } }
        return state
    }
}
@MainActor final class MoveDownloadsTests: XCTestCase {
    var root:URL!
    var db:SQLiteDatabase!
    private var sessions:D11Sessions!
    let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1)
    override func setUp() async throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        db=try SQLiteDatabase(url:root.appendingPathComponent("db"),libraryNow:{ DownloadLibraryTimestamp(123) })
        sessions=D11Sessions(scope)
    }
    override func tearDown() async throws { await db.close(); try FileManager.default.removeItem(at:root) }
    func seed(_ number:Int,state:DownloadJobState = .paused,owner:SessionScope? = nil) async throws -> DownloadSnapshot {
        let owner=owner ?? scope,id=UUID()
        let ref=try GalleryReference(key:GalleryKey(site:owner.storage.site,galleryID:GalleryID(Int64(number))),token:SensitiveText("synthetic"))
        let summary=try GallerySummary(reference:ref,title:"Synthetic \(number)",pageCount:NonnegativeCount(1))
        let complete=state == .completed
        let job=try DownloadJob(id:id,scope:owner.storage,reference:ref,state:state,totalPages:NonnegativeCount(1),completedPages:NonnegativeCount(complete ? 1 : 0),generation:1)
        let page=try DownloadPage(jobID:id,index:PageIndex(0),state:complete ? .completed : .pending,relativePath:complete ? RelativePath("\(id.uuidString)/0.img") : nil,size:complete ? NonnegativeCount(4) : nil)
        let snapshot=try DownloadSnapshot(job:job,pages:[page])
        let queued=try DownloadJob(id:id,scope:owner.storage,reference:ref,state:.queued,totalPages:NonnegativeCount(1),completedPages:NonnegativeCount(0),generation:1)
        _ = try await db.insertDownloadWithLibrary(summary:summary,snapshot:DownloadSnapshot(job:queued,pages:[DownloadPage(jobID:id,index:PageIndex(0),state:.pending)]))
        try await db.updateDownload(snapshot,expectedGeneration:1)
        if complete {
            let dir=root.appendingPathComponent(id.uuidString);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            try Data("page".utf8).write(to:dir.appendingPathComponent("0.img"))
        }
        return snapshot
    }
    func items() async throws -> [DownloadLibraryItem] { try await db.listItems(target:.all,account:scope.storage.accountID) }
    func model(_ values:[DownloadLibraryItem]) -> MoveDownloadsModel { MoveDownloadsModel(items:values,store:db,sessions:sessions,scope:scope) }
    func testMixedStatesMoveAtomicallyAndKeepFilesTimesAndProgress() async throws {
        var snapshots:[DownloadSnapshot]=[]
        for (i,state) in [DownloadJobState.downloading,.failed,.completed,.cancelled].enumerated() { snapshots.append(try await seed(i+1,state:state)) }
        let before=try await items(), move=model(before);await move.load()
        let created=await move.destination.createFolder(name:"目标📚");XCTAssertTrue(created)
        let target=try XCTUnwrap(move.destination.selectedFolderID)
        let success=await move.move();XCTAssertTrue(success);XCTAssertTrue(move.moved)
        let moved=try await items();XCTAssertEqual(moved.count,4)
        for item in moved {
            let old=try XCTUnwrap(before.first { $0.jobID == item.jobID })
            XCTAssertEqual(item.folderID,target);XCTAssertEqual(item.addedAt,old.addedAt);XCTAssertEqual(item.state,old.state)
            XCTAssertEqual(item.membershipRevision.value,old.membershipRevision.value+1)
        }
        let completed=try XCTUnwrap(snapshots.first { $0.job.state == .completed })
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(completed.job.id.uuidString+"/0.img")),Data("page".utf8))
        // Simulate a delayed progress save and metadata write after the membership change.
        for snapshot in snapshots { try await db.saveDownload(snapshot) }
        let metadata=try DownloadLibraryMetadata(artists:["A"],groups:[],state:.complete,sourceSite:.eh,fetchedAt:DownloadLibraryTimestamp(500))
        try await db.updateMetadata(jobID:moved[0].jobID,metadata:metadata,expectedMetadataRevision:moved[0].metadataRevision,account:scope.storage.accountID)
        let after=try await items();XCTAssertTrue(after.allSatisfy { $0.folderID == target })
        let saved=try await db.allDownloads(scope:scope.storage)
        XCTAssertEqual(Set(saved.map(\.job.id)),Set(snapshots.map(\.job.id)))
        for snapshot in snapshots { XCTAssertEqual(saved.first { $0.job.id == snapshot.job.id },snapshot) }
        await db.close();db=try SQLiteDatabase(url:root.appendingPathComponent("db"))
        let restored=try await items();XCTAssertTrue(restored.allSatisfy { $0.folderID == target })
    }
    func testCreateThenCancelDoesNotMoveAndZeroSelectionCannotSubmit() async throws {
        _ = try await seed(1);let before=try await items(), move=model(before);await move.load()
        _ = await move.destination.createFolder(name:"empty")
        let after=try await items();XCTAssertEqual(after,before)
        let empty=model([]);await empty.load();let moved=await empty.move()
        XCTAssertFalse(moved);XCTAssertNotNil(empty.error)
        let unchanged=try await items();XCTAssertEqual(unchanged,before)
    }
    func testMissingJobFailsWholeBatchWithoutDroppingSelection() async throws {
        let a=try await seed(1);_ = try await seed(2)
        let before=try await items(), move=model(before);await move.load();_ = await move.destination.createFolder(name:"target")
        try await db.removeDownload(jobID:a.job.id,scope:scope.storage)
        let success=await move.move();XCTAssertFalse(success);XCTAssertNotNil(move.error);XCTAssertEqual(move.jobIDs.count,2)
        await move.refreshMembers();XCTAssertNotNil(move.error);XCTAssertEqual(move.jobIDs.count,2)
        let remaining=try await items();XCTAssertEqual(remaining.count,1);XCTAssertNil(remaining[0].folderID)
    }
    func testConflictRequiresExplicitRefreshThenWholeBatchMoves() async throws {
        _ = try await seed(1);_ = try await seed(2)
        let before=try await items(), move=model(before);await move.load();_ = await move.destination.createFolder(name:"target")
        let other=try await db.createFolder(name:DownloadFolderName("other"),account:scope.storage.accountID)
        try await db.moveItems(expectedMembershipRevisions:[before[0].jobID:before[0].membershipRevision],destinationFolderID:other.id,account:scope.storage.accountID)
        let failed=await move.move();XCTAssertFalse(failed)
        let partial=try await items();XCTAssertNil(partial.first { $0.jobID == before[1].jobID }?.folderID)
        await move.refreshMembers();let success=await move.move();XCTAssertTrue(success)
        let after=try await items();XCTAssertTrue(after.allSatisfy { $0.folderID == move.destination.selectedFolderID })
    }
    func testDeletedTargetAndForeignItemsFailWithoutMutation() async throws {
        _ = try await seed(1);let before=try await items(), move=model(before);await move.load();_ = await move.destination.createFolder(name:"gone")
        let folder=try XCTUnwrap(move.destination.folders.first)
        try await db.deleteFolderAndUnfile(id:folder.id,expectedRevision:folder.revision,account:scope.storage.accountID)
        let failed=await move.move();XCTAssertFalse(failed);XCTAssertNotNil(move.error)
        let other=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:2)
        _ = try await seed(2,owner:other)
        let foreign=try await db.listItems(target:.all,account:other.storage.accountID)
        let mixed=model(before+foreign);await mixed.load();let rejected=await mixed.move();XCTAssertFalse(rejected)
        let unchanged=try await items();XCTAssertEqual(unchanged,before)
    }
    func testBusySubmissionAndScopeChangeGuard() async throws {
        _ = try await seed(1);let before=try await items(), move=model(before);await move.load();_ = await move.destination.createFolder(name:"target")
        await sessions.hold();let first=Task { await move.move() }
        while !(await sessions.waiting()) { await Task.yield() }
        let duplicate=await move.move();XCTAssertFalse(duplicate)
        await sessions.release();let success=await first.value;XCTAssertTrue(success)
        let again=await move.move();XCTAssertFalse(again)
        let moved=try await items();XCTAssertEqual(moved[0].membershipRevision.value,before[0].membershipRevision.value+1)
        let stale=model(moved);await stale.load();stale.destination.select(nil)
        await sessions.update(SessionScope(storage:scope.storage,generation:2))
        let rejected=await stale.move();XCTAssertFalse(rejected);XCTAssertNotNil(stale.error)
        let after=try await items();XCTAssertEqual(after,moved)
    }
}
