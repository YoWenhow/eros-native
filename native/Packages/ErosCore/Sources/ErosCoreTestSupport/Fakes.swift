import Foundation
import ErosCore

// Explicit injected behavior: unconfigured operations cannot silently return a successful empty result.
// This target is never a dependency of the application.
public struct FakeGalleryRepository: GalleryRepository {
    public let listHandler: @Sendable (GalleryListRequest) async throws -> PagedResult<GallerySummary>
    public let detailHandler: @Sendable (GalleryRequest) async throws -> GalleryDetail
    public let readerPagesHandler: @Sendable (ReaderPagesRequest) async throws -> PagedResult<ReaderPage>
    public init(list: @escaping @Sendable (GalleryListRequest) async throws -> PagedResult<GallerySummary>, detail: @escaping @Sendable (GalleryRequest) async throws -> GalleryDetail, readerPages: @escaping @Sendable (ReaderPagesRequest) async throws -> PagedResult<ReaderPage>) {
        self.listHandler = list
        self.detailHandler = detail
        self.readerPagesHandler = readerPages
    }
    public func list(request: GalleryListRequest) async throws -> PagedResult<GallerySummary> {
        try Task.checkCancellation()
        return try await listHandler(request)
    }
    public func detail(request: GalleryRequest) async throws -> GalleryDetail {
        try Task.checkCancellation()
        return try await detailHandler(request)
    }
    public func readerPages(request: ReaderPagesRequest) async throws -> PagedResult<ReaderPage> {
        try Task.checkCancellation()
        return try await readerPagesHandler(request)
    }
}

public struct FakeImagePageResolver: ImagePageResolver {
    public let resolveHandler: @Sendable (ImageResolutionRequest) async throws -> ResolvedImage
    public init(resolve: @escaping @Sendable (ImageResolutionRequest) async throws -> ResolvedImage) {
        self.resolveHandler = resolve
    }
    public func resolve(request: ImageResolutionRequest) async throws -> ResolvedImage {
        try Task.checkCancellation()
        return try await resolveHandler(request)
    }
}

public struct FakeFavoritesRepository: FavoritesRepository {
    public let groupsHandler: @Sendable (SessionScope) async throws -> [FavoriteGroup]
    public let listHandler: @Sendable (FavoritesListRequest) async throws -> PagedResult<GallerySummary>
    public let mutateHandler: @Sendable (FavoriteMutation) async throws -> Void
    public init(groups: @escaping @Sendable (SessionScope) async throws -> [FavoriteGroup], list: @escaping @Sendable (FavoritesListRequest) async throws -> PagedResult<GallerySummary>, mutate: @escaping @Sendable (FavoriteMutation) async throws -> Void) {
        self.groupsHandler = groups
        self.listHandler = list
        self.mutateHandler = mutate
    }
    public func groups(scope: SessionScope) async throws -> [FavoriteGroup] {
        try Task.checkCancellation()
        return try await groupsHandler(scope)
    }
    public func list(request: FavoritesListRequest) async throws -> PagedResult<GallerySummary> {
        try Task.checkCancellation()
        return try await listHandler(request)
    }
    public func mutate(request: FavoriteMutation) async throws -> Void {
        try Task.checkCancellation()
        return try await mutateHandler(request)
    }
}

public struct FakeHistoryStore: HistoryStore {
    public let saveHandler: @Sendable (ReadingProgress) async throws -> Void
    public let loadHandler: @Sendable (GalleryID, StorageScope) async throws -> ReadingProgress?
    public let listHandler: @Sendable (StorageScope) async throws -> [ReadingProgress]
    public let removeHandler: @Sendable (GalleryID, StorageScope) async throws -> Void
    public init(save: @escaping @Sendable (ReadingProgress) async throws -> Void, load: @escaping @Sendable (GalleryID, StorageScope) async throws -> ReadingProgress?, list: @escaping @Sendable (StorageScope) async throws -> [ReadingProgress], remove: @escaping @Sendable (GalleryID, StorageScope) async throws -> Void) {
        self.saveHandler = save
        self.loadHandler = load
        self.listHandler = list
        self.removeHandler = remove
    }
    public func save(progress: ReadingProgress) async throws -> Void {
        try Task.checkCancellation()
        return try await saveHandler(progress)
    }
    public func load(galleryID: GalleryID, scope: StorageScope) async throws -> ReadingProgress? {
        try Task.checkCancellation()
        return try await loadHandler(galleryID, scope)
    }
    public func list(scope: StorageScope) async throws -> [ReadingProgress] {
        try Task.checkCancellation()
        return try await listHandler(scope)
    }
    public func remove(galleryID: GalleryID, scope: StorageScope) async throws -> Void {
        try Task.checkCancellation()
        return try await removeHandler(galleryID, scope)
    }
}

public struct FakeLocalFavoritesStore: LocalFavoritesStore {
    public let saveHandler: @Sendable (LocalFavorite) async throws -> Void
    public let listHandler: @Sendable (StorageScope) async throws -> [LocalFavorite]
    public let removeHandler: @Sendable (GalleryID, StorageScope) async throws -> Void
    public init(save: @escaping @Sendable (LocalFavorite) async throws -> Void, list: @escaping @Sendable (StorageScope) async throws -> [LocalFavorite], remove: @escaping @Sendable (GalleryID, StorageScope) async throws -> Void) {
        self.saveHandler = save
        self.listHandler = list
        self.removeHandler = remove
    }
    public func save(favorite: LocalFavorite) async throws -> Void {
        try Task.checkCancellation()
        return try await saveHandler(favorite)
    }
    public func list(scope: StorageScope) async throws -> [LocalFavorite] {
        try Task.checkCancellation()
        return try await listHandler(scope)
    }
    public func remove(galleryID: GalleryID, scope: StorageScope) async throws -> Void {
        try Task.checkCancellation()
        return try await removeHandler(galleryID, scope)
    }
}

public struct FakeDownloadStore: DownloadStore {
    public let saveHandler: @Sendable (DownloadSnapshot) async throws -> Void
    public let loadHandler: @Sendable (UUID, StorageScope) async throws -> DownloadSnapshot?
    public let recoverableHandler: @Sendable (StorageScope) async throws -> [DownloadSnapshot]
    public let removeHandler: @Sendable (UUID, StorageScope) async throws -> Void
    public init(save: @escaping @Sendable (DownloadSnapshot) async throws -> Void, load: @escaping @Sendable (UUID, StorageScope) async throws -> DownloadSnapshot?, recoverable: @escaping @Sendable (StorageScope) async throws -> [DownloadSnapshot], remove: @escaping @Sendable (UUID, StorageScope) async throws -> Void) {
        self.saveHandler = save
        self.loadHandler = load
        self.recoverableHandler = recoverable
        self.removeHandler = remove
    }
    public func save(snapshot: DownloadSnapshot) async throws -> Void {
        try Task.checkCancellation()
        return try await saveHandler(snapshot)
    }
    public func load(jobID: UUID, scope: StorageScope) async throws -> DownloadSnapshot? {
        try Task.checkCancellation()
        return try await loadHandler(jobID, scope)
    }
    public func recoverable(scope: StorageScope) async throws -> [DownloadSnapshot] {
        try Task.checkCancellation()
        return try await recoverableHandler(scope)
    }
    public func remove(jobID: UUID, scope: StorageScope) async throws -> Void {
        try Task.checkCancellation()
        return try await removeHandler(jobID, scope)
    }
}

public struct FakeHTTPTransport: HTTPTransport {
    public let sendHandler: @Sendable (HTTPRequest) async throws -> HTTPResponse
    public init(send: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
        self.sendHandler = send
    }
    public func send(request: HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        return try await sendHandler(request)
    }
}

public struct FakeSessionProvider: SessionProvider {
    public let currentHandler: @Sendable () async throws -> SessionState
    public init(current: @escaping @Sendable () async throws -> SessionState) {
        self.currentHandler = current
    }
    public func current() async throws -> SessionState {
        try Task.checkCancellation()
        return try await currentHandler()
    }
}

public struct FakeDiagnosticSink: DiagnosticSink {
    public let recordHandler: @Sendable (DiagnosticEvent) async -> Void
    public init(record: @escaping @Sendable (DiagnosticEvent) async -> Void) {
        self.recordHandler = record
    }
    public func record(event: DiagnosticEvent) async -> Void {
        return await recordHandler(event)
    }
}

public struct FakeClock: Clock {
    public let nowHandler: @Sendable () async -> Date
    public let sleepHandler: @Sendable (TimeInterval) async throws -> Void
    public init(now: @escaping @Sendable () async -> Date, sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.nowHandler = now
        self.sleepHandler = sleep
    }
    public func now() async -> Date {
        return await nowHandler()
    }
    public func sleep(seconds: TimeInterval) async throws -> Void {
        try Task.checkCancellation()
        return try await sleepHandler(seconds)
    }
}


public actor MemoryHistoryStore: HistoryStore {
    private var values: [StorageScope: [GalleryID: ReadingProgress]] = [:]
    public init() {}
    public func save(progress: ReadingProgress) async throws {
        try Task.checkCancellation()
        values[progress.scope, default: [:]][progress.galleryID] = progress
    }
    public func load(galleryID: GalleryID, scope: StorageScope) async throws -> ReadingProgress? {
        try Task.checkCancellation()
        return values[scope]?[galleryID]
    }
    public func list(scope: StorageScope) async throws -> [ReadingProgress] {
        try Task.checkCancellation()
        return (values[scope].map { Array($0.values) } ?? []).sorted { $0.updatedAt > $1.updatedAt }
    }
    public func remove(galleryID: GalleryID, scope: StorageScope) async throws {
        try Task.checkCancellation()
        values[scope]?[galleryID] = nil
    }
}
