import Foundation

public enum GalleryAvailability: String, Codable, Hashable, Sendable { case available, authenticationRequired, accessDenied, removed, unknown }
public enum GallerySource: Codable, Hashable, Sendable { case browse, watched, popular, toplist(period: String) }
public enum GallerySort: String, Codable, Hashable, Sendable { case siteDefault }
public enum ReadingMode: String, Codable, Hashable, Sendable { case leftToRight, rightToLeft, vertical }
public enum ImageResolutionReason: String, Codable, Hashable, Sendable {
    case initial, expiredURL, invalidShowKey, changeSource
    case retryDownloadAddress, retryDownloadSource
}
public enum FavoriteAction: Codable, Hashable, Sendable { case add(groupID: String, note: String?), remove }
public enum DownloadJobState: String, Codable, Hashable, Sendable { case queued, resolving, downloading, completed, paused, waitingForNetwork, authenticationRequired, failed, cancelled }
public enum DownloadPageState: String, Codable, Hashable, Sendable { case pending, resolving, downloading, verifying, completed, skipped, paused, failed }
public enum HTTPMethod: String, Codable, Hashable, Sendable { case get = "GET", post = "POST" }
public enum AuthenticationState: String, Codable, Hashable, Sendable { case guest, authenticated, needsVerification }
public enum DiagnosticKind: String, Codable, Hashable, Sendable { case requestStarted, requestFinished, requestFailed, sessionChanged, storageFailed, downloadChanged }

public struct PixelSize: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) throws {
        guard width > 0 && height > 0 else { throw AppError.invalidInput }
        self.width = width
        self.height = height
    }
    private enum CodingKeys: String, CodingKey { case width, height }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            width: try c.decode(Int.self, forKey: .width),
            height: try c.decode(Int.self, forKey: .height)
        )
    }
}

public struct GallerySummary: Codable, Equatable, Sendable {
    public let reference: GalleryReference
    public let title: String
    public let coverURL: URL?
    public let category: String?
    public let uploader: String?
    public let pageCount: NonnegativeCount?
    public let rating: Double?
    public let listTags: [TagGroup]?
    public let postedAt: Date?
    /// Optional site title metadata; the canonical title remains unchanged.
    public let sourceTitles: GallerySourceTitles?
    public init(reference: GalleryReference, title: String, coverURL: URL? = nil, category: String? = nil, uploader: String? = nil, pageCount: NonnegativeCount? = nil, rating: Double? = nil, listTags: [TagGroup]? = nil, postedAt: Date? = nil, sourceTitles: GallerySourceTitles? = nil) throws {
        guard !title.isEmpty, rating?.isFinite != false else { throw AppError.invalidInput }
        self.reference = reference
        self.title = title
        self.coverURL = coverURL
        self.category = category
        self.uploader = uploader
        self.pageCount = pageCount
        self.rating = rating
        self.listTags = listTags
        self.postedAt = postedAt
        self.sourceTitles = sourceTitles
    }
    public func onSite(_ site: Site) throws -> Self {
        if reference.key.site == site { return self }
        return try Self(reference: reference.onSite(site), title: title, coverURL: coverURL, category: category,
            uploader: uploader, pageCount: pageCount, rating: rating, listTags: listTags, postedAt: postedAt,
            sourceTitles: sourceTitles)
    }
    private enum CodingKeys: String, CodingKey { case reference, title, coverURL, category, uploader, pageCount, rating, listTags, postedAt, sourceTitles }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            reference: try c.decode(GalleryReference.self, forKey: .reference),
            title: try c.decode(String.self, forKey: .title),
            coverURL: try c.decodeIfPresent(URL.self, forKey: .coverURL),
            category: try c.decodeIfPresent(String.self, forKey: .category),
            uploader: try c.decodeIfPresent(String.self, forKey: .uploader),
            pageCount: try c.decodeIfPresent(NonnegativeCount.self, forKey: .pageCount),
            rating: try c.decodeIfPresent(Double.self, forKey: .rating),
            listTags: try c.decodeIfPresent([TagGroup].self, forKey: .listTags),
            postedAt: try c.decodeIfPresent(Date.self, forKey: .postedAt),
            sourceTitles: try c.decodeIfPresent(GallerySourceTitles.self, forKey: .sourceTitles)
        )
    }
}

public struct TagGroup: Codable, Equatable, Sendable {
    public let namespace: String?
    public let tags: [String]
    public init(namespace: String?, tags: [String]) {
        self.namespace = namespace
        self.tags = tags
    }
    private enum CodingKeys: String, CodingKey { case namespace, tags }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            namespace: try c.decodeIfPresent(String.self, forKey: .namespace),
            tags: try c.decode([String].self, forKey: .tags)
        )
    }
}

public struct GalleryDetail: Codable, Equatable, Sendable {
    public let interaction: GalleryInteractionSnapshot?
    public let comments: CommentPage?
    public let summary: GallerySummary
    public let originalTitle: String?
    public let translatedTitle: String?
    public let tags: [TagGroup]
    public let thumbnailPageCount: NonnegativeCount?
    public let availability: GalleryAvailability
    public let sourceTitles: GallerySourceTitles?
    public init(summary: GallerySummary, originalTitle: String? = nil, translatedTitle: String? = nil, tags: [TagGroup] = [], thumbnailPageCount: NonnegativeCount? = nil, availability: GalleryAvailability = .unknown, sourceTitles: GallerySourceTitles? = nil, comments: CommentPage? = nil, interaction: GalleryInteractionSnapshot? = nil) {
        self.interaction = interaction
        self.comments = comments
        self.summary = summary
        self.originalTitle = originalTitle
        self.translatedTitle = translatedTitle
        self.tags = tags
        self.thumbnailPageCount = thumbnailPageCount
        self.availability = availability
        self.sourceTitles = sourceTitles
    }
    private enum CodingKeys: String, CodingKey { case summary, originalTitle, translatedTitle, tags, thumbnailPageCount, availability, sourceTitles, comments, interaction }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            summary: try c.decode(GallerySummary.self, forKey: .summary),
            originalTitle: try c.decodeIfPresent(String.self, forKey: .originalTitle),
            translatedTitle: try c.decodeIfPresent(String.self, forKey: .translatedTitle),
            tags: try c.decode([TagGroup].self, forKey: .tags),
            thumbnailPageCount: try c.decodeIfPresent(NonnegativeCount.self, forKey: .thumbnailPageCount),
            availability: try c.decode(GalleryAvailability.self, forKey: .availability),
            sourceTitles: try c.decodeIfPresent(GallerySourceTitles.self, forKey: .sourceTitles),
            comments: try c.decodeIfPresent(CommentPage.self, forKey: .comments),
            interaction: try c.decodeIfPresent(GalleryInteractionSnapshot.self,forKey:.interaction)
        )
    }
}

public struct GalleryQuery: Codable, Equatable, Sendable {
    public let terms: String
    public let excludedCategories: [String]
    public let source: GallerySource
    public let sort: GallerySort
    public let filters: SearchFilters?
    public init(terms: String = "", excludedCategories: [String] = [], source: GallerySource = .browse, sort: GallerySort = .siteDefault, filters: SearchFilters? = nil) {
        self.terms = terms.trimmingCharacters(in: .whitespacesAndNewlines)
        self.excludedCategories = excludedCategories
        self.source = source
        self.sort = sort
        self.filters = filters
    }
    private enum CodingKeys: String, CodingKey { case terms, excludedCategories, source, sort, filters }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            terms: try c.decode(String.self, forKey: .terms),
            excludedCategories: try c.decode([String].self, forKey: .excludedCategories),
            source: try c.decode(GallerySource.self, forKey: .source),
            sort: try c.decode(GallerySort.self, forKey: .sort),
            filters: try c.decodeIfPresent(SearchFilters.self, forKey: .filters)
        )
    }
}

public struct RequestContext: Codable, Equatable, Sendable {
    public let scope: SessionScope
    public let queryID: UUID
    public init(scope: SessionScope, queryID: UUID) {
        self.scope = scope
        self.queryID = queryID
    }
    private enum CodingKeys: String, CodingKey { case scope, queryID }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            scope: try c.decode(SessionScope.self, forKey: .scope),
            queryID: try c.decode(UUID.self, forKey: .queryID)
        )
    }
}

public struct PageCursor: Codable, Equatable, Sendable {
    public let context: RequestContext
    public let opaque: SensitiveText
    public init(context: RequestContext, opaque: SensitiveText) {
        self.context = context
        self.opaque = opaque
    }
    private enum CodingKeys: String, CodingKey { case context, opaque }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            context: try c.decode(RequestContext.self, forKey: .context),
            opaque: try c.decode(SensitiveText.self, forKey: .opaque)
        )
    }
}

public struct GalleryListRequest: Codable, Equatable, Sendable {
    public let query: GalleryQuery
    public let context: RequestContext
    public let cursor: PageCursor?
    public init(query: GalleryQuery, context: RequestContext, cursor: PageCursor? = nil) throws {
        guard cursor == nil || cursor?.context == context else { throw AppError.scopeMismatch }
        self.query = query
        self.context = context
        self.cursor = cursor
    }
    private enum CodingKeys: String, CodingKey { case query, context, cursor }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            query: try c.decode(GalleryQuery.self, forKey: .query),
            context: try c.decode(RequestContext.self, forKey: .context),
            cursor: try c.decodeIfPresent(PageCursor.self, forKey: .cursor)
        )
    }
}

public struct GalleryRequest: Codable, Equatable, Sendable {
    public let reference: GalleryReference
    public let scope: SessionScope
    public init(reference: GalleryReference, scope: SessionScope) throws {
        try reference.validate(scope: scope)
        self.reference = reference
        self.scope = scope
    }
    private enum CodingKeys: String, CodingKey { case reference, scope }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            reference: try c.decode(GalleryReference.self, forKey: .reference),
            scope: try c.decode(SessionScope.self, forKey: .scope)
        )
    }
}

public struct ReaderPagesRequest: Codable, Equatable, Sendable {
    public let reference: GalleryReference
    public let context: RequestContext
    public let cursor: PageCursor?
    public init(reference: GalleryReference, context: RequestContext, cursor: PageCursor? = nil) throws {
        try reference.validate(scope: context.scope)
        guard cursor == nil || cursor?.context == context else { throw AppError.scopeMismatch }
        self.reference = reference
        self.context = context
        self.cursor = cursor
    }
    private enum CodingKeys: String, CodingKey { case reference, context, cursor }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            reference: try c.decode(GalleryReference.self, forKey: .reference),
            context: try c.decode(RequestContext.self, forKey: .context),
            cursor: try c.decodeIfPresent(PageCursor.self, forKey: .cursor)
        )
    }
}

public struct ReaderPage: Codable, Equatable, Sendable {
    public struct Thumbnail: Codable, Equatable, Sendable {
        public let url: URL
        public let size: PixelSize?
        public let horizontalOffset: NonnegativeCount?

        public init(url: URL, size: PixelSize?, horizontalOffset: NonnegativeCount?) {
            self.url = url
            self.size = size
            self.horizontalOffset = horizontalOffset
        }
    }

    public let reference: GalleryReference
    public let index: PageIndex
    public let pageURL: URL
    public let dimensions: PixelSize?
    public let thumbnail: Thumbnail?
    public init(reference: GalleryReference, index: PageIndex, pageURL: URL, dimensions: PixelSize? = nil,
                thumbnail: Thumbnail? = nil) {
        self.reference = reference
        self.index = index
        self.pageURL = pageURL
        self.dimensions = dimensions
        self.thumbnail = thumbnail
    }
    private enum CodingKeys: String, CodingKey { case reference, index, pageURL, dimensions, thumbnail }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            reference: try c.decode(GalleryReference.self, forKey: .reference),
            index: try c.decode(PageIndex.self, forKey: .index),
            pageURL: try c.decode(URL.self, forKey: .pageURL),
            dimensions: try c.decodeIfPresent(PixelSize.self, forKey: .dimensions),
            thumbnail: try c.decodeIfPresent(Thumbnail.self, forKey: .thumbnail)
        )
    }
}

public struct ResolvedImage: Codable, Equatable, Sendable {
    public let page: ReaderPage
    public let scope: SessionScope
    public let url: URL
    public let headers: [String: String]
    public let resolvedAt: Date
    public init(page: ReaderPage, scope: SessionScope, url: URL, headers: [String: String] = [:], resolvedAt: Date) throws {
        try page.reference.validate(scope: scope)
        self.page = page
        self.scope = scope
        self.url = url
        self.headers = headers
        self.resolvedAt = resolvedAt
    }
    private enum CodingKeys: String, CodingKey { case page, scope, url, headers, resolvedAt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            page: try c.decode(ReaderPage.self, forKey: .page),
            scope: try c.decode(SessionScope.self, forKey: .scope),
            url: try c.decode(URL.self, forKey: .url),
            headers: try c.decode([String: String].self, forKey: .headers),
            resolvedAt: try c.decode(Date.self, forKey: .resolvedAt)
        )
    }
}

public struct ImageResolutionRequest: Codable, Equatable, Sendable {
    public let page: ReaderPage
    public let scope: SessionScope
    public let reason: ImageResolutionReason
    public init(page: ReaderPage, scope: SessionScope, reason: ImageResolutionReason) throws {
        try page.reference.validate(scope: scope)
        self.page = page
        self.scope = scope
        self.reason = reason
    }
    private enum CodingKeys: String, CodingKey { case page, scope, reason }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            page: try c.decode(ReaderPage.self, forKey: .page),
            scope: try c.decode(SessionScope.self, forKey: .scope),
            reason: try c.decode(ImageResolutionReason.self, forKey: .reason)
        )
    }
}

public struct ReadingProgress: Codable, Equatable, Sendable {
    public let scope: StorageScope
    public let galleryID: GalleryID
    public let index: PageIndex
    public let fraction: UnitFraction
    public let readingMode: ReadingMode
    public let updatedAt: Date
    public init(scope: StorageScope, galleryID: GalleryID, index: PageIndex, fraction: UnitFraction, readingMode: ReadingMode, updatedAt: Date) {
        self.scope = scope
        self.galleryID = galleryID
        self.index = index
        self.fraction = fraction
        self.readingMode = readingMode
        self.updatedAt = updatedAt
    }
    private enum CodingKeys: String, CodingKey { case scope, galleryID, index, fraction, readingMode, updatedAt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            scope: try c.decode(StorageScope.self, forKey: .scope),
            galleryID: try c.decode(GalleryID.self, forKey: .galleryID),
            index: try c.decode(PageIndex.self, forKey: .index),
            fraction: try c.decode(UnitFraction.self, forKey: .fraction),
            readingMode: try c.decode(ReadingMode.self, forKey: .readingMode),
            updatedAt: try c.decode(Date.self, forKey: .updatedAt)
        )
    }
}

public struct FavoriteGroup: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let count: NonnegativeCount?
    public init(id: String, title: String, count: NonnegativeCount? = nil) {
        self.id = id
        self.title = title
        self.count = count
    }
    private enum CodingKeys: String, CodingKey { case id, title, count }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            title: try c.decode(String.self, forKey: .title),
            count: try c.decodeIfPresent(NonnegativeCount.self, forKey: .count)
        )
    }
}

public struct FavoritesListRequest: Codable, Equatable, Sendable {
    public let groupID: String?
    public let titleQuery: String?
    public let context: RequestContext
    public let cursor: PageCursor?

    public init(groupID: String?, titleQuery: String? = nil, context: RequestContext, cursor: PageCursor? = nil) throws {
        guard cursor == nil || cursor?.context == context else { throw AppError.scopeMismatch }
        self.groupID = groupID
        let query = titleQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.titleQuery = query?.isEmpty == false ? query : nil
        self.context = context
        self.cursor = cursor
    }

    private enum CodingKeys: String, CodingKey { case groupID, titleQuery, context, cursor }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            groupID: try c.decodeIfPresent(String.self, forKey: .groupID),
            titleQuery: try c.decodeIfPresent(String.self, forKey: .titleQuery),
            context: try c.decode(RequestContext.self, forKey: .context),
            cursor: try c.decodeIfPresent(PageCursor.self, forKey: .cursor)
        )
    }
}

public struct FavoriteMutation: Codable, Equatable, Sendable {
    public let reference: GalleryReference
    public let scope: SessionScope
    public let action: FavoriteAction
    public init(reference: GalleryReference, scope: SessionScope, action: FavoriteAction) throws {
        try reference.validate(scope: scope)
        self.reference = reference
        self.scope = scope
        self.action = action
    }
    private enum CodingKeys: String, CodingKey { case reference, scope, action }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            reference: try c.decode(GalleryReference.self, forKey: .reference),
            scope: try c.decode(SessionScope.self, forKey: .scope),
            action: try c.decode(FavoriteAction.self, forKey: .action)
        )
    }
}

public struct LocalFavorite: Codable, Equatable, Sendable {
    public let scope: StorageScope
    public let summary: GallerySummary
    public let savedAt: Date
    public init(scope: StorageScope, summary: GallerySummary, savedAt: Date) throws {
        guard scope.site == summary.reference.key.site else { throw AppError.scopeMismatch }
        self.scope = scope
        self.summary = summary
        self.savedAt = savedAt
    }
    private enum CodingKeys: String, CodingKey { case scope, summary, savedAt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            scope: try c.decode(StorageScope.self, forKey: .scope),
            summary: try c.decode(GallerySummary.self, forKey: .summary),
            savedAt: try c.decode(Date.self, forKey: .savedAt)
        )
    }
}

public struct DownloadJob: Codable, Equatable, Sendable {
    public let id: UUID
    public let scope: StorageScope
    public let reference: GalleryReference
    public let state: DownloadJobState
    public let totalPages: NonnegativeCount
    public let completedPages: NonnegativeCount
    public let sourceKind: DownloadSourceKind
    public let variant: DownloadVariant
    public var contentKey: DownloadContentKey { DownloadContentKey(account: scope.accountID, gallery: reference.key.galleryID, sourceKind: sourceKind, variant: variant) }
    public let skippedPages: NonnegativeCount
    public var progressTotal: Int { totalPages.value - skippedPages.value }
    public let generation: UInt64
    public init(id: UUID, scope: StorageScope, reference: GalleryReference, state: DownloadJobState, totalPages: NonnegativeCount, completedPages: NonnegativeCount, generation: UInt64, skippedPages: NonnegativeCount = try! NonnegativeCount(0), sourceKind: DownloadSourceKind = .pages, variant: DownloadVariant = .display) throws {
        guard scope.site == reference.key.site else { throw AppError.scopeMismatch }
        guard skippedPages.value <= totalPages.value, completedPages.value <= totalPages.value - skippedPages.value else { throw AppError.invalidInput }
        guard state != .completed || completedPages.value == totalPages.value - skippedPages.value else { throw AppError.invalidInput }
        self.id = id
        self.scope = scope
        self.reference = reference
        self.state = state
        self.totalPages = totalPages
        self.completedPages = completedPages
        self.generation = generation
        self.skippedPages = skippedPages
        self.sourceKind = sourceKind; self.variant = variant
    }
    private enum CodingKeys: String, CodingKey { case id, scope, reference, state, totalPages, completedPages, generation, skippedPages, sourceKind, variant }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try c.decode(UUID.self, forKey: .id),
            scope: try c.decode(StorageScope.self, forKey: .scope),
            reference: try c.decode(GalleryReference.self, forKey: .reference),
            state: try c.decode(DownloadJobState.self, forKey: .state),
            totalPages: try c.decode(NonnegativeCount.self, forKey: .totalPages),
            completedPages: try c.decode(NonnegativeCount.self, forKey: .completedPages),
            generation: try c.decode(UInt64.self, forKey: .generation),
            skippedPages: try c.decodeIfPresent(NonnegativeCount.self, forKey: .skippedPages) ?? NonnegativeCount(0),
            sourceKind: try c.decodeIfPresent(DownloadSourceKind.self, forKey: .sourceKind) ?? .pages,
            variant: try c.decodeIfPresent(DownloadVariant.self, forKey: .variant) ?? .display
        )
    }
}

public struct DownloadPage: Codable, Equatable, Sendable {
    public let jobID: UUID
    public let index: PageIndex
    public let state: DownloadPageState
    public let relativePath: RelativePath?
    public let size: NonnegativeCount?
    public let taskIdentifier: NonnegativeCount?
    public let contentDigest: String?
    public let error: AppError?
    public init(jobID: UUID, index: PageIndex, state: DownloadPageState, relativePath: RelativePath? = nil, size: NonnegativeCount? = nil, taskIdentifier: NonnegativeCount? = nil, error: AppError? = nil, contentDigest: String? = nil) throws {
        guard (state != .completed && state != .skipped) || (relativePath != nil && size != nil && size!.value > 0 && error == nil) else { throw AppError.invalidInput }
        guard state != .skipped || contentDigest != nil else { throw AppError.invalidInput }
        guard contentDigest == nil || (contentDigest!.count == 64 && contentDigest!.allSatisfy { "0123456789abcdef".contains($0) }) else { throw AppError.invalidInput }
        self.contentDigest = contentDigest
        self.jobID = jobID
        self.index = index
        self.state = state
        self.relativePath = relativePath
        self.size = size
        self.taskIdentifier = taskIdentifier
        self.error = error
    }
    private enum CodingKeys: String, CodingKey { case jobID, index, state, relativePath, size, taskIdentifier, error, contentDigest }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            jobID: try c.decode(UUID.self, forKey: .jobID),
            index: try c.decode(PageIndex.self, forKey: .index),
            state: try c.decode(DownloadPageState.self, forKey: .state),
            relativePath: try c.decodeIfPresent(RelativePath.self, forKey: .relativePath),
            size: try c.decodeIfPresent(NonnegativeCount.self, forKey: .size),
            taskIdentifier: try c.decodeIfPresent(NonnegativeCount.self, forKey: .taskIdentifier),
            error: try c.decodeIfPresent(AppError.self, forKey: .error),
            contentDigest: try c.decodeIfPresent(String.self, forKey: .contentDigest)
        )
    }
}

public struct DownloadSnapshot: Codable, Equatable, Sendable {
    public let job: DownloadJob
    public let pages: [DownloadPage]
    public init(job: DownloadJob, pages: [DownloadPage]) throws {
        guard pages.allSatisfy({ $0.jobID == job.id && $0.index.value < job.totalPages.value }), Set(pages.map(\.index)).count == pages.count,
              pages.filter({ $0.state == .completed }).count == job.completedPages.value,
              pages.filter({ $0.state == .skipped }).count == job.skippedPages.value,
              job.state != .completed || pages.count == job.totalPages.value
        else { throw AppError.invalidInput }
        self.job = job
        self.pages = pages
    }
    private enum CodingKeys: String, CodingKey { case job, pages }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            job: try c.decode(DownloadJob.self, forKey: .job),
            pages: try c.decode([DownloadPage].self, forKey: .pages)
        )
    }
}

public struct HTTPRequest: Codable, Equatable, Sendable {
    public let id: UUID
    public let scope: SessionScope
    public let url: URL
    public let method: HTTPMethod
    public let headers: [String: String]
    public let body: Data?
    public init(id: UUID, scope: SessionScope, url: URL, method: HTTPMethod, headers: [String: String] = [:], body: Data? = nil) {
        self.id = id
        self.scope = scope
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
    private enum CodingKeys: String, CodingKey { case id, scope, url, method, headers, body }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            scope: try c.decode(SessionScope.self, forKey: .scope),
            url: try c.decode(URL.self, forKey: .url),
            method: try c.decode(HTTPMethod.self, forKey: .method),
            headers: try c.decode([String: String].self, forKey: .headers),
            body: try c.decodeIfPresent(Data.self, forKey: .body)
        )
    }
}

public struct HTTPResponse: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let scope: SessionScope
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public let finalURL: URL
    public init(requestID: UUID, scope: SessionScope, status: Int, headers: [String: String] = [:], body: Data, finalURL: URL) throws {
        guard (100...599).contains(status) else { throw AppError.invalidInput }
        self.requestID = requestID
        self.scope = scope
        self.status = status
        self.headers = headers
        self.body = body
        self.finalURL = finalURL
    }
    private enum CodingKeys: String, CodingKey { case requestID, scope, status, headers, body, finalURL }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requestID: try c.decode(UUID.self, forKey: .requestID),
            scope: try c.decode(SessionScope.self, forKey: .scope),
            status: try c.decode(Int.self, forKey: .status),
            headers: try c.decode([String: String].self, forKey: .headers),
            body: try c.decode(Data.self, forKey: .body),
            finalURL: try c.decode(URL.self, forKey: .finalURL)
        )
    }
}

public struct SessionState: Codable, Equatable, Sendable {
    public let scope: SessionScope
    public let authentication: AuthenticationState
    public let permitsNetwork:Bool
    public init(scope: SessionScope, authentication: AuthenticationState,permitsNetwork:Bool=true) {
        self.scope = scope
        self.authentication = authentication
        self.permitsNetwork=permitsNetwork
    }
    private enum CodingKeys: String, CodingKey { case scope, authentication, permitsNetwork }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            scope: try c.decode(SessionScope.self, forKey: .scope),
            authentication: try c.decode(AuthenticationState.self, forKey: .authentication),
            permitsNetwork:try c.decodeIfPresent(Bool.self,forKey:.permitsNetwork) ?? true
        )
    }
}

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let kind: DiagnosticKind
    public let requestID: UUID?
    public let error: AppError?
    public init(timestamp: Date, kind: DiagnosticKind, requestID: UUID? = nil, error: AppError? = nil) {
        self.timestamp = timestamp
        self.kind = kind
        self.requestID = requestID
        self.error = error
    }
    private enum CodingKeys: String, CodingKey { case timestamp, kind, requestID, error }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            timestamp: try c.decode(Date.self, forKey: .timestamp),
            kind: try c.decode(DiagnosticKind.self, forKey: .kind),
            requestID: try c.decodeIfPresent(UUID.self, forKey: .requestID),
            error: try c.decodeIfPresent(AppError.self, forKey: .error)
        )
    }
}

public struct PagedResult<Item: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let items: [Item]
    public let context: RequestContext
    public let next: PageCursor?
    public let previous: PageCursor?
    public let totalCount: GalleryResultCount?
    public init(items: [Item], context: RequestContext, next: PageCursor? = nil, previous: PageCursor? = nil, totalCount: GalleryResultCount? = nil) throws {
        guard next == nil || next?.context == context,
              previous == nil || previous?.context == context else { throw AppError.scopeMismatch }
        self.items = items; self.context = context; self.next = next; self.previous = previous; self.totalCount = totalCount
    }
    private enum CodingKeys: String, CodingKey { case items, context, next, previous, totalCount }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(items: c.decode([Item].self, forKey: .items),
                      context: c.decode(RequestContext.self, forKey: .context),
                      next: c.decodeIfPresent(PageCursor.self, forKey: .next),
                      previous: c.decodeIfPresent(PageCursor.self, forKey: .previous),
                      totalCount: c.decodeIfPresent(GalleryResultCount.self, forKey: .totalCount))
    }
    public func validate(current: RequestContext) throws {
        guard context == current else { throw AppError.staleSession }
    }
}
