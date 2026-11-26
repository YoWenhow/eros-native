import Foundation
import XCTest
import ErosCore
import ErosNetworking
import ErosPersistence
import ErosServices
import ErosOfflineDemo

actor DemoClock: Clock {
    private(set) var delays: [Double] = []
    func now() -> Date { .distantPast }
    func sleep(seconds: TimeInterval) throws { try Task.checkCancellation();delays.append(seconds) }
}

actor BarrierTransport: HTTPTransport {
    let base = FixtureTransport()
    private var entered = false
    private var continuation: CheckedContinuation<Void,Never>?
    func started() -> Bool { entered }
    func release() { continuation?.resume();continuation = nil }
    func send(request: HTTPRequest) async throws -> HTTPResponse {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        return try await base.send(request: request)
    }
}

actor IncompatibleShowPageTransport: HTTPTransport {
    let base = FixtureTransport()
    private(set) var apiCalls = 0
    private(set) var pageCalls = 0
    private(set) var reloadKeys: [String] = []
    func send(request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.path.hasPrefix("/s/") {
            pageCalls += 1
            if let key = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "nl" })?.value {
                reloadKeys.append(key)
                if reloadKeys.count == 1 { throw AppError.transport(code: -1001) }
            }
        }
        if request.url.path == "/api.php" {
            apiCalls += 1
            return try HTTPResponse(requestID: request.id, scope: request.scope, status: 200,
                headers: ["content-type": "text/html"], body: Data("<p>synthetic unsupported API response</p>".utf8), finalURL: request.url)
        }
        return try await base.send(request: request)
    }
}

@MainActor
final class ServicesTests: XCTestCase {
    let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()),site: .eh),generation: 1)
    func session() -> MutableSessionProvider { MutableSessionProvider(SessionState(scope: scope,authentication: .guest)) }
    func listRequest() throws -> GalleryListRequest { try GalleryListRequest(query: GalleryQuery(),context: RequestContext(scope: scope,queryID: UUID())) }
    func repository(_ transport: any HTTPTransport, _ session: any SessionProvider) -> LiveGalleryRepository {
        LiveGalleryRepository(client: HTTPClient(transport: transport,policy: FixtureTransport.policy),sessions: session,policy: FixtureTransport.policy)
    }
    func testCompleteOfflinePathThroughRealParsersAndImageBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("temporary cleanup failed") } }
        let app = try await AppContainer.offline(databaseURL: directory.appendingPathComponent("demo.sqlite"),sessions: session())
        let request = try listRequest(), model = GalleryFlowModel(repository: app.galleries)
        await model.load(request);XCTAssertNil(model.error)
        let first = try XCTUnwrap(model.list?.items.first)
        try await model.open(ReaderPagesRequest(reference: first.reference,context: request.context))
        XCTAssertNil(model.error);XCTAssertEqual(model.detail?.summary.pageCount?.value,3)
        let pages = try XCTUnwrap(model.pages?.items);XCTAssertEqual(pages.map(\.index.value),[0,1,2])
        for page in pages {
            let image = try await app.images.resolve(request: ImageResolutionRequest(page: page,scope: scope,reason: .initial))
            XCTAssertEqual(image.page.id,page.id);XCTAssertEqual(image.page.dimensions,try PixelSize(width: 320,height: 480));XCTAssertTrue(image.headers.isEmpty)
            let bytes = try await app.client.send(EndpointBuilder(policy: FixtureTransport.policy).media(url: image.url,scope: scope),expecting: .image)
            XCTAssertEqual(Array(bytes.body.prefix(8)),[137,80,78,71,13,10,26,10]);XCTAssertGreaterThan(bytes.body.count,100)
        }
        try await app.database.saveGallery(first,scope: scope.storage)
        try await app.history.save(progress: ReadingProgress(scope: scope.storage,galleryID: first.reference.key.galleryID,index: PageIndex(1),fraction: UnitFraction(0),readingMode: .leftToRight,updatedAt: .distantPast))
        let stored = try await app.history.load(galleryID: first.reference.key.galleryID,scope: scope.storage);XCTAssertEqual(stored?.index.value,1)
        await app.database.close()
    }
    func testSameViewModelAcceptsLiveAndFixtureRepositories() async throws {
        let transport = FixtureTransport(), sessions = session()
        let repos: [any GalleryRepository] = [repository(transport,sessions),FixtureGalleryRepository(transport: transport,sessions: sessions)]
        for repo in repos {
            let model = GalleryFlowModel(repository: repo);await model.load(try listRequest());XCTAssertEqual(model.list?.items.count,1);XCTAssertNil(model.error)
            model.reset();XCTAssertNil(model.list)
        }
    }
    func testPaginationFailurePreservesFirstPageAndCanRetry() async throws {
        let transport = FixtureTransport(scenario: FixtureScenario(paginationFailure: true)), repo = repository(transport,session())
        let request = try listRequest(), model = GalleryFlowModel(repository: repo)
        await model.load(request)
        let cursor = try XCTUnwrap(model.list?.next)
        let next = try GalleryListRequest(query: request.query,context: request.context,cursor: cursor)
        await model.load(next);XCTAssertEqual(model.error,.parseMismatch);XCTAssertEqual(model.list?.items.count,1)
        await transport.configure(FixtureScenario());await model.load(next);XCTAssertNil(model.error);XCTAssertNil(model.list?.next)
    }
    func testAuthenticationFailurePropagatesToViewModel() async throws {
        let transport = FixtureTransport(scenario: FixtureScenario(authenticationExpired: true)), model = GalleryFlowModel(repository: repository(transport,session()))
        await model.load(try listRequest());XCTAssertEqual(model.error,.authenticationRequired);XCTAssertNil(model.list);XCTAssertFalse(model.loading)
    }
    func testSessionChangeRejectsLateResponse() async throws {
        let transport = BarrierTransport(), sessions = session(), repo = repository(transport,sessions), request = try listRequest()
        let task = Task { try await repo.list(request: request) }
        while !(await transport.started()) { await Task.yield() }
        await sessions.update(SessionState(scope: try scope.advanced(),authentication: .guest));await transport.release()
        do { _ = try await task.value;XCTFail() } catch { XCTAssertEqual(error as? AppError,.staleSession) }
    }
    func testCancellationAndResetSuppressLateResults() async throws {
        let transport = BarrierTransport(), model = GalleryFlowModel(repository: repository(transport,session())), request = try listRequest()
        let task = Task { await model.load(request) }
        while !(await transport.started()) { await Task.yield() }
        model.reset();task.cancel();await transport.release();await task.value
        XCTAssertNil(model.list);XCTAssertNil(model.error);XCTAssertFalse(model.loading)
    }
    func testUnsupportedShowPageFallsBackOnceAndRemembersOnlyCurrentScope() async throws {
        let transport = IncompatibleShowPageTransport(), sessions = session(), repo = repository(transport, sessions)
        let request = try listRequest(), first = try await repo.list(request: request).items[0]
        let pages = try await repo.readerPages(request: ReaderPagesRequest(reference: first.reference, context: request.context)).items
        let resolver = LiveImagePageResolver(client: HTTPClient(transport: transport, policy: FixtureTransport.policy), sessions: sessions, policy: FixtureTransport.policy)
        for page in pages {
            let image = try await resolver.resolve(request: ImageResolutionRequest(page: page, scope: scope, reason: .initial))
            XCTAssertEqual(image.page.id, page.id)
        }
        let calls = await transport.apiCalls; XCTAssertEqual(calls, 1)
        let advanced = try scope.advanced(); await sessions.update(SessionState(scope: advanced, authentication: .guest))
        for page in pages.prefix(2) { _ = try await resolver.resolve(request: ImageResolutionRequest(page: page, scope: advanced, reason: .initial)) }
        let newCalls = await transport.apiCalls; XCTAssertEqual(newCalls, 2)
    }
    func testDownloadResolverReusesAddressAndKeepsReloadKeyAfterTransientCandidateFailure() async throws {
        let transport = IncompatibleShowPageTransport(), sessions = session(), repo = repository(transport, sessions)
        let request = try listRequest()
        let first = try await repo.list(request: request).items[0]
        let pages = try await repo.readerPages(request: ReaderPagesRequest(reference: first.reference, context: request.context)).items
        let resolver = LiveImagePageResolver(client: HTTPClient(transport: transport, policy: FixtureTransport.policy),
            sessions: sessions, policy: FixtureTransport.policy, retriesSiteReads: false)
        for page in pages.prefix(2) {
            _ = try await resolver.resolve(request: ImageResolutionRequest(page: page, scope: scope, reason: .initial))
        }
        let page = pages[1], pageCalls = await transport.pageCalls
        let same = try await resolver.resolve(request: ImageResolutionRequest(page: page, scope: scope, reason: .retryDownloadAddress))
        XCTAssertEqual(same.url.path, "/page2.png")
        let pageCallsAfterReuse = await transport.pageCalls
        XCTAssertEqual(pageCallsAfterReuse, pageCalls)

        let candidate = try ImageResolutionRequest(page: page, scope: scope, reason: .retryDownloadSource)
        do {
            _ = try await resolver.resolve(request: candidate)
            XCTFail("candidate timeout must reach the download retry loop")
        } catch {
            XCTAssertEqual(error as? AppError, .transport(code: -1001))
        }
        let retried = try await resolver.resolve(request: candidate)
        XCTAssertEqual(retried.page.id, page.id)
        let reloadKeys = await transport.reloadKeys
        XCTAssertEqual(reloadKeys, ["demosource2", "demosource2"])
        let apiCalls = await transport.apiCalls
        XCTAssertEqual(apiCalls, 1)
    }

    func testResolverKeyMismatchFallsBackAndContextIsScopeBound() async throws {
        let transport = FixtureTransport(), sessions = session(), repo = repository(transport,sessions)
        let request = try listRequest(), first = try await repo.list(request: request).items[0]
        let pages = try await repo.readerPages(request: ReaderPagesRequest(reference: first.reference,context: request.context)).items
        let resolver = LiveImagePageResolver(client: HTTPClient(transport: transport,policy: FixtureTransport.policy),sessions: sessions,policy: FixtureTransport.policy)
        _ = try await resolver.resolve(request: ImageResolutionRequest(page: pages[0],scope: scope,reason: .initial))
        await transport.configure(FixtureScenario(invalidShowKey: true))
        let before = await transport.requestCount
        let image = try await resolver.resolve(request: ImageResolutionRequest(page: pages[1],scope: scope,reason: .initial))
        let after = await transport.requestCount;XCTAssertEqual(after-before,2);XCTAssertEqual(image.page.id,pages[1].id)
        let advanced = try scope.advanced();await sessions.update(SessionState(scope: advanced,authentication: .guest))
        let count = await transport.requestCount
        _ = try await resolver.resolve(request: ImageResolutionRequest(page: pages[2],scope: advanced,reason: .initial))
        let end = await transport.requestCount;XCTAssertEqual(end-count,1)
    }
    func testForeignCursorRejectedBeforeNetworkAndUnknownDemoNoFallback() async throws {
        let transport = FixtureTransport(), repo = repository(transport,session()), request = try listRequest()
        let first = try await repo.list(request: request).items[0]
        let bad = PageCursor(context: request.context,opaque: try SensitiveText("url-v1:https://eh.demo.invalid/g/99/other/?p=1"))
        let before = await transport.requestCount
        do { _ = try await repo.readerPages(request: ReaderPagesRequest(reference: first.reference,context: request.context,cursor: bad));XCTFail() } catch { XCTAssertEqual(error as? AppError,.parseMismatch) }
        let after = await transport.requestCount;XCTAssertEqual(before,after)
        do { _ = try await transport.send(request: HTTPRequest(id: UUID(),scope: scope,url: URL(string: "https://eh.demo.invalid/unknown")!,method: .get));XCTFail() } catch { XCTAssertEqual(error as? AppError,.notFound) }
    }
    func testDelayInjectionAndNewQueryCannotRetainOldResults() async throws {
        let clock = DemoClock(), transport = FixtureTransport(scenario: FixtureScenario(delay: 5),clock: clock)
        let model = GalleryFlowModel(repository: repository(transport,session()))
        await model.load(try listRequest());XCTAssertNotNil(model.list)
        let delays = await clock.delays;XCTAssertEqual(delays,[5])
        await transport.configure(FixtureScenario(authenticationExpired: true))
        await model.load(try listRequest())
        XCTAssertEqual(model.error,.authenticationRequired);XCTAssertNil(model.list)
    }
    func testDemoSearchEmptyAndRecoverableErrorStates() async throws {
        let transport = FixtureTransport(), repo = repository(transport,session())
        let query = try GalleryListRequest(query: GalleryQuery(terms: "三色"),context: RequestContext(scope: scope,queryID: UUID()))
        let found = try await repo.list(request: query);XCTAssertEqual(found.items.count,1)
        let missing = try GalleryListRequest(query: GalleryQuery(terms: "不存在的示例"),context: RequestContext(scope: scope,queryID: UUID()))
        let empty = try await repo.list(request: missing);XCTAssertTrue(empty.items.isEmpty);XCTAssertNil(empty.next)
        await transport.configure(FixtureScenario(emptyList: true))
        let forced = try await repo.list(request: query);XCTAssertTrue(forced.items.isEmpty)
        await transport.configure(FixtureScenario(listFailure: true))
        do { _ = try await repo.list(request: query);XCTFail() } catch { XCTAssertEqual(error as? AppError,.transport(code: -1009)) }
        await transport.configure(FixtureScenario())
        let restored = try await repo.list(request: query);XCTAssertEqual(restored.items.count,1)
    }
}
