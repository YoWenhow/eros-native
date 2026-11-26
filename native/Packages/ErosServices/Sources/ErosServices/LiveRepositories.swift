import Foundation
import ErosCore
import ErosNetworking

public actor MutableSessionProvider: SessionProvider {
    private var state: SessionState
    public init(_ state: SessionState) { self.state = state }
    public func current() -> SessionState { state }
    /// SessionManager must cancel old work and advance generation before publishing a new state.
    public func update(_ state: SessionState) { self.state = state }
}

struct SessionGuard: Sendable {
    let provider: any SessionProvider
    func checkNetwork(_ scope:SessionScope) async throws {
        try Task.checkCancellation();let state=try await provider.current()
        guard state.scope==scope else{throw AppError.staleSession}
        guard state.permitsNetwork else{throw AppError.authenticationRequired};try Task.checkCancellation()
    }
    func check(_ scope: SessionScope) async throws {
        try Task.checkCancellation()
        guard try await provider.current().scope == scope else { throw AppError.staleSession }
        try Task.checkCancellation()
    }
}

/// Parsing runs on this actor, never the UI actor. No implicit database/network side effects beyond each request.
public actor LiveGalleryRepository: GalleryRepository {
    private let client: HTTPClient
    private let builder: EndpointBuilder
    private let publicToplistClient: HTTPClient
    private let sessions: SessionGuard
    public init(client: HTTPClient, sessions: any SessionProvider, policy: NetworkPolicy = NetworkPolicy(), publicToplistClient: HTTPClient? = nil) {
        self.client = client;builder = EndpointBuilder(policy: policy);self.sessions = SessionGuard(provider: sessions)
        // Separate ephemeral transport: no RequestCredentials, cookies, shared storage or account writes.
        self.publicToplistClient = publicToplistClient ?? HTTPClient(transport: URLSessionTransport(policy: policy), policy: policy)
    }
    public func list(request: GalleryListRequest) async throws -> PagedResult<GallerySummary> {
        try await sessions.checkNetwork(request.context.scope)
        if request.context.scope.storage.site == .ex, case .toplist(let period) = request.query.source {
            return try await publicToplist(request, period: period)
        }
        let response = try await client.send(builder.list(request),expecting: .html)
        try await sessions.checkNetwork(request.context.scope)
        let result = try GalleryListParser(policy: builder.policy.parsing).parse(response,context: request.context)
        try await sessions.checkNetwork(request.context.scope);return result
    }
    private func publicToplist(_ request: GalleryListRequest, period: String) async throws -> PagedResult<GallerySummary> {
        let active = request.context
        let transportScope = SessionScope(storage: StorageScope(accountID: active.scope.storage.accountID, site: .eh), generation: active.scope.generation)
        let transportContext = RequestContext(scope: transportScope, queryID: active.queryID)
        let prefix = "public-toplist-v1:"
        let cursor: PageCursor?
        if let original = request.cursor {
            guard original.context == active, original.opaque.value.hasPrefix(prefix) else { throw AppError.parseMismatch }
            cursor = PageCursor(context: transportContext, opaque: try SensitiveText(String(original.opaque.value.dropFirst(prefix.count))))
        } else { cursor = nil }
        // Validate the period even on cursor requests (the generic builder consumes opaque cursors first).
        guard ["11", "12", "13", "15"].contains(period) else { throw AppError.invalidInput }
        let http = try builder.list(GalleryListRequest(query: GalleryQuery(source: .toplist(period: period)), context: transportContext, cursor: cursor))
        try validatePublicToplistURL(http.url, period: period)
        let response = try await publicToplistClient.send(http, expecting: .html, retryRateLimits: false)
        try await sessions.checkNetwork(active.scope)
        try validatePublicToplistURL(response.finalURL, period: period)
        let page = try GalleryListParser(policy: builder.policy.parsing).parse(response, context: transportContext)
        let items = try page.items.map { item in
            try GallerySummary(reference: GalleryReference(key: GalleryKey(site: .ex, galleryID: item.reference.key.galleryID), token: item.reference.token),
                title: item.title, coverURL: item.coverURL, category: item.category, uploader: item.uploader, pageCount: item.pageCount, rating: item.rating, listTags: item.listTags, postedAt: item.postedAt)
        }
        func project(_ cursor: PageCursor?) throws -> PageCursor? {
            guard let cursor else { return nil }
            let url = try builder.policy.parsing.navigationURL(cursor: cursor, context: transportContext)
            try validatePublicToplistURL(url, period: period)
            return PageCursor(context: active, opaque: try SensitiveText(prefix + cursor.opaque.value))
        }
        let result = try PagedResult(items: items, context: active, next: project(page.next), previous: project(page.previous), totalCount: page.totalCount)
        try await sessions.checkNetwork(active.scope)
        return result
    }
    private func validatePublicToplistURL(_ url: URL, period: String) throws {
        guard url.scheme == "https", url.host == builder.policy.parsing.ehHost, url.path == "/toplist.php",
              url.user == nil, url.password == nil, url.fragment == nil, url.port == nil || url.port == 443,
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              query.filter({ $0.name == "tl" }).map(\.value) == [period],
              query.allSatisfy({ $0.name == "tl" || $0.name == "p" }), query.filter({ $0.name == "p" }).count <= 1
        else { throw AppError.accessDenied }
        if let page = query.first(where: { $0.name == "p" }) {
            guard let value = page.value, !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), Int(value) != nil else { throw AppError.accessDenied }
        }
    }
    public func detail(request: GalleryRequest) async throws -> GalleryDetail {
        try await sessions.checkNetwork(request.scope)
        let response = try await client.send(builder.detail(request),expecting: .html)
        try await sessions.checkNetwork(request.scope)
        let result = try GalleryDetailParser(policy: builder.policy.parsing).parse(response,reference: request.reference)
        try await sessions.checkNetwork(request.scope);return result
    }
    public func readerPages(request: ReaderPagesRequest) async throws -> PagedResult<ReaderPage> {
        let (batch, count) = try await thumbnailBatch(request: request)
        var pages = batch.items.map { item in
            let page = item.page
            let thumbnail = item.thumbnailURL.map {
                ReaderPage.Thumbnail(url: $0, size: item.thumbnailSize, horizontalOffset: item.horizontalOffset)
            }
            return ReaderPage(reference: page.reference, index: page.index, pageURL: page.pageURL,
                dimensions: page.dimensions, thumbnail: thumbnail)
        }
        if let first = pages.first(where: { $0.pageURL.path.hasPrefix("/mpv/") }) {
            // Legacy thumbnails can lack the original hash. Use their MPV directory
            // for any remaining single-page keys without blocking the detail thumbnail grid.
            guard let count else { throw AppError.parseMismatch }
            var parts = URLComponents(url: first.pageURL, resolvingAgainstBaseURL: false); parts?.fragment = nil
            guard let entry = parts?.url else { throw AppError.parseMismatch }
            let http = HTTPRequest(id: UUID(), scope: request.context.scope, url: entry, method: .get, headers: ["Accept":"text/html"])
            let response = try await catalogueHTML(http, phase: "mpvDirectoryResponse")
            try await sessions.checkNetwork(request.context.scope)
            let directory: MPVDirectory
            var issue = ReaderParseIssue("directoryMarkup")
            do {
                directory = try MPVDirectoryParser(policy: builder.policy.parsing).parse(
                    response, reference: request.reference, context: request.context, expectedCount: count.value,
                    use: .singlePageLinks) { issue = $0 }
            } catch AppError.parseMismatch {
                await logReaderParseFailure(request: http.id, phase: "mpvDirectory", issue: issue)
                throw AppError.parseMismatch
            }
            pages = try pages.map { page in
                guard page.pageURL.path.hasPrefix("/mpv/") else { return page }
                let locator = try directory.page(at: page.index, scope: request.context.scope)
                let normal = URL(string: "https://" + builder.policy.parsing.host(for: request.context.scope.storage.site))!
                    .appendingPathComponent("s").appendingPathComponent(locator.imageKey.value)
                    .appendingPathComponent("\(request.reference.key.galleryID.value)-\(locator.wirePage)")
                return ReaderPage(reference: page.reference, index: page.index, pageURL: normal,
                    dimensions: page.dimensions, thumbnail: page.thumbnail)
            }
        }
        try Task.checkCancellation(); try await sessions.checkNetwork(request.context.scope)
        return try PagedResult(items: pages, context: batch.context, next: batch.next, previous: batch.previous)
    }
    public func thumbnails(request: ReaderPagesRequest) async throws -> PagedResult<GalleryThumbnail> {
        try await thumbnailBatch(request: request).0
    }
    private func thumbnailBatch(request: ReaderPagesRequest) async throws -> (PagedResult<GalleryThumbnail>, NonnegativeCount?) {
        try await sessions.checkNetwork(request.context.scope)
        let http: HTTPRequest
        if let cursor = request.cursor {
            let url = try builder.policy.parsing.navigationURL(cursor: cursor,context: request.context)
            let expected = try builder.detail(GalleryRequest(reference: request.reference,scope: request.context.scope)).url
            guard url.path == expected.path || url.path == expected.path + "/" else {
                await logReaderParseFailure(request: request.context.queryID, phase: "thumbnailCursor", issue: ReaderParseIssue("cursorGalleryIdentity"))
                throw AppError.parseMismatch
            }
            http = HTTPRequest(id: UUID(),scope: request.context.scope,url: url,method: .get,headers: ["Accept":"text/html"])
        } else { http = try builder.detail(GalleryRequest(reference: request.reference,scope: request.context.scope)) }
        let response = try await catalogueHTML(http, phase: "thumbnailResponse")
        try await sessions.checkNetwork(request.context.scope)
        let detail: GalleryDetail
        do {
            detail = try GalleryDetailParser(policy: builder.policy.parsing).parse(response, reference: request.reference)
        } catch AppError.parseMismatch {
            await logReaderParseFailure(request: http.id, phase: "thumbnailDetail", issue: ReaderParseIssue("galleryDetail"))
            throw AppError.parseMismatch
        }
        let parsed: PagedResult<GalleryThumbnail>
        var issue = ReaderParseIssue("thumbnailMarkup")
        do {
            parsed = try ThumbnailPageParser(policy: builder.policy.parsing).parse(response, reference: request.reference,
                context: request.context, totalPages: detail.summary.pageCount) { issue = $0 }
        } catch AppError.parseMismatch {
            await logReaderParseFailure(request: http.id, phase: "thumbnail", issue: issue)
            throw AppError.parseMismatch
        }
        try await sessions.checkNetwork(request.context.scope)
        return (parsed, detail.summary.pageCount)
    }

    private func catalogueHTML(_ request: HTTPRequest, phase: StaticString) async throws -> HTTPResponse {
        do { return try await client.send(request, expecting: .html) }
        catch AppError.parseMismatch {
            await logReaderParseFailure(request: request.id, phase: phase, issue: ReaderParseIssue("responseClassifier"))
            throw AppError.parseMismatch
        }
    }
}

private func logReaderParseFailure(request: UUID, phase: StaticString, issue: ReaderParseIssue, pageIndex: Int? = nil) async {
    var fields: [AppLogField: AppLogValue] = [.phase: .label(phase), .failureKind: .label(issue.check)]
    fields[.expectedCount] = issue.expected.map(AppLogValue.integer)
    fields[.observedCount] = issue.observed.map(AppLogValue.integer)
    fields[.pageIndex] = pageIndex.map(AppLogValue.integer)
    await AppLog.shared.record(.readerParseFailure, request: request, fields: fields)
}

public actor LiveImagePageResolver: ImagePageResolver {
    private struct Key: Hashable { let scope: SessionScope;let reference: GalleryReference }
    private let client: HTTPClient
    private let sessions: SessionGuard
    private let policy: NetworkPolicy
    private let clock: any Clock
    private let retriesSiteReads: Bool
    private struct CachedPage {
        let context: ImageResolutionContext
        let receivedFromReloadPage: Bool
    }
    private var contexts: [Key: CachedPage] = [:]
    private var latest: [Key:UUID] = [:]
    private var htmlOnly: Set<Key> = []
    public init(client: HTTPClient, sessions: any SessionProvider, policy: NetworkPolicy = NetworkPolicy(),
                clock: any Clock = SystemNetworkClock(), retriesSiteReads: Bool = true) {
        self.client = client
        self.sessions = SessionGuard(provider: sessions)
        self.policy = policy
        self.clock = clock
        self.retriesSiteReads = retriesSiteReads
    }
    public func clearContexts() { contexts.removeAll();latest.removeAll();htmlOnly.removeAll() }
    public func resolve(request: ImageResolutionRequest) async throws -> ResolvedImage {
        try await resolveBackgroundImage(request: request).image
    }

    public func resolveBackgroundImage(request: ImageResolutionRequest) async throws -> BackgroundImageResolution {
        try await sessions.checkNetwork(request.scope)
        contexts = contexts.filter { $0.key.scope == request.scope }
        htmlOnly = htmlOnly.filter { $0.scope == request.scope }
        let key = Key(scope: request.scope, reference: request.page.reference)
        let previous = contexts[key]
        let context = request.reason == .initial && htmlOnly.contains(key) ? nil : previous?.context
        var flow = try ImageResolutionPolicy(request: request, context: context, parsing: policy.parsing)
        if request.reason == .retryDownloadAddress, let previous, let image = previous.context.resolvedImage(for: request) {
            try Task.checkCancellation()
            return BackgroundImageResolution(image: image, receivedFromReloadPage: previous.receivedFromReloadPage)
        }
        let ticket = UUID()
        latest[key] = ticket
        do {
            var action = try flow.start()
            while true {
                try await sessions.checkNetwork(request.scope)
                let http: HTTPRequest, kind: ResponseKind, sentReloadKey: Bool
                switch action {
                case .html(let url):
                    http = HTTPRequest(id: UUID(), scope: request.scope, url: url, method: .get, headers: ["Accept":"text/html"])
                    kind = .html
                    sentReloadKey = request.reason == .retryDownloadSource &&
                        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
                            $0.name == "nl" && $0.value?.isEmpty == false
                        } == true
                    if request.reason == .retryDownloadSource {
                        await ReaderLog.record(.downloadRetry, request: http.id, pageIndex: request.page.index.value,
                            phase: sentReloadKey ? "imagePageWithReloadKey" : "imagePageWithoutReloadKey")
                        try await sessions.checkNetwork(request.scope)
                    }
                case .showPage(let url,let body):
                    http = HTTPRequest(id: UUID(),scope: request.scope,url: url,method: .post,
                        headers: ["Accept":"application/json","Content-Type":"application/json"],body: body)
                    kind = .json
                    sentReloadKey = false
                }
                do {
                    let response = try await client.send(http, expecting: kind,
                        retryTransportFailures: retriesSiteReads, retryRateLimits: retriesSiteReads)
                    try await sessions.checkNetwork(request.scope)
                    let result = try flow.accept(response,resolvedAt: await clock.now(), diagnostics: true)
                    try await sessions.checkNetwork(request.scope)
                    if latest[key] == ticket {
                        if contexts.count >= 16 { contexts.removeAll() }
                        contexts[key] = flow.context.map { CachedPage(context: $0, receivedFromReloadPage: sentReloadKey) }
                        latest.removeValue(forKey: key)
                    }
                    return BackgroundImageResolution(image: result.image, receivedFromReloadPage: sentReloadKey)
                } catch let error as AppError {
                    if error == .unsupportedContent, kind == .json {
                        if htmlOnly.count >= 16 { htmlOnly.removeAll() }
                        htmlOnly.insert(key)
                        await ReaderLog.record(.imageAPIFallback, request: http.id, pageIndex: request.page.index.value, phase: "showpageUnsupportedToHTML", failureKind: "unsupportedContent")
                    }
                    if error == .parseMismatch, kind == .json { throw ImagePageFailure(stage: .api) }
                    if error == .parseMismatch, kind == .html {
                        await logReaderParseFailure(request: http.id, phase: "singlePage", issue: ReaderParseIssue("htmlBeforeImageParse"),
                            pageIndex: request.page.index.value)
                    }
                    action = try flow.recover(from: error)
                }
            }
        } catch {
            if latest[key] == ticket {
                // A transient error while asking for a new node must not lose the
                // last valid key for this exact page. A successful replacement
                // supersedes it, even when the replacement has no reload key.
                let preserve = request.reason == .retryDownloadSource && previous?.context.resolvedImage(for: request) != nil
                    && PageDownloadRetry.isTransient(error)
                if !preserve { contexts.removeValue(forKey: key) }
                latest.removeValue(forKey: key)
            }
            throw error
        }
    }
}
