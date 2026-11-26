import Foundation
import XCTest
import ErosCore
import ErosServices
import ErosPersistence

private actor D07Repository: GalleryRepository {
    var errors: [Int64: AppError] = [:]
    var empty: Set<Int64> = []
    var held: Int64?
    var gate: CheckedContinuation<Void,Never>?
    var calls: [Int64] = []
    var active = 0
    var peak = 0
    var secretError = false
    func configure(errors: [Int64:AppError] = [:], empty: Set<Int64> = [], held: Int64? = nil, secret: Bool = false) {
        self.errors=errors; self.empty=empty; self.held=held; calls=[]; peak=0; secretError=secret
    }
    func waiting() -> Bool { gate != nil }
    func release() { gate?.resume(); gate=nil }
    func recorded() -> [Int64] { calls }
    func maxActive() -> Int { peak }
    func detail(request: GalleryRequest) async throws -> GalleryDetail {
        let gid=request.reference.key.galleryID.value
        calls.append(gid); active += 1; peak=max(peak,active); defer { active -= 1 }
        if held == gid { await withCheckedContinuation { gate=$0 } }
        if let error=errors[gid] { throw error }
        if secretError { throw NSError(domain:"https://secret.invalid/?Cookie=SECRET",code:1,userInfo:[NSLocalizedDescriptionKey:"tag body SECRET"]) }
        let titles = GallerySourceTitles(gn: "Remote original \(gid)", gj: "日文 \(gid)")
        return try GalleryDetail(summary:GallerySummary(reference:request.reference,title:"synthetic",pageCount:NonnegativeCount(1)),tags:empty.contains(gid) ? [] : [.init(namespace:"artist",tags:["artist \(gid)"]),.init(namespace:"group",tags:["circle"])],sourceTitles:titles)
    }
    func list(request: GalleryListRequest) throws -> PagedResult<GallerySummary> { throw AppError.notFound }
    func readerPages(request: ReaderPagesRequest) throws -> PagedResult<ReaderPage> { throw AppError.notFound }
    func thumbnails(request: ReaderPagesRequest) throws -> PagedResult<GalleryThumbnail> { throw AppError.notFound }
}
private actor D07Progress {
    var values: [DownloadMetadataRefreshProgress] = []
    func append(_ value: DownloadMetadataRefreshProgress) { values.append(value) }
    func all() -> [DownloadMetadataRefreshProgress] { values }
}
@MainActor final class DownloadMetadataRefreshTests: XCTestCase {
    var root: URL!
    var db: SQLiteDatabase!
    var sessions: MutableSessionProvider!
    private var repository: D07Repository!
    var service: DownloadMetadataRefreshService!
    let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1)
    override func setUp() async throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        db=try SQLiteDatabase(url:root.appendingPathComponent("db"))
        sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated)); repository=D07Repository()
        service=DownloadMetadataRefreshService(database:db,repository:repository,sessions:sessions,now:{ DownloadLibraryTimestamp(100) })
    }
    override func tearDown() async throws { await db.close(); try FileManager.default.removeItem(at:root) }
    func insert(_ count: Int, known: Set<Int> = [], knownTitles: Set<Int>? = nil, site: Site = .eh) async throws -> [UUID] {
        var ids:[UUID]=[]
        for n in 1...count {
            let id=UUID(uuidString:String(format:"10000000-0000-0000-0000-%012d",n))!
            let ref=try GalleryReference(key:GalleryKey(site:site,galleryID:GalleryID(Int64(n))),token:SensitiveText("synthetic"))
            let titles = (knownTitles ?? known).contains(n) ? GallerySourceTitles(gn: "Saved original", gj: "保存済み") : nil
            let summary=try GallerySummary(reference:ref,title:"synthetic",pageCount:NonnegativeCount(1),sourceTitles:titles)
            let jobScope = StorageScope(accountID: scope.storage.accountID, site: site)
            let job=try DownloadJob(id:id,scope:jobScope,reference:ref,state:.queued,totalPages:NonnegativeCount(1),completedPages:NonnegativeCount(0),generation:1)
            let snapshot=try DownloadSnapshot(job:job,pages:[DownloadPage(jobID:id,index:PageIndex(0),state:.pending)])
            let metadata: DownloadLibraryMetadata = known.contains(n) ? try .from(detail:GalleryDetail(summary:summary,tags:[]),fetchedAt:DownloadLibraryTimestamp(0)) : .unknown
            _ = try await db.insertDownloadWithLibrary(summary:summary,snapshot:snapshot,metadata:metadata); ids.append(id)
        }
        return ids
    }
    func items() async throws -> [DownloadLibraryItem] { try await db.listItems(target:.all,account:scope.storage.accountID) }
    func testPreviewValidatesWholeSelectionAndKnownRefreshRequiresOptIn() async throws {
        let ids=try await insert(3,known:[1])
        let plan=try await service.prepare(jobIDs:Set(ids),scope:scope)
        XCTAssertEqual(plan.selectedCount,3); XCTAssertEqual(plan.knownSkippedCount,1); XCTAssertEqual(plan.total,2)
        let known=try await service.prepare(jobIDs:[ids[0]],scope:scope,refreshKnown:true); XCTAssertEqual(known.total,1)
        let other=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:2)
        await sessions.update(SessionState(scope:other,authentication:.authenticated))
        do { _ = try await service.prepare(jobIDs:Set(ids),scope:other); XCTFail() } catch { XCTAssertEqual(error as? DownloadLibraryError,.jobNotFound) }
        await sessions.update(SessionState(scope:scope,authentication:.authenticated))
        do { _ = try await service.prepare(jobIDs:Set(ids+[UUID()]),scope:scope); XCTFail() } catch { XCTAssertEqual(error as? DownloadLibraryError,.jobNotFound) }
        let calls=await repository.recorded(); XCTAssertTrue(calls.isEmpty)
        let result=try await service.run(known); XCTAssertEqual(result.succeeded,1)
    }
    func testTitleOnlyRowsAreIncludedAndExistingTagsAndTitlesAreKept() async throws {
        let jobs = try await insert(4, known: [1, 3], knownTitles: [3, 4])
        let before = try await items()
        let plan = try await service.prepare(jobIDs: Set(jobs), scope: scope)
        XCTAssertEqual(plan.jobIDs, [jobs[0], jobs[1], jobs[3]])
        XCTAssertEqual(plan.knownSkippedCount, 1)
        XCTAssertEqual(plan.unknownTitleCount, 2)
        XCTAssertEqual(plan.unknownTagCount, 2)
        let result = try await service.run(plan)
        XCTAssertEqual(result.succeeded, 3)
        let calls = await repository.recorded()
        XCTAssertEqual(calls, [1, 2, 4])
        let after = try await items()
        XCTAssertEqual(after[0].summary.displayTitle(preferred: .japanese), "日文 1")
        XCTAssertEqual(after[0].summary.title, before[0].summary.title)
        XCTAssertEqual(after[0].metadata, before[0].metadata)
        XCTAssertEqual(after[0].metadataRevision, before[0].metadataRevision)
        XCTAssertEqual(after[1].summary.sourceTitles?.gn, "Remote original 2")
        XCTAssertEqual(after[1].metadata.artists, ["artist 2"])
        XCTAssertEqual(after[2], before[2])
        XCTAssertEqual(after[3].summary.sourceTitles, before[3].summary.sourceTitles)
        XCTAssertEqual(after[3].metadata.artists, ["artist 4"])
        let next = try await service.prepare(jobIDs: Set(jobs), scope: scope)
        XCTAssertEqual(next.total, 0)
    }

    func testActiveSiteLookupStoresTitlesUnderTheOriginalDownloadReference() async throws {
        let jobs = try await insert(1, site: .ex)
        let before = try await items()
        let reference = try XCTUnwrap(before.first?.summary.reference)
        let originalScope = StorageScope(accountID: scope.storage.accountID, site: .ex)
        let snapshot = try await db.download(jobID: jobs[0], scope: originalScope)
        let plan = try await service.prepare(jobIDs: Set(jobs), scope: scope)
        let result = try await service.run(plan)
        XCTAssertEqual(result.succeeded, 1)
        let after = try await items()
        XCTAssertEqual(after[0].summary.reference, reference)
        XCTAssertEqual(after[0].summary.sourceTitles?.gj, "日文 1")
        XCTAssertEqual(after[0].metadata.sourceSite, .eh)
        let saved = try await db.download(jobID: jobs[0], scope: originalScope)
        XCTAssertEqual(saved, snapshot)
        let activeSiteCopy = try await db.gallery(galleryID: reference.key.galleryID, scope: scope.storage)
        XCTAssertNil(activeSiteCopy)
    }

    func testFiftyLimitSerialAndDeferredRequiresAnotherExplicitBatch() async throws {
        let ids=try await insert(52,known:[1])
        let plan=try await service.prepare(jobIDs:Set(ids),scope:scope)
        XCTAssertEqual(plan.total,50); XCTAssertEqual(plan.deferredJobIDs,[ids[51]]); XCTAssertEqual(plan.jobIDs,Array(ids[1...50])); XCTAssertEqual(plan.deferredCount,1); XCTAssertEqual(plan.knownSkippedCount,1)
        let result=try await service.run(plan)
        XCTAssertEqual(result.succeeded,50); XCTAssertEqual(result.remaining,0)
        let calls=await repository.recorded(), peak=await repository.maxActive()
        XCTAssertEqual(calls,Array(2...51).map(Int64.init)); XCTAssertEqual(peak,1)
        let second=try await service.prepare(jobIDs:Set(ids),scope:scope); XCTAssertEqual(second.total,1)
        let rows=try await items(); XCTAssertEqual(rows.last?.metadata,.unknown)
    }
    func testOrdinaryFailuresContinueAndProgressCountsStayConsistent() async throws {
        let ids=try await insert(4), recorder=D07Progress()
        await repository.configure(errors:[2:.transport(code:-1009),3:.notFound],empty:[1])
        let before=try await db.download(jobID:ids[1],scope:scope.storage)
        let plan=try await service.prepare(jobIDs:Set(ids),scope:scope)
        let result=try await service.run(plan,onProgress:{ await recorder.append($0) })
        XCTAssertEqual(result.succeeded,2); XCTAssertEqual(result.failed,2); XCTAssertEqual(result.remaining,0); XCTAssertNil(result.stop)
        XCTAssertEqual(result.failures[ids[1]],.network); XCTAssertEqual(result.failures[ids[2]],.unavailable)
        let progress=await recorder.all(); XCTAssertEqual(progress.count,5)
        for value in progress { XCTAssertEqual(value.total,value.succeeded+value.failed+value.cancelled+value.remaining) }
        let rows=try await items(); XCTAssertEqual(rows[0].metadata.state,.complete); XCTAssertTrue(rows[0].metadata.artists.isEmpty); XCTAssertEqual(rows[1].metadata,.unknown)
        let after=try await db.download(jobID:ids[1],scope:scope.storage); XCTAssertEqual(after,before)
        let calls=await repository.recorded(); XCTAssertEqual(calls,[1,2,3,4])
    }
    func testRateQuotaAndAuthenticationStopPreservingPartialSuccess() async throws {
        let ids=try await insert(3)
        for (error,stop) in [(AppError.rateLimited(retryAfter:60),DownloadMetadataRefreshStop.rateLimited),(.httpStatus(429),.rateLimited),(.quotaExceeded,.quota),(.authenticationRequired,.authentication)] {
            await repository.configure(errors:[2:error])
            let plan=try await service.prepare(jobIDs:Set(ids),scope:scope,refreshKnown:true)
            let result=try await service.run(plan)
            XCTAssertEqual(result.succeeded,1); XCTAssertEqual(result.failed,1); XCTAssertEqual(result.remaining,1); XCTAssertEqual(result.stop,stop)
            let calls=await repository.recorded(); XCTAssertEqual(calls,[1,2])
        }
        let rows=try await items(); XCTAssertEqual(rows[2].metadata,.unknown)
    }
    func testCancelBetweenItemsStopsBeforeNextRequestAndKeepsSuccess() async throws {
        let ids=try await insert(3), service=service!
        let plan=try await service.prepare(jobIDs:Set(ids),scope:scope)
        let result=try await service.run(plan,onProgress:{ value in if value.succeeded == 1 { await service.cancel() } })
        XCTAssertEqual(result.succeeded,1); XCTAssertEqual(result.cancelled,2); XCTAssertEqual(result.failed,0); XCTAssertEqual(result.stop,.cancelled)
        let calls=await repository.recorded(); XCTAssertEqual(calls,[1])
        let retry=try await service.prepare(jobIDs:Set(ids),scope:scope)
        let rest=try await service.run(retry); XCTAssertEqual(rest.succeeded,2)
    }
    func testTaskCancellationAndConcurrentRunRejection() async throws {
        let ids=try await insert(2)
        await repository.configure(held:1)
        let plan=try await service.prepare(jobIDs:Set(ids),scope:scope), service=service!
        let task=Task { try await service.run(plan) }
        while !(await repository.waiting()) { await Task.yield() }
        do { _ = try await service.run(plan); XCTFail() } catch { XCTAssertEqual(error as? DownloadLibraryError,.conflict) }
        task.cancel(); await repository.release()
        let result=try await task.value; XCTAssertEqual(result.cancelled,2); XCTAssertEqual(result.succeeded,0)
        let rows=try await items(); XCTAssertTrue(rows.allSatisfy { $0.metadata == .unknown })
        let calls=await repository.recorded(); XCTAssertEqual(calls,[1])
    }
    func testDeleteAndMoveWhileAwaitingDoNotResurrectOrOverwriteFolder() async throws {
        let ids=try await insert(2)
        let folder=try await db.createFolder(name:DownloadFolderName("offline"),account:scope.storage.accountID)
        await repository.configure(held:1)
        let plan=try await service.prepare(jobIDs:Set(ids),scope:scope), service=service!
        let task=Task { try await service.run(plan) }
        while !(await repository.waiting()) { await Task.yield() }
        try await db.removeDownload(jobID:ids[0],scope:scope.storage)
        try await db.moveItems(expectedMembershipRevisions:[ids[1]:DownloadLibraryRevision(1)],destinationFolderID:folder.id,account:scope.storage.accountID)
        await repository.release(); let result=try await task.value
        XCTAssertEqual(result.failures[ids[0]],.missing); XCTAssertEqual(result.succeeded,1)
        let rows=try await items(); XCTAssertEqual(rows.count,1); XCTAssertEqual(rows[0].folderID,folder.id); XCTAssertEqual(rows[0].membershipRevision.value,2)
    }
    func testScopeSwitchDropsLateResponseAndStopsRemaining() async throws {
        let ids=try await insert(2)
        await repository.configure(held:1)
        let plan=try await service.prepare(jobIDs:Set(ids),scope:scope), service=service!
        let task=Task { try await service.run(plan) }
        while !(await repository.waiting()) { await Task.yield() }
        await sessions.update(SessionState(scope:SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:2),authentication:.authenticated))
        await repository.release(); let result=try await task.value
        XCTAssertEqual(result.stop,.staleSession); XCTAssertEqual(result.cancelled,2)
        let rows=try await items(); XCTAssertTrue(rows.allSatisfy { $0.metadata == .unknown && $0.summary.sourceTitles == nil })
        let calls=await repository.recorded(); XCTAssertEqual(calls,[1])
    }
    func testCASConflictAndSanitizedFailureSummary() async throws {
        let ids=try await insert(2)
        let plan=try await service.prepare(jobIDs:Set(ids),scope:scope)
        let winner=try DownloadLibraryMetadata(artists:["private tag body"],groups:[],state:.complete,sourceSite:.ex,fetchedAt:DownloadLibraryTimestamp(-1))
        try await db.updateMetadata(jobID:ids[0],metadata:winner,expectedMetadataRevision:DownloadLibraryRevision(1),account:scope.storage.accountID)
        await repository.configure(secret:true)
        let result=try await service.run(plan)
        XCTAssertEqual(result.failures[ids[0]],.conflict); XCTAssertEqual(result.failures[ids[1]],.invalidResponse)
        let rendered=String(describing:result)
        for secret in ["SECRET","secret.invalid","Cookie","private tag body"] { XCTAssertFalse(rendered.contains(secret)) }
        let rows=try await items(); XCTAssertEqual(rows[0].metadata,winner)
        let calls=await repository.recorded(); XCTAssertEqual(calls,[2])
    }
    func testLateCASWinnerAndEmptySelectionNeverRequestExtraDetails() async throws {
        let ids=try await insert(1)
        let empty=try await service.prepare(jobIDs:[],scope:scope)
        let emptyResult=try await service.run(empty); XCTAssertEqual(emptyResult.total,0)
        await repository.configure(held:1)
        let plan=try await service.prepare(jobIDs:Set(ids),scope:scope), service=service!
        let task=Task { try await service.run(plan) }
        while !(await repository.waiting()) { await Task.yield() }
        let winner=try DownloadLibraryMetadata(artists:["winner"],groups:[],state:.complete,sourceSite:.ex,fetchedAt:DownloadLibraryTimestamp(-1))
        try await db.updateMetadata(jobID:ids[0],metadata:winner,expectedMetadataRevision:DownloadLibraryRevision(1),account:scope.storage.accountID)
        await repository.release(); let result=try await task.value
        XCTAssertEqual(result.failures[ids[0]],.conflict); XCTAssertEqual(result.succeeded,0)
        let rows=try await items(); XCTAssertEqual(rows[0].metadata,winner); XCTAssertNil(rows[0].summary.sourceTitles)
        let calls=await repository.recorded(); XCTAssertEqual(calls,[1])
    }

}