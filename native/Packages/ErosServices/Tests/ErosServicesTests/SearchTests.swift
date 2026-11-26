import Foundation
import XCTest
import ErosCore
import ErosServices

private actor SearchRepository: GalleryRepository {
    var requests: [GalleryListRequest] = []
    var blockNext = false
    var continuation: CheckedContinuation<Void, Never>?
    func block() { blockNext = true }
    func waiting() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
    func list(request: GalleryListRequest) async throws -> PagedResult<GallerySummary> {
        requests.append(request)
        if blockNext { blockNext = false; await withCheckedContinuation { continuation = $0 } }
        if request.query.terms == "fail" { throw AppError.transport(code: -1009) }
        if request.query.terms == "empty" { return try PagedResult(items: [], context: request.context) }
        let id: Int64 = request.cursor == nil ? 1 : 2
        let item = try GallerySummary(reference: GalleryReference(key: GalleryKey(site: request.context.scope.storage.site, galleryID: GalleryID(id)), token: SensitiveText("synthetic")), title: request.query.terms)
        return try PagedResult(items: [item], context: request.context,
            next: request.cursor == nil ? PageCursor(context: request.context, opaque: SensitiveText("second")) : nil)
    }
    func detail(request: GalleryRequest) async throws -> GalleryDetail { throw AppError.notFound }
    func readerPages(request: ReaderPagesRequest) async throws -> PagedResult<ReaderPage> { throw AppError.notFound }
}

@MainActor final class SearchTests: XCTestCase {
    let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
    func testRootAndNestedResultPagesKeepIndependentQueriesAndPagination() async throws {
        let repo = SearchRepository()
        let entry = SearchViewModel(repository: repo)
        let results = SearchViewModel(repository: repo)
        let firstTag = SearchViewModel(repository: repo)
        let nestedTag = SearchViewModel(repository: repo)

        entry.activate(scope: scope)
        entry.draft = "original entry"
        XCTAssertTrue(entry.validateDraft(scope: scope))
        results.startResults(terms: entry.draft, scope: scope, filters: entry.appliedFilters)
        await results.refresh(scope: scope, submission: results.submissionID)
        let entryResultContext = results.results.context

        firstTag.startResults(terms: "artist:sample", scope: scope, filters: nil)
        await firstTag.refresh(scope: scope, submission: firstTag.submissionID)
        await firstTag.results.loadMore()
        nestedTag.startResults(terms: "group:sample", scope: scope, filters: nil)
        await nestedTag.refresh(scope: scope, submission: nestedTag.submissionID)
        nestedTag.draft = ""
        XCTAssertNil(nestedTag.submitDraft(scope: scope))
        XCTAssertEqual(nestedTag.submittedTerms, "group:sample")
        XCTAssertEqual(nestedTag.results.items.map(\.title), ["group:sample"])
        nestedTag.draft = "edited nested"
        let edited = try XCTUnwrap(nestedTag.submitDraft(scope: scope))
        await nestedTag.refresh(scope: scope, submission: edited)

        XCTAssertEqual(nestedTag.results.items.map(\.title), ["edited nested"])
        XCTAssertNil(entry.submittedQuery)
        XCTAssertEqual(entry.draft, "original entry")
        XCTAssertEqual(results.results.context, entryResultContext)
        XCTAssertEqual(results.results.items.map(\.title), ["original entry"])
        XCTAssertEqual(firstTag.draft, "artist:sample")
        XCTAssertEqual(firstTag.results.pagesLoaded, 2)
        XCTAssertEqual(firstTag.results.items.map(\.title), ["artist:sample", "artist:sample"])

        firstTag.startResults(terms: "artist:sample", scope: scope, filters: nil)
        XCTAssertEqual(firstTag.results.pagesLoaded, 2)
    }
    func testDraftEditsDoNotRequestAndSubmissionPreservesExpression() async {
        let repo = SearchRepository(); let model = SearchViewModel(repository: repo); model.activate(scope: scope)
        for draft in ["n", "ni", "日本語", "  language:\"中文 日本語\" -tag:test + & % #  "] { model.draft = draft }
        let before = await repo.requests; XCTAssertTrue(before.isEmpty)
        await model.submit(scope: scope)
        let after = await repo.requests; XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.query.terms, GalleryQuery(terms: model.draft).terms); XCTAssertEqual(model.submittedTerms, after.first?.query.terms)
    }
    func testBlankSubmissionAndClearNeverBrowseHomepage() async {
        let repo = SearchRepository(); let model = SearchViewModel(repository: repo); model.activate(scope: scope)
        model.draft = " \n "; await model.submit(scope: scope)
        let requests = await repo.requests; XCTAssertTrue(requests.isEmpty)
        XCTAssertNotNil(model.validationMessage); XCTAssertNil(model.submittedTerms)
        model.clear(); XCTAssertTrue(model.draft.isEmpty); XCTAssertNil(model.validationMessage)
    }
    func testEmptyResultsDistinctFromNetworkFailureAndRetry() async {
        let repo = SearchRepository(); let model = SearchViewModel(repository: repo); model.activate(scope: scope)
        model.draft = "empty"; await model.submit(scope: scope)
        XCTAssertTrue(model.results.hasLoaded); XCTAssertTrue(model.results.items.isEmpty); XCTAssertNil(model.results.initialError)
        model.draft = "fail"; await model.submit(scope: scope)
        XCTAssertFalse(model.results.hasLoaded); XCTAssertEqual(model.results.initialError, .transport(code: -1009))
        model.draft = "recovered"; await model.submit(scope: scope)
        XCTAssertNil(model.results.initialError); XCTAssertEqual(model.results.items.first?.title, "recovered")
    }
    func testDraftDoesNotChangeRefreshOrPaginationOfSubmittedQuery() async {
        let repo = SearchRepository(); let model = SearchViewModel(repository: repo); model.activate(scope: scope)
        model.draft = "submitted"; await model.submit(scope: scope)
        model.draft = "unsubmitted"; await model.results.loadMore(); await model.refresh(scope: scope)
        let requests = await repo.requests
        XCTAssertEqual(requests.map(\.query.terms), ["submitted", "submitted", "submitted"])
        XCTAssertNotNil(requests[1].cursor); XCTAssertNil(requests[2].cursor)
        XCTAssertEqual(model.results.pagesLoaded, 1); XCTAssertEqual(model.draft, "unsubmitted")
    }
    func testNewQuerySuppressesLateOldResponse() async {
        let repo = SearchRepository(); let model = SearchViewModel(repository: repo); model.activate(scope: scope)
        model.draft = "old"; await repo.block()
        let old = Task { await model.submit(scope: scope) }
        while !(await repo.waiting()) { await Task.yield() }
        model.draft = "new"; await model.submit(scope: scope); await repo.release(); await old.value
        XCTAssertEqual(model.submittedTerms, "new"); XCTAssertEqual(model.results.items.first?.title, "new")
        let requests = await repo.requests; XCTAssertNotEqual(requests[0].context.queryID, requests[1].context.queryID)
    }
    func testScopeResetAndClearSuppressLateResults() async {
        for clearDraft in [false, true] {
            let repo = SearchRepository(); let model = SearchViewModel(repository: repo); model.activate(scope: scope)
            model.draft = "old"; await repo.block(); let task = Task { await model.submit(scope: scope) }
            while !(await repo.waiting()) { await Task.yield() }
            if clearDraft { model.clear() } else { model.resetForScopeChange() }
            await repo.release(); await task.value
            XCTAssertNil(model.submittedTerms); XCTAssertTrue(model.results.items.isEmpty)
            XCTAssertEqual(model.draft, clearDraft ? "" : "old")
            let ex = SessionScope(storage: StorageScope(accountID: scope.storage.accountID, site: .ex), generation: 2)
            model.activate(scope: ex) // The host activates the new session before a keyboard submission.
            model.draft = "new"; await model.submit(scope: ex)
            XCTAssertEqual(model.results.context?.scope, ex)
            XCTAssertEqual(model.results.items.first?.reference.key.site, .ex)
        }
    }
    func testSearchDoesNotReplaceLibraryFeed() async {
        let repo = SearchRepository(); let search = SearchViewModel(repository: repo); search.activate(scope: scope)
        let library = LibraryViewModel(repository: repo)
        await library.refresh(scope: scope, query: GalleryQuery(terms: "homepage"))
        let context = library.context
        search.draft = "query"; await search.submit(scope: scope)
        XCTAssertEqual(library.context, context); XCTAssertEqual(library.items.first?.title, "homepage")
        XCTAssertEqual(search.results.items.first?.title, "query")
    }
}

@MainActor final class SearchFilterApplicationTests: XCTestCase {
    let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
    func testApplyResetsCursorAndRefreshPreservesAppliedQuery() async throws {
        let repo = SearchRepository(); let model = SearchViewModel(repository: repo); model.activate(scope: scope)
        model.draft = "language:\"中文 日本語\" + %25"; await model.submit(scope: scope)
        let old = model.results.context
        var draft = try model.filterDraft(); draft.requireTorrent = true
        let ticket = try model.applyFilters(draft, scope: scope)
        XCTAssertNil(model.results.next); XCTAssertNil(model.results.context)
        await model.refresh(scope: scope, submission: ticket)
        XCTAssertNotEqual(model.results.context?.queryID, old?.queryID)
        model.draft = "not submitted"; await model.results.loadMore(); await model.refresh(scope: scope)
        let requests = await repo.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertNil(requests[1].cursor); XCTAssertNotNil(requests[2].cursor)
        for request in requests.dropFirst() {
            XCTAssertEqual(request.query.terms, "language:\"中文 日本語\" + %25")
            XCTAssertEqual(request.query.filters?.requireTorrent, true)
        }
    }
    func testCancelAndResetAreOnlyLocalUntilApplied() async throws {
        let repo = SearchRepository(); let model = SearchViewModel(repository: repo); model.activate(scope: scope)
        model.activate(scope: scope); model.draft = "search"
        var form = SearchFilterDraft(); form.requireTorrent = true
        try model.applyFilters(form, scope: scope); await model.refresh(scope: scope)
        let context = model.results.context
        var edited = try model.filterDraft(); edited.reset()
        XCTAssertEqual(model.appliedFilters.activeCount, 1); XCTAssertEqual(model.results.context, context)
        XCTAssertTrue(try model.filterDraft().requireTorrent)
        let before = await repo.requests; XCTAssertEqual(before.count, 1)
        try model.applyFilters(edited, scope: scope); await model.refresh(scope: scope)
        XCTAssertEqual(model.appliedFilters.activeCount, 0)
        let after = await repo.requests; XCTAssertNil(after.last?.query.filters)
    }
    func testInvalidFormDoesNotCommitOrRequest() async throws {
        let repo = SearchRepository(); let model = SearchViewModel(repository: repo); model.activate(scope: scope)
        model.draft = "old"; await model.submit(scope: scope)
        let context = model.results.context, query = model.submittedQuery
        var form = SearchFilterDraft(); form.pageRangeEnabled = true
        form.minimumPageCount = "10"; form.maximumPageCount = "1"
        XCTAssertThrowsError(try model.applyFilters(form, scope: scope))
        XCTAssertEqual(model.submittedQuery, query); XCTAssertEqual(model.results.context, context)
        let requests = await repo.requests; XCTAssertEqual(requests.count, 1)
    }
    func testOldPaginationCannotWriteAfterFilterApplication() async throws {
        let repo = SearchRepository(); let model = SearchViewModel(repository: repo); model.activate(scope: scope)
        model.draft = "old"; await model.submit(scope: scope)
        await repo.block(); let old = Task { await model.results.loadMore() }
        while !(await repo.waiting()) { await Task.yield() }
        var form = SearchFilterDraft(); form.includeExpunged = true
        try model.applyFilters(form, scope: scope); await model.refresh(scope: scope)
        let context = model.results.context
        await repo.release(); await old.value
        XCTAssertEqual(model.results.context, context); XCTAssertEqual(model.results.items.count, 1)
        XCTAssertEqual(model.results.pagesLoaded, 1)
    }
    func testFailureRetainsInputsAndAppliedFiltersForRetry() async throws {
        let repo = SearchRepository(); let model = SearchViewModel(repository: repo); model.activate(scope: scope)
        model.activate(scope: scope); model.draft = "fail"
        var form = SearchFilterDraft(); form.disableTagFilter = true
        try model.applyFilters(form, scope: scope); await model.refresh(scope: scope)
        XCTAssertEqual(model.results.initialError, .transport(code: -1009))
        XCTAssertEqual(model.draft, "fail"); XCTAssertEqual(model.appliedFilters.activeCount, 1)
        model.draft = "unsubmitted"; await model.refresh(scope: scope)
        let requests = await repo.requests; XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].query, requests[1].query)
    }
    func testStaleSheetAndScheduledApplicationAreRejected() async throws {
        let repo = SearchRepository(); let model = SearchViewModel(repository: repo); model.activate(scope: scope)
        model.activate(scope: scope)
        let ticket = try model.applyFilters(SearchFilterDraft(), scope: scope)
        model.draft = "new"; await model.submit(scope: scope)
        await model.refresh(scope: scope, submission: ticket)
        let ex = SessionScope(storage: StorageScope(accountID: scope.storage.accountID, site: .ex), generation: 2)
        model.activate(scope: ex)
        XCTAssertThrowsError(try model.applyFilters(SearchFilterDraft(), scope: scope))
        await model.refresh(scope: scope)
        await model.submit(scope: scope) // stale keyboard task must not reactivate the old site
        let requests = await repo.requests; XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(model.activeScope, ex)
        XCTAssertNil(model.submittedQuery); XCTAssertEqual(model.appliedFilters.activeCount, 0)
        model.resetForScopeChange()
        await model.submit(scope: scope)
        XCTAssertNil(model.activeScope)
        let afterReset = await repo.requests; XCTAssertEqual(afterReset.count, 1)
    }
    func testPreferenceReopenAcrossSitesAndAccountIsolation() async throws {
        let suite = "f02b-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SearchFilterPreferences(defaults: defaults)
        let repo = SearchRepository(); let first = SearchViewModel(repository: repo, preferences: store)
        first.activate(scope: scope); first.draft = "private expression"
        var form = SearchFilterDraft(); form.requireTorrent = true; form.excludedCategories = [.manga]
        try first.applyFilters(form, scope: scope)
        let reopened = SearchViewModel(repository: repo, preferences: SearchFilterPreferences(defaults: defaults))
        reopened.activate(scope: scope)
        XCTAssertEqual(reopened.appliedFilters.activeCount, 2); XCTAssertEqual(reopened.draft, "")
        XCTAssertNil(reopened.submittedQuery)
        reopened.activate(scope: SessionScope(storage: scope.storage, generation: 2))
        XCTAssertEqual(reopened.appliedFilters.activeCount, 2)
        reopened.activate(scope: SessionScope(storage: StorageScope(accountID: scope.storage.accountID, site: .ex), generation: 3))
        XCTAssertEqual(reopened.appliedFilters.activeCount, 2)
        reopened.activate(scope: SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 4))
        XCTAssertEqual(reopened.appliedFilters.activeCount, 0)
        reopened.activate(scope: scope); XCTAssertEqual(reopened.appliedFilters.activeCount, 2)
        let stored = try XCTUnwrap(defaults.persistentDomain(forName: suite))
        XCTAssertEqual(stored.count, 1)
        let data = try XCTUnwrap(stored.values.first as? Data)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private expression"))
        let requests = await repo.requests; XCTAssertTrue(requests.isEmpty)
    }
    func testEntryLaunchCarriesItsFiltersAndRefreshesPreferencesOnReturn() async throws {
        let suite = "search-route-filters-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SearchFilterPreferences(defaults: defaults)
        let history = SearchHistoryStore(defaults: defaults)
        let repo = SearchRepository()
        let entry = SearchViewModel(repository: repo, preferences: preferences, history: history)
        let results = SearchViewModel(repository: repo, preferences: preferences, history: history)
        entry.activate(scope: scope)
        var form = SearchFilterDraft()
        form.includedCategories = [.manga]
        try entry.saveFilters(form, scope: scope)
        let launchFilters = entry.appliedFilters

        let before = await repo.requests
        XCTAssertTrue(before.isEmpty)
        XCTAssertNil(entry.submittedQuery)
        try preferences.save(SearchFilterSelection(), scope: scope.storage)
        results.startResults(terms: "", scope: scope, filters: launchFilters)
        await results.refresh(scope: scope, submission: results.submissionID)
        entry.reloadSavedFilters(scope: scope)
        results.reloadSavedFilters(scope: scope)

        let after = await repo.requests
        XCTAssertEqual(after.map(\.query), [launchFilters.query(terms: "")])
        XCTAssertEqual(entry.appliedFilters.activeCount, 0)
        XCTAssertEqual(results.appliedFilters.activeCount, 9)
    }

    func testFilterOnlySearchAndClearRetainsSelection() async throws {
        let repo = SearchRepository(); let model = SearchViewModel(repository: repo); model.activate(scope: scope)
        model.activate(scope: scope)
        var form = SearchFilterDraft(); form.requireTorrent = true
        try model.applyFilters(form, scope: scope); await model.refresh(scope: scope)
        model.clear(); XCTAssertNil(model.submittedQuery); XCTAssertEqual(model.appliedFilters.activeCount, 1)
        await model.submit(scope: scope)
        let requests = await repo.requests; XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.query.terms, ""); XCTAssertEqual(requests.last?.query.filters?.requireTorrent, true)
    }
}

@MainActor final class SearchFilterRecoveryTests: XCTestCase {
    func testUnreadableSavedSelectionWarnsWithoutOverwritingUntilApply() throws {
        let suite = "f02b-recovery-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .eh), generation: 1)
        let key = "native.search.filters.v1." + scope.storage.accountID.value.uuidString + ".eh"
        let invalid = Data("not JSON".utf8); defaults.set(invalid, forKey: key)
        let model = SearchViewModel(repository: SearchRepository(), preferences: SearchFilterPreferences(defaults: defaults))
        model.activate(scope: scope)
        XCTAssertNotNil(model.preferencesMessage); XCTAssertEqual(model.appliedFilters.activeCount, 0)
        XCTAssertEqual(defaults.data(forKey: key), invalid)
        var form = try model.filterDraft(); form.includeExpunged = true
        try model.applyFilters(form, scope: scope)
        XCTAssertNil(model.preferencesMessage)
        XCTAssertEqual(try SearchFilterPreferences(defaults: defaults).load(scope: scope.storage).activeCount, 1)
    }
}
