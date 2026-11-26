import Foundation
import XCTest
import ErosCore
@testable import ErosPersistence

private final class D05Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 100
    func now() -> DownloadLibraryTimestamp { lock.lock(); defer { lock.unlock() }; return DownloadLibraryTimestamp(value) }
    func set(_ value: Int64) { lock.lock(); defer { lock.unlock() }; self.value = value }
}
@MainActor final class DownloadLifecycleTests: XCTestCase {
    var directory: URL!
    var url: URL { directory.appendingPathComponent("test.sqlite") }
    var db: SQLiteDatabase!
    private var clock: D05Clock!
    var fixture: D01V1Fixture.Expected!
    var scope: StorageScope { D01V1Fixture.scopes[0] }
    var account: AccountID { scope.accountID }
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("D05-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fixture = try D01V1Fixture.create(at: url); clock = D05Clock()
        let clock = clock!
        db = try SQLiteDatabase(url: url, libraryNow: { clock.now() })
    }
    override func tearDown() async throws { await db.close(); try FileManager.default.removeItem(at: directory) }
    func raw(_ work: (SQLiteConnection) throws -> Void) throws {
        let c = try SQLiteConnection(path: url.path); defer { c.close() }; try work(c)
    }
    func proposed(gid: Int64 = 999, scope: StorageScope? = nil, id: UUID = UUID()) throws -> (GallerySummary, DownloadSnapshot) {
        let scope = scope ?? self.scope
        let reference = try GalleryReference(key: GalleryKey(site: scope.site, galleryID: GalleryID(gid)), token: SensitiveText("synthetic"))
        let summary = try GallerySummary(reference: reference, title: "D05", pageCount: NonnegativeCount(2))
        let job = try DownloadJob(id: id, scope: scope, reference: reference, state: .queued, totalPages: NonnegativeCount(2), completedPages: NonnegativeCount(0), generation: 1)
        return (summary, try DownloadSnapshot(job: job, pages: (0..<2).map { try DownloadPage(jobID: id, index: PageIndex($0), state: .pending) }))
    }
    func changed(_ snapshot: DownloadSnapshot, state: DownloadJobState, generation: UInt64) throws -> DownloadSnapshot {
        let job = snapshot.job
        let complete = state == .completed
        let pages = try (0..<2).map { try DownloadPage(jobID: job.id, index: PageIndex($0), state: complete ? .completed : .pending, relativePath: complete ? RelativePath("\(job.id.uuidString)/\($0).img") : nil, size: complete ? NonnegativeCount(4) : nil) }
        return try DownloadSnapshot(job: DownloadJob(id: job.id, scope: job.scope, reference: job.reference, state: state, totalPages: job.totalPages, completedPages: NonnegativeCount(complete ? 2 : 0), generation: generation), pages: pages)
    }
    func item(_ id: UUID) async throws -> DownloadLibraryItem {
        let items = try await db.listItems(target: .all, account: account)
        return try XCTUnwrap(items.first { $0.jobID == id })
    }
    func testDownloadTitleAndTagUpdateRollsBackTogether() async throws {
        let (summary, initial) = try proposed()
        _ = try await db.insertDownloadWithLibrary(summary: summary, snapshot: initial)
        let before = try await item(initial.job.id)
        let metadata = try DownloadLibraryMetadata(artists: ["synthetic artist"], groups: [], state: .complete,
            sourceSite: scope.site, fetchedAt: DownloadLibraryTimestamp(100))
        let titles = GallerySourceTitles(gn: "Synthetic title", gj: "日文")
        try raw { connection in
            try connection.execute("CREATE TRIGGER reject_tags BEFORE UPDATE OF metadataState ON download_library_items BEGIN SELECT RAISE(ABORT,'injected'); END")
        }
        do {
            try await db.updateMetadata(jobID: initial.job.id, metadata: metadata, titleUpdate: (summary.reference, titles),
                expectedMetadataRevision: before.metadataRevision, account: account)
            XCTFail("Injected write failure was ignored")
        } catch {
            XCTAssertTrue(error is PersistenceError)
        }
        let after = try await item(initial.job.id)
        XCTAssertEqual(after, before)
    }

    func testSinglePageCheckpointPreservesPeerMembershipAndRollsBackFailure() async throws {
        let folder = try await db.createFolder(name: DownloadFolderName("checkpoint"), account: account)
        let (summary, initial) = try proposed()
        _ = try await db.insertDownloadWithLibrary(summary: summary, snapshot: initial, destinationFolderID: folder.id)
        let beforeMetadata = try await item(initial.job.id)
        let id = initial.job.id
        let first = try DownloadPage(jobID: id, index: PageIndex(0), state: .completed,
            relativePath: RelativePath("\(id.uuidString)/0.img"), size: NonnegativeCount(4))
        let partial = try DownloadJob(id: id, scope: scope, reference: initial.job.reference, state: .downloading,
            totalPages: NonnegativeCount(2), completedPages: NonnegativeCount(1), generation: 1)
        try await db.updateDownloadPage(job: partial, page: first, expectedGeneration: 1)
        let checkpoint = try await db.download(jobID: id, scope: scope)
        XCTAssertEqual(checkpoint, try DownloadSnapshot(job: partial, pages: [first, initial.pages[1]]))
        let afterMetadata = try await item(id)
        XCTAssertEqual(afterMetadata.folderID, beforeMetadata.folderID)
        XCTAssertEqual(afterMetadata.addedAt, beforeMetadata.addedAt)
        XCTAssertEqual(afterMetadata.metadata, beforeMetadata.metadata)
        XCTAssertEqual(afterMetadata.membershipRevision, beforeMetadata.membershipRevision)
        XCTAssertEqual(afterMetadata.metadataRevision, beforeMetadata.metadataRevision)
        XCTAssertEqual(afterMetadata.completedPages.value, 1)
        XCTAssertEqual(afterMetadata.storedBytes.value, 4)
        let second = try DownloadPage(jobID: id, index: PageIndex(1), state: .completed,
            relativePath: RelativePath("\(id.uuidString)/1.img"), size: NonnegativeCount(4))
        let complete = try DownloadJob(id: id, scope: scope, reference: initial.job.reference, state: .completed,
            totalPages: NonnegativeCount(2), completedPages: NonnegativeCount(2), generation: 1)
        try raw { c in try c.execute("CREATE TRIGGER remediation_fail BEFORE INSERT ON download_pages WHEN NEW.pageIndex=1 BEGIN SELECT RAISE(ABORT,'injected'); END") }
        do { try await db.updateDownloadPage(job: complete, page: second, expectedGeneration: 1); XCTFail("injected failure ignored") }
        catch { XCTAssertNotNil(error as? PersistenceError) }
        let rolledBack = try await db.download(jobID: id, scope: scope); XCTAssertEqual(rolledBack, checkpoint)
        try raw { c in try c.execute("DROP TRIGGER remediation_fail") }
        clock.set(555)
        try await db.updateDownloadPage(job: complete, page: second, expectedGeneration: 1)
        let final = try await db.download(jobID: id, scope: scope)
        XCTAssertEqual(final, try DownloadSnapshot(job: complete, pages: [first, second]))
        let finalMetadata = try await item(id)
        XCTAssertEqual(finalMetadata.folderID, folder.id); XCTAssertEqual(finalMetadata.firstCompletedAt?.value, 555)
        XCTAssertEqual(finalMetadata.membershipRevision, beforeMetadata.membershipRevision)
        clock.set(666)
        try await db.updateDownloadPage(job: complete, page: second, expectedGeneration: 1)
        let repeated = try await item(id); XCTAssertEqual(repeated.firstCompletedAt?.value, 555)
    }
    func testSinglePageCheckpointRejectsStaleGenerationWrongOwnerAndCounterDrift() async throws {
        let (summary, initial) = try proposed()
        _ = try await db.insertDownloadWithLibrary(summary: summary, snapshot: initial)
        let id = initial.job.id
        let first = try DownloadPage(jobID: id, index: PageIndex(0), state: .completed,
            relativePath: RelativePath("\(id.uuidString)/0.img"), size: NonnegativeCount(4))
        // Completed-page counter must agree with the exact prior page delta.
        do { try await db.updateDownloadPage(job: initial.job, page: first, expectedGeneration: 1); XCTFail() }
        catch { XCTAssertEqual(error as? AppError, .staleSession) }
        let foreign = try DownloadJob(id: id, scope: StorageScope(accountID: AccountID(UUID()), site: .eh), reference: initial.job.reference,
            state: .queued, totalPages: NonnegativeCount(2), completedPages: NonnegativeCount(0), generation: 1)
        do { try await db.updateDownloadPage(job: foreign, page: initial.pages[0], expectedGeneration: 1); XCTFail() }
        catch { XCTAssertEqual(error as? AppError, .staleSession) }
        try await db.updateDownload(changed(initial, state: .paused, generation: 2), expectedGeneration: 1)
        do { try await db.updateDownloadPage(job: initial.job, page: initial.pages[0], expectedGeneration: 1); XCTFail() }
        catch { XCTAssertEqual(error as? AppError, .staleSession) }
        try await db.removeDownload(jobID: id, scope: scope)
        do { try await db.updateDownloadPage(job: initial.job, page: initial.pages[0], expectedGeneration: 1); XCTFail() }
        catch { XCTAssertEqual(error as? AppError, .staleSession) }
        let gone = try await db.download(jobID: id, scope: scope); XCTAssertNil(gone)
    }
    func testExactLocalReadIgnoresUnrelatedCorruptPagesAndPreservesCancelledPartialRead() async throws {
        let (summary, initial) = try proposed()
        _ = try await db.insertDownloadWithLibrary(summary: summary, snapshot: initial)
        let full = try changed(initial, state: .completed, generation: 1)
        try await db.updateDownload(full, expectedGeneration: 1)
        let cancelled = try DownloadSnapshot(job: DownloadJob(id: full.job.id, scope: scope, reference: full.job.reference,
            state: .cancelled, totalPages: full.job.totalPages, completedPages: full.job.completedPages, generation: 2), pages: full.pages)
        try await db.updateDownload(cancelled, expectedGeneration: 1)
        try raw { c in try c.execute("UPDATE download_pages SET payload=X'00' WHERE jobID!=?", [.text(full.job.id.uuidString)]) }
        let result = try await db.storedDownloadPage(jobID: full.job.id, index: PageIndex(0), account: account)
        XCTAssertEqual(result, full.pages[0])
        let scoped = try await db.download(jobID: full.job.id, account: account); XCTAssertEqual(scoped, cancelled)
        let foreign = try await db.storedDownloadPage(jobID: full.job.id, index: PageIndex(0), account: AccountID(UUID()))
        XCTAssertNil(foreign)
        let outside = try await db.storedDownloadPage(jobID: full.job.id, index: PageIndex(2), account: account)
        XCTAssertNil(outside)
    }
    func testAtomicInsertCrossSiteDedupAndExistingDoesNotMoveOrRetimestamp() async throws {
        let folder = try await db.createFolder(name: DownloadFolderName("target"), account: account)
        let (summary,snapshot) = try proposed()
        let inserted = try await db.insertDownloadWithLibrary(summary: summary, snapshot: snapshot, destinationFolderID: folder.id)
        XCTAssertEqual(inserted,.inserted(snapshot.job.id))
        let before = try await item(snapshot.job.id); XCTAssertEqual(before.addedAt?.value,100); XCTAssertEqual(before.folderID,folder.id)
        clock.set(999)
        let (exSummary,exSnapshot) = try proposed(scope: StorageScope(accountID: account,site:.ex))
        let duplicate = try await db.insertDownloadWithLibrary(summary: exSummary,snapshot:exSnapshot,destinationFolderID:DownloadFolderID(UUID()))
        XCTAssertEqual(duplicate,.existing(snapshot.job.id))
        let after = try await item(snapshot.job.id); XCTAssertEqual(after,before)
        // Historical same-account EH/EX duplicates remain; UUID ascending winner is deterministic.
        let (oldSummary,oldSnapshot) = try proposed(gid:100)
        let old = try await db.insertDownloadWithLibrary(summary:oldSummary,snapshot:oldSnapshot)
        XCTAssertEqual(old,.existing(fixture.jobs[0].job.id))
        let (otherSummary,otherSnapshot) = try proposed(scope:D01V1Fixture.scopes[2])
        let other = try await db.insertDownloadWithLibrary(summary:otherSummary,snapshot:otherSnapshot)
        XCTAssertEqual(other,.inserted(otherSnapshot.job.id))
    }
    func testInsertionFailureAndDeletedTargetLeaveNoPartialRecords() async throws {
        let f = try await db.createFolder(name:DownloadFolderName("gone"),account:account)
        try await db.deleteFolderAndUnfile(id:f.id,expectedRevision:f.revision,account:account)
        let (s,v) = try proposed()
        do { _ = try await db.insertDownloadWithLibrary(summary:s,snapshot:v,destinationFolderID:f.id); XCTFail() } catch { XCTAssertEqual(error as? DownloadLibraryError,.folderNotFound) }
        try raw { c in try c.execute("CREATE TRIGGER d05_abort BEFORE INSERT ON download_library_items BEGIN SELECT RAISE(ABORT,'test'); END") }
        do { _ = try await db.insertDownloadWithLibrary(summary:s,snapshot:v); XCTFail() } catch { XCTAssertNotNil(error as? PersistenceError) }
        try raw { c in
            XCTAssertTrue(try c.rows("SELECT * FROM download_jobs WHERE id=?",[.text(v.job.id.uuidString)]).isEmpty)
            XCTAssertTrue(try c.rows("SELECT * FROM download_pages WHERE jobID=?",[.text(v.job.id.uuidString)]).isEmpty)
            XCTAssertTrue(try c.rows("SELECT * FROM galleries WHERE gid=999").isEmpty)
            try c.execute("DROP TRIGGER d05_abort")
        }
        _ = try await db.insertDownloadWithLibrary(summary:s,snapshot:v)
    }
    func testFirstCompletionSurvivesRepeatPauseRepairAndClockReversal() async throws {
        let (s,v) = try proposed(); _ = try await db.insertDownloadWithLibrary(summary:s,snapshot:v)
        clock.set(200)
        let completed = try changed(v,state:.completed,generation:1)
        try await db.updateDownload(completed,expectedGeneration:1)
        let first = try await item(v.job.id); XCTAssertEqual(first.firstCompletedAt?.value,200); XCTAssertEqual(first.completionTimeOrigin,.nativeObserved)
        clock.set(-100)
        try await db.updateDownload(completed,expectedGeneration:1)
        try await db.updateDownload(changed(v,state:.paused,generation:2),expectedGeneration:1)
        try await db.updateDownload(changed(v,state:.queued,generation:3),expectedGeneration:2)
        try await db.updateDownload(changed(v,state:.completed,generation:3),expectedGeneration:3)
        let repaired = try await item(v.job.id)
        XCTAssertEqual(repaired.addedAt?.value,100); XCTAssertEqual(repaired.firstCompletedAt?.value,200)
        XCTAssertEqual(repaired.membershipRevision.value,1); XCTAssertEqual(repaired.metadataRevision.value,1)
        do { try await db.updateDownload(completed,expectedGeneration:1); XCTFail() } catch { XCTAssertEqual(error as? AppError,.staleSession) }
        try await db.removeDownload(jobID:v.job.id,scope:scope)
        do { try await db.updateDownload(completed,expectedGeneration:3); XCTFail() } catch { XCTAssertEqual(error as? AppError,.staleSession) }
        try raw { c in XCTAssertTrue(try c.rows("SELECT * FROM download_library_items WHERE jobID=?",[.text(v.job.id.uuidString)]).isEmpty) }
        let (s2,v2) = try proposed(); _ = try await db.insertDownloadWithLibrary(summary:s2,snapshot:v2)
        let recreated = try await item(v2.job.id); XCTAssertEqual(recreated.addedAt?.value,-100); XCTAssertNil(recreated.firstCompletedAt)
    }
    func testCompletionFailureRollsBackSnapshotAndTimeTogether() async throws {
        let (s,v) = try proposed(); _ = try await db.insertDownloadWithLibrary(summary:s,snapshot:v)
        try raw { c in try c.execute("CREATE TRIGGER d05_abort_time BEFORE UPDATE OF firstCompletedAtMs ON download_library_items BEGIN SELECT RAISE(ABORT,'test'); END") }
        do { try await db.updateDownload(changed(v,state:.completed,generation:1),expectedGeneration:1); XCTFail() } catch { XCTAssertNotNil(error as? PersistenceError) }
        let retained = try await db.download(jobID:v.job.id,scope:scope); XCTAssertEqual(retained,v)
        let row = try await item(v.job.id); XCTAssertNil(row.firstCompletedAt)
        try raw { c in try c.execute("DROP TRIGGER d05_abort_time") }
        clock.set(500); try await db.updateDownload(changed(v,state:.completed,generation:1),expectedGeneration:1)
        let final = try await item(v.job.id); XCTAssertEqual(final.firstCompletedAt?.value,500)
    }
    func testLegacyCompletionStaysUnknownAndRecoveryOnlyFillsMissingRows() async throws {
        let old = fixture.jobs.first { $0.job.scope == scope && $0.job.state == .completed }!
        try await db.updateDownload(changed(old,state:.queued,generation:2),expectedGeneration:1)
        clock.set(400); try await db.updateDownload(changed(old,state:.completed,generation:2),expectedGeneration:2)
        let legacy = try await item(old.job.id); XCTAssertNil(legacy.firstCompletedAt); XCTAssertEqual(legacy.completionTimePolicy,.preserveLegacyUnknown)
        let pending = fixture.jobs[0]
        try await db.updateDownload(changed(pending,state:.completed,generation:1),expectedGeneration:1)
        let observed = try await item(pending.job.id); XCTAssertEqual(observed.firstCompletedAt?.value,400)
        let f = try await db.createFolder(name:DownloadFolderName("keep"),account:account)
        try await db.moveItems(expectedMembershipRevisions:[old.job.id:legacy.membershipRevision],destinationFolderID:f.id,account:account)
        let before = try await item(old.job.id)
        let missingPending = fixture.jobs[1]
        try raw { c in
            try c.execute("DELETE FROM download_library_items WHERE jobID IN (?,?)",[.text(pending.job.id.uuidString),.text(missingPending.job.id.uuidString)])
        }
        await db.close(); let clock = clock!; db = try SQLiteDatabase(url:url,libraryNow:{ clock.now() })
        let recovered = try await item(pending.job.id); XCTAssertNil(recovered.addedAt); XCTAssertNil(recovered.firstCompletedAt); XCTAssertEqual(recovered.completionTimePolicy,.preserveLegacyUnknown)
        let missingRecovered = try await item(missingPending.job.id)
        XCTAssertEqual(missingRecovered.completionTimePolicy,.recordFirstObserved); XCTAssertNil(missingRecovered.addedAt)
        try await db.updateDownload(changed(missingPending,state:.completed,generation:1),expectedGeneration:1)
        let recoveredComplete = try await item(missingPending.job.id); XCTAssertEqual(recoveredComplete.firstCompletedAt?.value,400)
        let preserved = try await item(old.job.id); XCTAssertEqual(preserved,before)
        await db.close(); db = try SQLiteDatabase(url:url,libraryNow:{ clock.now() })
        let again = try await item(old.job.id); XCTAssertEqual(again,before)
    }
    func testConcurrentDatabaseInsertHasSingleWinner() async throws {
        let proposals = try (0..<8).map { _ in try proposed() }, database = db!
        let results = try await withThrowingTaskGroup(of:EnqueueResult.self) { group in
            for (s,v) in proposals { group.addTask { try await database.insertDownloadWithLibrary(summary:s,snapshot:v) } }
            var results:[EnqueueResult]=[]; for try await result in group { results.append(result) }; return results
        }
        let inserted = results.compactMap { result -> UUID? in if case .inserted(let id)=result { return id }; return nil }
        XCTAssertEqual(inserted.count,1)
        for result in results { switch result { case .inserted(let id),.existing(let id): XCTAssertEqual(id,inserted[0]) } }
    }
    func testMetadataCreatedAtomicallyAndRetainedOfflineWithoutChangingExisting() async throws {
        let (summary,snapshot) = try proposed()
        let metadata = try DownloadLibraryMetadata.from(detail: GalleryDetail(summary: summary, tags: [.init(namespace: "artist", tags: ["A","B"]),.init(namespace: "group", tags: ["Circle"])]), fetchedAt: DownloadLibraryTimestamp(77))
        _ = try await db.insertDownloadWithLibrary(summary: summary, snapshot: snapshot, metadata: metadata)
        let row = try await item(snapshot.job.id); XCTAssertEqual(row.metadata,metadata); XCTAssertEqual(row.metadataRevision.value,1)
        let (s2,v2) = try proposed()
        _ = try await db.insertDownloadWithLibrary(summary:s2,snapshot:v2,metadata:.unknown)
        await db.close(); db = try SQLiteDatabase(url:url)
        let reopened = try await item(snapshot.job.id); XCTAssertEqual(reopened,row)
        let offline = try await db.listItems(target:.all,account:account)
        for field in [DownloadSortField.artist,.group] {
            XCTAssertEqual(DownloadLibrarySort.sorted(offline,by:DownloadSort(field:field)).first?.jobID,snapshot.job.id)
        }
        let captured = try await db.downloadMetadataRevisions(galleryID:summary.reference.key.galleryID,account:account)
        XCTAssertEqual(captured,[snapshot.job.id:row.metadataRevision])
        let foreign = try await db.downloadMetadataRevisions(galleryID:summary.reference.key.galleryID,account:D01V1Fixture.scopes[2].accountID)
        XCTAssertTrue(foreign.isEmpty)
    }
    func testMetadataInsertFailureRollsBackAndWrongSourceIsRejected() async throws {
        let (s,v) = try proposed()
        let wrong = try DownloadLibraryMetadata(artists:["A"],groups:[],state:.complete,sourceSite:.ex,fetchedAt:DownloadLibraryTimestamp(1))
        do { _ = try await db.insertDownloadWithLibrary(summary:s,snapshot:v,metadata:wrong); XCTFail() } catch { XCTAssertEqual(error as? AppError,.scopeMismatch) }
        let valid = try DownloadLibraryMetadata.from(detail:GalleryDetail(summary:s,tags:[]),fetchedAt:DownloadLibraryTimestamp(5))
        try raw { c in try c.execute("CREATE TRIGGER d06_abort BEFORE INSERT ON download_library_items WHEN NEW.metadataState='complete' BEGIN SELECT RAISE(ABORT,'test'); END") }
        do { _ = try await db.insertDownloadWithLibrary(summary:s,snapshot:v,metadata:valid); XCTFail() } catch { XCTAssertNotNil(error as? PersistenceError) }
        try raw { c in
            XCTAssertTrue(try c.rows("SELECT * FROM download_jobs WHERE gid=999").isEmpty)
            XCTAssertTrue(try c.rows("SELECT * FROM galleries WHERE gid=999").isEmpty)
            try c.execute("DROP TRIGGER d06_abort")
        }
        _ = try await db.insertDownloadWithLibrary(summary:s,snapshot:v,metadata:valid)
        let item = try await item(v.job.id); XCTAssertEqual(item.metadata.state,.complete); XCTAssertTrue(item.metadata.artists.isEmpty)
    }

}