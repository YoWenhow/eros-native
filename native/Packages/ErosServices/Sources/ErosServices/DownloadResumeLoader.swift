import Foundation
import ErosCore
import ErosPersistence

public struct DownloadResumeState: Sendable {
    public let download: DownloadSnapshot
    public let index: PageIndex
    public let progress: ReadingProgress?
}

public struct DownloadResumeLoader: Sendable {
    private let coordinator: DownloadCoordinator
    private let database: SQLiteDatabase
    private let sessions: any SessionProvider
    public init(coordinator: DownloadCoordinator, database: SQLiteDatabase, sessions: any SessionProvider) {
        self.coordinator = coordinator; self.database = database; self.sessions = sessions
    }
    public func load(id: UUID, scope: SessionScope) async throws -> DownloadResumeState {
        try await SessionGuard(provider: sessions).check(scope)
        let download = try await coordinator.localSnapshot(id: id, scope: scope)
        guard download.job.totalPages.value > 0 else { throw AppError.notFound }
        var candidates: [ReadingProgress] = []
        for site in [Site.eh, .ex] {
            if let progress = try await database.progress(galleryID: download.job.reference.key.galleryID, scope: StorageScope(accountID: scope.storage.accountID, site: site)) { candidates.append(progress) }
        }
        let saved = candidates.max { $0.updatedAt < $1.updatedAt }
        let index = try PageIndex(min(saved?.index.value ?? 0, download.job.totalPages.value - 1))
        let progress = try saved.map { ReadingProgress(scope: scope.storage, galleryID: $0.galleryID, index: index,
            fraction: $0.index == index ? $0.fraction : try UnitFraction(0), readingMode: $0.readingMode, updatedAt: $0.updatedAt) }
        try await SessionGuard(provider: sessions).check(scope)
        return DownloadResumeState(download: download, index: index, progress: progress)
    }
}
