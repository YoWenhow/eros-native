import Foundation
import Observation
import ErosCore

@MainActor @Observable public final class GalleryDetailViewModel {
    public private(set) var detail: GalleryDetail?
    public private(set) var downloadMetadata: DownloadLibraryMetadata?
    public private(set) var metadataSaveFailed = false
    public private(set) var thumbnails: [GalleryThumbnail] = []
    public private(set) var loading = false
    public private(set) var loadingMore = false
    public private(set) var error: AppError?
    public private(set) var thumbnailError: AppError?
    public private(set) var next: PageCursor?
    public private(set) var context: RequestContext?
    public private(set) var detailSite: Site?
    private let repository: any GalleryRepository
    private let router: GalleryDetailRouter?
    private var previewSource: GalleryDetailReadSource?
    private let downloadLibrary: DownloadDetailMetadataService?
    private let now: @Sendable () -> DownloadLibraryTimestamp
    private var revision = UUID()
    private var consumed: Set<String> = []
    private var work: Task<Void, Never>?
    public init(repository: any GalleryRepository, downloadLibrary: DownloadDetailMetadataService? = nil,
                router: GalleryDetailRouter? = nil,
                now: @escaping @Sendable () -> DownloadLibraryTimestamp = { DownloadLibraryTimestamp(Int64(Date().timeIntervalSince1970 * 1000)) }) {
        self.repository = repository; self.downloadLibrary = downloadLibrary; self.router = router; self.now = now
    }
    public func reset() {
        revision = UUID(); work?.cancel(); work = nil; detail = nil; thumbnails = []; next = nil
        downloadMetadata = nil; metadataSaveFailed = false
        context = nil; detailSite = nil; previewSource = nil
        error = nil; thumbnailError = nil; loading = false; loadingMore = false; consumed = []
    }
    public func load(reference: GalleryReference, scope: SessionScope) async {
        await load(reference: reference, scope: scope, keepingSnapshot: false)
    }

    public func refresh(reference: GalleryReference, scope: SessionScope) async {
        let sameGallery = detail?.summary.reference == reference && context?.scope == scope
        await load(reference: reference, scope: scope, keepingSnapshot: sameGallery)
    }

    private func load(reference: GalleryReference, scope: SessionScope, keepingSnapshot: Bool) async {
        guard !Task.isCancelled else { return }
        if keepingSnapshot {
            revision = UUID()
            work?.cancel()
            loadingMore = false
            error = nil
        } else {
            reset()
        }
        loading = true
        let ticket = revision
        let requested = RequestContext(scope: scope, queryID: UUID())
        if !keepingSnapshot { context = requested }
        let task = Task { [self] in
            defer { if revision == ticket { loading = false; work = nil } }
            do {
                var metadataTicket: DownloadDetailMetadataTicket?
                var captureFailed = false
                if let downloadLibrary {
                    do { metadataTicket = try await downloadLibrary.capture(reference: reference, scope: scope) }
                    catch is CancellationError { throw CancellationError() }
                    catch AppError.staleSession { throw AppError.staleSession }
                    catch { captureFailed = true }
                }
                try Task.checkCancellation()
                guard revision == ticket else { return }
                let request = try GalleryRequest(reference: reference, scope: scope)
                let source = GalleryDetailReadSource(request: request, repository: repository)
                let read: RoutedGalleryDetail
                if let router {
                    read = try await router.load(source)
                } else {
                    read = RoutedGalleryDetail(detail: try await repository.detail(request: request), source: source)
                }
                let value = read.detail
                try Task.checkCancellation()
                guard revision == ticket else { return }
                guard value.summary.reference == reference else { throw AppError.parseMismatch }
                let metadata = try DownloadLibraryMetadata.from(detail: value, fetchedAt: now())
                let replacement: PagedResult<GalleryThumbnail>? = if keepingSnapshot {
                    try await readThumbnails(source: read.source, queryID: requested.queryID,
                        pageCount: value.summary.pageCount, cursor: nil)
                } else {
                    nil
                }
                if let downloadLibrary { try await downloadLibrary.check(scope: scope) }
                try Task.checkCancellation()
                guard revision == ticket else { return }

                // A pull keeps the visible detail and its cursor until the new first page is ready.
                detail = value
                context = requested
                downloadMetadata = metadata
                metadataSaveFailed = captureFailed
                previewSource = read.source
                detailSite = read.source.request.scope.storage.site
                if let replacement {
                    consumed = []
                    applyThumbnails(replacement, cursor: nil)
                }

                if let downloadLibrary, let metadataTicket, detailSite == scope.storage.site {
                    do { try await downloadLibrary.apply(metadata, reference: reference, ticket: metadataTicket) }
                    catch is CancellationError { return }
                    catch { if revision == ticket { metadataSaveFailed = true } }
                }
                if !keepingSnapshot, revision == ticket, !Task.isCancelled {
                    await fetch(source: read.source, queryID: requested.queryID, cursor: nil, ticket: ticket)
                }
            } catch is CancellationError {} catch AppError.cancelled {} catch {
                if revision == ticket, !Task.isCancelled { self.error = error as? AppError ?? .parseMismatch }
            }
        }
        work = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    public func loadMore() async {
        guard !loading, !loadingMore, let source = previewSource, let context else { return }
        // A failed first thumbnail request may be retried independently of the detail.
        guard next != nil || (thumbnails.isEmpty && thumbnailError != nil) else { return }
        loadingMore = true; let ticket = revision, cursor = next
        let task = Task { [self] in
            defer { if revision == ticket { loadingMore = false; work = nil } }
            await fetch(source: source, queryID: context.queryID, cursor: cursor, ticket: ticket)
        }
        work = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    private func fetch(source: GalleryDetailReadSource, queryID: UUID, cursor: PageCursor?, ticket: UUID) async {
        thumbnailError = nil
        do {
            if let cursor, consumed.contains(cursor.opaque.value) { throw AppError.parseMismatch }
            let result = try await readThumbnails(source: source, queryID: queryID,
                pageCount: detail?.summary.pageCount, cursor: cursor)
            guard revision == ticket else { return }
            applyThumbnails(result, cursor: cursor)
        } catch is CancellationError {} catch AppError.cancelled {} catch {
            if revision == ticket, !Task.isCancelled { thumbnailError = error as? AppError ?? .parseMismatch }
        }
    }

    private func readThumbnails(source: GalleryDetailReadSource, queryID: UUID,
                                pageCount: NonnegativeCount?, cursor: PageCursor?) async throws -> PagedResult<GalleryThumbnail> {
        let reference = source.request.reference
        let requested = RequestContext(scope: source.request.scope, queryID: queryID)
        let request = try ReaderPagesRequest(reference: reference, context: requested, cursor: cursor)
        let result = try await source.repository.thumbnails(request: request)
        try Task.checkCancellation()
        try result.validate(current: requested)
        guard result.items.allSatisfy({ item in
            item.page.reference == reference && (pageCount.map { item.page.index.value < $0.value } ?? true)
        }) else { throw AppError.parseMismatch }
        return result
    }

    private func applyThumbnails(_ result: PagedResult<GalleryThumbnail>, cursor: PageCursor?) {
        var merged = cursor == nil ? [:] : Dictionary(uniqueKeysWithValues: thumbnails.map { ($0.page.index.value, $0) })
        for item in result.items { merged[item.page.index.value] = item }
        thumbnails = merged.values.sorted { $0.page.index.value < $1.page.index.value }
        if let cursor { consumed.insert(cursor.opaque.value) }
        if let following = result.next, consumed.contains(following.opaque.value) {
            next = nil
            thumbnailError = .parseMismatch
        } else {
            next = result.next
            thumbnailError = nil
        }
    }
    public func acceptInteractionReadback(_ value: GalleryDetail,scope: SessionScope,metadataSaveFailed: Bool) {
        guard context?.scope==scope,detail?.summary.reference==value.summary.reference else { return }
        detail=value;downloadMetadata=try? DownloadLibraryMetadata.from(detail:value,fetchedAt:now())
        self.metadataSaveFailed=metadataSaveFailed
    }
    public func readerPage(index: PageIndex) throws -> ReaderPage {
        guard let page = thumbnails.first(where: { $0.page.index == index })?.page else { throw AppError.notFound }
        return page
    }
}
