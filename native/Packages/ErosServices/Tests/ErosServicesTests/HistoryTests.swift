import XCTest
import Foundation
import ErosCore
import ErosPersistence
import ErosServices

private actor HistoryTagRepository: GalleryRepository {
    var count = 0
    var fail = false
    var hold = false
    var gate: CheckedContinuation<Void,Never>?
    func configure(fail:Bool = false,hold:Bool = false) { self.fail=fail; self.hold=hold }
    func waiting() -> Bool { gate != nil }
    func release() { gate?.resume(); gate=nil }
    func detail(request:GalleryRequest) async throws -> GalleryDetail {
        count += 1
        if hold { await withCheckedContinuation { gate=$0 } }
        if fail { throw AppError.transport(code:-1009) }
        return try GalleryDetail(summary:GallerySummary(reference:request.reference,title:"Enriched",pageCount:NonnegativeCount(3)),tags:[TagGroup(namespace:"artist",tags:["sample"])],sourceTitles:GallerySourceTitles(gn:"Enriched",gj:"豊かな原題"))
    }
    func list(request:GalleryListRequest) throws -> PagedResult<GallerySummary> { throw AppError.notFound }
    func readerPages(request:ReaderPagesRequest) throws -> PagedResult<ReaderPage> { throw AppError.notFound }
}

@MainActor final class HistoryTests: XCTestCase {
    func seed(_ db: SQLiteDatabase, scope: StorageScope, id: Int64 = 42, time: Double = 100, index: Int = 2) async throws {
        let gid = try GalleryID(id)
        let summary = try GallerySummary(reference: GalleryReference(key: GalleryKey(site: scope.site, galleryID: gid), token: SensitiveText("synthetic")), title: "Synthetic history", pageCount: NonnegativeCount(30))
        try await db.saveGallery(summary, scope: scope)
        try await db.saveProgress(ReadingProgress(scope: scope, galleryID: gid, index: PageIndex(index), fraction: UnitFraction(0.45), readingMode: .vertical, updatedAt: Date(timeIntervalSince1970: time)))
    }
    func testLegacyTagsPersistWithoutChangingProgressOrRepeatingRequests() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let db=try SQLiteDatabase(url:root.appendingPathComponent("db.sqlite"))
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1)
        try await seed(db,scope:scope.storage,index:18)
        let provider=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated)), repo=HistoryTagRepository()
        let model=HistoryViewModel(database:db,sessions:provider,scope:scope,repository:repo)
        await model.load(); let old=model.items[0].progress, id=model.items[0].id
        model.requestMetadata(id); model.requestMetadata(id)
        for _ in 0..<100 where model.items[0].summary.listTags == nil { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertEqual(model.items[0].summary.listTags?.first?.tags,["sample"])
        XCTAssertEqual(model.items[0].progress,old); XCTAssertEqual(model.items[0].summary.pageCount?.value,30)
        XCTAssertEqual(model.items[0].displayTitle,"豊かな原題"); XCTAssertEqual(model.items[0].summary.title,"Enriched")
        await model.load(); model.requestMetadata(id)
        let count=await repo.count; XCTAssertEqual(count,1)
        XCTAssertEqual(model.items[0].summary.listTags?.first?.tags,["sample"])
        model.stopMetadata(); await db.close()
    }
    func testTagFailurePreservesHistoryAndExplicitReloadCanRetry() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let db=try SQLiteDatabase(url:root.appendingPathComponent("db.sqlite"))
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1)
        try await seed(db,scope:scope.storage)
        let provider=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated)), repo=HistoryTagRepository()
        await repo.configure(fail:true)
        let model=HistoryViewModel(database:db,sessions:provider,scope:scope,repository:repo)
        await model.load(); let old=model.items[0], id=old.id
        model.requestMetadata(id)
        for _ in 0..<100 where model.metadataFailures.isEmpty { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertTrue(model.metadataFailures.contains(id)); XCTAssertEqual(model.items[0].summary,old.summary); XCTAssertEqual(model.items[0].progress,old.progress)
        model.requestMetadata(id); let count=await repo.count; XCTAssertEqual(count,1)
        await repo.configure(); await model.load(); model.requestMetadata(id)
        for _ in 0..<100 where model.items[0].summary.listTags == nil { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertNotNil(model.items[0].summary.listTags); model.stopMetadata(); await db.close()
    }
    func testCancelledAndStaleTagResponsesCannotWriteBack() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let db=try SQLiteDatabase(url:root.appendingPathComponent("db.sqlite"))
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1)
        try await seed(db,scope:scope.storage)
        let provider=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated)), repo=HistoryTagRepository()
        await repo.configure(hold:true)
        let model=HistoryViewModel(database:db,sessions:provider,scope:scope,repository:repo)
        await model.load(); let id=model.items[0].id
        model.requestMetadata(id)
        for _ in 0..<100 { if await repo.waiting() { break }; try await Task.sleep(for:.milliseconds(5)) }
        await provider.update(SessionState(scope:try scope.advanced(),authentication:.guest))
        model.stopMetadata(); await repo.release()
        try await Task.sleep(for:.milliseconds(20))
        let saved=try await db.gallery(galleryID:id,scope:scope.storage)
        XCTAssertNil(saved?.listTags); XCTAssertNil(saved?.sourceTitles); XCTAssertEqual(model.items[0].summary.title,"Synthetic history")
        await db.close()
    }
    func testTitlesAreEnrichedWithExistingTagsAndPersistAcrossReload() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let db=try SQLiteDatabase(url:root.appendingPathComponent("db.sqlite"))
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1)
        try await seed(db,scope:scope.storage,index:18)
        let prior=try await db.gallery(galleryID:GalleryID(42),scope:scope.storage)
        let old=try XCTUnwrap(prior)
        let tagged=try GallerySummary(reference:old.reference,title:old.title,pageCount:old.pageCount,listTags:[TagGroup(namespace:"language",tags:["japanese"])])
        try await db.saveGallery(tagged,scope:scope.storage)
        let provider=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated)),repo=HistoryTagRepository()
        let model=HistoryViewModel(database:db,sessions:provider,scope:scope,repository:repo)
        await model.load()
        let progress=model.items[0].progress,id=model.items[0].id
        XCTAssertEqual(model.items[0].displayTitle,"Synthetic history")
        model.requestMetadata(id);model.requestMetadata(id)
        for _ in 0..<100 where model.items[0].summary.sourceTitles == nil { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertEqual(model.items[0].displayTitle,"豊かな原題")
        XCTAssertEqual(model.items[0].summary.title,"Enriched")
        XCTAssertEqual(model.items[0].progress,progress)
        XCTAssertEqual(model.items[0].summary.pageCount?.value,30)
        await model.load();model.requestMetadata(id)
        XCTAssertEqual(model.items[0].displayTitle,"豊かな原題")
        let count=await repo.count;XCTAssertEqual(count,1)
        model.stopMetadata();await db.close()
    }

    func testHeldTitleResponseCannotWriteAfterHistoryReload() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let db=try SQLiteDatabase(url:root.appendingPathComponent("db.sqlite"))
        let scope=SessionScope(storage:StorageScope(accountID:AccountID(UUID()),site:.eh),generation:1)
        try await seed(db,scope:scope.storage)
        let provider=MutableSessionProvider(SessionState(scope:scope,authentication:.authenticated)),repo=HistoryTagRepository()
        await repo.configure(hold:true)
        let model=HistoryViewModel(database:db,sessions:provider,scope:scope,repository:repo)
        await model.load();let id=model.items[0].id
        model.requestMetadata(id)
        for _ in 0..<100 { if await repo.waiting() { break };try await Task.sleep(for:.milliseconds(5)) }
        await model.load()
        await repo.release()
        try await Task.sleep(for:.milliseconds(20))
        let saved=try await db.gallery(galleryID:id,scope:scope.storage)
        XCTAssertNil(saved?.sourceTitles)
        XCTAssertEqual(model.items[0].displayTitle,"Synthetic history")
        model.stopMetadata();await db.close()
    }

    func testDedupLatestOrderingAndColdReopenRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
        let provider = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let url = root.appendingPathComponent("db.sqlite"), db = try SQLiteDatabase(url: root.appendingPathComponent("db.sqlite"))
        try await seed(db, scope: scope.storage); try await seed(db, scope: scope.storage, id: 43, time: 200)
        let ex = StorageScope(accountID: scope.storage.accountID, site: .ex)
        try await seed(db, scope: ex, time: 300, index: 18)
        await db.close()
        let reopened = try SQLiteDatabase(url: url)
        let history = HistoryViewModel(database: reopened, sessions: provider, scope: scope)
        await history.load()
        XCTAssertNil(history.error); XCTAssertEqual(history.items.map(\.id.value), [42, 43])
        XCTAssertEqual(history.items.first?.progress.index.value, 18)
        XCTAssertEqual(history.items.first?.progress.fraction.value, 0.45)
        XCTAssertEqual(history.items.first?.progress.readingMode, .vertical)
        XCTAssertEqual(history.items.first?.summary.reference.key.site, .eh)
        let position = try await reopened.accountProgress(galleryID: GalleryID(42), account: scope.storage.accountID)
        XCTAssertEqual(position?.index.value, 18)
        await reopened.close()
    }
    func testScopedDeleteClearAndStaleSessionCannotModify() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageScope(accountID: AccountID(UUID()), site: .eh)
        let scope = SessionScope(storage: storage, generation: 1)
        let other = StorageScope(accountID: storage.accountID, site: .ex)
        let foreign = StorageScope(accountID: AccountID(UUID()), site: .eh)
        let db = try SQLiteDatabase(url: root.appendingPathComponent("db.sqlite"))
        for partition in [storage, other, foreign] { try await seed(db, scope: partition); try await seed(db, scope: partition, id: 43) }
        let provider = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let history = HistoryViewModel(database: db, sessions: provider, scope: scope)
        await history.load(); XCTAssertEqual(history.items.count, 2)
        await history.remove(try GalleryID(42)); XCTAssertEqual(history.items.map(\.id.value), [43])
        await history.clear(); XCTAssertTrue(history.items.isEmpty)
        let otherSiteRows = try await db.progressList(scope: other)
        let foreignRows = try await db.progressList(scope: foreign)
        XCTAssertTrue(otherSiteRows.isEmpty)
        XCTAssertEqual(foreignRows.count, 2)
        let gallery = try await db.gallery(galleryID: GalleryID(42), scope: storage); XCTAssertNotNil(gallery)
        try await seed(db, scope: storage)
        await history.load(); XCTAssertEqual(history.items.count, 1)
        await provider.update(SessionState(scope: try scope.advanced(), authentication: .guest))
        await history.clear(); XCTAssertEqual(history.error, .staleSession); XCTAssertTrue(history.items.isEmpty)
        let untouched = try await db.progressList(scope: storage); XCTAssertEqual(untouched.count, 1)
        await db.close()
    }
}
