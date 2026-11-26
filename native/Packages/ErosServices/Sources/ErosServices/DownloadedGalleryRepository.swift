import Foundation
import ErosCore
import ErosPersistence

/// Supplies only saved metadata. There is deliberately no remote dependency.
public struct DownloadedGalleryRepository: GalleryRepository {
    public let coordinator: DownloadCoordinator
    public let database: SQLiteDatabase
    public let id: UUID
    public init(coordinator: DownloadCoordinator, database: SQLiteDatabase, id: UUID) {
        self.coordinator = coordinator; self.database = database; self.id = id
    }
    public func detail(request: GalleryRequest) async throws -> GalleryDetail {
        let snapshot = try await coordinator.localSnapshot(id: id, scope: request.scope)
        guard snapshot.job.reference.key.galleryID == request.reference.key.galleryID else { throw AppError.scopeMismatch }
        let saved = try await database.gallery(galleryID: request.reference.key.galleryID, scope: snapshot.job.scope)
        return try GalleryDetail(summary: GallerySummary(reference: request.reference, title: saved?.title ?? "已下载画廊",
            coverURL: saved?.coverURL, category: saved?.category, uploader: saved?.uploader, pageCount: snapshot.job.totalPages,
            rating: saved?.rating, listTags: saved?.listTags, postedAt: saved?.postedAt, sourceTitles: saved?.sourceTitles),
            tags: saved?.listTags ?? [], sourceTitles: saved?.sourceTitles)
    }
    public func list(request: GalleryListRequest) async throws -> PagedResult<GallerySummary> { throw AppError.notFound }
    public func readerPages(request: ReaderPagesRequest) async throws -> PagedResult<ReaderPage> { throw AppError.notFound }
    public func thumbnails(request: ReaderPagesRequest) async throws -> PagedResult<GalleryThumbnail> { throw AppError.notFound }
}
public struct OfflineImageResolver: ImagePageResolver {
    public init() {}
    public func resolve(request: ImageResolutionRequest) async throws -> ResolvedImage { throw AppError.notFound }
}
