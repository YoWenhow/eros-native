import Foundation
import Observation
import XCTest
import ErosCore
import ErosServices
@testable import ErosPersistence

private final class D09ObservationCounter: @unchecked Sendable {
    private let lock=NSLock()
    private var value=0
    func increment() { lock.withLock { value += 1 } }
    func count() -> Int { lock.withLock { value } }
}
private actor D08Reader: DownloadLibraryReading {
    var value: DownloadLibraryViewSnapshot
    var held=false
    var gate: CheckedContinuation<Void,Never>?
    var failed=false
    var loads=0
    var forces:[Bool]=[]
    init(_ value:DownloadLibraryViewSnapshot) { self.value=value }
    func configure(_ value:DownloadLibraryViewSnapshot? = nil, held:Bool=false, failed:Bool=false) { if let value { self.value=value }; self.held=held; self.failed=failed }
    func waiting() -> Bool { gate != nil }
    func release() { gate?.resume(); gate=nil }
    func count() -> Int { loads }
    func load(target:DownloadLibraryTarget,scope:SessionScope,force:Bool) async throws -> DownloadLibraryViewSnapshot {
        loads += 1; forces.append(force); let captured=value
        if held { held=false; await withCheckedContinuation { gate=$0 } }
        if failed { throw AppError.transport(code:-1) }; return captured
    }
    func saveSort(_ sort:DownloadSort,target:DownloadLibraryTarget,scope:SessionScope) async throws {
        if failed { throw AppError.storageFull }
        value=DownloadLibraryViewSnapshot(target:target,sort:sort,folders:value.folders,counts:value.counts,items:DownloadLibrarySort.sorted(value.items,by:sort))
    }
}
private actor D08Controls: DownloadLibraryControlling {
    var calls:[UUID]=[]
    private var failingIDs: Set<UUID> = []
    func fail(_ id: UUID) { failingIDs.insert(id) }
    var held=false
    var gate:CheckedContinuation<Void,Never>?
    func configureHeld() { held=true }
    func waiting() -> Bool { gate != nil }
    func release() { gate?.resume(); gate=nil }
    func count() -> Int { calls.count }
    func control(_ action:DownloadLibraryControl,id:UUID,scope:SessionScope) async throws {
        calls.append(id)
        if held { held=false; await withCheckedContinuation { gate=$0 } }
        if failingIDs.contains(id) { throw DownloadLibraryError.primaryHasRetainedCopies }
    }
}
private actor D08Tick {
    var gate:CheckedContinuation<Void,Never>?
    func wait() async throws { await withCheckedContinuation { gate=$0 }; try Task.checkCancellation() }
    func waiting() -> Bool { gate != nil }
    func release() { gate?.resume(); gate=nil }
}
@MainActor final class DownloadLibraryViewModelTests: XCTestCase {
    let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1)
    func item(_ n:Int, artist:String="A") throws -> DownloadLibraryItem {
        let id=UUID(uuidString:String(format:"10000000-0000-0000-0000-%012d",n))!
        let summary=try GallerySummary(reference:GalleryReference(key:GalleryKey(site:.eh,galleryID:GalleryID(Int64(n))),token:SensitiveText("synthetic")),title:"gallery",pageCount:NonnegativeCount(1))
        return try DownloadLibraryItem(jobID:id,owner:scope.storage.accountID,folderID:nil,summary:summary,state:.queued,completedPages:NonnegativeCount(0),totalPages:NonnegativeCount(1),addedAt:DownloadLibraryTimestamp(Int64(n)),firstCompletedAt:nil,completionTimePolicy:.recordFirstObserved,completionTimeOrigin:.unknown,membershipRevision:DownloadLibraryRevision(1),metadataRevision:DownloadLibraryRevision(1),metadata:DownloadLibraryMetadata(artists:[artist],groups:[],state:.complete,sourceSite:.eh,fetchedAt:DownloadLibraryTimestamp(0)))
    }
    func snapshot(_ items:[DownloadLibraryItem],target:DownloadLibraryTarget = .all) -> DownloadLibraryViewSnapshot { .init(target:target,sort:DownloadSort(),folders:[],counts:[.all:items.count,.unfiled:items.count],items:items) }
    func testSearchFindsBothArchiveTitlesAfterLocalTitleFill() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try SQLiteDatabase(url: directory.appendingPathComponent("library.sqlite"))
        let account = scope.storage.accountID
        let folder = try await database.createFolder(name: DownloadFolderName("Archive folder"), account: account)

        let archiveScope = StorageScope(accountID: account, site: .ex)
        let archiveReference = try GalleryReference(key: GalleryKey(site: .ex, galleryID: GalleryID(201)),
                                                   token: SensitiveText("synthetic"))
        let archive = try GallerySummary(reference: archiveReference, title: "Saved archive name", pageCount: NonnegativeCount(1))
        let ordinary = try item(202).summary.withSourceTitles(GallerySourceTitles(gn: "Ordinary original", gj: "逐頁見本"))
        let fixture: [(GallerySummary, StorageScope, DownloadSourceKind, DownloadFolderID?)] = [
            (archive, archiveScope, .archive, folder.id), (ordinary, scope.storage, .pages, nil)
        ]
        var ids: [UUID] = []
        for (summary, storage, kind, destination) in fixture {
            let job = try DownloadJob(id: UUID(), scope: storage, reference: summary.reference, state: .queued,
                totalPages: NonnegativeCount(1), completedPages: NonnegativeCount(0), generation: 1, sourceKind: kind)
            let page = try DownloadPage(jobID: job.id, index: PageIndex(0), state: .pending)
            _ = try await database.insertDownloadWithLibrary(summary: summary, snapshot: DownloadSnapshot(job: job, pages: [page]),
                                                             destinationFolderID: destination)
            ids.append(job.id)
        }
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated, permitsNetwork: false))
        let model = DownloadLibraryViewModel(repository: DownloadLibraryRepository(database: database, sessions: sessions),
                                             controls: D08Controls(), sessions: sessions, scope: scope)
        await model.refresh()
        XCTAssertEqual(model.items(matchingTitle: "").count, 2)
        XCTAssertEqual(model.items(matchingTitle: "saved archive").map(\.jobID), [ids[0]])
        XCTAssertEqual(model.items(matchingTitle: "逐頁").map(\.jobID), [ids[1]])
        XCTAssertTrue(model.items(matchingTitle: "アーカイブ").isEmpty)

        try await database.fillGallerySourceTitles(GallerySourceTitles(gn: "Canonical original", gj: "アーカイブ見本"),
                                                   reference: archiveReference, scope: archiveScope)
        await model.refresh()
        XCTAssertEqual(model.items(matchingTitle: "アーカイブ").map(\.jobID), [ids[0]])
        XCTAssertEqual(model.items(matchingTitle: "ORIGINAL").count, 2)

        await model.selectTarget(.unfiled)
        XCTAssertTrue(model.items(matchingTitle: "アーカイブ").isEmpty)
        await model.selectTarget(.folder(folder.id))
        XCTAssertEqual(model.items(matchingTitle: "アーカイブ").map(\.sourceKind), [.archive])
        await database.close()
    }

    func testEmptyLibraryBackgroundRefreshDoesNotBecomeInitialLoadingAgain() async throws {
        let reader=D08Reader(snapshot([])), sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        let model=DownloadLibraryViewModel(repository:reader,controls:D08Controls(),sessions:sessions,scope:scope)
        XCTAssertFalse(model.hasLoaded)
        await model.refresh(); XCTAssertTrue(model.hasLoaded)
        await reader.configure(held:true)
        let refresh=Task { await model.refresh() }
        while !(await reader.waiting()) { await Task.yield() }
        XCTAssertFalse(model.loading); XCTAssertTrue(model.hasLoaded)
        await reader.release(); await refresh.value
        let next=SessionScope(storage:scope.storage,generation:scope.generation + 1)
        model.setScope(next); XCTAssertFalse(model.hasLoaded)
    }
    func testUnchangedPollingDoesNotInvalidateListButChangedCountsDo() async throws {
        let a=try item(1), reader=D08Reader(snapshot([try item(1)]))
        let sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        let model=DownloadLibraryViewModel(repository:reader,controls:D08Controls(),sessions:sessions,scope:scope)
        await model.refresh()
        let changes=D09ObservationCounter()
        withObservationTracking {
            _ = model.folders; _ = model.counts; _ = model.items
            _ = model.loading; _ = model.hasLoaded; _ = model.error
        } onChange: { changes.increment() }
        await model.refresh(); await model.refresh()
        XCTAssertEqual(changes.count(),0)
        await reader.configure(snapshot([a,try item(2)]))
        await model.refresh()
        XCTAssertGreaterThan(changes.count(),0)
        XCTAssertEqual(model.counts[.all],2)
        XCTAssertEqual(model.items.count,2)
    }
    func testPollingOnlyInvalidatesSelectionWhenSelectedIDsChange() async throws {
        let item = try item(1)
        let reader = D08Reader(snapshot([item]))
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let model = DownloadLibraryViewModel(repository: reader, controls: D08Controls(), sessions: sessions, scope: scope)
        await model.refresh()
        model.setSelection([item.jobID])

        let changes = D09ObservationCounter()
        withObservationTracking {
            _ = model.selection
        } onChange: { changes.increment() }

        await model.refresh()
        XCTAssertEqual(changes.count(), 0)
        let updated = try self.item(1, artist: "Updated metadata")
        await reader.configure(snapshot([updated]))
        await model.refresh()
        XCTAssertEqual(model.items, [updated])
        XCTAssertEqual(model.selection, [item.jobID])
        XCTAssertEqual(changes.count(), 0)

        await reader.configure(snapshot([]))
        await model.refresh()
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(changes.count(), 1)
    }

    func testLateOldTargetCannotReplaceNewTarget() async throws {
        let a=try item(1), b=try item(2)
        let reader=D08Reader(snapshot([a])), controls=D08Controls(), sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        let model=DownloadLibraryViewModel(repository:reader,controls:controls,sessions:sessions,scope:scope)
        await reader.configure(held:true)
        let old=Task { await model.refresh() }
        while !(await reader.waiting()) { await Task.yield() }
        await reader.configure(snapshot([b],target:.unfiled))
        await model.selectTarget(.unfiled)
        await reader.release(); await old.value
        XCTAssertEqual(model.target,.unfiled); XCTAssertEqual(model.items.map(\.jobID),[b.jobID]); XCTAssertFalse(model.loading)
    }
    func testSelectionAnchorIntersectionAndErrorsPreserveContent() async throws {
        let a=try item(1),b=try item(2)
        let reader=D08Reader(snapshot([a,b])), controls=D08Controls(), sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        let model=DownloadLibraryViewModel(repository:reader,controls:controls,sessions:sessions,scope:scope)
        await model.refresh(); model.setSelection([a.jobID,b.jobID,UUID()]); model.setVisibleAnchor(b.jobID)
        await reader.configure(snapshot([b])); await model.refresh()
        XCTAssertEqual(model.selection,[b.jobID]); XCTAssertEqual(model.visibleAnchor,b.jobID)
        await reader.configure(failed:true); await model.refresh(force:true)
        XCTAssertEqual(model.items,[b]); XCTAssertEqual(model.error,.unavailable)
        await reader.configure(snapshot([])); await model.refresh()
        XCTAssertTrue(model.items.isEmpty); XCTAssertTrue(model.selection.isEmpty); XCTAssertNil(model.visibleAnchor); XCTAssertNil(model.error)
    }
    func testScopeChangeAndLateResponseClearOldAccountData() async throws {
        let reader=D08Reader(snapshot([try item(1)])), sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        let model=DownloadLibraryViewModel(repository:reader,controls:D08Controls(),sessions:sessions,scope:scope)
        await model.refresh(); await reader.configure(held:true)
        let old=Task { await model.refresh() }; while !(await reader.waiting()) { await Task.yield() }
        let next=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:2)
        await sessions.update(SessionState(scope:next,authentication:.authenticated)); model.setScope(next)
        await reader.release(); await old.value
        XCTAssertTrue(model.items.isEmpty); XCTAssertTrue(model.selection.isEmpty); XCTAssertFalse(model.loading)
        // A model whose caller has not yet delivered the scope update also rejects stale data.
        model.setScope(scope); await model.refresh(); XCTAssertEqual(model.error,.staleSession); XCTAssertTrue(model.items.isEmpty)
    }
    func testDisplaySortNeverControlsSchedulerAndBusyRequestsAreCoalesced() async throws {
        let a=try item(1,artist:"Z"),b=try item(2,artist:"A")
        let reader=D08Reader(snapshot([a,b])), controls=D08Controls(), sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        let model=DownloadLibraryViewModel(repository:reader,controls:controls,sessions:sessions,scope:scope)
        await model.refresh(); model.setSelection([a.jobID]); model.setVisibleAnchor(a.jobID)
        await model.setSort(DownloadSort(field:.artist))
        XCTAssertEqual(model.items.map(\.jobID),[b.jobID,a.jobID]); XCTAssertEqual(model.selection,[a.jobID]); XCTAssertEqual(model.visibleAnchor,a.jobID)
        let zero=await controls.count(); XCTAssertEqual(zero,0)
        await controls.configureHeld()
        let action=Task { await model.operate(.pause,id:a.jobID) }
        while !(await controls.waiting()) { await Task.yield() }
        let count=await reader.count(); await model.refresh(); await model.operate(.pause,id:a.jobID)
        let during=await reader.count(); XCTAssertEqual(count,during); XCTAssertEqual(model.busyIDs,[a.jobID])
        await controls.release(); await action.value
        let calls=await controls.count(); XCTAssertEqual(calls,1); XCTAssertTrue(model.busyIDs.isEmpty)
    }
    func testBatchDeleteReservesConfirmedJobsAndRefreshesOnceAfterPartialFailure() async throws {
        let failed = try item(1), deleted = try item(2), untouched = try item(3)
        let reader = D08Reader(snapshot([failed, deleted, untouched]))
        let controls = D08Controls()
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let model = DownloadLibraryViewModel(repository: reader, controls: controls, sessions: sessions, scope: scope)
        await model.refresh()
        model.setSelection([failed.jobID, deleted.jobID])
        await controls.fail(failed.jobID)
        await controls.configureHeld()

        let batch = Task { await model.deleteSelected([failed.jobID, deleted.jobID, UUID()]) }
        while !(await controls.waiting()) { await Task.yield() }
        XCTAssertEqual(model.busyIDs, [failed.jobID, deleted.jobID])
        await model.operate(.pause, id: deleted.jobID)
        await model.refresh()
        let loadsDuringDelete = await reader.count()
        XCTAssertEqual(loadsDuringDelete, 1)

        await reader.configure(snapshot([failed, untouched]))
        await controls.release()
        let remaining = await batch.value
        let calls = await controls.calls
        let loads = await reader.count()
        XCTAssertEqual(remaining, 1)
        XCTAssertEqual(calls, [failed.jobID, deleted.jobID])
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(model.items, [failed, untouched])
        XCTAssertEqual(model.selection, [failed.jobID])
        XCTAssertTrue(model.busyIDs.isEmpty)
    }

    func testBatchDeleteStopsBeforeNextJobWhenSessionChanges() async throws {
        let first = try item(1), second = try item(2)
        let reader = D08Reader(snapshot([first, second]))
        let controls = D08Controls()
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let model = DownloadLibraryViewModel(repository: reader, controls: controls, sessions: sessions, scope: scope)
        await model.refresh()
        await controls.configureHeld()
        let batch = Task { await model.deleteSelected([first.jobID, second.jobID]) }
        while !(await controls.waiting()) { await Task.yield() }
        let next = SessionScope(storage: scope.storage, generation: scope.generation + 1)
        await sessions.update(SessionState(scope: next, authentication: .authenticated))
        await controls.release()
        _ = await batch.value
        let calls = await controls.calls
        XCTAssertEqual(calls, [first.jobID])
        XCTAssertEqual(model.error, .staleSession)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(model.busyIDs.isEmpty)
    }

    func testPollingOnlyVisibleForegroundAndLateHiddenLoadIsIgnored() async throws {
        let a=try item(1), reader=D08Reader(snapshot([])), tick=D08Tick(), sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        let model=DownloadLibraryViewModel(repository:reader,controls:D08Controls(),sessions:sessions,scope:scope,waitForPoll:{ try await tick.wait() })
        model.setActivity(visible:true,foreground:false)
        let initial=await reader.count(); XCTAssertEqual(initial,0)
        model.setActivity(visible:true,foreground:true)
        while !(await tick.waiting()) { await Task.yield() }
        model.setActivity(visible:false,foreground:true); await tick.release()
        XCTAssertFalse(model.polling)
        await reader.configure(snapshot([a]),held:true)
        model.setActivity(visible:true,foreground:true)
        while !(await reader.waiting()) { await Task.yield() }
        model.setActivity(visible:true,foreground:false); await reader.release()
        // Queue an actor read after release; cancelled refresh must not publish captured contents.
        _ = await reader.count()
        XCTAssertTrue(model.items.isEmpty); XCTAssertFalse(model.loading)
        // Release any injected sleep reached by the exiting loop.
        await tick.release()
    }
    func testResumingFolderPollingAfterReadbackWaitsForTheNextTick() async throws {
        let reader = D08Reader(snapshot([])), tick = D08Tick()
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let model = DownloadLibraryViewModel(repository: reader, controls: D08Controls(), sessions: sessions,
                                             scope: scope, waitForPoll: { try await tick.wait() })
        await model.refresh(force: true)
        model.setActivity(visible: true, foreground: true, refreshImmediately: false)
        while !(await tick.waiting()) { await Task.yield() }
        let beforeTick = await reader.count()
        XCTAssertEqual(beforeTick, 1)

        await tick.release()
        while !(await tick.waiting()) { await Task.yield() }
        let afterTick = await reader.count()
        XCTAssertEqual(afterTick, 2)

        model.setActivity(visible: false, foreground: true)
        await tick.release()
        XCTAssertFalse(model.polling)
    }

    func testSortSaveFailurePreservesDisplayedSortAndReportsError() async throws {
        let a=try item(1), reader=D08Reader(snapshot([])), sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        await reader.configure(snapshot([a]))
        let model=DownloadLibraryViewModel(repository:reader,controls:D08Controls(),sessions:sessions,scope:scope)
        await model.refresh(); await reader.configure(failed:true)
        await model.setSort(DownloadSort(field:.artist))
        XCTAssertEqual(model.sort,DownloadSort()); XCTAssertEqual(model.items,[a]); XCTAssertEqual(model.error,.unavailable)
        await reader.configure(); await model.setSort(DownloadSort(field:.group))
        XCTAssertEqual(model.sort.field,.group); XCTAssertNil(model.error)
    }

    func testDeletedTargetFallbackClearsSelectionAndAnchor() async throws {
        let a=try item(1), folder=DownloadFolderID(UUID())
        let reader=D08Reader(snapshot([a],target:.folder(folder))), sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        let model=DownloadLibraryViewModel(repository:reader,controls:D08Controls(),sessions:sessions,scope:scope)
        await model.selectTarget(.folder(folder)); model.setSelection([a.jobID]); model.setVisibleAnchor(a.jobID)
        await reader.configure(snapshot([a],target:.unfiled)); await model.refresh()
        XCTAssertEqual(model.target,.unfiled); XCTAssertTrue(model.selection.isEmpty); XCTAssertNil(model.visibleAnchor)
    }
}

@MainActor final class DownloadLibraryRepositoryTests: XCTestCase {
    var directory:URL!
    var url:URL { directory.appendingPathComponent("db") }
    var db:SQLiteDatabase!
    var sessions:MutableSessionProvider!
    let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1)
    override func setUp() async throws {
        directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        db=try SQLiteDatabase(url:url,libraryNow:{DownloadLibraryTimestamp(10)})
        sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
    }
    override func tearDown() async throws { await db.close(); try FileManager.default.removeItem(at:directory) }
    func seed() async throws -> UUID {
        let id=UUID(), ref=try GalleryReference(key:GalleryKey(site:.eh,galleryID:GalleryID(1)),token:SensitiveText("synthetic"))
        let summary=try GallerySummary(reference:ref,title:"title",pageCount:NonnegativeCount(1))
        let job=try DownloadJob(id:id,scope:scope.storage,reference:ref,state:.queued,totalPages:NonnegativeCount(1),completedPages:NonnegativeCount(0),generation:1)
        let snapshot=try DownloadSnapshot(job:job,pages:[DownloadPage(jobID:id,index:PageIndex(0),state:.pending)])
        _ = try await db.insertDownloadWithLibrary(summary:summary,snapshot:snapshot,metadata:DownloadLibraryMetadata.from(detail:GalleryDetail(summary:summary,tags:[.init(namespace:"artist",tags:["A"])]),fetchedAt:DownloadLibraryTimestamp(1)))
        return id
    }
    func testFolderOverviewCountsMembershipWithoutReadingTaskPayloads() async throws {
        let id=try await seed(), reader=DownloadFolderOverviewReader(database:db,sessions:sessions)
        let folder=try await db.createFolder(name:DownloadFolderName("folder"),account:scope.storage.accountID)
        let first=try await reader.load(target:.all,scope:scope,force:true)
        XCTAssertEqual(first.counts[.all],1); XCTAssertEqual(first.counts[.unfiled],1)
        XCTAssertEqual(first.counts[.folder(folder.id)],0); XCTAssertTrue(first.items.isEmpty)
        try await db.moveItems(expectedMembershipRevisions:[id:DownloadLibraryRevision(1)],destinationFolderID:folder.id,account:scope.storage.accountID)
        let raw=try SQLiteConnection(path:url.path)
        try raw.execute("UPDATE download_jobs SET payload=X'00'")
        try raw.execute("UPDATE download_pages SET payload=X'00'")
        try raw.execute("UPDATE galleries SET payload=X'00'")
        try raw.execute("UPDATE download_library_items SET artistsPayload=X'00'")
        raw.close()
        let moved=try await reader.load(target:.all,scope:scope,force:false)
        XCTAssertEqual(moved.counts[.unfiled],0); XCTAssertEqual(moved.counts[.folder(folder.id)],1)
        XCTAssertEqual(moved.folders,[folder]); XCTAssertTrue(moved.items.isEmpty)
        try await db.deleteFolderAndUnfile(id:folder.id,expectedRevision:folder.revision,account:scope.storage.accountID)
        let deleted=try await reader.load(target:.all,scope:scope,force:false)
        XCTAssertEqual(deleted.counts[.all],1); XCTAssertEqual(deleted.counts[.unfiled],1); XCTAssertTrue(deleted.folders.isEmpty)
        let other=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:2)
        await sessions.update(SessionState(scope:other,authentication:.authenticated))
        do { _ = try await reader.load(target:.all,scope:scope,force:false); XCTFail() } catch { XCTAssertEqual(error as? AppError,.staleSession) }
        let isolated=try await reader.load(target:.all,scope:other,force:false)
        XCTAssertEqual(isolated.counts[.all],0); XCTAssertTrue(isolated.folders.isEmpty)
    }
    func testScalarProgressPollingDoesNotDecodeAnyPayloadAndForceReportsCorruption() async throws {
        let id=try await seed(), repository=DownloadLibraryRepository(database:db,sessions:sessions)
        let first=try await repository.load(target:.all,scope:scope)
        let raw=try SQLiteConnection(path:url.path)
        try raw.execute("UPDATE download_jobs SET state='paused',payload=X'00'")
        try raw.execute("UPDATE download_pages SET payload=X'00'")
        try raw.execute("UPDATE galleries SET payload=X'00'")
        try raw.execute("UPDATE download_library_items SET artistsPayload=X'00'")
        raw.close()
        let polled=try await repository.load(target:.all,scope:scope)
        XCTAssertEqual(polled.items[0].jobID,id); XCTAssertEqual(polled.items[0].state,.paused); XCTAssertEqual(polled.items[0].summary,first.items[0].summary)
        do { _ = try await repository.load(target:.all,scope:scope,force:true); XCTFail() } catch { XCTAssertEqual(error as? PersistenceError,.corruptRecord) }
    }
    func testFolderMetadataDirtyCountsAndDeletedTargetFallback() async throws {
        let id=try await seed(), repository=DownloadLibraryRepository(database:db,sessions:sessions)
        _ = try await repository.load(target:.all,scope:scope)
        let f=try await db.createFolder(name:DownloadFolderName("folder"),account:scope.storage.accountID)
        try await db.moveItems(expectedMembershipRevisions:[id:DownloadLibraryRevision(1)],destinationFolderID:f.id,account:scope.storage.accountID)
        try await db.renameFolder(id:f.id,name:DownloadFolderName("renamed"),expectedRevision:f.revision,account:scope.storage.accountID)
        let metadata=try DownloadLibraryMetadata(artists:["new"],groups:[],state:.complete,sourceSite:.ex,fetchedAt:DownloadLibraryTimestamp(20))
        try await db.updateMetadata(jobID:id,metadata:metadata,expectedMetadataRevision:DownloadLibraryRevision(1),account:scope.storage.accountID)
        let dirty=try await repository.load(target:.folder(f.id),scope:scope)
        XCTAssertEqual(dirty.items[0].metadata,metadata); XCTAssertEqual(dirty.folders[0].displayName.value,"renamed"); XCTAssertEqual(dirty.counts[.all],1); XCTAssertEqual(dirty.counts[.unfiled],0)
        try await db.deleteFolderAndUnfile(id:f.id,expectedRevision:DownloadLibraryRevision(2),account:scope.storage.accountID)
        let fallback=try await repository.load(target:.folder(f.id),scope:scope)
        XCTAssertEqual(fallback.target,.unfiled); XCTAssertEqual(fallback.items[0].jobID,id); XCTAssertEqual(fallback.counts[.unfiled],1)
    }
    func testSortPersistenceAndScopeRevalidation() async throws {
        _ = try await seed(); let repository=DownloadLibraryRepository(database:db,sessions:sessions)
        try await repository.saveSort(DownloadSort(field:.group,direction:.descending),target:.all,scope:scope)
        let restored=try await DownloadLibraryRepository(database:db,sessions:sessions).load(target:.all,scope:scope)
        XCTAssertEqual(restored.sort,DownloadSort(field:.group,direction:.descending))
        await sessions.update(SessionState(scope:SessionScope(storage:scope.storage,generation:2),authentication:.authenticated))
        do { _ = try await repository.load(target:.all,scope:scope); XCTFail() } catch { XCTAssertEqual(error as? AppError,.staleSession) }
    }
}