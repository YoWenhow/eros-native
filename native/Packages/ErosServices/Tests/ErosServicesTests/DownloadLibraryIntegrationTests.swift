import Foundation
import XCTest
import ErosCore
import ErosServices
@testable import ErosPersistence

private extension SQLiteDatabase {
    func resetD13Metrics() {
        connection.diagnosticStatementCount=0
        connection.diagnosticSingleGalleryReads=0
        diagnosticPageDecodeAttempts=0
    }
    func d13Metrics() -> [String:Int] {
        ["sqlStatements":connection.diagnosticStatementCount,
         "individualTitleQueries":connection.diagnosticSingleGalleryReads,
         "pageDecodeAttempts":diagnosticPageDecodeAttempts]
    }
    func poisonD13Payloads() throws {
        try connection.execute("UPDATE download_pages SET payload=X'00'")
        try connection.execute("UPDATE download_jobs SET payload=X'00'")
    }
}

@MainActor final class DownloadLibraryIntegrationTests: XCTestCase {
    var root:URL!
    var db:SQLiteDatabase!
    let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1)
    override func setUp() async throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("D13-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        db=try SQLiteDatabase(url:root.appendingPathComponent("db"),libraryNow:{DownloadLibraryTimestamp(1234)})
    }
    override func tearDown() async throws { await db.close(); try FileManager.default.removeItem(at:root) }
    func proposed(_ n:Int,scope:SessionScope,sourceKind:DownloadSourceKind = .pages) throws -> (GallerySummary,DownloadSnapshot) {
        let id=UUID(),ref=try GalleryReference(key:GalleryKey(site:scope.storage.site,galleryID:GalleryID(Int64(n))),token:SensitiveText("SYNTHETIC"))
        let summary=try GallerySummary(reference:ref,title:"SYNTHETIC \(n)",pageCount:NonnegativeCount(1))
        let job=try DownloadJob(id:id,scope:scope.storage,reference:ref,state:.queued,totalPages:NonnegativeCount(1),completedPages:NonnegativeCount(0),generation:1,sourceKind:sourceKind)
        return (summary,try DownloadSnapshot(job:job,pages:[DownloadPage(jobID:id,index:PageIndex(0),state:.pending)]))
    }
    nonisolated static func attempt(_ summary:GallerySummary,_ snapshot:DownloadSnapshot,_ folder:DownloadFolderID,database:SQLiteDatabase) async throws -> Bool {
        do {
            _ = try await database.insertDownloadWithLibrary(summary:summary,snapshot:snapshot,destinationFolderID:folder)
            return true
        } catch DownloadLibraryError.folderNotFound { return false }
    }
    func testUnfinishedCollectionIncludesAllPendingStatesAndTracksStateOnlyChanges() async throws {
        let owner = scope.storage.accountID
        let ex = SessionScope(storage: StorageScope(accountID: owner, site: .ex), generation: scope.generation)
        let other = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
        let folder = try await db.createFolder(name: DownloadFolderName("Existing folder"), account: owner)
        let states: [DownloadJobState] = [.queued, .resolving, .downloading, .paused, .waitingForNetwork,
                                          .authenticationRequired, .failed, .cancelled, .completed]
        var fixtures: [DownloadSnapshot] = []
        for (index, state) in states.enumerated() {
            let isArchive = index.isMultiple(of: 2)
            let (summary, queued) = try proposed(index + 1, scope: isArchive ? ex : scope,
                                                 sourceKind: isArchive ? .archive : .pages)
            _ = try await db.insertDownloadWithLibrary(summary: summary, snapshot: queued,
                                                       destinationFolderID: isArchive ? folder.id : nil)
            let snapshot = try snapshot(queued, withState: state)
            if state != .queued { try await db.saveDownload(snapshot) }
            fixtures.append(snapshot)
        }
        let (otherSummary, otherJob) = try proposed(20, scope: other)
        _ = try await db.insertDownloadWithLibrary(summary: otherSummary, snapshot: otherJob, destinationFolderID: nil)

        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let repository = DownloadLibraryRepository(database: db, sessions: sessions)
        let sort = DownloadSort(field: .addedAt, direction: .ascending)
        try await repository.saveSort(sort, target: .unfinished, scope: scope)
        let allSort = try await db.loadSort(target: .all, account: owner)
        XCTAssertEqual(allSort, sort)

        let first = try await repository.load(target: .unfinished, scope: scope)
        let direct = try await db.listItems(target: .unfinished, account: owner)
        let overview = try await db.downloadFolderOverview(account: owner)
        let expected = Set(fixtures.dropLast().map(\.job.id))
        XCTAssertEqual(first.target, .unfinished)
        XCTAssertEqual(first.sort, sort)
        XCTAssertEqual(Set(first.items.map(\.state)), Set(states.dropLast()))
        XCTAssertEqual(Set(first.items.map(\.jobID)), expected)
        XCTAssertEqual(Set(direct.map(\.jobID)), expected)
        XCTAssertEqual(first.counts, overview.counts)
        XCTAssertEqual(first.counts[.unfinished], 8)
        XCTAssertEqual(first.counts[.all], 9)
        XCTAssertEqual(first.counts[.unfiled], 4)
        XCTAssertEqual(first.counts[.folder(folder.id)], 5)

        let completed = try XCTUnwrap(fixtures.last)
        try await db.saveDownload(snapshot(completed, withState: .failed))
        await db.resetD13Metrics()
        let reopened = try await repository.load(target: .unfinished, scope: scope)
        let metrics = await db.d13Metrics()
        XCTAssertEqual(Set(reopened.items.map(\.jobID)), expected.union([completed.job.id]))
        XCTAssertEqual(reopened.counts[.unfinished], 9)
        XCTAssertEqual(metrics["sqlStatements"], 5)

        try await db.saveDownload(completed)
        let finished = try await repository.load(target: .unfinished, scope: scope)
        let finalOverview = try await db.downloadFolderOverview(account: owner)
        XCTAssertEqual(Set(finished.items.map(\.jobID)), expected)
        XCTAssertEqual(finished.counts, finalOverview.counts)
        XCTAssertEqual(finished.counts[.unfinished], 8)
    }

    private func snapshot(_ original: DownloadSnapshot, withState state: DownloadJobState) throws -> DownloadSnapshot {
        let previous = original.job
        let job = try DownloadJob(id: previous.id, scope: previous.scope, reference: previous.reference, state: state,
            totalPages: previous.totalPages, completedPages: NonnegativeCount(state == .completed ? 1 : 0),
            generation: previous.generation, sourceKind: previous.sourceKind)
        let page = if state == .completed {
            try DownloadPage(jobID: job.id, index: PageIndex(0), state: .completed,
                             relativePath: RelativePath("\(job.id.uuidString)/0001.jpg"), size: NonnegativeCount(1))
        } else {
            try DownloadPage(jobID: job.id, index: PageIndex(0), state: .pending)
        }
        return try DownloadSnapshot(job: job, pages: [page])
    }

    func testDeleteFolderRacesEnqueueWithoutPartialRowsOrLostDownloads() async throws {
        let account=scope.storage.accountID
        for n in 1...20 {
            let folder=try await db.createFolder(name:DownloadFolderName("race \(n)"),account:account)
            try await db.saveDefaultFolder(folderID:folder.id,account:account)
            try await db.saveSort(target:.folder(folder.id),sort:DownloadSort(field:.artist),account:account)
            let (summary,snapshot)=try proposed(n,scope:scope)
            let database=db!
            async let inserted=Self.attempt(summary,snapshot,folder.id,database:database)
            async let deleted:Void=database.deleteFolderAndUnfile(id:folder.id,expectedRevision:folder.revision,account:account)
            let success=try await inserted
            try await deleted
            let items=try await db.listItems(target:.all,account:account)
            let found=items.first { $0.jobID == snapshot.job.id }
            XCTAssertEqual(found != nil,success)
            XCTAssertNil(found?.folderID)
            let saved=try await db.download(jobID:snapshot.job.id,scope:scope.storage)
            XCTAssertEqual(saved != nil,success)
            let defaultID=try await db.loadDefaultFolder(account:account);XCTAssertNil(defaultID)
            let folders=try await db.listFolders(account:account);XCTAssertTrue(folders.isEmpty)
        }
    }
    func testThousandItemsHundredFoldersPerAccountUseBoundedProjectionQueries() async throws {
        let second=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.ex),generation:2)
        let sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated))
        for owner in [scope,second] {
            var folders:[DownloadFolder]=[]
            for n in 0..<100 { folders.append(try await db.createFolder(name:DownloadFolderName("folder \(n)"),account:owner.storage.accountID)) }
            for n in 1...1000 {
                let (summary,snapshot)=try proposed(n,scope:owner)
                let metadata=try DownloadLibraryMetadata(artists:["artist \(n % 19)","secondary"],groups:["group \(n % 23)"],state:.complete,sourceSite:owner.storage.site,fetchedAt:DownloadLibraryTimestamp(5))
                _ = try await db.insertDownloadWithLibrary(summary:summary,snapshot:snapshot,destinationFolderID:folders[n % 100].id,metadata:metadata)
            }
        }
        // Invalid payloads prove that projections never decode a job/page payload.
        try await db.poisonD13Payloads()
        for (index,owner) in [scope,second].enumerated() {
            await sessions.update(SessionState(scope:owner,authentication:.authenticated))
            let repository=DownloadLibraryRepository(database:db,sessions:sessions)
            await db.resetD13Metrics()
            let start=ContinuousClock.now
            let full=try await repository.load(target:.all,scope:owner,force:true)
            let fullDuration=start.duration(to:.now)
            let fullMetrics=await db.d13Metrics()
            XCTAssertEqual(full.items.count,1000);XCTAssertEqual(full.folders.count,100)
            XCTAssertEqual(full.counts[.all],1000);XCTAssertEqual(full.counts[.unfiled],0)
            XCTAssertTrue(full.items.allSatisfy{$0.owner == owner.storage.accountID})
            XCTAssertTrue(full.folders.allSatisfy{full.counts[.folder($0.id)] == 10})
            XCTAssertEqual(fullMetrics["sqlStatements"],8)
            XCTAssertEqual(fullMetrics["individualTitleQueries"],0);XCTAssertEqual(fullMetrics["pageDecodeAttempts"],0)
            await db.resetD13Metrics()
            let warm=try await repository.load(target:.all,scope:owner)
            let warmMetrics=await db.d13Metrics()
            XCTAssertEqual(warm.items,full.items);XCTAssertEqual(warmMetrics["sqlStatements"],5)
            XCTAssertEqual(warmMetrics["pageDecodeAttempts"],0)
            await db.resetD13Metrics()
            let overview=try await DownloadFolderOverviewReader(database:db,sessions:sessions).load(target:.all,scope:owner,force:true)
            let overviewMetrics=await db.d13Metrics()
            XCTAssertEqual(overview.counts,full.counts);XCTAssertEqual(overviewMetrics["sqlStatements"],2)
            let sortStart=ContinuousClock.now
            for field in DownloadSortField.allCases {
                for direction in DownloadSortDirection.allCases {
                    let sort=DownloadSort(field:field,direction:direction)
                    let ordered=DownloadLibrarySort.sorted(full.items,by:sort)
                    XCTAssertEqual(ordered.map(\.jobID),DownloadLibrarySort.sorted(Array(full.items.reversed()),by:sort).map(\.jobID))
                }
            }
            let sortDuration=sortStart.duration(to:.now)
            let report:[String:Any]=["accountIndex":index,"items":1000,"folders":100,"full":fullMetrics,"warm":warmMetrics,"overview":overviewMetrics,"fullLoadMilliseconds":milliseconds(fullDuration),"twelveSortsMilliseconds":milliseconds(sortDuration),"networkDependencies":0,"poisonedPageAndJobPayloads":true]
            print("D13_METRICS "+String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
        }
    }
    private func milliseconds(_ duration:Duration) -> Double {
        Double(duration.components.seconds)*1000 + Double(duration.components.attoseconds)/1e15
    }
    func testCalendarYearSecondsTimezoneAndUnknownDisplay() throws {
        let parser=ISO8601DateFormatter()
        let value=try XCTUnwrap(parser.date(from:"2019-12-30T15:04:05Z"))
        let timestamp=DownloadLibraryTimestamp(Int64(value.timeIntervalSince1970*1000))
        XCTAssertEqual(DownloadMetadataPresentation.timestamp(timestamp,timeZone:TimeZone(secondsFromGMT:0)!),"2019-12-30 15:04:05")
        XCTAssertEqual(DownloadMetadataPresentation.timestamp(timestamp,timeZone:TimeZone(secondsFromGMT:28800)!),"2019-12-30 23:04:05")
        XCTAssertEqual(DownloadMetadataPresentation.timestamp(nil),"未知")
    }
}
