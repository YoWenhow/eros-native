import Foundation

// Cancellation propagates as CancellationError or AppError.cancelled; adapters must not swallow it.
public protocol GalleryRepository: Sendable {
    func list(request: GalleryListRequest) async throws -> PagedResult<GallerySummary>
    func detail(request: GalleryRequest) async throws -> GalleryDetail
    func readerPages(request: ReaderPagesRequest) async throws -> PagedResult<ReaderPage>
    func thumbnails(request: ReaderPagesRequest) async throws -> PagedResult<GalleryThumbnail>
}

extension GalleryRepository {
    public func thumbnails(request: ReaderPagesRequest) async throws -> PagedResult<GalleryThumbnail> { throw AppError.unsupportedContent }
}

public protocol ImagePageResolver: Sendable {
    func resolve(request: ImageResolutionRequest) async throws -> ResolvedImage
}

public protocol FavoritesRepository: Sendable {
    func groups(scope: SessionScope) async throws -> [FavoriteGroup]
    func list(request: FavoritesListRequest) async throws -> PagedResult<GallerySummary>
    func mutate(request: FavoriteMutation) async throws -> Void
}

public protocol HistoryStore: Sendable {
    func save(progress: ReadingProgress) async throws -> Void
    func load(galleryID: GalleryID, scope: StorageScope) async throws -> ReadingProgress?
    func list(scope: StorageScope) async throws -> [ReadingProgress]
    func remove(galleryID: GalleryID, scope: StorageScope) async throws -> Void
}

public protocol LocalFavoritesStore: Sendable {
    func save(favorite: LocalFavorite) async throws -> Void
    func list(scope: StorageScope) async throws -> [LocalFavorite]
    func remove(galleryID: GalleryID, scope: StorageScope) async throws -> Void
}

public protocol DownloadStore: Sendable {
    func save(snapshot: DownloadSnapshot) async throws -> Void
    func load(jobID: UUID, scope: StorageScope) async throws -> DownloadSnapshot?
    func recoverable(scope: StorageScope) async throws -> [DownloadSnapshot]
    func remove(jobID: UUID, scope: StorageScope) async throws -> Void
}

public protocol HTTPTransport: Sendable {
    func send(request: HTTPRequest) async throws -> HTTPResponse
}

public protocol SessionProvider: Sendable {
    func current() async throws -> SessionState
}

public protocol DiagnosticSink: Sendable {
    func record(event: DiagnosticEvent) async -> Void
}

public protocol Clock: Sendable {
    func now() async -> Date
    func sleep(seconds: TimeInterval) async throws -> Void
}
