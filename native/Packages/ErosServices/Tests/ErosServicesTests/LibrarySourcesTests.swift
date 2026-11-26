import Foundation
import XCTest
import ErosCore
import ErosServices

private actor SourceRepository: GalleryRepository {
    var requests: [GalleryListRequest] = []
    var error: AppError?
    var empty = false
    var loop = false
    var popularCursor = false
    var blockNext = false
    var continuation: CheckedContinuation<Void, Never>?
    func configure(error: AppError? = nil, empty: Bool = false, loop: Bool = false, popularCursor: Bool = false) {
        self.error = error; self.empty = empty; self.loop = loop; self.popularCursor = popularCursor
    }
    func block() { blockNext = true }
    func waiting() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
    func list(request: GalleryListRequest) async throws -> PagedResult<GallerySummary> {
        requests.append(request)
        let failure = error, isEmpty = empty, repeats = loop, hasPopularCursor = popularCursor
        if blockNext { blockNext = false; await withCheckedContinuation { continuation = $0 } }
        if let failure { throw failure }
        if isEmpty { return try PagedResult(items: [], context: request.context) }
        let item = try GallerySummary(reference: GalleryReference(key: GalleryKey(site: request.context.scope.storage.site, galleryID: GalleryID(request.cursor == nil ? 1 : 2)), token: SensitiveText("synthetic")), title: String(describing: request.query.source))
        let paginated = request.query.source != .popular || hasPopularCursor
        let next = paginated && (request.cursor == nil || repeats) ? PageCursor(context: request.context, opaque: try SensitiveText("server-cursor")) : nil
        return try PagedResult(items: [item], context: request.context, next: next)
    }
    func detail(request: GalleryRequest) async throws -> GalleryDetail { throw AppError.notFound }
    func readerPages(request: ReaderPagesRequest) async throws -> PagedResult<ReaderPage> { throw AppError.notFound }
}

@MainActor final class LibrarySourcesTests: XCTestCase {
    let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
    func testSevenSourcesKeepIndependentContextsAndReturnWithoutReload() async throws {
        let repo = SourceRepository(); let model = LibrarySourcesViewModel(repository: repo); model.activate(scope: scope, authenticated: true)
        var ids: Set<UUID> = []
        for source in LibrarySourceSelection.all {
            try await model.select(source, scope: scope)
            ids.insert(try XCTUnwrap(model.current.context?.queryID))
            XCTAssertEqual(model.current.items.first?.title, String(describing: source.source))
        }
        XCTAssertEqual(ids.count, 7)
        for source in LibrarySourceSelection.all { try await model.select(source, scope: scope) }
        let requests = await repo.requests; XCTAssertEqual(requests.count, 7)
        XCTAssertTrue(requests.allSatisfy { $0.query.terms.isEmpty && $0.query.excludedCategories.isEmpty && $0.query.filters == nil })
    }
    func testLateFirstPageAfterSourceSwitchCannotWriteEitherFeed() async throws {
        let repo = SourceRepository(); let model = LibrarySourcesViewModel(repository: repo); model.activate(scope: scope, authenticated: true)
        await repo.block(); let old = Task { try await model.select(.watched, scope: scope) }
        while !(await repo.waiting()) { await Task.yield() }
        XCTAssertTrue(model.state(for: .watched).initialLoading)
        try await model.select(.popular, scope: scope)
        let context = model.current.context
        await repo.release(); try await old.value
        XCTAssertEqual(model.selected, .popular); XCTAssertEqual(model.current.context, context)
        XCTAssertNil(model.state(for: .watched).context); XCTAssertFalse(model.state(for: .watched).initialLoading)
        try await model.select(.watched, scope: scope)
        XCTAssertEqual(model.current.items.first?.title, "watched")
        let requests = await repo.requests; XCTAssertEqual(requests.map(\.query.source), [.watched, .popular, .watched])
    }
    func testSwitchSuspendsPaginationButPreservesAcceptedRowsAndCursor() async throws {
        let repo = SourceRepository(); let model = LibrarySourcesViewModel(repository: repo); model.activate(scope: scope, authenticated: true)
        try await model.select(.browse, scope: scope)
        let context = model.current.context, cursor = model.current.next
        await repo.block(); let old = Task { try await model.loadMore(scope: scope) }
        while !(await repo.waiting()) { await Task.yield() }
        try await model.select(.popular, scope: scope)
        await repo.release(); try await old.value
        let browse = model.state(for: .browse)
        XCTAssertEqual(browse.items.count, 1); XCTAssertEqual(browse.context, context); XCTAssertEqual(browse.next, cursor)
        XCTAssertFalse(browse.loadingMore)
        try await model.select(.browse, scope: scope); try await model.loadMore(scope: scope)
        XCTAssertEqual(model.current.items.count, 2); XCTAssertEqual(model.current.context, context)
        let requests = await repo.requests; XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[1].cursor, requests[3].cursor)
    }
    func testRefreshChangesOnlySelectedFeedAndDeduplicatesSameSourceLoad() async throws {
        let repo = SourceRepository(); let model = LibrarySourcesViewModel(repository: repo); model.activate(scope: scope, authenticated: true)
        try await model.select(.browse, scope: scope); let browse = model.current.context
        await repo.block(); let first = Task { try await model.select(.watched, scope: scope) }
        while !(await repo.waiting()) { await Task.yield() }
        try await model.select(.watched, scope: scope)
        await repo.release(); try await first.value
        let old = model.current.context
        try await model.refresh(scope: scope)
        XCTAssertNotEqual(model.current.context, old); XCTAssertEqual(model.state(for: .browse).context, browse)
        let requests = await repo.requests; XCTAssertEqual(requests.count, 3)
    }
    func testEXToplistsKeepActiveScopeForEveryPeriod() async throws {
        let repo = SourceRepository(); let model = LibrarySourcesViewModel(repository: repo)
        let ex = SessionScope(storage: StorageScope(accountID: scope.storage.accountID, site: .ex), generation: 2)
        model.activate(scope: ex, authenticated: true)
        for period in ToplistPeriod.allCases {
            try await model.select(.toplist(period), scope: ex)
            XCTAssertEqual(model.selected, .toplist(period)); XCTAssertEqual(model.current.context?.scope, ex)
            XCTAssertEqual(model.activeScope, ex)
        }
        let requests = await repo.requests; XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.allSatisfy { $0.context.scope == ex })
    }
    func testScopeAndLogoutResetEveryFeedAndRejectLateResponses() async throws {
        for change in 0..<4 {
            let repo = SourceRepository(); let model = LibrarySourcesViewModel(repository: repo); model.activate(scope: scope, authenticated: true)
            try await model.select(.popular, scope: scope)
            await repo.block(); let old = Task { try await model.select(.watched, scope: scope) }
            while !(await repo.waiting()) { await Task.yield() }
            switch change {
            case 0: model.reset()
            case 1: model.activate(scope: SessionScope(storage: scope.storage, generation: 2))
            case 2: model.activate(scope: SessionScope(storage: StorageScope(accountID: scope.storage.accountID, site: .ex), generation: 2))
            default: model.activate(scope: SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 2))
            }
            await repo.release(); try await old.value
            XCTAssertEqual(model.selected, .browse)
            for source in LibrarySourceSelection.all {
                let feed = model.state(for: source)
                XCTAssertTrue(feed.items.isEmpty); XCTAssertNil(feed.context); XCTAssertNil(feed.next)
                XCTAssertFalse(feed.initialLoading); XCTAssertFalse(feed.refreshing); XCTAssertFalse(feed.loadingMore)
            }
            do { try await model.select(.popular, scope: scope); XCTFail("stale scope") }
            catch { XCTAssertEqual(error as? AppError, .scopeMismatch) }
        }
    }
    func testEmptyAuthenticationPermissionRateAndStructureRemainDistinct() async throws {
        let repo = SourceRepository(); let model = LibrarySourcesViewModel(repository: repo); model.activate(scope: scope, authenticated: true)
        await repo.configure(empty: true); try await model.select(.watched, scope: scope)
        XCTAssertTrue(model.current.hasLoaded); XCTAssertTrue(model.current.items.isEmpty); XCTAssertNil(model.current.initialError)
        for error in [AppError.authenticationRequired, .accessDenied, .rateLimited(retryAfter: 37), .parseMismatch] {
            await repo.configure(error: error); try await model.refresh(scope: scope)
            XCTAssertTrue(model.current.hasLoaded); XCTAssertNil(model.current.initialError)
            XCTAssertEqual(model.current.refreshError, error)
            XCTAssertNil(model.current.next)
        }
        await repo.configure(); try await model.refresh(scope: scope)
        XCTAssertTrue(model.current.hasLoaded); XCTAssertNil(model.current.initialError)
    }
    func testPopularNeverInventsPaginationButCanConsumeReturnedCursor() async throws {
        let repo = SourceRepository(); let model = LibrarySourcesViewModel(repository: repo); model.activate(scope: scope, authenticated: true)
        try await model.select(.popular, scope: scope)
        try await model.loadMore(scope: scope); try await model.loadMore(scope: scope)
        let first = await repo.requests; XCTAssertEqual(first.count, 1); XCTAssertNil(model.current.next)
        await repo.configure(popularCursor: true); try await model.refresh(scope: scope)
        let cursor = model.current.next
        try await model.loadMore(scope: scope)
        let later = await repo.requests; XCTAssertEqual(later.count, 3); XCTAssertEqual(later.last?.cursor, cursor)
        XCTAssertEqual(later.last?.query.source, .popular); XCTAssertNil(model.current.next)
    }
    func testDuplicateCursorStopsOnlyItsOwnSource() async throws {
        let repo = SourceRepository(); let model = LibrarySourcesViewModel(repository: repo); model.activate(scope: scope, authenticated: true)
        await repo.configure(loop: true)
        try await model.select(.watched, scope: scope); try await model.loadMore(scope: scope)
        XCTAssertEqual(model.current.paginationError, .parseMismatch); XCTAssertNil(model.current.next)
        try await model.loadMore(scope: scope)
        await repo.configure(); try await model.select(.browse, scope: scope)
        XCTAssertNil(model.current.paginationError); XCTAssertNotNil(model.current.next)
        let requests = await repo.requests; XCTAssertEqual(requests.count, 3)
    }
}

@MainActor final class LibrarySourceRestorationTests: XCTestCase {
    let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
    func testReopenRestoresSharedSourceWithoutRequesting() async throws {
        let suite = "f03b-" + UUID().uuidString; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibrarySourcePreferences(defaults: defaults), repo = SourceRepository()
        let first = LibrarySourcesViewModel(repository: repo, preferences: store)
        first.activate(scope: scope, authenticated: true)
        try await first.select(.toplist(.month), scope: scope)
        let ex = SessionScope(storage: StorageScope(accountID: scope.storage.accountID, site: .ex), generation: 2)
        first.activate(scope: ex, authenticated: true); try await first.select(.popular, scope: ex)
        let reopened = LibrarySourcesViewModel(repository: repo, preferences: LibrarySourcePreferences(defaults: defaults))
        reopened.activate(scope: scope, authenticated: true)
        XCTAssertEqual(reopened.selected, .popular); XCTAssertNil(reopened.current.context)
        let beforeLoad = await repo.requests; XCTAssertEqual(beforeLoad.count, 2)
        try await reopened.load(scope: scope)
        let loaded = await repo.requests; XCTAssertEqual(loaded.last?.query.source, .popular)
        let context = reopened.current.context
        try await reopened.load(scope: scope); XCTAssertEqual(reopened.current.context, context)
        let repeated = await repo.requests; XCTAssertEqual(repeated.count, 3)
        reopened.activate(scope: SessionScope(storage: scope.storage, generation: 3), authenticated: true)
        XCTAssertEqual(reopened.selected, .popular); XCTAssertNil(reopened.current.context)
        reopened.activate(scope: ex, authenticated: true); XCTAssertEqual(reopened.selected, .popular)
        reopened.activate(scope: SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 4))
        XCTAssertEqual(reopened.selected, .browse)
    }
    func testWatchedGuestAndRestoredGuestRequireLoginWithoutRequests() async throws {
        let suite = "f03b-" + UUID().uuidString; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibrarySourcePreferences(defaults: defaults), repo = SourceRepository()
        let model = LibrarySourcesViewModel(repository: repo, preferences: store)
        model.activate(scope: scope)
        try await model.select(.watched, scope: scope)
        XCTAssertTrue(model.requiresLogin); XCTAssertEqual(try store.load(scope: scope.storage), .watched)
        try await model.load(scope: scope); try await model.refresh(scope: scope); try await model.loadMore(scope: scope)
        let guest = await repo.requests; XCTAssertTrue(guest.isEmpty)
        model.reset(); model.activate(scope: scope)
        XCTAssertEqual(model.selected, .watched); XCTAssertTrue(model.requiresLogin)
        try await model.load(scope: scope)
        let restored = await repo.requests; XCTAssertTrue(restored.isEmpty)
        model.activate(scope: scope, authenticated: true); try await model.load(scope: scope)
        XCTAssertFalse(model.requiresLogin); XCTAssertTrue(model.current.hasLoaded)
        let verified = await repo.requests; XCTAssertEqual(verified.count, 1)
    }
    func testSameScopeAuthenticationLossClearsWatchedAndRejectsLatePage() async throws {
        let repo = SourceRepository(); let model = LibrarySourcesViewModel(repository: repo)
        model.activate(scope: scope, authenticated: true); try await model.select(.watched, scope: scope)
        await repo.block(); let old = Task { try await model.loadMore(scope: scope) }
        while !(await repo.waiting()) { await Task.yield() }
        model.activate(scope: scope, authenticated: false)
        await repo.release(); try await old.value
        XCTAssertTrue(model.requiresLogin); XCTAssertTrue(model.current.items.isEmpty); XCTAssertNil(model.current.next)
        try await model.load(scope: scope)
        let calls = await repo.requests; XCTAssertEqual(calls.count, 2)
        model.activate(scope: scope, authenticated: true); try await model.load(scope: scope)
        XCTAssertTrue(model.current.hasLoaded); XCTAssertEqual(model.current.items.count, 1)
    }
    func testAuthenticationPermissionAndEmptyHaveDifferentPresentationState() async throws {
        let repo = SourceRepository(); let model = LibrarySourcesViewModel(repository: repo)
        model.activate(scope: scope, authenticated: true)
        await repo.configure(error: .authenticationRequired); try await model.select(.watched, scope: scope)
        XCTAssertTrue(model.requiresLogin)
        await repo.configure(error: .accessDenied); try await model.refresh(scope: scope)
        XCTAssertFalse(model.requiresLogin); XCTAssertEqual(model.current.initialError, .accessDenied); XCTAssertFalse(model.current.hasLoaded)
        await repo.configure(empty: true); try await model.refresh(scope: scope)
        XCTAssertFalse(model.requiresLogin); XCTAssertNil(model.current.initialError); XCTAssertTrue(model.current.hasLoaded)
    }
    func testSharedToplistPreferenceStillRejectsStaleSiteSelection() async throws {
        let suite = "f03-adjust-" + UUID().uuidString; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibrarySourcePreferences(defaults: defaults), repo = SourceRepository()
        let ex = SessionScope(storage: StorageScope(accountID: scope.storage.accountID, site: .ex), generation: 2)
        let model = LibrarySourcesViewModel(repository: repo, preferences: store)
        model.activate(scope: ex, authenticated: true); try await model.select(.toplist(.yesterday), scope: ex)
        XCTAssertEqual(try store.load(scope: ex.storage), .toplist(.yesterday))
        model.activate(scope: scope, authenticated: true)
        do { try await model.select(.watched, scope: ex); XCTFail("stale menu") }
        catch { XCTAssertEqual(error as? AppError, .scopeMismatch) }
        XCTAssertEqual(try store.load(scope: ex.storage), .toplist(.yesterday))
        try await model.select(.toplist(.month), scope: scope)
        XCTAssertEqual(try store.load(scope: ex.storage), .toplist(.month))
        let requests = await repo.requests; XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.context.scope.storage.site), [.ex, .eh])
    }
    func testUnsupportedOrMalformedPreferenceFallsBackWithoutOverwriting() async throws {
        let suite = "f03b-" + UUID().uuidString; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "native.library.source.v1." + scope.storage.accountID.value.uuidString + ".eh"
        let shared = "native.library.source.v2." + scope.storage.accountID.value.uuidString
        let store = LibrarySourcePreferences(defaults: defaults)
        for json in ["not JSON", "{\"version\":2}", "{\"source\":{\"toplist\":{\"_0\":\"999\"}}}"] {
            defaults.removeObject(forKey: shared)
            let data = Data(json.utf8); defaults.set(data, forKey: key)
            let model = LibrarySourcesViewModel(repository: SourceRepository(), preferences: store)
            model.activate(scope: scope, authenticated: true)
            XCTAssertEqual(model.selected, .browse); XCTAssertNotNil(model.preferencesMessage)
            XCTAssertEqual(defaults.data(forKey: key), data)
            try await model.select(.popular, scope: scope)
            XCTAssertNil(model.preferencesMessage); XCTAssertEqual(try store.load(scope: scope.storage), .popular)
        }
        defaults.removeObject(forKey: shared)
        defaults.set(Data("{}".utf8), forKey: key)
        XCTAssertEqual(try store.load(scope: scope.storage), .browse)
    }
    func testRestoredEXToplistLoadsWithoutChangingReadingSite() async throws {
        let suite = "f03b-" + UUID().uuidString; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ex = SessionScope(storage: StorageScope(accountID: scope.storage.accountID, site: .ex), generation: 2)
        let store = LibrarySourcePreferences(defaults: defaults), repo = SourceRepository()
        try store.save(.toplist(.year), scope: ex.storage)
        let model = LibrarySourcesViewModel(repository: repo, preferences: store)
        model.activate(scope: ex, authenticated: true)
        XCTAssertEqual(model.selected, .toplist(.year)); XCTAssertEqual(model.activeScope, ex); XCTAssertNil(model.preferencesMessage)
        let before = await repo.requests; XCTAssertTrue(before.isEmpty)
        try await model.load(scope: ex)
        let after = await repo.requests; XCTAssertEqual(after.count, 1); XCTAssertEqual(after[0].query.source, .toplist(period: "12"))
        XCTAssertEqual(after[0].context.scope, ex)
    }
    func testFailedSourceSelectionPersistsAndRetryKeepsSource() async throws {
        let suite = "f03b-" + UUID().uuidString; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibrarySourcePreferences(defaults: defaults), repo = SourceRepository()
        let model = LibrarySourcesViewModel(repository: repo, preferences: store); model.activate(scope: scope, authenticated: true)
        await repo.configure(error: .transport(code: -1009)); try await model.select(.toplist(.allTime), scope: scope)
        XCTAssertEqual(try store.load(scope: scope.storage), .toplist(.allTime))
        XCTAssertEqual(model.current.initialError, .transport(code: -1009))
        await repo.configure(); try await model.refresh(scope: scope)
        XCTAssertTrue(model.current.hasLoaded)
        let requests = await repo.requests; XCTAssertEqual(requests.map(\.query.source), [.toplist(period: "11"), .toplist(period: "11")])
        let stored = try XCTUnwrap(defaults.persistentDomain(forName: suite))
        XCTAssertEqual(stored.count, 1)
        let data = try XCTUnwrap(stored.values.first as? Data)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(record.keys), Set(["version", "source"]))
    }
}
