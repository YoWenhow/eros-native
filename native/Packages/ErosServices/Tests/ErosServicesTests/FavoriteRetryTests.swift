import Foundation
import Testing
import XCTest
import ErosCore
import ErosServices

private actor RetryFavorites: RemoteFavoritesRepository {
    private var failNext = false
    private var requests: [FavoritesListRequest] = []
    private let containsFavorites: Bool
    private let allowedGroups: Set<String>
    private var holdNextGroups = false
    private var heldGroups: CheckedContinuation<Void, Never>?

    init(containsFavorites: Bool = true, allowedGroups: Set<String> = ["2"]) {
        self.containsFavorites = containsFavorites
        self.allowedGroups = allowedGroups
    }
    func failPage() { failNext = true }
    func cursors() -> [String?] { requests.map { $0.cursor?.opaque.value } }
    func listRequests() -> [FavoritesListRequest] { requests }
    func holdUpcomingGroupsRead() { holdNextGroups = true }
    func groupsReadIsHeld() -> Bool { heldGroups != nil }
    func releaseGroupsRead() {
        let continuation = heldGroups
        heldGroups = nil
        continuation?.resume()
    }
    func groups(scope: SessionScope) async -> [FavoriteGroup] {
        if holdNextGroups {
            holdNextGroups = false
            await withCheckedContinuation { heldGroups = $0 }
        }
        return []
    }
    func mutate(request: FavoriteMutation) throws { throw AppError.unsupportedContent }
    func popup(request: GalleryRequest) throws -> FavoritePopup { throw AppError.unsupportedContent }
    func list(request: FavoritesListRequest) throws -> PagedResult<GallerySummary> {
        XCTAssertTrue(allowedGroups.contains(request.groupID ?? ""))
        let cursor = request.cursor?.opaque.value
        requests.append(request)
        if cursor != nil && failNext { failNext = false; throw AppError.transport(code: -1009) }
        guard containsFavorites else { return try PagedResult(items: [], context: request.context, next: nil) }
        let next = cursor == "A" ? "B" : "A"
        let ref = try GalleryReference(
            key: GalleryKey(site: request.context.scope.storage.site, galleryID: GalleryID(cursor == nil ? 42 : 43)),
            token: SensitiveText("synthetic"))
        return try PagedResult(items: [GallerySummary(reference: ref, title: "Synthetic favorite")], context: request.context,
                               next: PageCursor(context: request.context, opaque: SensitiveText(next)))
    }
}
@MainActor
struct FavoriteAutomaticPaginationTests {
    private let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)

    @Test func rejectsAnOldSelectionAndAScheduledPageAlreadyLoadedManually() async {
        let repo = RetryFavorites(allowedGroups: ["2", "3"])
        let model = RemoteFavoritesViewModel(repository: repo, scope: scope)
        await model.loadOnAppearance(group: "2", titleQuery: "old")
        let oldQuery = model.queryID

        await model.loadOnAppearance(group: "3", titleQuery: "new")
        let currentQuery = model.queryID
        await model.loadMoreIfCurrent(queryID: oldQuery, afterPage: 1)
        #expect(await repo.cursors() == [nil, nil])

        await model.more()
        await model.loadMoreIfCurrent(queryID: currentQuery, afterPage: 1)

        let requests = await repo.listRequests()
        #expect(requests.map(\.groupID) == ["2", "3", "3"])
        #expect(requests.map(\.titleQuery) == ["old", "new", "new"])
        #expect(requests.map { $0.cursor?.opaque.value } == [nil, nil, "A"])
        #expect(model.pagesLoaded == 2)
    }

    @Test func repeatedScrollEventsLoadTheCurrentPageOnce() async {
        let repo = RetryFavorites()
        let model = RemoteFavoritesViewModel(repository: repo, scope: scope)
        await model.loadOnAppearance(group: "2")
        let query = model.queryID

        await model.loadMoreIfCurrent(queryID: query, afterPage: 1)
        await model.loadMoreIfCurrent(queryID: query, afterPage: 1)

        #expect(await repo.cursors() == [nil, "A"])
        #expect(model.pagesLoaded == 2)
        #expect(model.items.count == 2)
    }

    @Test func scrollEventsLeaveAFailedPageForExplicitRetry() async {
        let repo = RetryFavorites()
        let model = RemoteFavoritesViewModel(repository: repo, scope: scope)
        await model.loadOnAppearance(group: "2", titleQuery: "favorite")
        let query = model.queryID
        await repo.failPage()

        await model.loadMoreIfCurrent(queryID: query, afterPage: 1)
        await model.loadMoreIfCurrent(queryID: query, afterPage: 1)
        #expect(model.error == .transport(code: -1009))
        #expect(model.pagesLoaded == 1)
        #expect(await repo.cursors() == [nil, "A"])

        await model.retry()
        #expect(model.error == nil)
        #expect(model.pagesLoaded == 2)
        #expect(await repo.cursors() == [nil, "A", "A"])
    }
}

@MainActor final class FavoriteRetryTests: XCTestCase {
    let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
    func testCursorCycleRecoversByRefreshingSameGroup() async throws {
        let repo = RetryFavorites()
        let target = RemoteFavoritesViewModel(repository: repo, scope: scope)
        await target.refresh(group: "2"); await target.more(); await target.more()
        XCTAssertEqual(target.error, .parseMismatch); XCTAssertTrue(target.retryNeedsRefresh)
        XCTAssertFalse(target.items.isEmpty)
        let oldQuery = target.queryID
        await target.retry()
        XCTAssertNil(target.error); XCTAssertEqual(target.groupID, "2")
        XCTAssertNotEqual(target.queryID, oldQuery); XCTAssertEqual(target.pagesLoaded, 1)
        let cursors = await repo.cursors(); XCTAssertEqual(cursors, [nil, "A", "B", nil])
    }
    func testTransportErrorRetainsCursorAndQueryForRetry() async throws {
        let repo = RetryFavorites()
        let model = RemoteFavoritesViewModel(repository: repo, scope: scope)
        await model.refresh(group: "2"); let query = model.queryID
        await repo.failPage(); await model.more()
        XCTAssertNotNil(model.error); XCTAssertFalse(model.retryNeedsRefresh)
        await model.retry()
        XCTAssertNil(model.error); XCTAssertEqual(model.queryID, query); XCTAssertEqual(model.pagesLoaded, 2)
        let cursors = await repo.cursors(); XCTAssertEqual(cursors, [nil, "A", "A"])
    }

    func testTitleSearchAndFolderSurvivePaginationRetry() async {
        let repo = RetryFavorites()
        let model = RemoteFavoritesViewModel(repository: repo, scope: scope)
        await model.loadOnAppearance(group: "2", titleQuery: "favorite")
        await repo.failPage()
        await model.more()
        await model.retry()

        let requests = await repo.listRequests()
        XCTAssertEqual(requests.map(\.groupID), ["2", "2", "2"])
        XCTAssertEqual(requests.map(\.titleQuery), ["favorite", "favorite", "favorite"])
        XCTAssertEqual(requests.map { $0.cursor?.opaque.value }, [nil, "A", "A"])
        XCTAssertEqual(Set(requests.map(\.context.queryID)).count, 1)
        XCTAssertEqual(model.pagesLoaded, 2)
    }

    func testNewFavoriteSearchSupersedesALateRefreshForAnotherFolder() async {
        let repo = RetryFavorites(allowedGroups: ["2", "3"])
        let model = RemoteFavoritesViewModel(repository: repo, scope: scope)
        await repo.holdUpcomingGroupsRead()
        let old = Task { await model.refresh(group: "2", titleQuery: "old") }
        while !(await repo.groupsReadIsHeld()) { await Task.yield() }

        await model.loadOnAppearance(group: "3", titleQuery: "new")
        let accepted = model.queryID
        await repo.releaseGroupsRead()
        await old.value

        XCTAssertEqual(model.queryID, accepted)
        XCTAssertEqual(model.groupID, "3")
        XCTAssertEqual(model.titleQuery, "new")
        XCTAssertFalse(model.loading)
        let requests = await repo.listRequests()
        XCTAssertEqual(requests.map(\.groupID), ["3"])
        XCTAssertEqual(requests.map(\.titleQuery), ["new"])
    }

    func testReappearanceKeepsAcceptedRowsAndCursor() async {
        let repo = RetryFavorites()
        let model = RemoteFavoritesViewModel(repository: repo, scope: scope)
        await model.loadOnAppearance(group: "2")
        await model.more()
        let items = model.items
        let query = model.queryID
        let keys = model.lastPageKeys
        let cursor = model.next?.opaque.value

        await model.loadOnAppearance(group: "2")
        await model.loadOnAppearance(group: "2")

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(model.items, items)
        XCTAssertEqual(model.pagesLoaded, 2)
        XCTAssertEqual(model.queryID, query)
        XCTAssertEqual(model.lastPageKeys, keys)
        XCTAssertEqual(model.next?.opaque.value, cursor)
        let reads = await repo.cursors()
        XCTAssertEqual(reads, [nil, "A"])
    }

    func testEmptyGroupStaysLoadedWhileChildReturnAndManualReadsStillRefresh() async {
        let repo = RetryFavorites(containsFavorites: false, allowedGroups: ["2", "3"])
        let model = RemoteFavoritesViewModel(repository: repo, scope: scope)
        await model.loadOnAppearance(group: "2")
        let initial = model.queryID
        await model.loadOnAppearance(group: "2")
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.pagesLoaded, 1)
        XCTAssertEqual(model.queryID, initial)

        await model.loadOnAppearance(group: "2", refreshAfterChild: true)
        let returnedFromChild = model.queryID
        XCTAssertNotEqual(returnedFromChild, initial)
        await model.refresh(group: "2")
        XCTAssertNotEqual(model.queryID, returnedFromChild)
        await model.refresh(group: "3")
        XCTAssertEqual(model.groupID, "3")
        let reads = await repo.cursors()
        XCTAssertEqual(reads, [nil, nil, nil, nil])
    }

    func testAppearanceReplacesCancelledFirstReadAndRejectsItsLateCompletion() async {
        let repo = RetryFavorites()
        let model = RemoteFavoritesViewModel(repository: repo, scope: scope)
        await repo.holdUpcomingGroupsRead()
        let previous = Task { await model.loadOnAppearance(group: "2") }
        while !(await repo.groupsReadIsHeld()) { await Task.yield() }
        previous.cancel()
        let cancelled = model.queryID

        await model.loadOnAppearance(group: "2")
        let accepted = model.queryID
        await repo.releaseGroupsRead()
        await previous.value

        XCTAssertNotEqual(accepted, cancelled)
        XCTAssertEqual(model.queryID, accepted)
        XCTAssertEqual(model.pagesLoaded, 1)
        XCTAssertFalse(model.loading)
        XCTAssertNil(model.error)
        let reads = await repo.cursors()
        XCTAssertEqual(reads, [nil])
    }

    func testAppearanceKeepsAnActiveExplicitRefreshInControl() async {
        let repo = RetryFavorites()
        let model = RemoteFavoritesViewModel(repository: repo, scope: scope)
        await repo.holdUpcomingGroupsRead()
        let refresh = Task { await model.refresh(group: "2") }
        while !(await repo.groupsReadIsHeld()) { await Task.yield() }
        let inFlight = model.queryID

        await model.loadOnAppearance(group: "2")
        XCTAssertEqual(model.queryID, inFlight)
        XCTAssertTrue(model.loading)
        await repo.releaseGroupsRead()
        await refresh.value

        XCTAssertEqual(model.pagesLoaded, 1)
        let reads = await repo.cursors()
        XCTAssertEqual(reads, [nil])
    }
}
