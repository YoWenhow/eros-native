import Foundation
import XCTest
import ErosCore
@testable import ErosPersistence

@MainActor
final class PersistenceTests: XCTestCase {
    var directory: URL!
    var url: URL { directory.appendingPathComponent("test.sqlite") }
    let scope = StorageScope(accountID: AccountID(UUID()),site: .eh)
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try FileManager.default.removeItem(at: directory) }
    func summary(scope: StorageScope? = nil, count: Int? = 3) throws -> GallerySummary {
        let site = (scope ?? self.scope).site
        return try GallerySummary(reference: GalleryReference(key: GalleryKey(site: site,galleryID: GalleryID(42)),token: SensitiveText("synthetic-token")), title: "合成 ' ; DROP TABLE galleries; -- 日本語",pageCount: count.map(NonnegativeCount.init))
    }
    func progress(scope: StorageScope? = nil, index: Int = 1) throws -> ReadingProgress {
        try ReadingProgress(scope: scope ?? self.scope,galleryID: GalleryID(42),index: PageIndex(index),fraction: UnitFraction(0.5),readingMode: .leftToRight,updatedAt: Date(timeIntervalSince1970: 100))
    }
    func snapshot(id: UUID = UUID(), generation: UInt64 = 1, state: DownloadJobState = .paused, scope: StorageScope? = nil) throws -> DownloadSnapshot {
        let scope = scope ?? self.scope
        let job = try DownloadJob(id: id,scope: scope,reference: summary(scope: scope).reference,state: state,totalPages: NonnegativeCount(2),completedPages: NonnegativeCount(1),generation: generation)
        return try DownloadSnapshot(job: job,pages: [DownloadPage(jobID: id,index: PageIndex(0),state: .completed,relativePath: RelativePath("downloads/\(id)/0.jpg"),size: NonnegativeCount(120)),DownloadPage(jobID: id,index: PageIndex(1),state: .pending)])
    }
    func testMigrationIdempotencyAndReopenAllStores() async throws {
        let db = try SQLiteDatabase(url: url)
        let version = try await db.schemaVersion(); XCTAssertEqual(version,Schema.migrations.count)
        let gallery = try summary(), p = try progress(), f = try LocalFavorite(scope: scope,summary: gallery,savedAt: .distantPast), s = try snapshot()
        try await db.saveGallery(gallery,scope: scope)
        let history = SQLiteHistoryStore(database: db), favorites = SQLiteLocalFavoritesStore(database: db), downloads = SQLiteDownloadStore(database: db)
        for _ in 0..<2 { try await history.save(progress: p); try await favorites.save(favorite: f); try await downloads.save(snapshot: s) }
        await db.close()
        let reopened = try SQLiteDatabase(url: url)
        let actualP = try await reopened.progressList(scope: scope), actualF = try await reopened.favorites(scope: scope), actualD = try await reopened.recoverableDownloads(scope: scope)
        XCTAssertEqual(actualP,[p]); XCTAssertEqual(actualF,[f]); XCTAssertEqual(actualD,[s])
        let actualG = try await reopened.gallery(galleryID: GalleryID(42),scope: scope); XCTAssertEqual(actualG,gallery)
        await reopened.close()
        let raw = try SQLiteConnection(path: url.path)
        XCTAssertEqual(try raw.rows("SELECT version FROM schema_migrations").count,Schema.migrations.count)
        XCTAssertEqual(try raw.rows("PRAGMA foreign_key_check").count,0)
        raw.close()
    }
    func testLocalFavoriteSearchReadsStoredAlternateTitlesInTheSamePartition() async throws {
        let database = try SQLiteDatabase(url: url)
        let ex = StorageScope(accountID: scope.accountID, site: .ex)
        let original = try summary()
        let date = Date(timeIntervalSince1970: 100)
        try await database.saveFavorite(LocalFavorite(scope: scope, summary: original, savedAt: date))
        try await database.saveFavorite(LocalFavorite(scope: ex, summary: summary(scope: ex), savedAt: date))
        try await database.fillGallerySourceTitles(GallerySourceTitles(gn: "Synthetic Title", gj: "別タイトル"),
                                                  reference: original.reference, scope: scope)
        let local = try await database.favorites(scope: scope)
        let otherSite = try await database.favorites(scope: ex)
        let item = try XCTUnwrap(local.first)
        XCTAssertEqual(item.summary.title, original.title)
        XCTAssertEqual(item.savedAt, date)
        XCTAssertTrue(item.summary.titleContains("別タイ"))
        XCTAssertNil(otherSite.first?.summary.sourceTitles)
        await database.close()
    }
    func testReaderLocalLookupOnlyCompletedPagesInSamePartition() async throws {
        let db = try SQLiteDatabase(url: url), saved = try snapshot()
        try await db.saveDownload(saved)
        let page = try await db.completedReaderPage(galleryID: GalleryID(42), index: PageIndex(0), scope: scope)
        XCTAssertEqual(page, saved.pages[0])
        let pending = try await db.completedReaderPage(galleryID: GalleryID(42), index: PageIndex(1), scope: scope)
        XCTAssertNil(pending)
        let other = StorageScope(accountID: AccountID(UUID()), site: .eh)
        let foreign = try await db.completedReaderPage(galleryID: GalleryID(42), index: PageIndex(0), scope: other)
        XCTAssertNil(foreign)
        try await db.saveDownload(snapshot(id: saved.job.id, generation: 2, state: .cancelled))
        let cancelled = try await db.completedReaderPage(galleryID: GalleryID(42), index: PageIndex(0), scope: scope)
        XCTAssertNil(cancelled); await db.close()
    }
    func testClearHistoryPreservesOtherPartitionsAndFavorites() async throws {
        let db = try SQLiteDatabase(url: url)
        let other = StorageScope(accountID: scope.accountID, site: .ex)
        for s in [scope, other] {
            try await db.saveFavorite(LocalFavorite(scope: s, summary: summary(scope: s), savedAt: .distantPast))
            try await db.saveProgress(progress(scope: s))
        }
        try await db.clearProgress(scope: scope)
        let empty = try await db.progressList(scope: scope), kept = try await db.progressList(scope: other)
        XCTAssertTrue(empty.isEmpty); XCTAssertEqual(kept.count, 1)
        let favorites = try await db.favorites(scope: scope); XCTAssertEqual(favorites.count, 1)
        await db.close()
    }
    func testScopeIsolationAndScopedDeletes() async throws {
        let db = try SQLiteDatabase(url: url)
        let scopes = [scope,StorageScope(accountID: AccountID(UUID()),site: .eh),StorageScope(accountID: scope.accountID,site: .ex)]
        for s in scopes { try await db.saveFavorite(LocalFavorite(scope: s,summary: summary(scope: s),savedAt: .distantPast)); try await db.saveProgress(progress(scope: s)) }
        try await db.removeFavorite(galleryID: GalleryID(42),scope: scope)
        try await db.removeProgress(galleryID: GalleryID(42),scope: scope)
        for s in scopes {
            let f = try await db.favorites(scope: s), p = try await db.progressList(scope: s)
            XCTAssertEqual(f.count,s == scope ? 0 : 1); XCTAssertEqual(p.count,s == scope ? 0 : 1)
        }
        let snap = try snapshot();try await db.saveDownload(snap)
        try await db.removeDownload(jobID: snap.job.id,scope: scopes[1])
        let kept = try await db.download(jobID: snap.job.id,scope: scope);XCTAssertNotNil(kept)
        try await db.removeDownload(jobID: snap.job.id,scope: scope)
        await db.close()
        let raw = try SQLiteConnection(path: url.path);XCTAssertTrue(try raw.rows("SELECT * FROM download_pages").isEmpty);raw.close()
    }
    func testProgressBoundsAndMissingCount() async throws {
        let db = try SQLiteDatabase(url: url)
        do { try await db.saveProgress(progress()); XCTFail() } catch { XCTAssertEqual(error as? PersistenceError,.missingGalleryPageCount) }
        try await db.saveGallery(summary(),scope: scope)
        do { try await db.saveProgress(progress(index: 3)); XCTFail() } catch { XCTAssertEqual(error as? AppError,.invalidInput) }
        try await db.saveProgress(progress(index: 2))
        do { try await db.saveGallery(summary(count: 2),scope: scope); XCTFail() } catch { XCTAssertNotNil(error as? PersistenceError) }
        let p = try await db.progress(galleryID: GalleryID(42),scope: scope);XCTAssertEqual(p?.index.value,2)
        await db.close()
    }
    func testMigrationFailureRollsBackAndFutureVersionIsPreserved() throws {
        let raw = try SQLiteConnection(path: url.path);raw.close()
        let migrations = Schema.migrations + [Migration(version: Schema.migrations.count + 1,statements: ["CREATE TABLE migration_sentinel(id INTEGER)","INSERT INTO missing_table VALUES(1)"])]
        XCTAssertThrowsError(try SQLiteConnection(path: url.path,migrations: migrations))
        let check = try SQLiteConnection(path: url.path)
        XCTAssertTrue(try check.rows("SELECT name FROM sqlite_master WHERE name='migration_sentinel'").isEmpty)
        XCTAssertEqual(try check.rows("SELECT version FROM schema_migrations").count,Schema.migrations.count)
        try check.execute("INSERT INTO schema_migrations VALUES(?,'synthetic')", [.integer(Int64(Schema.migrations.count + 1))]);check.close()
        XCTAssertThrowsError(try SQLiteConnection(path: url.path)) { XCTAssertEqual($0 as? PersistenceError,.unsupportedSchema) }
        let newer = try SQLiteConnection(path: url.path,migrations: Schema.migrations + [Migration(version: Schema.migrations.count + 1,statements: [])])
        XCTAssertEqual(try newer.rows("SELECT version FROM schema_migrations").count,Schema.migrations.count + 1);newer.close()
    }
    func testForeignKeysAndMidSnapshotFailureRollback() async throws {
        let db = try SQLiteDatabase(url: url);let original = try snapshot();try await db.saveDownload(original);await db.close()
        let raw = try SQLiteConnection(path: url.path)
        XCTAssertThrowsError(try raw.execute("INSERT INTO download_pages(jobID,pageIndex,state,payload) VALUES('absent',0,'pending',X'00')"))
        try raw.execute("CREATE TRIGGER fail_second_page BEFORE INSERT ON download_pages WHEN NEW.pageIndex=1 BEGIN SELECT RAISE(ABORT,'injected'); END")
        raw.close()
        let reopened = try SQLiteDatabase(url: url)
        do { try await reopened.saveDownload(snapshot(id: original.job.id,generation: 2));XCTFail() } catch { XCTAssertNotNil(error as? PersistenceError) }
        let kept = try await reopened.download(jobID: original.job.id,scope: scope);XCTAssertEqual(kept,original)
        await reopened.close()
    }
    func testStaleGenerationCancellationAndCrossScopeJobCannotOverwrite() async throws {
        let db = try SQLiteDatabase(url: url);let cancelled = try snapshot(generation: UInt64.max,state: .cancelled)
        try await db.saveDownload(cancelled)
        for new in [try snapshot(id: cancelled.job.id,generation: 1),try snapshot(id: cancelled.job.id,generation: UInt64.max)] {
            do { try await db.saveDownload(new);XCTFail() } catch { XCTAssertEqual(error as? AppError,.staleSession) }
        }
        let other = StorageScope(accountID: AccountID(UUID()),site: .eh)
        do { try await db.saveDownload(snapshot(id: cancelled.job.id,scope: other));XCTFail() } catch { XCTAssertEqual(error as? AppError,.scopeMismatch) }
        let pending = try await db.recoverableDownloads(scope: scope);XCTAssertTrue(pending.isEmpty)
        await db.close()
    }
    func testCorruptPayloadFailsWithoutRebuilding() async throws {
        let db = try SQLiteDatabase(url: url);try await db.saveFavorite(LocalFavorite(scope: scope,summary: summary(),savedAt: .distantPast));await db.close()
        let raw = try SQLiteConnection(path: url.path);try raw.execute("UPDATE local_favorites SET payload=X'00'");raw.close()
        let reopened = try SQLiteDatabase(url: url)
        do { _ = try await reopened.favorites(scope: scope);XCTFail() } catch { XCTAssertEqual(error as? PersistenceError,.corruptRecord) }
        let version = try await reopened.schemaVersion();XCTAssertEqual(version,Schema.migrations.count);await reopened.close()
    }
    func testConcurrentWritesSerializeAndCancellationDoesNotWrite() async throws {
        let db = try SQLiteDatabase(url: url);let gallery = try summary();try await db.saveGallery(gallery,scope: scope)
        let p = try progress()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<30 { group.addTask { try await db.saveProgress(p) } }
            try await group.waitForAll()
        }
        let all = try await db.progressList(scope: scope);XCTAssertEqual(all,[p])
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do { try await db.removeProgress(galleryID: p.galleryID,scope: p.scope);XCTFail() } catch is CancellationError {} catch { XCTFail() }
        }
        await task.value
        let kept = try await db.progressList(scope: scope);XCTAssertEqual(kept,[p]);await db.close()
        do { _ = try await db.schemaVersion();XCTFail() } catch { XCTAssertEqual(error as? PersistenceError,.closed) }
    }
}


extension PersistenceTests {
    func testAccountProgressWatchFollowsCommittedReadingAndRemoval() async throws {
        let db = try SQLiteDatabase(url: url)
        let ex = StorageScope(accountID: scope.accountID, site: .ex)
        let first = try progress(scope: ex)
        let galleryID = first.galleryID
        try await db.saveGallery(summary(scope: ex), scope: ex)
        var watched = await db.watchAccountProgress(galleryID: galleryID, account: scope.accountID).makeAsyncIterator()
        var other = await db.watchAccountProgress(galleryID: galleryID, account: AccountID(UUID())).makeAsyncIterator()
        let initial = await watched.next()
        let otherInitial = await other.next()
        XCTAssertNotNil(initial)
        XCTAssertNotNil(otherInitial)

        let oldIntent = ContinuousClock.now
        let accepted = try await db.saveAccountProgress(first, observedAt: .now)
        XCTAssertTrue(accepted)
        let savedUpdate = await watched.next()
        let saved = try await db.accountProgress(galleryID: galleryID, account: scope.accountID)
        XCTAssertNotNil(savedUpdate)
        XCTAssertEqual(saved, first)

        try await db.removeAccountProgress(galleryID: galleryID, account: scope.accountID)
        let removedUpdate = await watched.next()
        let removed = try await db.accountProgress(galleryID: galleryID, account: scope.accountID)
        XCTAssertNotNil(removedUpdate)
        XCTAssertNil(removed)
        let rejected = try await db.saveAccountProgress(first, observedAt: oldIntent)
        XCTAssertFalse(rejected)
        await db.close()
        let afterClose = await watched.next()
        let unrelated = await other.next()
        XCTAssertNil(afterClose)
        XCTAssertNil(unrelated)
    }

    func testRemoveHistoryRejectsOldIntentAndAllowsOtherGalleryAndNewReading() async throws {
        let db = try SQLiteDatabase(url: url)
        let target = try summary()
        let other = try GallerySummary(reference: GalleryReference(key: GalleryKey(site: scope.site, galleryID: GalleryID(43)), token: SensitiveText("synthetic")),
            title: "Unrelated synthetic gallery", pageCount: NonnegativeCount(3))
        try await db.saveGallery(target, scope: scope); try await db.saveGallery(other, scope: scope)
        let old = ContinuousClock.now
        try await db.removeProgress(galleryID: GalleryID(42), scope: scope)
        let rejected = try await db.saveProgress(progress(), observedAt: old)
        let unrelated = try ReadingProgress(scope: scope, galleryID: GalleryID(43), index: PageIndex(1), fraction: UnitFraction(0.5), readingMode: .leftToRight, updatedAt: Date())
        let kept = try await db.saveProgress(unrelated, observedAt: old)
        let fresh = try await db.saveProgress(progress(index: 2), observedAt: .now)
        XCTAssertFalse(rejected); XCTAssertTrue(kept); XCTAssertTrue(fresh)
        let saved = try await db.progress(galleryID: GalleryID(42), scope: scope)
        XCTAssertEqual(saved?.index, try PageIndex(2))
        await db.close()
    }
    func testClearHistoryFencesOnlyItsPartitionAndAllowsFreshReading() async throws {
        let db = try SQLiteDatabase(url: url)
        let otherSite = StorageScope(accountID: scope.accountID, site: .ex)
        let otherOwner = StorageScope(accountID: AccountID(UUID()), site: scope.site)
        for partition in [scope, otherSite, otherOwner] { try await db.saveGallery(summary(scope: partition), scope: partition) }
        let old = ContinuousClock.now
        try await db.clearProgress(scope: scope)
        let rejected = try await db.saveProgress(progress(), observedAt: old)
        let siteKept = try await db.saveProgress(progress(scope: otherSite), observedAt: old)
        let ownerKept = try await db.saveProgress(progress(scope: otherOwner), observedAt: old)
        let fresh = try await db.saveProgress(progress(index: 2), observedAt: .now)
        XCTAssertFalse(rejected); XCTAssertTrue(siteKept); XCTAssertTrue(ownerKept); XCTAssertTrue(fresh)
        await db.close()
    }
    func testFailedHistoryClearDoesNotFencePendingIntent() async throws {
        let db = try SQLiteDatabase(url: url)
        try await db.saveGallery(summary(), scope: scope)
        try await db.saveProgress(progress())
        let raw = try SQLiteConnection(path: url.path)
        try raw.execute("CREATE TRIGGER fail_history_clear BEFORE DELETE ON reading_progress BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END;")
        let pending = ContinuousClock.now
        do { try await db.clearProgress(scope: scope); XCTFail("Synthetic delete should fail") } catch {}
        let accepted = try await db.saveProgress(progress(index: 2), observedAt: pending)
        XCTAssertTrue(accepted)
        let saved = try await db.progress(galleryID: GalleryID(42), scope: scope)
        XCTAssertEqual(saved?.index, try PageIndex(2))
        raw.close(); await db.close()
    }
}
