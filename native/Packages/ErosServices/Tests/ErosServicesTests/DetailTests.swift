import Foundation
import XCTest
import ErosCore
import ErosServices
import ErosNetworking
import ErosOfflineDemo

private actor DetailRepository: GalleryRepository {
    var failDetail = false
    var failPages = false
    var invalidIndex = false
    var loop = false
    var block = false
    var continuation: CheckedContinuation<Void, Never>?
    var pageCalls = 0
    var title = String(repeating: "Long title 中文 ", count: 30)
    func configure(detail: Bool = false, pages: Bool = false, invalid: Bool = false, loop: Bool = false,
                   block: Bool = false, title: String? = nil) {
        failDetail = detail; failPages = pages; invalidIndex = invalid; self.loop = loop; self.block = block
        if let title { self.title = title }
    }
    func waiting() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
    func list(request: GalleryListRequest) async throws -> PagedResult<GallerySummary> { throw AppError.notFound }
    func readerPages(request: ReaderPagesRequest) async throws -> PagedResult<ReaderPage> { throw AppError.notFound }
    func detail(request: GalleryRequest) async throws -> GalleryDetail {
        if failDetail { throw AppError.httpStatus(404) }
        return try GalleryDetail(summary: GallerySummary(reference: request.reference, title: title, pageCount: NonnegativeCount(3)), tags: [TagGroup(namespace: "language", tags: ["chinese"])])
    }
    func thumbnails(request: ReaderPagesRequest) async throws -> PagedResult<GalleryThumbnail> {
        pageCalls += 1
        if block { block = false; await withCheckedContinuation { continuation = $0 } }
        if failPages { throw AppError.transport(code: -1009) }
        let indices = invalidIndex ? [3] : (request.cursor == nil ? [0,1] : [1,2])
        let items = try indices.map { i in
            GalleryThumbnail(page: ReaderPage(reference: request.reference, index: try PageIndex(i), pageURL: URL(string: "https://eh.example.invalid/s/test/42-\(i+1)")!), thumbnailURL: URL(string: "https://cdn.example.invalid/sprite.jpg"), thumbnailSize: try PixelSize(width: 100, height: 150), horizontalOffset: try NonnegativeCount(i * 100))
        }
        return try PagedResult(items: items, context: request.context,
            next: request.cursor == nil || loop ? PageCursor(context: request.context, opaque: SensitiveText("next")) : nil)
    }
}

@MainActor final class DetailTests: XCTestCase {
    let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
    func reference() throws -> GalleryReference { try GalleryReference(key: GalleryKey(site: .eh, galleryID: GalleryID(42)), token: SensitiveText("synthetic")) }
    func testDetailAndTwoThumbnailPagesPreserveMetadataAndZeroBasedSelection() async throws {
        let repo = DetailRepository()
        let feed = GalleryDetailViewModel(repository: repo)
        await feed.load(reference: try reference(), scope: scope); await feed.loadMore()
        XCTAssertEqual(feed.thumbnails.map(\.page.index.value), [0,1,2]); XCTAssertNil(feed.next)
        XCTAssertEqual(feed.thumbnails.last?.horizontalOffset?.value, 200)
        XCTAssertEqual(try feed.readerPage(index: PageIndex(0)).index.displayNumber, 1)
        XCTAssertEqual(try feed.readerPage(index: PageIndex(2)).index.displayNumber, 3)
        XCTAssertThrowsError(try feed.readerPage(index: PageIndex(3)))
        XCTAssertNotNil(feed.detail?.tags.first)
    }
    func testThumbnailFailureKeepsDetailAndRetriesFirstPage() async throws {
        let repo = DetailRepository(); let feed = GalleryDetailViewModel(repository: repo)
        await repo.configure(pages: true); await feed.load(reference: try reference(), scope: scope)
        XCTAssertNotNil(feed.detail); XCTAssertNil(feed.error); XCTAssertNotNil(feed.thumbnailError)
        await repo.configure(); await feed.loadMore()
        XCTAssertEqual(feed.thumbnails.count, 2); XCTAssertNil(feed.thumbnailError)
    }
    func testAppendFailureKeepsRowsAndCursorForRetry() async throws {
        let repo = DetailRepository(); let feed = GalleryDetailViewModel(repository: repo)
        await feed.load(reference: try reference(), scope: scope); let next = feed.next
        await repo.configure(pages: true); await feed.loadMore()
        XCTAssertEqual(feed.thumbnails.count, 2); XCTAssertEqual(feed.next, next)
        await repo.configure(); await feed.loadMore(); XCTAssertEqual(feed.thumbnails.count, 3)
    }
    func testDeletedDetailErrorRetriesWithoutFakeEmptySuccess() async throws {
        let repo = DetailRepository(); let feed = GalleryDetailViewModel(repository: repo)
        await repo.configure(detail: true); await feed.load(reference: try reference(), scope: scope)
        XCTAssertEqual(feed.error, .httpStatus(404)); XCTAssertNil(feed.detail)
        let calls = await repo.pageCalls; XCTAssertEqual(calls, 0)
        await repo.configure(); await feed.load(reference: try reference(), scope: scope); XCTAssertNil(feed.error)
    }
    func testOutOfBoundsThumbnailIsRejectedAndCursorLoopStops() async throws {
        let repo = DetailRepository(); let feed = GalleryDetailViewModel(repository: repo)
        await repo.configure(invalid: true); await feed.load(reference: try reference(), scope: scope)
        XCTAssertTrue(feed.thumbnails.isEmpty); XCTAssertEqual(feed.thumbnailError, .parseMismatch)
        await repo.configure(loop: true); await feed.load(reference: try reference(), scope: scope); await feed.loadMore()
        XCTAssertNil(feed.next); XCTAssertEqual(feed.thumbnailError, .parseMismatch)
    }
    func testConcurrentAppendAndResetSuppressLateResponse() async throws {
        let repo = DetailRepository(); let feed = GalleryDetailViewModel(repository: repo)
        await feed.load(reference: try reference(), scope: scope); await repo.configure(block: true)
        let task = Task { await feed.loadMore() }
        while !(await repo.waiting()) { await Task.yield() }
        await feed.loadMore(); feed.reset(); await repo.release(); await task.value
        XCTAssertNil(feed.detail); XCTAssertTrue(feed.thumbnails.isEmpty); XCTAssertFalse(feed.loadingMore)
        let calls = await repo.pageCalls; XCTAssertEqual(calls, 2)
    }
    func testPullRefreshPublishesDetailAndFirstPageTogether() async throws {
        let repo = DetailRepository()
        let feed = GalleryDetailViewModel(repository: repo)
        let ref = try reference()
        await feed.load(reference: ref, scope: scope)
        await feed.loadMore()
        let displayed = feed.detail
        let oldContext = feed.context

        await repo.configure(block: true, title: "Refreshed title")
        let refresh = Task { await feed.refresh(reference: ref, scope: scope) }
        while !(await repo.waiting()) { await Task.yield() }
        XCTAssertTrue(feed.loading)
        XCTAssertEqual(feed.detail, displayed)
        XCTAssertEqual(feed.thumbnails.map(\.page.index.value), [0, 1, 2])
        XCTAssertEqual(feed.context, oldContext)

        await repo.release()
        await refresh.value
        XCTAssertFalse(feed.loading)
        XCTAssertEqual(feed.detail?.summary.title, "Refreshed title")
        XCTAssertEqual(feed.thumbnails.map(\.page.index.value), [0, 1])
        XCTAssertNotEqual(feed.context, oldContext)
        XCTAssertEqual(feed.next?.context, feed.context)
        XCTAssertNil(feed.error)
    }

    func testFailedOrCancelledRefreshLeavesThePreviousPagerUsable() async throws {
        let repo = DetailRepository()
        let feed = GalleryDetailViewModel(repository: repo)
        let ref = try reference()
        await feed.load(reference: ref, scope: scope)
        let displayed = feed.detail
        let oldContext = feed.context
        let oldCursor = feed.next

        await repo.configure(pages: true, title: "Unpublished title")
        await feed.refresh(reference: ref, scope: scope)
        XCTAssertEqual(feed.error, .transport(code: -1009))
        XCTAssertEqual(feed.detail, displayed)
        XCTAssertEqual(feed.next, oldCursor)

        await repo.configure(block: true)
        let refresh = Task { await feed.refresh(reference: ref, scope: scope) }
        while !(await repo.waiting()) { await Task.yield() }
        refresh.cancel()
        await repo.release()
        await refresh.value
        XCTAssertFalse(feed.loading)
        XCTAssertNil(feed.error)
        XCTAssertEqual(feed.detail, displayed)
        XCTAssertEqual(feed.context, oldContext)
        XCTAssertEqual(feed.next, oldCursor)
        await feed.loadMore()
        XCTAssertEqual(feed.thumbnails.map(\.page.index.value), [0, 1, 2])
    }

    func testRefreshSupersedesAnAppendFromThePreviousSnapshot() async throws {
        let repo = DetailRepository()
        let feed = GalleryDetailViewModel(repository: repo)
        let ref = try reference()
        await feed.load(reference: ref, scope: scope)

        await repo.configure(block: true)
        let append = Task { await feed.loadMore() }
        while !(await repo.waiting()) { await Task.yield() }
        await repo.configure(title: "Refreshed during append")
        await feed.refresh(reference: ref, scope: scope)
        let refreshedCursor = feed.next
        await repo.release()
        await append.value

        XCTAssertEqual(feed.detail?.summary.title, "Refreshed during append")
        XCTAssertEqual(feed.thumbnails.map(\.page.index.value), [0, 1])
        XCTAssertEqual(feed.next, refreshedCursor)
        XCTAssertFalse(feed.loadingMore)
    }

    func testPreviewPolicyAllowsOnlyExactKnownMediaHosts() throws {
        let policy = PreviewImageLoader.productionPolicy
        for host in ["ehgt.org", "s.exhentai.org"] {
            let url = URL(string: "https://" + host + "/image.jpg")!
            XCTAssertNoThrow(try policy.validate(url, scope: scope, allowMedia: true))
            XCTAssertThrowsError(try policy.validate(url, scope: scope, allowMedia: false))
        }
        for url in ["http://ehgt.org/a", "https://ehgt.org.evil.invalid/a", "https://unknown.invalid/a", "https://user:pass@ehgt.org/a", "https://ehgt.org:444/a"] {
            XCTAssertThrowsError(try policy.validate(URL(string: url)!, scope: scope, allowMedia: true))
        }
    }
    func testLiveRepositoryRetainsParsedThumbnailMetadata() async throws {
        let transport = FixtureTransport(), sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .guest))
        let repo = LiveGalleryRepository(client: HTTPClient(transport: transport, policy: FixtureTransport.policy), sessions: sessions, policy: FixtureTransport.policy)
        let ref = try GalleryReference(key: GalleryKey(site: .eh, galleryID: GalleryID(42)), token: SensitiveText("demotoken"))
        let request = try ReaderPagesRequest(reference: ref, context: RequestContext(scope: scope, queryID: UUID()))
        let thumbs = try await repo.thumbnails(request: request), pages = try await repo.readerPages(request: request)
        XCTAssertEqual(thumbs.items.count, pages.items.count)
        for (preview, page) in zip(thumbs.items, pages.items) {
            XCTAssertEqual(preview.page.index, page.index)
            XCTAssertEqual(preview.page.pageURL, page.pageURL)
            XCTAssertEqual(preview.thumbnailURL, page.thumbnail?.url)
            XCTAssertEqual(preview.thumbnailSize, page.thumbnail?.size)
            XCTAssertEqual(preview.horizontalOffset, page.thumbnail?.horizontalOffset)
        }
        XCTAssertEqual(thumbs.items.count, 3); XCTAssertNotNil(thumbs.items.first?.thumbnailURL)
        let cursor = PageCursor(context: request.context, opaque: try SensitiveText("url-v1:https://eh.demo.invalid/g/42/demotoken/?p=1"))
        let followed = try await repo.thumbnails(request: ReaderPagesRequest(reference: ref, context: request.context, cursor: cursor))
        XCTAssertEqual(followed.items.map(\.page.pageURL), pages.items.map(\.pageURL))
        let wrong = PageCursor(context: request.context, opaque: try SensitiveText("url-v1:https://eh.demo.invalid/g/43/other/?p=1"))
        do { _ = try await repo.thumbnails(request: ReaderPagesRequest(reference: ref, context: request.context, cursor: wrong)); XCTFail("other gallery accepted") }
        catch { XCTAssertEqual(error as? AppError, .parseMismatch) }
    }
}
