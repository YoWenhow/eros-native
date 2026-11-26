import Foundation
import ErosCore
import ErosPersistence

public enum DownloadMetadataRefreshFailure: String, Sendable, Equatable {
    case unavailable, network, invalidResponse, storage, conflict, missing, authentication, quota, rateLimited
}
public enum DownloadMetadataRefreshStop: String, Sendable, Equatable {
    case cancelled, staleSession, authentication, quota, rateLimited
}
public enum DownloadMetadataBatchSize: Int, CaseIterable, Sendable {
    case fifty = 50
    case oneHundred = 100
    case twoHundred = 200
    case fiveHundred = 500
    case all = 0

    public var limit: Int? { self == .all ? nil : rawValue }
}

public struct DownloadMetadataRefreshPlan: Sendable {
    public let id: UUID
    public let selectedCount: Int
    public internal(set) var batchSize: DownloadMetadataBatchSize
    public var knownSkippedCount: Int { selectedCount - eligibleItems.count }
    public var deferredJobIDs: [UUID] { eligibleItems.dropFirst(total).map(\.jobID) }
    public var deferredCount: Int { eligibleItems.count - total }
    public var jobIDs: [UUID] { candidates.map(\.jobID) }
    public var total: Int { min(batchSize.limit ?? eligibleItems.count, eligibleItems.count) }
    public var unknownTitleCount: Int { candidates.count { $0.summary.sourceTitles == nil } }
    public var unknownTagCount: Int { candidates.count { $0.metadata.state == .unknown } }
    let scope: SessionScope
    let refreshKnown: Bool
    let eligibleItems: [DownloadLibraryItem]
    var candidates: ArraySlice<DownloadLibraryItem> { eligibleItems.prefix(total) }
}
/// Safe UI summary: identifiers and fixed codes only, no tags, URL, error description or credential.
public struct DownloadMetadataRefreshProgress: Sendable, Equatable {
    public let total: Int
    public internal(set) var succeeded = 0
    public internal(set) var failures: [UUID: DownloadMetadataRefreshFailure] = [:]
    public internal(set) var cancelled = 0
    public internal(set) var stop: DownloadMetadataRefreshStop?
    public var failed: Int { failures.count }
    public var remaining: Int { total - succeeded - failed - cancelled }
}

/// Explicit two-step API: prepare a preview, then run only after a user action.
/// No callers are wired from polling, sorting, folder operations or startup.
public actor DownloadMetadataRefreshService {
    private let database: SQLiteDatabase
    private let repository: any GalleryRepository
    private let sessions: any SessionProvider
    private let storageLease: StorageLease?
    private let now: @Sendable () -> DownloadLibraryTimestamp
    private var running = false
    private var activeTask: Task<DownloadMetadataRefreshProgress, Never>?
    public init(database: SQLiteDatabase, repository: any GalleryRepository, sessions: any SessionProvider,
                storageLease: StorageLease? = nil,
                now: @escaping @Sendable () -> DownloadLibraryTimestamp = { DownloadLibraryTimestamp(Int64(Date().timeIntervalSince1970 * 1000)) }) {
        self.database = database; self.repository = repository; self.sessions = sessions
        self.storageLease = storageLease; self.now = now
    }
    private func check(_ scope: SessionScope) async throws {
        try Task.checkCancellation()
        guard try await sessions.current().scope == scope else { throw AppError.staleSession }
        try Task.checkCancellation()
        try storageLease?.check()
    }
    /// Every requested ID must exist in this account, including IDs filtered as known or deferred.
    public func prepare(jobIDs: Set<UUID>, scope: SessionScope, refreshKnown: Bool = false,
                        batchSize: DownloadMetadataBatchSize = .fifty) async throws -> DownloadMetadataRefreshPlan {
        try await check(scope)
        let all = try await database.listItems(target: .all, account: scope.storage.accountID)
        let selected = all.filter { jobIDs.contains($0.jobID) }.sorted { $0.jobID.uuidString < $1.jobID.uuidString }
        guard selected.count == jobIDs.count else { throw DownloadLibraryError.jobNotFound }
        let eligibleItems = refreshKnown ? selected : selected.filter(\.hasUnknownInformation)
        try await check(scope)
        return DownloadMetadataRefreshPlan(id: UUID(), selectedCount: selected.count,
            batchSize: refreshKnown ? .fifty : batchSize, scope: scope, refreshKnown: refreshKnown, eligibleItems: eligibleItems)
    }
    public func cancel() { activeTask?.cancel() }
    /// At most one detail load per candidate. HTTPClient owns its existing bounded retry budget.
    public func run(_ plan: DownloadMetadataRefreshPlan,
                    onProgress: @escaping @Sendable (DownloadMetadataRefreshProgress) async -> Void = { _ in }) async throws -> DownloadMetadataRefreshProgress {
        guard !running else { throw DownloadLibraryError.conflict }
        running = true
        let task = Task { await perform(plan, onProgress: onProgress) }
        activeTask = task
        defer { running = false; activeTask = nil }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    private func perform(_ plan: DownloadMetadataRefreshPlan,
                         onProgress: @Sendable (DownloadMetadataRefreshProgress) async -> Void) async -> DownloadMetadataRefreshProgress {
        var progress = DownloadMetadataRefreshProgress(total: plan.total)
        await onProgress(progress)
        for item in plan.candidates {
            do {
                try await refresh(item, in: plan)
                progress.succeeded += 1
            } catch is CancellationError {
                progress.stop = .cancelled; progress.cancelled = progress.remaining
            } catch AppError.cancelled {
                progress.stop = .cancelled; progress.cancelled = progress.remaining
            } catch AppError.staleSession {
                progress.stop = .staleSession; progress.cancelled = progress.remaining
            } catch {
                if Task.isCancelled {
                    progress.stop = .cancelled; progress.cancelled = progress.remaining
                } else {
                    let failure = Self.classify(error)
                    progress.failures[item.jobID] = failure
                    switch failure {
                    case .authentication: progress.stop = .authentication
                    case .quota: progress.stop = .quota
                    case .rateLimited: progress.stop = .rateLimited
                    default: break
                    }
                }
            }
            await onProgress(progress)
            if progress.stop != nil { break }
        }
        return progress
    }
    private func refresh(_ item: DownloadLibraryItem, in plan: DownloadMetadataRefreshPlan) async throws {
        let scope = plan.scope
        let account = scope.storage.accountID
        try await check(scope)
        guard let current = try await database.downloadLibraryItem(jobID: item.jobID, account: account) else {
            throw DownloadLibraryError.jobNotFound
        }
        let savedReference = item.summary.reference
        guard current.metadataRevision == item.metadataRevision, current.summary.reference == savedReference else {
            throw DownloadLibraryError.conflict
        }
        try await check(scope)
        let fetchTags = plan.refreshKnown || current.metadata.state == .unknown
        let fillTitles = !plan.refreshKnown && current.summary.sourceTitles == nil
        guard fetchTags || fillTitles else { return }

        // Match the existing detail lookup on the active site, then store titles under the job's own reference.
        let reference = GalleryReference(
            key: GalleryKey(site: scope.storage.site, galleryID: savedReference.key.galleryID), token: savedReference.token)
        let detail = try await repository.detail(request: GalleryRequest(reference: reference, scope: scope))
        try await check(scope)
        guard detail.summary.reference == reference else { throw AppError.parseMismatch }

        let metadata = fetchTags ? try DownloadLibraryMetadata.from(detail: detail, fetchedAt: now()) : nil
        var titleUpdate: (reference: GalleryReference, titles: GallerySourceTitles)?
        if fillTitles {
            guard let titles = detail.sourceTitles ?? detail.summary.sourceTitles,
                  titles.gn != nil || titles.gj != nil else { throw AppError.parseMismatch }
            titleUpdate = (savedReference, titles)
        }
        try storageLease?.admit()
        defer { storageLease?.finish() }
        try await database.updateMetadata(jobID: item.jobID, metadata: metadata, titleUpdate: titleUpdate,
            expectedMetadataRevision: item.metadataRevision, account: account)
    }

    private static func classify(_ error: any Error) -> DownloadMetadataRefreshFailure {
        switch error {
        case AppError.authenticationRequired, AppError.httpStatus(401): .authentication
        case AppError.quotaExceeded: .quota
        case AppError.rateLimited, AppError.httpStatus(429): .rateLimited
        case AppError.transport: .network
        case AppError.notFound, AppError.accessDenied, AppError.httpStatus(403), AppError.httpStatus(404), AppError.httpStatus(410): .unavailable
        case DownloadLibraryError.conflict: .conflict
        case DownloadLibraryError.jobNotFound: .missing
        case is PersistenceError, AppError.storageFull: .storage
        default: .invalidResponse
        }
    }
}