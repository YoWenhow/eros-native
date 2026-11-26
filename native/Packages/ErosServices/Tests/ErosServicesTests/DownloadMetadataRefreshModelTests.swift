import Foundation
import XCTest
import ErosCore
import ErosServices
import ErosPersistence

private actor D12Repository: GalleryRepository {
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
private actor D12Progress {
    var values: [DownloadMetadataRefreshProgress] = []
    func append(_ value: DownloadMetadataRefreshProgress) { values.append(value) }
    func all() -> [DownloadMetadataRefreshProgress] { values }
}
@MainActor final class DownloadMetadataRefreshModelTests: XCTestCase {
    var root: URL!
    var db: SQLiteDatabase!
    var sessions: MutableSessionProvider!
    private var repository: D12Repository!
    var service: DownloadMetadataRefreshService!
    let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1)
    override func setUp() async throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        db=try SQLiteDatabase(url:root.appendingPathComponent("db"))
        sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated)); repository=D12Repository()
        service=DownloadMetadataRefreshService(database:db,repository:repository,sessions:sessions,now:{ DownloadLibraryTimestamp(100) })
    }
    override func tearDown() async throws { await db.close(); try FileManager.default.removeItem(at:root) }
    func insert(_ count: Int, known: Set<Int> = []) async throws -> [UUID] {
        var ids:[UUID]=[]
        for n in 1...count {
            let id=UUID(uuidString:String(format:"10000000-0000-0000-0000-%012d",n))!
            let ref=try GalleryReference(key:GalleryKey(site:.eh,galleryID:GalleryID(Int64(n))),token:SensitiveText("synthetic"))
            let titles = known.contains(n) ? GallerySourceTitles(gn: "Saved original", gj: "保存済み") : nil
            let summary=try GallerySummary(reference:ref,title:"synthetic",pageCount:NonnegativeCount(1),sourceTitles:titles)
            let job=try DownloadJob(id:id,scope:scope.storage,reference:ref,state:.queued,totalPages:NonnegativeCount(1),completedPages:NonnegativeCount(0),generation:1)
            let snapshot=try DownloadSnapshot(job:job,pages:[DownloadPage(jobID:id,index:PageIndex(0),state:.pending)])
            let metadata: DownloadLibraryMetadata = known.contains(n) ? try .from(detail:GalleryDetail(summary:summary,tags:[]),fetchedAt:DownloadLibraryTimestamp(0)) : .unknown
            _ = try await db.insertDownloadWithLibrary(summary:summary,snapshot:snapshot,metadata:metadata); ids.append(id)
        }
        return ids
    }
    func items() async throws -> [DownloadLibraryItem] { try await db.listItems(target:.all,account:scope.storage.accountID) }

    func waitForFinish(_ model:DownloadMetadataRefreshModel) async {
        while model.running { await Task.yield() }
    }
    func testExplicitConfirmationFiftyLimitFailuresAndNextPreviewDoesNotAutoRun() async throws {
        let ids=try await insert(502)
        await repository.configure(errors:Dictionary(uniqueKeysWithValues:(1...502).map{(Int64($0),AppError.transport(code:-1009))}))
        let model=DownloadMetadataRefreshModel(jobIDs:Set(ids),scope:scope,service:service)
        await model.prepare()
        XCTAssertEqual(model.plan?.total, 50)
        let sizes: [(DownloadMetadataBatchSize, Int)] = [
            (.fifty, 50), (.oneHundred, 100), (.twoHundred, 200), (.fiveHundred, 500), (.all, 502)
        ]
        for (size, count) in sizes {
            model.selectBatchSize(size)
            XCTAssertEqual(model.plan?.total, count)
            XCTAssertEqual(model.plan?.deferredCount, ids.count - count)
            XCTAssertEqual(model.plan?.jobIDs, Array(ids.prefix(count)))
        }
        model.selectBatchSize(.fifty)
        let before=await repository.recorded(); XCTAssertTrue(before.isEmpty)
        model.start(); model.start()
        await waitForFinish(model)
        XCTAssertEqual(model.progress?.failed,50)
        let first=await repository.recorded(); XCTAssertEqual(first.count,50)
        let stored=try await items(); XCTAssertTrue(stored.allSatisfy{$0.metadata.state == .unknown})
        await model.prepareNextBatch()
        XCTAssertEqual(model.plan?.total, 50); XCTAssertNil(model.progress)
        model.selectBatchSize(.all)
        XCTAssertEqual(model.plan?.jobIDs, Array(ids.dropFirst(50)))
        let preview=await repository.recorded(); XCTAssertEqual(preview.count,50)
        model.start(); await waitForFinish(model)
        XCTAssertEqual(model.progress?.failed,452)
        let final=await repository.recorded(); XCTAssertEqual(final, Array(1...502).map(Int64.init))
    }
    func testKnownRefreshIsExplicitAndEmptyConfirmationCannotRun() async throws {
        let ids=try await insert(2,known:[1,2])
        let ordinary=DownloadMetadataRefreshModel(jobIDs:Set(ids),scope:scope,service:service)
        await ordinary.prepare(); XCTAssertEqual(ordinary.plan?.total,0)
        ordinary.start(); XCTAssertFalse(ordinary.running)
        let explicit=DownloadMetadataRefreshModel(jobIDs:Set(ids),scope:scope,service:service,refreshKnown:true)
        await explicit.prepare(); XCTAssertEqual(explicit.plan?.total,2)
        let before=await repository.recorded(); XCTAssertTrue(before.isEmpty)
        explicit.start(); await waitForFinish(explicit)
        XCTAssertEqual(explicit.progress?.succeeded,2)
        explicit.start()
        let calls=await repository.recorded(); XCTAssertEqual(calls.count,2)
    }
    func testCancelRejectsLateResultAndStopsRemainingCandidates() async throws {
        let ids=try await insert(2)
        await repository.configure(held:1)
        let model=DownloadMetadataRefreshModel(jobIDs:Set(ids),scope:scope,service:service)
        await model.prepare(); model.start()
        while !(await repository.waiting()) { await Task.yield() }
        model.cancel()
        await repository.release(); await waitForFinish(model)
        XCTAssertEqual(model.progress?.stop,.cancelled)
        XCTAssertEqual(model.progress?.cancelled,2)
        let stored=try await items(); XCTAssertTrue(stored.allSatisfy{$0.metadata.state == .unknown})
        XCTAssertEqual(model.nextBatchCount, 2)
        await model.prepareNextBatch()
        XCTAssertEqual(model.plan?.jobIDs, ids)
        XCTAssertNil(model.progress)
        let calls=await repository.recorded(); XCTAssertEqual(calls,[1])
    }
    func testClosedPreviewCannotStartAndStaleSessionStopsInFlight() async throws {
        let ids=try await insert(1)
        let closed=DownloadMetadataRefreshModel(jobIDs:Set(ids),scope:scope,service:service)
        await closed.prepare(); closed.close(); closed.start()
        XCTAssertFalse(closed.running)
        await repository.configure(held:1)
        let model=DownloadMetadataRefreshModel(jobIDs:Set(ids),scope:scope,service:service)
        await model.prepare(); model.start()
        while !(await repository.waiting()) { await Task.yield() }
        await sessions.update(SessionState(scope:SessionScope(storage:scope.storage,generation:2),authentication:.authenticated))
        await repository.release(); await waitForFinish(model)
        XCTAssertEqual(model.progress?.stop,.staleSession)
        let stored=try await items(); XCTAssertEqual(stored[0].metadata.state,.unknown)
    }
    func testPrimaryRawLabelUnknownAndKnownEmpty() {
        XCTAssertEqual(DownloadMetadataPresentation.summary([],state:.unknown),"待补全")
        XCTAssertEqual(DownloadMetadataPresentation.summary([],state:.complete),"未标注")
        XCTAssertEqual(DownloadMetadataPresentation.summary(["Zulu","Alpha","alpha"],state:.complete),"Alpha 等 2 个")
        XCTAssertEqual(DownloadMetadataPresentation.summary(["   "],state:.complete),"未标注")
    }
    func testEachTargetKeepsSortAcrossReopenAndSiteSwitchWithoutNetwork() async throws {
        let ids=try await insert(2)
        await repository.configure(errors:[1:.transport(code:-1009),2:.transport(code:-1009)])
        let account=scope.storage.accountID
        let a=try await db.createFolder(name:DownloadFolderName("A"),account:account)
        let b=try await db.createFolder(name:DownloadFolderName("B"),account:account)
        try await db.moveItems(expectedMembershipRevisions:[ids[0]:DownloadLibraryRevision(1)],destinationFolderID:a.id,account:account)
        let reader=DownloadLibraryRepository(database:db,sessions:sessions)
        let targets:[DownloadLibraryTarget]=[.all,.unfiled,.folder(a.id),.folder(b.id)]
        let expected=[DownloadSort(field:.artist),DownloadSort(field:.group,direction:.descending),DownloadSort(field:.addedAt,direction:.ascending),DownloadSort()]
        for (target,sort) in zip(targets,expected) { try await reader.saveSort(sort,target:target,scope:scope) }
        // Changing A must not affect the other three targets.
        try await reader.saveSort(DownloadSort(field:.group),target:.folder(a.id),scope:scope)
        await db.close()
        db=try SQLiteDatabase(url:root.appendingPathComponent("db"))
        let ex=SessionScope(storage:StorageScope(accountID:account,site:.ex),generation:2)
        await sessions.update(SessionState(scope:ex,authentication:.authenticated))
        let reopened=DownloadLibraryRepository(database:db,sessions:sessions)
        for (index,target) in targets.enumerated() {
            let value=try await reopened.load(target:target,scope:ex,force:true)
            XCTAssertEqual(value.sort,index == 2 ? DownloadSort(field:.group) : expected[index])
        }
        let calls=await repository.recorded(); XCTAssertTrue(calls.isEmpty)
    }
}
