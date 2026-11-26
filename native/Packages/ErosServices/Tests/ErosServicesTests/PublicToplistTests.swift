import Foundation
import XCTest
import ErosCore
import ErosNetworking
import ErosServices

private actor PublicRankingTransport: HTTPTransport {
    static let policy = NetworkPolicy(parsing: ParsingPolicy(ehHost: "eh.example.invalid", exHost: "ex.example.invalid", forumHost: "forum.example.invalid"))
    var calls: [HTTPRequest] = []
    var blocked = false
    var continuation: CheckedContinuation<Void, Never>?
    var status = 200
    var replacementLink: String?
    var finalOverride: URL?
    func configure(status: Int = 200, link: String? = nil, final: URL? = nil, blocked: Bool = false) {
        self.status = status; replacementLink = link; finalOverride = final; self.blocked = blocked
    }
    func waiting() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
    func send(request: HTTPRequest) async throws -> HTTPResponse {
        calls.append(request)
        if blocked { blocked = false; await withCheckedContinuation { continuation = $0 } }
        let period = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "tl" }?.value ?? "15"
        var html = Self.html.replacingOccurrences(of: "tl=15", with: "tl=" + period)
        if let replacementLink { html = html.replacingOccurrences(of: "?tl=" + period + "&amp;p=1", with: replacementLink) }
        return try HTTPResponse(requestID: request.id, scope: request.scope, status: status,
            headers: ["Content-Type":"text/html", "Retry-After":"37", "Set-Cookie":"synthetic=never-import"],
            body: Data(html.utf8), finalURL: finalOverride ?? request.url)
    }
    // Existing F01b synthetic design layout; never claimed to be a live response.
    static let html = #"""
<!doctype html>
<!-- SYNTHETIC F01b layout assumption; NOT a captured endpoint response. -->
<html><head><meta charset="utf-8"></head><body><table class="itg"><tbody><tr><td class="gl1c glcat"><div>Non-H</div></td><td class="gl2c"><div><div><img src="https://cdn.example.invalid/cover.png" style="height:120px;width:80px"></div></div><div><div>2020-01-01 00:00</div><div class="ir" style="background-position:-16px -0px"></div></div><div><div></div><div class="ir"></div></div></td><td class="gl3c glname"><a href="/g/42/synthetictoken/"><div class="glink">合成画集 日本語</div></a><div class="gt">synthetic</div></td><td class="gl4c glhide"><div>SYNTHETIC_UPLOADER</div><div>3 pages</div></td></tr></tbody></table><table class="ptt"><tr><td>&lt;</td><td class="ptds"><a href="?tl=15&amp;p=0">1</a></td><td><a href="?tl=15&amp;p=1">2</a></td><td>&gt;</td></tr></table></body></html>
"""#
}
private actor PrivateRankingTransport: HTTPTransport {
    var calls: [HTTPRequest] = []
    func send(request: HTTPRequest) throws -> HTTPResponse { calls.append(request); throw AppError.notFound }
}

@MainActor final class PublicToplistTests: XCTestCase {
    let ex = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .ex), generation: 7)
    private func setup(_ transport: PublicRankingTransport, _ privateTransport: PrivateRankingTransport) -> (LiveGalleryRepository, MutableSessionProvider) {
        let session = MutableSessionProvider(SessionState(scope: ex, authentication: .authenticated))
        let policy = PublicRankingTransport.policy
        let repository = LiveGalleryRepository(client: HTTPClient(transport: privateTransport, policy: policy), sessions: session, policy: policy,
            publicToplistClient: HTTPClient(transport: transport, policy: policy))
        return (repository, session)
    }
    func request(period: String = "15", cursor: PageCursor? = nil, context: RequestContext? = nil) throws -> GalleryListRequest {
        try GalleryListRequest(query: GalleryQuery(terms: "must-not-send", excludedCategories: ["Manga"], source: .toplist(period: period), filters: SearchFilters(requireTorrent: true)),
            context: context ?? RequestContext(scope: ex, queryID: UUID()), cursor: cursor)
    }
    func testPublicRankingProjectsAllPeriodsToEXAndDetailUsesEXClient() async throws {
        let transport = PublicRankingTransport(), privateTransport = PrivateRankingTransport()
        let (repo, session) = setup(transport, privateTransport)
        for period in ["15", "13", "12", "11"] {
            let req = try request(period: period)
            let page = try await repo.list(request: req)
            XCTAssertEqual(page.context, req.context); XCTAssertEqual(page.items.first?.reference.key.site, .ex)
            XCTAssertEqual(page.items.first?.reference.key.galleryID.value, 42)
            XCTAssertEqual(page.items.first?.title, "合成画集 日本語")
            XCTAssertEqual(page.items.first?.listTags, [TagGroup(namespace: nil, tags: ["synthetic"])])
            XCTAssertEqual(page.items.first?.postedAt?.timeIntervalSince1970, 1577836800)
            XCTAssertEqual(page.items.first?.rating, 4)
            let cursor = try XCTUnwrap(page.next); XCTAssertEqual(cursor.context, req.context)
            _ = try await repo.list(request: request(period: period, cursor: cursor, context: req.context))
            do { _ = try await repo.detail(request: GalleryRequest(reference: page.items[0].reference, scope: ex)); XCTFail("spy") }
            catch { XCTAssertEqual(error as? AppError, .notFound) }
        }
        let calls = await transport.calls; XCTAssertEqual(calls.count, 8)
        for call in calls {
            XCTAssertEqual(call.url.host, "eh.example.invalid"); XCTAssertEqual(call.url.path, "/toplist.php")
            XCTAssertEqual(call.scope.storage.site, .eh); XCTAssertNil(call.headers["Cookie"]); XCTAssertNil(call.headers["Authorization"])
            let names = URLComponents(url: call.url, resolvingAgainstBaseURL: false)!.queryItems!.map(\.name)
            XCTAssertTrue(Set(names).isSubset(of: ["tl", "p"]))
        }
        let details = await privateTransport.calls; XCTAssertEqual(details.count, 4)
        XCTAssertTrue(details.allSatisfy { $0.url.host == "ex.example.invalid" && $0.scope == ex && $0.url.path.hasPrefix("/g/") })
        let state = await session.current(); XCTAssertEqual(state.scope, ex)
    }
    func testForeignOrUnscopedCursorNeverReachesEitherTransport() async throws {
        let transport = PublicRankingTransport(), privateTransport = PrivateRankingTransport(); let (repo, _) = setup(transport, privateTransport)
        let context = RequestContext(scope: ex, queryID: UUID())
        for opaque in ["url-v1:https://eh.example.invalid/toplist.php?tl=15&p=1", "public-toplist-v1:url-v1:https://evil.invalid/toplist.php?tl=15", "public-toplist-v1:url-v1:https://eh.example.invalid/mytags?tl=15", "public-toplist-v1:url-v1:https://eh.example.invalid/toplist.php?tl=12", "public-toplist-v1:url-v1:https://eh.example.invalid/toplist.php?tl=15&act=login", "public-toplist-v1:url-v1:https://eh.example.invalid/toplist.php?tl=15&p=-1"] {
            let cursor = PageCursor(context: context, opaque: try SensitiveText(opaque))
            do { _ = try await repo.list(request: request(cursor: cursor, context: context)); XCTFail("invalid cursor") } catch {}
        }
        let calls = await transport.calls, privateCalls = await privateTransport.calls
        XCTAssertTrue(calls.isEmpty); XCTAssertTrue(privateCalls.isEmpty)
    }
    func testUnsafeResponseNavigationAndFinalURLAreRejected() async throws {
        let transport = PublicRankingTransport(), privateTransport = PrivateRankingTransport(); let (repo, _) = setup(transport, privateTransport)
        for link in ["/mytags?tl=15", "?tl=12&amp;p=1", "?tl=15&amp;p=1&amp;p=2"] {
            await transport.configure(link: link)
            do { _ = try await repo.list(request: request()); XCTFail("invalid response navigation") } catch {}
        }
        await transport.configure(final: URL(string: "https://eh.example.invalid/mytags?tl=15")!)
        do { _ = try await repo.list(request: request()); XCTFail("wrong final path") } catch {}
    }
    func testHTTPFailuresPropagateWithoutAuthenticatedFallback() async throws {
        let transport = PublicRankingTransport(), privateTransport = PrivateRankingTransport(); let (repo, _) = setup(transport, privateTransport)
        for (status, error) in [(401, AppError.authenticationRequired), (403, .accessDenied), (429, .rateLimited(retryAfter: 37))] {
            await transport.configure(status: status)
            do { _ = try await repo.list(request: request()); XCTFail("HTTP failure") }
            catch let actual { XCTAssertEqual(actual as? AppError, error) }
        }
        let calls = await transport.calls, privateCalls = await privateTransport.calls
        XCTAssertEqual(calls.count, 3); XCTAssertTrue(privateCalls.isEmpty)
    }
    func testSessionChangeDropsLatePublicResponse() async throws {
        let transport = PublicRankingTransport(), privateTransport = PrivateRankingTransport(); let (repo, session) = setup(transport, privateTransport)
        await transport.configure(blocked: true)
        let req = try request(); let old = Task { try await repo.list(request: req) }
        while !(await transport.waiting()) { await Task.yield() }
        await session.update(SessionState(scope: try ex.advanced(), authentication: .authenticated))
        await transport.release()
        do { _ = try await old.value; XCTFail("stale") } catch { XCTAssertEqual(error as? AppError, .staleSession) }
    }
    func testPublicRequestCancellationDoesNotReturnPage() async throws {
        let transport = PublicRankingTransport(), privateTransport = PrivateRankingTransport(); let (repo, _) = setup(transport, privateTransport)
        await transport.configure(blocked: true)
        let req = try request(); let old = Task { try await repo.list(request: req) }
        while !(await transport.waiting()) { await Task.yield() }
        old.cancel(); await transport.release()
        do { _ = try await old.value; XCTFail("cancelled") } catch { XCTAssertTrue(error is CancellationError || error as? AppError == .cancelled) }
    }
}

extension PublicToplistTests {
    func testLocalOnlyBlocksEvenCookieFreePublicRankingClient() async throws {
        let publicTransport=PublicRankingTransport(),privateTransport=PrivateRankingTransport()
        let (repository,sessions)=setup(publicTransport,privateTransport)
        await sessions.update(SessionState(scope:ex,authentication:.needsVerification,permitsNetwork:false))
        do{_=try await repository.list(request:request());XCTFail()}catch AppError.authenticationRequired{}catch{XCTFail()}
        let publicCalls=await publicTransport.calls.count,privateCalls=await privateTransport.calls.count
        XCTAssertEqual(publicCalls,0);XCTAssertEqual(privateCalls,0)
    }
}
