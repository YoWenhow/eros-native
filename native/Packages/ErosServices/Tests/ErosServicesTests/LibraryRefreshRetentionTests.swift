import Foundation
import Testing
import ErosCore
import ErosServices

private actor RetentionRepository: GalleryRepository {
    private(set) var requests: [GalleryListRequest] = []
    private var blockNext = false
    private var failure: AppError?
    private var pending: CheckedContinuation<Void, Never>?
    func configure(block: Bool = false, failure: AppError? = nil) {
        blockNext = block; self.failure = failure
    }
    func waiting() -> Bool { pending != nil }
    func release() { pending?.resume(); pending = nil }
    func list(request: GalleryListRequest) async throws -> PagedResult<GallerySummary> {
        requests.append(request)
        let serial = requests.count, error = failure
        if blockNext {
            blockNext = false
            // Intentionally ignores cancellation to prove late-result rejection.
            await withCheckedContinuation { pending = $0 }
        }
        if let error { throw error }
        let ids: [Int64] = request.cursor == nil ? [1, 2] : [3, 4]
        let rows = try ids.map { id in
            try GallerySummary(reference: GalleryReference(key: GalleryKey(
                site: request.context.scope.storage.site, galleryID: GalleryID(id)),
                token: SensitiveText("synthetic")), title: "Item \(id) request \(serial)")
        }
        let next = request.cursor == nil ? PageCursor(context: request.context,
            opaque: try SensitiveText("synthetic-next")) : nil
        return try PagedResult(items: rows, context: request.context, next: next,
            totalCount: .exact(20))
    }
    func detail(request: GalleryRequest) async throws -> GalleryDetail { throw AppError.notFound }
    func readerPages(request: ReaderPagesRequest) async throws -> PagedResult<ReaderPage> { throw AppError.notFound }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct LibraryRefreshRetentionTests {
    private var scope: SessionScope {
        SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
    }
    @Test func refreshingOnlyTheSelectedSourceRetainsItsRowsUntilTheRequestReturns() async throws {
        let repo = RetentionRepository(), owner = scope
        let sources = LibrarySourcesViewModel(repository: repo)
        sources.activate(scope: owner, authenticated: true)
        try await sources.select(.popular, scope: owner)
        let rows = sources.current.items, context = sources.current.context
        await repo.configure(block: true)
        let request = Task { try await sources.refresh(scope: owner) }
        while !(await repo.waiting()) { await Task.yield() }
        #expect(sources.current.items == rows && sources.current.context == context && sources.current.refreshing)
        let requests = await repo.requests
        #expect(requests.count == 2 && requests.last?.query == LibrarySourceSelection.popular.query)
        #expect(requests.last?.context.scope == owner && sources.state(for: .browse).items.isEmpty)
        await repo.release(); try await request.value
        #expect(sources.selected == .popular && sources.current.items.first?.title.hasSuffix("request 2") == true)
        #expect(!sources.current.refreshing)
    }
    @Test func refreshingKeepsAcceptedRowsThenReplacesOnlyTheFirstPage() async {
        let repo = RetentionRepository(), owner = scope
        let feed = LibraryViewModel(repository: repo)
        await feed.refresh(scope: owner); await feed.loadMore()
        let rows = feed.items, context = feed.context, presentation = feed.presentationRevision
        await repo.configure(block: true)
        let request = Task { await feed.refresh(scope: owner, preservingItems: true) }
        while !(await repo.waiting()) { await Task.yield() }
        #expect(feed.items == rows && feed.context == context && feed.presentationRevision == presentation)
        #expect(feed.refreshing && !feed.canLoadMore && feed.next == nil && feed.paginationNeedsRefresh)
        #expect(feed.pagesLoaded == 2 && feed.totalCount == .exact(20))
        await repo.release(); await request.value
        #expect(feed.items.map(\.reference.key.galleryID.value) == [1, 2])
        #expect(feed.pagesLoaded == 1 && feed.context != context && feed.next != nil)
        #expect(feed.presentationRevision == presentation && !feed.paginationNeedsRefresh)
    }
    @Test func failureKeepsRowsAndConditionsButInvalidatesTheOldCursor() async {
        let repo = RetentionRepository(), owner = scope
        let feed = LibraryViewModel(repository: repo)
        let query = GalleryQuery(terms: "synthetic filter", excludedCategories: ["manga"])
        await feed.refresh(scope: owner, query: query); await feed.loadMore()
        let rows = feed.items, context = feed.context
        await repo.configure(failure: .transport(code: -1009))
        await feed.refresh(scope: owner, query: query, preservingItems: true)
        #expect(feed.items == rows && feed.context == context)
        #expect(feed.refreshError == .transport(code: -1009) && feed.initialError == nil)
        #expect(feed.pagesLoaded == 2 && feed.totalCount == .exact(20) && feed.next == nil && feed.paginationNeedsRefresh)
        await feed.loadMore()
        #expect(await repo.requests.count == 3)
        await repo.configure()
        await feed.refresh(scope: owner, query: query, preservingItems: true)
        let requests = await repo.requests
        #expect(requests.count == 4 && requests.last?.query == query && requests.last?.cursor == nil)
        #expect(feed.refreshError == nil && feed.pagesLoaded == 1 && !feed.paginationNeedsRefresh)
    }
    @Test func cancelledBeforeStartingCannotSendARequest() async {
        let repo = RetentionRepository(), owner = scope
        let feed = LibraryViewModel(repository: repo)
        let request = Task { await feed.refresh(scope: owner, preservingItems: true) }
        request.cancel(); await request.value
        #expect(await repo.requests.isEmpty)
        #expect(!feed.initialLoading && feed.items.isEmpty)
    }
    @Test func repeatedRefreshDuringFirstLoadSendsOneRequest() async {
        let repo = RetentionRepository(), owner = scope
        let model = LibrarySourcesViewModel(repository: repo)
        model.activate(scope: owner, authenticated: true)
        await repo.configure(block: true)
        let initial = Task { try await model.load(scope: owner) }
        while !(await repo.waiting()) { await Task.yield() }
        try? await model.refresh(scope: owner); try? await model.refresh(scope: owner)
        #expect(await repo.requests.count == 1)
        await repo.release(); _ = try? await initial.value
        #expect(model.current.items.count == 2)
    }
    @Test func repeatedRefreshOfLoadedFeedSendsOneRequest() async {
        let repo = RetentionRepository(), owner = scope
        let feed = LibraryViewModel(repository: repo)
        await feed.refresh(scope: owner)
        await repo.configure(block: true)
        let first = Task { await feed.refresh(scope: owner, preservingItems: true) }
        while !(await repo.waiting()) { await Task.yield() }
        await feed.refresh(scope: owner, preservingItems: true)
        #expect(await repo.requests.count == 2)
        await repo.release(); await first.value
        #expect(feed.items.first?.title.hasSuffix("request 2") == true)
    }
    @Test func latePaginationCannotAppendAfterPreservingRefresh() async {
        let repo = RetentionRepository(), owner = scope
        let feed = LibraryViewModel(repository: repo)
        await feed.refresh(scope: owner); await repo.configure(block: true)
        let more = Task { await feed.loadMore() }
        while !(await repo.waiting()) { await Task.yield() }
        await feed.refresh(scope: owner, preservingItems: true)
        let accepted = feed.items, context = feed.context
        await repo.release(); await more.value
        #expect(feed.items == accepted && feed.context == context && feed.pagesLoaded == 1)
        #expect(!feed.loadingMore && feed.next != nil)
    }
    @Test func suspendAndReenterRejectOldSuccessWithoutClearingAcceptedRows() async {
        let repo = RetentionRepository(), owner = scope
        let feed = LibraryViewModel(repository: repo)
        await feed.refresh(scope: owner)
        let rows = feed.items
        await repo.configure(block: true)
        let old = Task { await feed.refresh(scope: owner, preservingItems: true) }
        while !(await repo.waiting()) { await Task.yield() }
        feed.suspend()
        #expect(feed.items == rows && !feed.refreshing)
        await feed.refresh(scope: owner, preservingItems: true)
        let context = feed.context
        await repo.release(); await old.value
        #expect(feed.context == context && feed.items.first?.title.hasSuffix("request 3") == true)
    }
    @Test func cancelledCallerCannotAcceptTheLateResult() async {
        let repo = RetentionRepository(), owner = scope
        let feed = LibraryViewModel(repository: repo)
        await feed.refresh(scope: owner); let rows = feed.items, context = feed.context
        await repo.configure(block: true)
        let request = Task { await feed.refresh(scope: owner, preservingItems: true) }
        while !(await repo.waiting()) { await Task.yield() }
        request.cancel(); await repo.release(); await request.value
        #expect(feed.items == rows && feed.context == context && feed.next == nil && !feed.refreshing)
        #expect(feed.refreshError == nil)
    }
    @Test(arguments: [false, true])
    func differentScopeOrQueryCannotRetainOldRows(changeScope: Bool) async throws {
        let repo = RetentionRepository(), owner = scope
        let feed = LibraryViewModel(repository: repo)
        await feed.refresh(scope: owner)
        await repo.configure(block: true)
        let nextOwner = changeScope ? try owner.advanced() : owner
        let query = changeScope ? GalleryQuery() : GalleryQuery(terms: "another synthetic query")
        let request = Task { await feed.refresh(scope: nextOwner, query: query, preservingItems: true) }
        while !(await repo.waiting()) { await Task.yield() }
        #expect(feed.items.isEmpty && feed.context == nil)
        await repo.release(); await request.value
        #expect(feed.context?.scope == nextOwner && feed.items.count == 2)
    }
    @Test func loginRequiredSourceDoesNotReloadOnRootReturn() async throws {
        let repo = RetentionRepository(), owner = scope
        let sources = LibrarySourcesViewModel(repository: repo)
        sources.activate(scope: owner, authenticated: true)
        await repo.configure(failure: .authenticationRequired)
        try await sources.select(.watched, scope: owner)
        #expect(sources.requiresLogin)
        try await sources.load(scope: owner); try await sources.load(scope: owner)
        #expect(await repo.requests.count == 1)
        sources.activate(scope: owner, authenticated: false)
        sources.activate(scope: owner, authenticated: true)
        await repo.configure()
        try await sources.load(scope: owner)
        #expect(await repo.requests.count == 2)
        #expect(!sources.requiresLogin && sources.current.hasLoaded)
    }
    @Test func sourceSwitchCancelsRefreshAndPreservesTheOtherFeed() async throws {
        let repo = RetentionRepository(), owner = scope
        let sources = LibrarySourcesViewModel(repository: repo)
        sources.activate(scope: owner, authenticated: true)
        try await sources.select(.popular, scope: owner)
        let popular = sources.current.context
        try await sources.select(.browse, scope: owner)
        let rows = sources.current.items
        await repo.configure(block: true)
        let old = Task { try await sources.refresh(scope: owner) }
        while !(await repo.waiting()) { await Task.yield() }
        try await sources.select(.popular, scope: owner)
        await repo.release(); try await old.value
        #expect(sources.selected == .popular && sources.current.context == popular)
        #expect(sources.state(for: .browse).items == rows)
        #expect(!sources.state(for: .browse).refreshing)
    }
}
