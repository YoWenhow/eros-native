import Foundation
import XCTest
import ErosCore
import ErosServices

private actor FeedRepository: GalleryRepository {
    var calls = 0
    var totalCount: GalleryResultCount?
    func setTotal(_ count: GalleryResultCount?) { totalCount = count }
    var fail = false
    var loop = false
    var blocked = false
    var continuation: CheckedContinuation<Void, Never>?
    func configure(fail: Bool = false, loop: Bool = false, blocked: Bool = false) { self.fail = fail; self.loop = loop; self.blocked = blocked }
    func release() { continuation?.resume(); continuation = nil }
    func waiting() -> Bool { continuation != nil }
    func list(request: GalleryListRequest) async throws -> PagedResult<GallerySummary> {
        calls += 1
        let serial = calls
        if blocked { blocked = false; await withCheckedContinuation { continuation = $0 } }
        if fail { throw AppError.transport(code: -1009) }
        let page = Int(request.cursor?.opaque.value ?? "1")!
        let ids: [Int64] = page == 1 ? [1,2] : page == 2 ? [2,3] : [3,4]
        let values = try ids.map { id in
            try GallerySummary(reference: GalleryReference(key: GalleryKey(site: request.context.scope.storage.site, galleryID: GalleryID(id)), token: SensitiveText("test")), title: "Item \(id) request \(serial)")
        }
        let next = page < 3 ? PageCursor(context: request.context, opaque: try SensitiveText(loop ? String(page) : String(page + 1))) : nil
        return try PagedResult(items: values, context: request.context, next: next, totalCount: totalCount)
    }
    func detail(request: GalleryRequest) async throws -> GalleryDetail { throw AppError.notFound }
    func readerPages(request: ReaderPagesRequest) async throws -> PagedResult<ReaderPage> { throw AppError.notFound }
}

@MainActor final class LibraryTests: XCTestCase {
    let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
    func testTotalBelongsToQueryNotLoadedRowsAndResetsOnFailure() async {
        let repo = FeedRepository(); let feed = LibraryViewModel(repository: repo)
        await repo.setTotal(.approximate(200)); await feed.refresh(scope: scope)
        XCTAssertEqual(feed.totalCount, .approximate(200)); XCTAssertEqual(feed.items.count, 2)
        await repo.setTotal(nil); await feed.loadMore()
        XCTAssertEqual(feed.totalCount, .approximate(200)); XCTAssertEqual(feed.items.count, 3)
        await repo.configure(fail: true); await feed.refresh(scope: scope)
        XCTAssertNil(feed.totalCount); XCTAssertEqual(feed.resultCountText, "网站未提供总数")
        await repo.configure(); await feed.refresh(scope: scope)
        XCTAssertNil(feed.totalCount)
        await feed.loadMore(); await feed.loadMore()
        XCTAssertEqual(feed.totalCount, .exact(4))
        feed.reset(); XCTAssertNil(feed.totalCount)
    }
    func testThreePagesDeduplicateInOrderAndStop() async {
        let repo = FeedRepository()
        let feed = LibraryViewModel(repository: repo)
        await feed.refresh(scope: scope); await feed.loadMore(); await feed.loadMore(); await feed.loadMore()
        XCTAssertEqual(feed.items.map(\.reference.key.galleryID.value), [1,2,3,4])
        XCTAssertEqual(feed.pagesLoaded, 3); XCTAssertEqual(feed.duplicateCount, 2); XCTAssertNil(feed.next)
        XCTAssertEqual(Set(feed.lastPageKeys.map(\.galleryID.value)), [3,4])
        let count = await repo.calls; XCTAssertEqual(count, 3)
    }
    func testAppendFailureRetriesSameCursorAndKeepsRows() async {
        let repo = FeedRepository()
        let model = LibraryViewModel(repository: repo)
        await model.refresh(scope: scope); let cursor = model.next
        await repo.configure(fail: true); await model.loadMore()
        XCTAssertEqual(model.items.count, 2); XCTAssertEqual(model.next, cursor); XCTAssertNotNil(model.paginationError)
        await repo.configure(); await model.loadMore()
        XCTAssertEqual(model.items.count, 3); XCTAssertNil(model.paginationError)
    }
    func testFullRefreshClearsImmediatelyAndRestartsAtFirstPage() async {
        let repo = FeedRepository(); let feed = LibraryViewModel(repository: repo)
        await feed.refresh(scope: scope); await feed.loadMore(); await feed.loadMore()
        let context = feed.context
        await repo.configure(blocked: true)
        let refresh = Task { await feed.refresh(scope: scope) }
        while !(await repo.waiting()) { await Task.yield() }
        XCTAssertTrue(feed.items.isEmpty); XCTAssertNil(feed.context); XCTAssertNil(feed.next)
        XCTAssertEqual(feed.pagesLoaded, 0); XCTAssertEqual(feed.duplicateCount, 0)
        XCTAssertTrue(feed.refreshing); XCTAssertFalse(feed.canLoadMore)
        await repo.release(); await refresh.value
        XCTAssertEqual(feed.items.map(\.reference.key.galleryID.value), [1,2])
        XCTAssertEqual(feed.pagesLoaded, 1); XCTAssertNotEqual(feed.context, context)
        await feed.loadMore(); XCTAssertEqual(feed.items.count, 3)
    }
    func testFailedFullRefreshLeavesEmptyStateAndRetriesFirstPage() async {
        let repo = FeedRepository(); let feed = LibraryViewModel(repository: repo)
        await feed.refresh(scope: scope); await feed.loadMore()
        await repo.configure(fail: true); await feed.refresh(scope: scope)
        XCTAssertNil(feed.context); XCTAssertNil(feed.next); XCTAssertTrue(feed.items.isEmpty)
        XCTAssertEqual(feed.pagesLoaded, 0); XCTAssertNotNil(feed.initialError)
        await repo.configure(); await feed.refresh(scope: scope)
        XCTAssertEqual(feed.items.count, 2); XCTAssertEqual(feed.pagesLoaded, 1); XCTAssertNil(feed.initialError)
    }
    func testFullRefreshRejectsLateSameScopeAppend() async {
        let repo = FeedRepository(); let feed = LibraryViewModel(repository: repo)
        await feed.refresh(scope: scope); await repo.configure(blocked: true)
        let old = Task { await feed.loadMore() }
        while !(await repo.waiting()) { await Task.yield() }
        await feed.refresh(scope: scope); await repo.release(); await old.value
        XCTAssertEqual(feed.items.map(\.reference.key.galleryID.value), [1,2])
        XCTAssertEqual(feed.pagesLoaded, 1); XCTAssertFalse(feed.loadingMore)
    }
    func testDuplicateAppendWhilePendingOnlySendsOnce() async {
        let repo = FeedRepository(); let feed = LibraryViewModel(repository: repo)
        await feed.refresh(scope: scope); await repo.configure(blocked: true)
        let task = Task { await feed.loadMore() }
        while !(await repo.waiting()) { await Task.yield() }
        await feed.loadMore(); await repo.release(); await task.value
        let calls = await repo.calls; XCTAssertEqual(calls, 2); XCTAssertEqual(feed.pagesLoaded, 2)
    }
    func testRapidRefreshRejectsLateFirstResponse() async {
        let repo = FeedRepository(); let feed = LibraryViewModel(repository: repo)
        await repo.configure(blocked: true)
        let old = Task { await feed.refresh(scope: scope) }
        while !(await repo.waiting()) { await Task.yield() }
        await feed.refresh(scope: scope); let context = feed.context
        await repo.release(); await old.value
        XCTAssertEqual(feed.context, context); XCTAssertTrue(feed.items[0].title.hasSuffix("request 2"))
    }
    func testScopeChangeRejectsOldAppend() async throws {
        let repo = FeedRepository(); let feed = LibraryViewModel(repository: repo)
        await feed.refresh(scope: scope); await repo.configure(blocked: true)
        let old = Task { await feed.loadMore() }
        while !(await repo.waiting()) { await Task.yield() }
        let newer = try scope.advanced(); await feed.refresh(scope: newer)
        await repo.release(); await old.value
        XCTAssertEqual(feed.context?.scope, newer); XCTAssertEqual(feed.items.count, 2); XCTAssertEqual(feed.pagesLoaded, 1)
    }
    func testRepeatedCursorStopsWithoutInfiniteRequests() async {
        let repo = FeedRepository(); let feed = LibraryViewModel(repository: repo)
        await feed.refresh(scope: scope); await repo.configure(loop: true); await feed.loadMore()
        XCTAssertNil(feed.next); XCTAssertEqual(feed.paginationError, .parseMismatch)
        await feed.loadMore(); let calls = await repo.calls; XCTAssertEqual(calls, 2)
    }
    func testResetCancelsPendingAndTabReturnDoesNotReload() async {
        let repo = FeedRepository(); let feed = LibraryViewModel(repository: repo)
        await feed.loadIfNeeded(scope: scope); await feed.loadIfNeeded(scope: scope)
        let count = await repo.calls; XCTAssertEqual(count, 1)
        await repo.configure(blocked: true); let pending = Task { await feed.loadMore() }
        while !(await repo.waiting()) { await Task.yield() }
        feed.reset(); await repo.release(); await pending.value
        XCTAssertTrue(feed.items.isEmpty); XCTAssertFalse(feed.loadingMore)
    }
}
