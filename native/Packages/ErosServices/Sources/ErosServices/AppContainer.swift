import Foundation
import Observation
import ErosCore
import ErosNetworking
import ErosPersistence

/// App lifetime dependencies. One database and one transport instance per container.
public struct AppContainer: Sendable {
    public let storage: LibraryStorage?
    public let archiveOperations: ArchiveOperationService?
    public let myTagsWrites:MyTagsWriteService
    public let myTagsChanges:MyTagsChangeSignal
    public let myTags: any MyTagsRepository
    public let galleryInteractions: GalleryInteractionService
    public let commentMutations: CommentMutationService
    public let commentDrafts: CommentDraftStore
    public let galleries: any GalleryRepository
    public let galleryTitleLookup: GalleryTitleLookup?
    public let images: any ImagePageResolver
    public let sessions: any SessionProvider
    public let client: HTTPClient
    public let database: SQLiteDatabase
    public let history: SQLiteHistoryStore
    public let favorites: SQLiteLocalFavoritesStore
    public let remoteFavorites: any RemoteFavoritesRepository
    public let downloadMetadataRefresh: DownloadMetadataRefreshService
    public let downloadLibrary: DownloadLibraryRepository
    public let downloadFileHealth: DownloadFileHealthVerifier?
    public let downloads: SQLiteDownloadStore
    public init(galleries: any GalleryRepository, images: any ImagePageResolver, sessions: any SessionProvider, client: HTTPClient,
                database: SQLiteDatabase, archiveOperations: ArchiveOperationService? = nil,
                downloadFileHealth: DownloadFileHealthVerifier? = nil, downloadStatusSite: Site? = nil,
                storage: LibraryStorage? = nil, galleryTitleLookup: GalleryTitleLookup? = nil,
                availableDownloadSites: (@Sendable (AccountID) async -> Set<Site>)? = nil) {
        self.storage = storage
        self.galleryTitleLookup = galleryTitleLookup
        let support = storage?.layout.applicationSupport ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = storage?.layout.caches ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let lease = storage?.lease
        let commentPolicy=NetworkPolicy(allowGalleryAPI:true)
        let commentClient=HTTPClient(transport:URLSessionTransport(policy:commentPolicy,credentials:sessions as? any RequestCredentials),policy:commentPolicy)
        let draftRoot=support.appendingPathComponent(CommentDraftStore.directoryName)
        let drafts=CommentDraftStore(root:draftRoot,sessions:sessions, storageLease: lease)
        commentDrafts=drafts;commentMutations=CommentMutationService(client:commentClient,sessions:sessions,drafts:drafts, storageLease: lease)
        let interactionPolicy=NetworkPolicy(allowGalleryInteractions:true)
        let interactionClient=HTTPClient(transport:URLSessionTransport(policy:interactionPolicy,credentials:sessions as? any RequestCredentials),policy:interactionPolicy)
        let interactionRoot=support.appendingPathComponent(GalleryInteractionStore.directoryName)
        galleryInteractions=GalleryInteractionService(client:interactionClient,sessions:sessions,store:GalleryInteractionStore(root:interactionRoot,sessions:sessions, storageLease: lease),metadata:DownloadDetailMetadataService(database:database,sessions:sessions), storageLease: lease)
        let myTagsRoot=caches.appendingPathComponent("MyTags-v1")
        let myTagsCache=MyTagsCache(root:myTagsRoot,sessions:sessions)
        let myTagsReader=LiveMyTagsRepository(client:client,sessions:sessions,cache:myTagsCache)
        myTags=myTagsReader
        let myTagsSignal=MyTagsChangeSignal();myTagsChanges=myTagsSignal
        let myTagsPolicy=NetworkPolicy(allowMyTagsWrite:true)
        let myTagsClient=HTTPClient(transport:URLSessionTransport(policy:myTagsPolicy,credentials:sessions as? any RequestCredentials),policy:myTagsPolicy)
        let myTagsRecordRoot=support.appendingPathComponent(MyTagsMutationStore.directoryName)
        myTagsWrites=MyTagsWriteService(store:MyTagsMutationStore(root:myTagsRecordRoot,sessions:sessions, storageLease: lease),reader:myTagsReader,cache:myTagsCache,client:myTagsClient,sessions:sessions,signal:myTagsSignal, storageLease: lease)
        self.archiveOperations=archiveOperations
        self.galleries = galleries;self.images = images;self.sessions = sessions;self.client = client;self.database = database
        downloadMetadataRefresh = DownloadMetadataRefreshService(database: database, repository: galleries,
            sessions: sessions, storageLease: lease)
        self.downloadFileHealth = downloadFileHealth
        downloadLibrary = DownloadLibraryRepository(database: database, sessions: sessions,
            verifyFileHealth: downloadFileHealth.map { $0.health(of:) }, downloadStatusSite: downloadStatusSite,
            availableSites: availableDownloadSites)
        remoteFavorites = LiveFavoritesRepository(client: client, sessions: sessions, policy: client.classifier.policy, storageLease: lease)
        history = SQLiteHistoryStore(database: database);favorites = SQLiteLocalFavoritesStore(database: database);downloads = SQLiteDownloadStore(database: database)
    }
    public static func live(layout baseLayout: StorageLayout, sessions: any SessionProvider,
                            policy: NetworkPolicy = NetworkPolicy(), resuming: Bool = false,
                            archiveImageValidator: @escaping ArchiveFileInstaller.ImageValidator) async throws -> AppContainer {
        let storage = try await LibraryStorage.open(layout: baseLayout, resuming: resuming, validateImage: archiveImageValidator)
        return live(storage: storage, sessions: sessions, policy: policy, archiveImageValidator: archiveImageValidator)
    }

    public static func live(storage: LibraryStorage, sessions: any SessionProvider,
                            policy: NetworkPolicy = NetworkPolicy(),
                            availableDownloadSites: (@Sendable (AccountID) async -> Set<Site>)? = nil,
                            archiveImageValidator: @escaping ArchiveFileInstaller.ImageValidator) -> AppContainer {
        let layout = storage.layout
        let database = storage.database
        let client = HTTPClient(transport: URLSessionTransport(policy: policy, credentials: sessions as? any RequestCredentials),policy: policy)
        let archivePolicy=NetworkPolicy(parsing:policy.parsing,allowArchiveWrite:true)
        let archiveClient=HTTPClient(transport:URLSessionTransport(policy:archivePolicy,credentials:sessions as? any RequestCredentials),policy:archivePolicy)
        #if canImport(Security)
        let archiveCapabilities: any ArchivePreparationCapabilityStore=KeychainArchivePreparationCapabilityStore()
        #else
        let archiveCapabilities: any ArchivePreparationCapabilityStore=MemoryArchivePreparationCapabilityStore()
        #endif
        let archive = ArchiveOperationService(store: storage.archiveJournal,
            quoteReader: ArchiveQuoteService(client: client, sessions: sessions), client: archiveClient,
            sessions: sessions, capabilities: archiveCapabilities, database: database,
            installer: ArchiveFileInstaller(stagingRoot: layout.archiveStaging, downloadsRoot: layout.downloads,
                                            validate: archiveImageValidator, publicRoot: storage.publicDownloads), storageLease: storage.lease)
        let titlePolicy = NetworkPolicy(parsing: policy.parsing, allowGalleryTitleReads: true)
        let titleClient = HTTPClient(transport: URLSessionTransport(policy: titlePolicy,
            credentials: sessions as? any RequestCredentials, requestTimeout: 3, resourceTimeout: 5), policy: titlePolicy)
        let galleryTitles = GalleryTitleLookup(client: titleClient, sessions: sessions, database: database,
            storageLease: storage.lease)
        return AppContainer(galleries: LiveGalleryRepository(client: client,sessions: sessions,policy: policy),
            images: LiveImagePageResolver(client: client,sessions: sessions,policy: policy), sessions: sessions,
            client: client, database: database, archiveOperations: archive,
            downloadFileHealth: DownloadFileHealthVerifier(database: database, root: layout.downloads,
                validate: archiveImageValidator, publicRoot: storage.publicDownloads), storage: storage,
            galleryTitleLookup: galleryTitles, availableDownloadSites: availableDownloadSites)
    }
}

/// Shared live/offline ViewModel. T17 supplies navigation; late selections cannot replace the current selection.
@MainActor @Observable
public final class GalleryFlowModel {
    public private(set) var list: PagedResult<GallerySummary>?
    public private(set) var detail: GalleryDetail?
    public private(set) var pages: PagedResult<ReaderPage>?
    public private(set) var loading = false
    public private(set) var error: AppError?
    private let repository: any GalleryRepository
    private var revision = UUID()
    public init(repository: any GalleryRepository) { self.repository = repository }
    public func reset() { revision = UUID();list = nil;detail = nil;pages = nil;error = nil;loading = false }
    public func load(_ request: GalleryListRequest) async {
        let ticket = UUID();revision = ticket;loading = true;error = nil
        if list?.context != request.context { list = nil;detail = nil;pages = nil }
        defer { if revision == ticket { loading = false } }
        do { let result = try await repository.list(request: request);try Task.checkCancellation();if revision == ticket { list = result } }
        catch is CancellationError {}
        catch AppError.cancelled {}
        catch { if revision == ticket { self.error = error as? AppError ?? .parseMismatch } }
    }
    public func open(_ request: ReaderPagesRequest) async {
        let ticket = UUID();revision = ticket;loading = true;error = nil;detail = nil;pages = nil
        defer { if revision == ticket { loading = false } }
        do {
            let selected = try await repository.detail(request: GalleryRequest(reference: request.reference,scope: request.context.scope))
            let result = try await repository.readerPages(request: request)
            try Task.checkCancellation()
            if revision == ticket { detail = selected;pages = result }
        } catch is CancellationError {}
        catch AppError.cancelled {}
        catch { if revision == ticket { self.error = error as? AppError ?? .parseMismatch } }
    }
}
