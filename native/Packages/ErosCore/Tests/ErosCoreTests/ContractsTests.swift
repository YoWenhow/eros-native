import XCTest
import Foundation
import ErosCore
import ErosCoreTestSupport

@MainActor
final class ContractsTests: XCTestCase {
    private func scope(_ site: Site = .eh, generation: UInt64 = 0, account: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!) -> SessionScope {
        SessionScope(storage: StorageScope(accountID: AccountID(account), site: site), generation: generation)
    }
    private func reference(_ site: Site = .eh) throws -> GalleryReference {
        GalleryReference(key: GalleryKey(site: site, galleryID: try GalleryID(42)), token: try SensitiveText("synthetic-not-a-real-token"))
    }
    private func roundtrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value)), value, file: file, line: line)
    }
    private func replacing<T: Encodable>(_ value: T, key: String, with replacement: Any) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        object[key] = replacement
        return try JSONSerialization.data(withJSONObject: object)
    }
    func testPageBoundariesAndUntrustedDecoding() throws {
        XCTAssertEqual(try PageIndex(displayNumber: 1, pageCount: 10).value, 0)
        XCTAssertEqual(try PageIndex(displayNumber: 10, pageCount: 10).value, 9)
        XCTAssertEqual(try PageIndex(9).checked(pageCount: 10).displayNumber, 10)
        for bad in [-1, Int.max] { XCTAssertThrowsError(try PageIndex(bad)) }
        for bad in [0, 11] { XCTAssertThrowsError(try PageIndex(displayNumber: bad, pageCount: 10)) }
        XCTAssertThrowsError(try PageIndex(0).checked(pageCount: 0))
        XCTAssertThrowsError(try PageIndex(10).checked(pageCount: 10))
        XCTAssertThrowsError(try JSONDecoder().decode(PageIndex.self, from: Data("-1".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(GalleryID.self, from: Data("0".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(UnitFraction.self, from: Data("1.1".utf8)))
        XCTAssertThrowsError(try UnitFraction(.nan))
        XCTAssertThrowsError(try NonnegativeCount(-1))
        try roundtrip(PageIndex(0))
        try roundtrip(GalleryID(Int64.max))
    }
    func testQueryPreservesSearchLanguage() throws {
        let text = #"  中文 日本語 female:"long hair" -male:foo  a%20b  "#
        let query = GalleryQuery(terms: text, excludedCategories: ["Manga"], source: .watched)
        XCTAssertEqual(query.terms, #"中文 日本語 female:"long hair" -male:foo  a%20b"#)
        try roundtrip(query)
    }
    func testCursorBindingAndStaleResponses() throws {
        let context = RequestContext(scope: scope(), queryID: UUID())
        let cursor = PageCursor(context: context, opaque: try SensitiveText("synthetic-next-or-page=17"))
        let request = try GalleryListRequest(query: GalleryQuery(), context: context, cursor: cursor)
        try roundtrip(request)
        let terminal = try PagedResult<GallerySummary>(items: [], context: context)
        XCTAssertNil(terminal.next)
        try roundtrip(terminal)
        let result = try PagedResult<GallerySummary>(items: [], context: context, next: cursor, previous: cursor)
        try roundtrip(result)
        for other in [
            RequestContext(scope: scope(.ex), queryID: context.queryID),
            RequestContext(scope: scope(generation: 1), queryID: context.queryID),
            RequestContext(scope: scope(), queryID: UUID()),
            RequestContext(scope: scope(account: UUID()), queryID: context.queryID)
        ] {
            XCTAssertThrowsError(try GalleryListRequest(query: GalleryQuery(), context: other, cursor: cursor))
            XCTAssertThrowsError(try result.validate(current: other))
            XCTAssertThrowsError(try PagedResult<GallerySummary>(items: [], context: other, next: cursor))
        }
        let altered = try replacing(request, key: "context", with: JSONSerialization.jsonObject(with: JSONEncoder().encode(RequestContext(scope: scope(.ex), queryID: context.queryID))))
        XCTAssertThrowsError(try JSONDecoder().decode(GalleryListRequest.self, from: altered))
        XCTAssertThrowsError(try GalleryRequest(reference: reference(), scope: scope(.ex)))
        XCTAssertThrowsError(try scope(generation: .max).advanced())
        XCTAssertEqual(try scope().advanced().generation, 1)
    }
    func testAllDomainModelsRoundtripWithNilMetadata() throws {
        let scope = scope()
        let ref = try reference()
        let context = RequestContext(scope: scope, queryID: UUID())
        let summary = try GallerySummary(reference: ref, title: "中文・日本語")
        XCTAssertNil(summary.coverURL)
        XCTAssertNil(summary.rating)
        let detail = GalleryDetail(summary: summary, tags: [TagGroup(namespace: "female", tags: ["synthetic"])])
        let page = ReaderPage(reference: ref, index: try PageIndex(0), pageURL: URL(string: "https://example.invalid/s/synthetic/42-1")!)
        let resolved = try ResolvedImage(page: page, scope: scope, url: URL(string: "https://example.invalid/image")!, resolvedAt: Date(timeIntervalSince1970: 42))
        let progress = ReadingProgress(scope: scope.storage, galleryID: ref.key.galleryID, index: try PageIndex(0), fraction: try UnitFraction(0.5), readingMode: .rightToLeft, updatedAt: Date(timeIntervalSince1970: 1))
        try roundtrip(scope); try roundtrip(ref); try roundtrip(summary); try roundtrip(detail)
        try roundtrip(PixelSize(width: 1, height: 2)); try roundtrip(page); try roundtrip(resolved); try roundtrip(progress)
        try roundtrip(GalleryRequest(reference: ref, scope: scope))
        try roundtrip(ReaderPagesRequest(reference: ref, context: context))
        try roundtrip(ImageResolutionRequest(page: page, scope: scope, reason: .invalidShowKey))
        try roundtrip(FavoriteGroup(id: "synthetic", title: "合成分组"))
        try roundtrip(FavoritesListRequest(groupID: nil, context: context))
        try roundtrip(FavoriteMutation(reference: ref, scope: scope, action: .add(groupID: "synthetic", note: nil)))
        try roundtrip(LocalFavorite(scope: scope.storage, summary: summary, savedAt: Date(timeIntervalSince1970: 1)))
        try roundtrip(SessionState(scope: scope, authentication: .guest))
        try roundtrip(DiagnosticEvent(timestamp: Date(timeIntervalSince1970: 1), kind: .requestFailed, error: .parseMismatch))
        let request = HTTPRequest(id: UUID(), scope: scope, url: URL(string: "https://example.invalid/")!, method: .post, headers: ["Accept": "application/json"], body: Data([0, 255]))
        try roundtrip(request)
        try roundtrip(HTTPResponse(requestID: request.id, scope: scope, status: 200, body: Data([0, 255]), finalURL: request.url))
        XCTAssertThrowsError(try JSONDecoder().decode(GallerySummary.self, from: replacing(summary, key: "title", with: "")))
        XCTAssertThrowsError(try PixelSize(width: 0, height: 1))
    }
    func testDownloadSnapshotRejectsInconsistentOrUnsafeData() throws {
        let id = UUID()
        let job = try DownloadJob(id: id, scope: scope().storage, reference: reference(), state: .completed, totalPages: NonnegativeCount(1), completedPages: NonnegativeCount(1), generation: 2)
        let page = try DownloadPage(jobID: id, index: PageIndex(0), state: .completed, relativePath: RelativePath("downloads/synthetic/0001.jpg"), size: NonnegativeCount(100))
        let snapshot = try DownloadSnapshot(job: job, pages: [page])
        try roundtrip(snapshot)
        XCTAssertThrowsError(try DownloadSnapshot(job: job, pages: []))
        XCTAssertThrowsError(try DownloadSnapshot(job: job, pages: [page, page]))
        XCTAssertThrowsError(try DownloadPage(jobID: id, index: PageIndex(0), state: .completed))
        XCTAssertThrowsError(try JSONDecoder().decode(DownloadSnapshot.self, from: replacing(snapshot, key: "pages", with: [])))
        for path in ["/tmp/file", "../file", "a/../file", "a//file", "a\\file", "C:/file", "%2e%2e/file", "a/./b", ""] {
            XCTAssertThrowsError(try RelativePath(path))
            XCTAssertThrowsError(try JSONDecoder().decode(RelativePath.self, from: JSONEncoder().encode(path)))
        }
    }
    func testHistoryAccountSiteIsolationAndGenerationContinuity() async throws {
        let store: any HistoryStore = MemoryHistoryStore()
        let a = scope()
        let ref = try reference()
        let progress = ReadingProgress(scope: a.storage, galleryID: ref.key.galleryID, index: try PageIndex(1), fraction: try UnitFraction(0), readingMode: .leftToRight, updatedAt: Date())
        try await store.save(progress: progress)
        try await store.save(progress: progress)
        let rows = try await store.list(scope: a.storage)
        XCTAssertEqual(rows.count, 1)
        let same = try await store.load(galleryID: ref.key.galleryID, scope: a.advanced().storage)
        XCTAssertEqual(same, progress)
        let ex = try await store.load(galleryID: ref.key.galleryID, scope: scope(.ex).storage)
        let other = try await store.load(galleryID: ref.key.galleryID, scope: scope(account: UUID()).storage)
        XCTAssertNil(ex); XCTAssertNil(other)
        try await store.remove(galleryID: ref.key.galleryID, scope: scope(.ex).storage)
        let retained = try await store.load(galleryID: ref.key.galleryID, scope: a.storage)
        XCTAssertEqual(retained, progress)
        try await store.remove(galleryID: ref.key.galleryID, scope: a.storage)
        let removed = try await store.list(scope: a.storage)
        XCTAssertTrue(removed.isEmpty)
    }
    func testErrorsAndSensitiveDescriptions() throws {
        let errors: [AppError] = [.transport(code: -1), .httpStatus(403), .authenticationRequired, .accessDenied, .rateLimited(retryAfter: 1), .quotaExceeded, .parseMismatch, .imageExpired, .storageFull, .cancelled, .unsupportedContent, .invalidInput, .scopeMismatch, .staleSession, .notFound]
        for error in errors { try roundtrip(error) }
        let secret = try SensitiveText("synthetic-only")
        XCTAssertEqual(String(describing: secret), "<redacted>")
        XCTAssertFalse(String(reflecting: try reference()).contains("synthetic-not-a-real-token"))
    }
    func testStableIdentitySurvivesTokenAndImageURLChanges() throws {
        let first = try reference()
        let refreshed = GalleryReference(key: first.key, token: try SensitiveText("synthetic-refreshed"))
        let a = try GallerySummary(reference: first, title: "A")
        let b = try GallerySummary(reference: refreshed, title: "B")
        XCTAssertEqual(a.id, b.id)
        let pageA = ReaderPage(reference: first, index: try PageIndex(0), pageURL: URL(string: "https://example.invalid/old")!)
        let pageB = ReaderPage(reference: refreshed, index: try PageIndex(0), pageURL: URL(string: "https://example.invalid/new")!)
        XCTAssertEqual(pageA.id, pageB.id)
        try roundtrip(pageA.id)
        XCTAssertNotEqual(first.key, try reference(.ex).key)
    }
    func testSearchFilterBoundsAndDecode() throws {
        let filters = try SearchFilters(requireTorrent: true, minimumRating: NonnegativeCount(4),
                                        minimumPageCount: NonnegativeCount(10), maximumPageCount: NonnegativeCount(20),
                                        disableTagFilter: true)
        try roundtrip(GalleryQuery(terms: "中文", filters: filters))
        XCTAssertThrowsError(try SearchFilters(minimumPageCount: NonnegativeCount(20), maximumPageCount: NonnegativeCount(10)))
        XCTAssertThrowsError(try JSONDecoder().decode(SearchFilters.self, from: replacing(filters, key: "maximumPageCount", with: 1)))
    }
    func testRepositoryAndResolverFakesPreserveRequestContext() async throws {
        let context = RequestContext(scope: scope(), queryID: UUID())
        let ref = try reference()
        let summary = try GallerySummary(reference: ref, title: "Synthetic")
        let detail = GalleryDetail(summary: summary)
        let page = ReaderPage(reference: ref, index: try PageIndex(0), pageURL: URL(string: "https://example.invalid/synthetic")!)
        let repository: any GalleryRepository = FakeGalleryRepository(
            list: { request in
                guard request.context == context else { throw AppError.staleSession }
                return try PagedResult(items: [summary], context: request.context)
            },
            detail: { request in
                guard request.scope == context.scope && request.reference == ref else { throw AppError.scopeMismatch }
                return detail
            },
            readerPages: { request in
                guard request.context == context && request.reference == ref else { throw AppError.scopeMismatch }
                return try PagedResult(items: [page], context: request.context)
            })
        let list = try await repository.list(request: GalleryListRequest(query: GalleryQuery(), context: context))
        XCTAssertEqual(list.items, [summary])
        try list.validate(current: context)
        let loaded = try await repository.detail(request: GalleryRequest(reference: ref, scope: context.scope))
        XCTAssertEqual(loaded, detail)
        let pages = try await repository.readerPages(request: ReaderPagesRequest(reference: ref, context: context))
        XCTAssertEqual(pages.items, [page])
        let resolver: any ImagePageResolver = FakeImagePageResolver { request in
            guard request.scope == context.scope && request.reason == .expiredURL else { throw AppError.staleSession }
            return try ResolvedImage(page: request.page, scope: request.scope, url: URL(string: "https://example.invalid/refreshed")!, resolvedAt: Date(timeIntervalSince1970: 42))
        }
        let image = try await resolver.resolve(request: ImageResolutionRequest(page: page, scope: context.scope, reason: .expiredURL))
        XCTAssertEqual(image.page.id, page.id)
        XCTAssertEqual(image.scope, context.scope)
    }
    func testTransportFakeFailureAndCancellation() async throws {
        let request = HTTPRequest(id: UUID(), scope: scope(), url: URL(string: "https://example.invalid")!, method: .get)
        let fake = FakeHTTPTransport { _ in throw AppError.httpStatus(503) }
        do { _ = try await fake.send(request: request); XCTFail("must propagate failure") }
        catch { XCTAssertEqual(error as? AppError, .httpStatus(503)) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fake.send(request: request)
        }
        do { _ = try await task.value; XCTFail("must propagate cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
