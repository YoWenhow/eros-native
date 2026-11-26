import Foundation
import Observation
import ErosCore
import ErosPersistence

public struct HistoryEntry: Identifiable, Sendable {
    public var id: GalleryID { progress.galleryID }
    public let summary: GallerySummary
    public let progress: ReadingProgress
    public var displayTitle: String {
        summary.displayTitle(preferred: .japanese)
    }
}

@MainActor @Observable public final class HistoryViewModel {
    public private(set) var items: [HistoryEntry] = []
    public private(set) var loading = false
    public private(set) var changing = false
    public private(set) var error: AppError?
    public let scope: SessionScope
    private let database: SQLiteDatabase
    private let sessions: SessionGuard
    private var revision = UUID()
    public private(set) var metadataPass = UUID()
    public private(set) var metadataFailures: Set<GalleryID> = []
    private let repository: (any GalleryRepository)?
    private var metadataActive = false
    private var metadataQueue: [GalleryID] = []
    private var attempted: Set<GalleryID> = []
    private var metadataTask: Task<Void, Never>?

    public init(database: SQLiteDatabase, sessions: any SessionProvider, scope: SessionScope, repository: (any GalleryRepository)? = nil) {
        self.repository = repository
        self.database = database; self.sessions = SessionGuard(provider: sessions); self.scope = scope
    }
    public func load() async {
        stopMetadata(); metadataActive = true; attempted = []; metadataFailures = []
        let ticket = UUID(); revision = ticket; loading = true; error = nil
        defer { if revision == ticket { loading = false; metadataPass = UUID() } }
        do {
            try await sessions.check(scope)
            let records = try await database.accountProgressList(account: scope.storage.accountID)
            var result: [HistoryEntry] = []
            for progress in records {
                try Task.checkCancellation()
                guard let summary = try await database.gallery(galleryID: progress.galleryID, scope: progress.scope),
                      let count = summary.pageCount, progress.index.value < count.value else { throw AppError.parseMismatch }
                result.append(HistoryEntry(summary: try summary.onSite(scope.storage.site), progress: progress))
            }
            try await sessions.check(scope)
            if ticket == revision { items = result }
        } catch is CancellationError {} catch {
            if ticket == revision {
                self.error = error as? AppError ?? .unsupportedContent
                if self.error == .staleSession { items = [] }
            }
        }
    }
    /// Only visible rows missing tags or source titles are queued, one at a time; progress is unchanged.
    public func requestMetadata(_ id: GalleryID) {
        guard metadataActive, repository != nil, !loading, !changing, !attempted.contains(id),
              let entry = items.first(where: { $0.id == id }), entry.progress.scope == scope.storage,
              entry.summary.listTags == nil || entry.summary.sourceTitles == nil else { return }
        attempted.insert(id); metadataQueue.append(id)
        guard metadataTask == nil else { return }
        let pass = metadataPass
        metadataTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.metadataPass == pass { self.metadataTask = nil } }
            while !Task.isCancelled, self.metadataPass == pass, !self.metadataQueue.isEmpty {
                let id = self.metadataQueue.removeFirst()
                await self.enrich(id, pass: pass)
            }
        }
    }
    public func cancelQueuedMetadata(_ id: GalleryID) {
        if metadataQueue.contains(id) { metadataQueue.removeAll { $0 == id }; attempted.remove(id) }
    }
    public func stopMetadata() {
        metadataActive = false; metadataPass = UUID(); metadataTask?.cancel(); metadataTask = nil; metadataQueue = []
    }
    private func enrich(_ id: GalleryID, pass: UUID) async {
        guard let repository, let entry = items.first(where: { $0.id == id }) else { return }
        do {
            try await sessions.check(scope)
            let detail = try await repository.detail(request: GalleryRequest(reference: entry.summary.reference, scope: scope))
            try await sessions.check(scope)
            guard pass == metadataPass, let current = items.first(where: { $0.id == id }),
                  detail.summary.reference.key == current.summary.reference.key else { return }
            let old = current.summary, fresh = detail.summary
            // Preserve the historical count: old edition progress must remain valid.
            let summary = try GallerySummary(reference: old.reference, title: fresh.title, coverURL: fresh.coverURL ?? old.coverURL,
                category: fresh.category ?? old.category, uploader: fresh.uploader ?? old.uploader, pageCount: old.pageCount,
                rating: fresh.rating ?? old.rating, listTags: detail.tags, postedAt: fresh.postedAt ?? old.postedAt,
                sourceTitles: detail.sourceTitles ?? fresh.sourceTitles ?? old.sourceTitles)
            try await database.saveGallery(summary, scope: scope.storage)
            try await sessions.check(scope)
            guard pass == metadataPass, let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index] = HistoryEntry(summary: summary, progress: items[index].progress)
        } catch is CancellationError {} catch {
            if pass == metadataPass && !Task.isCancelled {
                metadataFailures.insert(id)
                switch error as? AppError {
                case .transport, .rateLimited, .quotaExceeded, .authenticationRequired, .staleSession:
                    metadataQueue = []; metadataActive = false
                default: break
                }
            }
        }
    }
    public func remove(_ id: GalleryID) async {
        await mutate(id: id)
    }
    /// UI must obtain explicit confirmation before invoking the scoped clear.
    public func clear() async { await mutate(id: nil) }
    private func mutate(id: GalleryID?) async {
        guard !changing else { return }; stopMetadata(); changing = true; error = nil
        defer { changing = false }
        do {
            try await sessions.check(scope)
            if let id { try await database.removeAccountProgress(galleryID: id, account: scope.storage.accountID) }
            else { try await database.clearAccountProgress(account: scope.storage.accountID) }
            try await sessions.check(scope)
            await load()
        } catch {
            self.error = error as? AppError ?? .unsupportedContent
            if self.error == .staleSession { items = [] }
        }
    }
}
