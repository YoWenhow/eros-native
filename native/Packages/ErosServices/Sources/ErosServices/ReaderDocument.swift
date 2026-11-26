import Foundation
import ErosCore

/// A lazy page catalogue. Only follows actual, scoped pagination links; never
/// guesses gallery page sizes or constructs image-page keys from an index.
public actor ReaderDocument {
    public nonisolated let reference: GalleryReference
    public nonisolated let scope: SessionScope
    private let repository: any GalleryRepository
    private let context: RequestContext
    private let authorizeNetwork: (@Sendable () async throws -> Void)?
    private var summary: GallerySummary?
    private var preparation: (id: UUID, task: Task<GallerySummary, any Error>)?
    private var pages: [PageIndex: ReaderPage] = [:]
    private var next: PageCursor?
    private var started = false
    private var consumed: [PageCursor] = []
    private var batch: Task<PagedResult<ReaderPage>, any Error>?
    private var batchID: UUID?
    private var selectedLocalFiles: Task<LocalReaderSelection, any Error>?
    private var localSelectionID: UUID?
    public init(reference: GalleryReference, scope: SessionScope, repository: any GalleryRepository,
                authorizeNetwork: (@Sendable () async throws -> Void)? = nil) {
        self.reference = reference; self.scope = scope; self.repository = repository
        self.authorizeNetwork = authorizeNetwork
        context = RequestContext(scope: scope, queryID: UUID())
    }
    func localSelection(using files: any LocalReaderFiles) async throws -> LocalReaderSelection {
        let task: Task<LocalReaderSelection, any Error>
        let id: UUID
        if let selectedLocalFiles, let localSelectionID {
            task = selectedLocalFiles
            id = localSelectionID
        } else {
            id = UUID()
            task = Task { try await files.selection(reference: reference, scope: scope.storage) }
            localSelectionID = id
            selectedLocalFiles = task
        }
        do { return try await task.value }
        catch {
            if localSelectionID == id { selectedLocalFiles = nil; localSelectionID = nil }
            throw error
        }
    }
    public func prepare() async throws -> GallerySummary {
        if let summary { return summary }
        let flight: (id: UUID, task: Task<GallerySummary, any Error>)
        if let preparation {
            flight = preparation
        } else {
            let task = Task {
                try await authorizeNetwork?()
                let detail = try await repository.detail(request: GalleryRequest(reference: reference, scope: scope))
                guard let count = detail.summary.pageCount, count.value > 0 else { throw AppError.parseMismatch }
                try Task.checkCancellation()
                return detail.summary
            }
            flight = (UUID(), task)
            preparation = flight
        }
        defer { if preparation?.id == flight.id { preparation = nil } }
        let value: GallerySummary
        if authorizeNetwork != nil {
            value = try await withTaskCancellationHandler { try await flight.task.value } onCancel: { flight.task.cancel() }
        } else {
            value = try await flight.task.value
        }
        try Task.checkCancellation()
        summary = value
        return value
    }
    public func seed(_ cached: GallerySummary?) {
        if summary == nil, let cached, cached.reference == reference, (cached.pageCount?.value ?? 0) > 0 { summary = cached }
    }
    public func page(at index: PageIndex) async throws -> ReaderPage {
        let summary = try await prepare()
        guard index.value < summary.pageCount!.value else { throw AppError.invalidInput }
        while pages[index] == nil {
            try Task.checkCancellation()
            guard !started || next != nil else { throw AppError.notFound }
            let cursor = next
            let task: Task<PagedResult<ReaderPage>, any Error>
            let ticket: UUID
            if let batch, let batchID { task = batch; ticket = batchID } else {
                let request = try ReaderPagesRequest(reference: reference, context: context, cursor: cursor)
                ticket = UUID(); batchID = ticket
                task = Task {
                    try await authorizeNetwork?()
                    return try await repository.readerPages(request: request)
                }
                batch = task
            }
            let result: PagedResult<ReaderPage>
            // Metadata is shared by different page requests. Cancelling one page
            // must not cancel the catalogue fetch needed by its replacement.
            do {
                if authorizeNetwork != nil {
                    // Download documents belong to one worker. Their requests
                    // can be cancelled as a unit when its execution is revoked.
                    result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                } else {
                    result = try await task.value
                }
            }
            catch { if batchID == ticket { batch = nil; batchID = nil }; throw error }
            // Another waiter may already have merged this same batch.
            if batchID == ticket {
                guard result.context == context, !result.items.isEmpty,
                      result.items.allSatisfy({ $0.reference == reference && $0.index.value < summary.pageCount!.value }),
                      result.next != cursor || result.next == nil,
                      result.next.map({ !consumed.contains($0) }) ?? true else {
                    batch = nil; batchID = nil
                    await AppLog.shared.record(.readerParseFailure, request: context.queryID, fields: [
                        .phase: .label("readerCatalogue"), .failureKind: .label("batchIdentityOrPagination"),
                        .pageIndex: .integer(index.value), .observedCount: .integer(result.items.count)
                    ])
                    throw AppError.parseMismatch
                }
                for page in result.items { pages[page.index] = page }
                if let cursor { consumed.append(cursor) }
                started = true; next = result.next
                batch = nil; batchID = nil
            }
            try Task.checkCancellation()
        }
        return pages[index]!
    }
}
