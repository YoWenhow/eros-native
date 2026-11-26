import Foundation
import XCTest
import ErosCore
import ErosServices
import ErosPersistence

private actor D06Repository: GalleryRepository {
    var tags: [TagGroup] = [.init(namespace:"artist",tags:["new artist"]),.init(namespace:"group",tags:["circle"])]
    var held = false
    var fail = false
    var continuation: CheckedContinuation<Void,Never>?
    private(set) var detailCalls = 0
    func configure(held: Bool = false, fail: Bool = false, tags: [TagGroup]? = nil) { self.held=held; self.fail=fail; if let tags { self.tags=tags } }
    func waiting() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation=nil }
    func detail(request: GalleryRequest) async throws -> GalleryDetail {
        detailCalls += 1
        let tags = tags
        if held { await withCheckedContinuation { continuation=$0 } }
        if fail { throw AppError.transport(code:-1) }
        return try GalleryDetail(summary: GallerySummary(reference:request.reference,title:"synthetic",pageCount:NonnegativeCount(2)),tags:tags)
    }
    func list(request: GalleryListRequest) throws -> PagedResult<GallerySummary> { throw AppError.notFound }
    func readerPages(request: ReaderPagesRequest) throws -> PagedResult<ReaderPage> { throw AppError.notFound }
    func thumbnails(request: ReaderPagesRequest) throws -> PagedResult<GalleryThumbnail> { try PagedResult(items:[],context:request.context) }
}
@MainActor final class DownloadDetailMetadataTests: XCTestCase {
    var root: URL!
    var db: SQLiteDatabase!
    var sessions: MutableSessionProvider!
    private var repo: D06Repository!
    let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1)
    var service: DownloadDetailMetadataService { .init(database:db,sessions:sessions) }
    override func setUp() async throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        db=try SQLiteDatabase(url:root.appendingPathComponent("db"),libraryNow:{ DownloadLibraryTimestamp(50) })
        sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated)); repo=D06Repository()
    }
    override func tearDown() async throws { await db.close(); try FileManager.default.removeItem(at:root) }
    func summary(site: Site = .eh) throws -> GallerySummary {
        try GallerySummary(reference:GalleryReference(key:GalleryKey(site:site,galleryID:GalleryID(777)),token:SensitiveText("synthetic")),title:"[artist:fake]",pageCount:NonnegativeCount(2))
    }
    func enqueue(_ scope: SessionScope? = nil, metadata: DownloadLibraryMetadata = .unknown) async throws -> UUID {
        let scope=scope ?? self.scope
        let c=DownloadCoordinator(database:db,repository:repo,sessions:sessions,root:root,validate:{ _ in },load:{ _,_ in throw AppError.notFound })
        let result=try await c.enqueue(summary(site:scope.storage.site),scope:scope,metadata:metadata)
        switch result { case .inserted(let id),.existing(let id): return id }
    }
    func items(account: AccountID? = nil) async throws -> [DownloadLibraryItem] { try await db.listItems(target:.all,account:account ?? scope.storage.accountID) }
    func model() -> GalleryDetailViewModel { GalleryDetailViewModel(repository:repo,downloadLibrary:service,now:{ DownloadLibraryTimestamp(100) }) }
    func testDetailRefreshPersistsAndNewDownloadUsesLoadedSnapshotWithoutExtraFetch() async throws {
        let feed=model(), s=try summary()
        await feed.load(reference:s.reference,scope:scope)
        let before=try await items(); XCTAssertTrue(before.isEmpty)
        let metadata=try XCTUnwrap(feed.downloadMetadata)
        let id=try await enqueue(metadata:metadata)
        let saved=try await items(); XCTAssertEqual(saved[0].jobID,id); XCTAssertEqual(saved[0].metadata,metadata); XCTAssertEqual(saved[0].metadataRevision.value,1)
        let calls=await repo.detailCalls; XCTAssertEqual(calls,1)
        await repo.configure(tags:[])
        await feed.load(reference:s.reference,scope:scope)
        let empty=try await items(); XCTAssertEqual(empty[0].metadata.state,.complete); XCTAssertTrue(empty[0].metadata.artists.isEmpty); XCTAssertEqual(empty[0].metadataRevision.value,2)
        XCTAssertFalse(feed.metadataSaveFailed)
    }
    func testMoveDuringDetailKeepsMembershipAndCASRejectsOlderResponse() async throws {
        let id=try await enqueue(), feed=model(), ref=try summary().reference
        await repo.configure(held:true)
        let task=Task { await feed.load(reference:ref,scope:scope) }
        while !(await repo.waiting()) { await Task.yield() }
        let folder=try await db.createFolder(name:DownloadFolderName("moved"),account:scope.storage.accountID)
        try await db.moveItems(expectedMembershipRevisions:[id:DownloadLibraryRevision(1)],destinationFolderID:folder.id,account:scope.storage.accountID)
        await repo.release(); await task.value
        let moved=try await items(); XCTAssertEqual(moved[0].folderID,folder.id); XCTAssertEqual(moved[0].membershipRevision.value,2); XCTAssertEqual(moved[0].metadata.artists,["new artist"])
        // Start another request, then let a newer metadata writer win before its response.
        let older=Task { await feed.load(reference:ref,scope:scope) }
        while !(await repo.waiting()) { await Task.yield() }
        let newer=try DownloadLibraryMetadata(artists:["winner"],groups:[],state:.complete,sourceSite:.ex,fetchedAt:DownloadLibraryTimestamp(-999))
        try await db.updateMetadata(jobID:id,metadata:newer,expectedMetadataRevision:DownloadLibraryRevision(2),account:scope.storage.accountID)
        await repo.release(); await older.value
        let result=try await items(); XCTAssertEqual(result[0].metadata,newer); XCTAssertEqual(result[0].folderID,folder.id); XCTAssertEqual(result[0].metadataRevision.value,3)
    }
    func testDeletionAndRecreationDuringDetailDoNotEnrollNewJob() async throws {
        let id=try await enqueue(), feed=model(), ref=try summary().reference
        await repo.configure(held:true)
        let task=Task { await feed.load(reference:ref,scope:scope) }
        while !(await repo.waiting()) { await Task.yield() }
        try await db.removeDownload(jobID:id,scope:scope.storage)
        let replacement=try await enqueue(); XCTAssertNotEqual(replacement,id)
        await repo.release(); await task.value
        let rows=try await items(); XCTAssertEqual(rows.count,1); XCTAssertEqual(rows[0].jobID,replacement); XCTAssertEqual(rows[0].metadata,.unknown)
    }
    func testFailureResetAndScopeChangePreserveOldMetadata() async throws {
        let initial=try DownloadLibraryMetadata(artists:["keep"],groups:[],state:.complete,sourceSite:.eh,fetchedAt:DownloadLibraryTimestamp(1))
        _ = try await enqueue(metadata:initial)
        let feed=model(), ref=try summary().reference
        await repo.configure(fail:true); await feed.load(reference:ref,scope:scope)
        let failed=try await items(); XCTAssertEqual(failed[0].metadata,initial)
        await repo.configure(held:true)
        let cancelled=Task { await feed.load(reference:ref,scope:scope) }
        while !(await repo.waiting()) { await Task.yield() }
        feed.reset(); await repo.release(); await cancelled.value
        let reset=try await items(); XCTAssertEqual(reset[0].metadata,initial); XCTAssertNil(feed.downloadMetadata)
        let stale=Task { await feed.load(reference:ref,scope:scope) }
        while !(await repo.waiting()) { await Task.yield() }
        await sessions.update(SessionState(scope:SessionScope(storage:scope.storage,generation:2),authentication:.authenticated))
        await repo.release(); await stale.value
        let retained=try await items(); XCTAssertEqual(retained[0].metadata,initial); XCTAssertNil(feed.detail); XCTAssertEqual(feed.error,.staleSession)
    }
    func testCrossSiteUpdatesOnlyCapturedAccountAndLeavesOtherUnknown() async throws {
        _ = try await enqueue()
        let other=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:2)
        await sessions.update(SessionState(scope:other,authentication:.authenticated)); _ = try await enqueue(other)
        let ex=SessionScope(storage:StorageScope(accountID:scope.storage.accountID,site:.ex),generation:3)
        await sessions.update(SessionState(scope:ex,authentication:.authenticated))
        let feed=model(); await feed.load(reference:try summary(site:.ex).reference,scope:ex)
        let owned=try await items(), foreign=try await items(account:other.storage.accountID)
        XCTAssertEqual(owned[0].metadata.sourceSite,.ex); XCTAssertEqual(owned[0].metadata.artists,["new artist"]); XCTAssertEqual(foreign[0].metadata,.unknown)
    }
    func testStorageFailureDoesNotHideDetailOrPreventSnapshotForEnqueue() async throws {
        await db.close()
        let feed=model(); await feed.load(reference:try summary().reference,scope:scope)
        XCTAssertNotNil(feed.detail); XCTAssertNotNil(feed.downloadMetadata); XCTAssertTrue(feed.metadataSaveFailed); XCTAssertNil(feed.error)
        let calls=await repo.detailCalls; XCTAssertEqual(calls,1)
    }
}