import Foundation
import Observation
import ErosCore

/// One ordered feed per scope/query; refresh tickets never change the account's storage identity.
@MainActor @Observable
public final class LibraryViewModel {
    public private(set) var items: [GallerySummary] = []
    public private(set) var lastPageKeys: Set<GalleryKey> = []
    public private(set) var totalCount: GalleryResultCount?
    public var resultCountText: String { totalCount?.displayText ?? "网站未提供总数" }
    public private(set) var initialLoading = false
    public private(set) var refreshing = false
    public private(set) var loadingMore = false
    public private(set) var initialError: AppError?
    public private(set) var refreshError: AppError?
    public private(set) var paginationError: AppError?
    public private(set) var paginationNeedsRefresh = false
    /// Resets presentation only when changing query/scope or explicitly clearing.
    public private(set) var presentationRevision = UUID()
    public private(set) var pagesLoaded = 0
    public private(set) var duplicateCount = 0
    public private(set) var context: RequestContext?
    public private(set) var next: PageCursor?
    public var hasLoaded: Bool { context != nil }
    public var canLoadMore: Bool { next != nil && !initialLoading && !refreshing && !loadingMore }
    private let repository: any GalleryRepository
    private var query = GalleryQuery()
    private var revision = UUID()
    private var consumed: Set<String> = []
    private var firstTask: Task<PagedResult<GallerySummary>, any Error>?
    private var firstRequest: (scope: SessionScope, query: GalleryQuery)?
    private var moreTask: Task<PagedResult<GallerySummary>, any Error>?
    public init(repository: any GalleryRepository) { self.repository = repository }

    public func reset() {
        presentationRevision = UUID()
        revision = UUID(); firstTask?.cancel(); moreTask?.cancel(); firstTask = nil; moreTask = nil
        items = []; lastPageKeys = []; totalCount = nil; context = nil; next = nil; consumed = []; pagesLoaded = 0; duplicateCount = 0
        initialLoading = false; refreshing = false; loadingMore = false
        firstRequest = nil; initialError = nil; refreshError = nil; paginationError = nil; paginationNeedsRefresh = false
    }
    /// Stop work when leaving a source, preserving accepted rows/cursor for a later return.
    public func suspend() {
        revision = UUID(); firstTask?.cancel(); moreTask?.cancel(); firstTask = nil; moreTask = nil
        firstRequest = nil; initialLoading = false; refreshing = false; loadingMore = false
    }
    public func loadIfNeeded(scope: SessionScope, query: GalleryQuery = GalleryQuery()) async {
        guard context?.scope != scope || !hasLoaded else { return }
        guard firstTask == nil else { return }
        await refresh(scope: scope, query: query)
    }
    /// Library-source refreshes retain only accepted rows for the exact same scope/query.
    /// Search submissions keep their existing replacement behavior.
    public func refresh(scope: SessionScope, query: GalleryQuery = GalleryQuery(), preservingItems: Bool = false) async {
        guard !Task.isCancelled else { return }
        if preservingItems, firstTask != nil, firstRequest?.scope == scope, firstRequest?.query == query {
            return
        }
        let keepRows = preservingItems && context?.scope == scope && self.query == query
        let isRefresh = hasLoaded || refreshing
        if keepRows {
            // Invalidate pagination before awaiting. A failed refresh must never
            // resurrect a cursor from the old response or accept its late append.
            revision = UUID(); firstTask?.cancel(); moreTask?.cancel()
            firstTask = nil; firstRequest = nil; moreTask = nil
            next = nil; consumed = []; loadingMore = false; paginationNeedsRefresh = true
            initialError = nil; refreshError = nil; paginationError = nil
        } else {
            reset()
        }
        let ticket = UUID(); revision = ticket
        initialLoading = !isRefresh; refreshing = isRefresh
        let requested = RequestContext(scope: scope, queryID: UUID())
        let repository = self.repository
        let task = Task { try await repository.list(request: GalleryListRequest(query: query, context: requested)) }
        firstTask = task; firstRequest = (scope, query)
        defer { if revision == ticket { initialLoading = false; refreshing = false; firstTask = nil; firstRequest = nil } }
        do {
            let page = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation(); try page.validate(current: requested)
            guard revision == ticket else { return }
            try validateItems(page.items, scope: scope)
            self.query = query; context = requested; items = []; consumed = []; duplicateCount = 0
            refreshError = nil; paginationNeedsRefresh = false
            appendUnique(page.items); lastPageKeys = Set(page.items.map(\.reference.key)); next = page.next; pagesLoaded = 1
            totalCount = page.totalCount ?? (page.next == nil && page.previous == nil ? .exact(items.count) : nil)
        } catch is CancellationError {} catch AppError.cancelled {} catch {
            guard revision == ticket else { return }
            if keepRows { refreshError = error as? AppError ?? .parseMismatch }
            else { initialError = error as? AppError ?? .parseMismatch }
        }
    }
    public func loadMore() async {
        guard canLoadMore, let context, let cursor = next else { return }
        guard !consumed.contains(cursor.opaque.value) else { next = nil; paginationError = .parseMismatch; return }
        loadingMore = true; paginationError = nil
        let ticket = revision, repository = self.repository, query = self.query
        let task = Task { try await repository.list(request: GalleryListRequest(query: query, context: context, cursor: cursor)) }
        moreTask = task
        defer { if revision == ticket { loadingMore = false; moreTask = nil } }
        do {
            let page = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation(); try page.validate(current: context)
            guard revision == ticket, self.context == context else { return }
            try validateItems(page.items, scope: context.scope)
            consumed.insert(cursor.opaque.value); appendUnique(page.items); lastPageKeys = Set(page.items.map(\.reference.key)); pagesLoaded += 1
            if let following = page.next, consumed.contains(following.opaque.value) {
                next = nil; paginationError = .parseMismatch
            } else {
                next = page.next
                if let count = page.totalCount { totalCount = count }
                if next == nil && totalCount == nil { totalCount = .exact(items.count) }
            }
        } catch is CancellationError {} catch AppError.cancelled {} catch {
            if revision == ticket { paginationError = error as? AppError ?? .parseMismatch }
            // Failed cursors are not consumed; retry requests the same cursor.
        }
    }
    private func validateItems(_ values: [GallerySummary], scope: SessionScope) throws {
        for item in values { try item.reference.validate(scope: scope) }
    }
    private func appendUnique(_ values: [GallerySummary]) {
        var merged = items
        var duplicates = 0
        var indices = Dictionary(uniqueKeysWithValues: merged.enumerated().map { ($0.element.reference.key, $0.offset) })
        for item in values {
            if let index = indices[item.reference.key] {
                if merged[index] != item { merged[index] = item }
                duplicates += 1
            } else {
                indices[item.reference.key] = merged.count
                merged.append(item)
            }
        }
        items = merged
        duplicateCount += duplicates
    }
}
