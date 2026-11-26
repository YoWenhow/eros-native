import Foundation
import XCTest
import ErosCore
import ErosServices
import ErosNetworking

private actor PreviewTransport: HTTPTransport {
    let status: Int
    var requests: [HTTPRequest] = []
    init(status: Int = 403) { self.status = status }
    func send(request: HTTPRequest) throws -> HTTPResponse {
        requests.append(request)
        let mirror = request.url.host == "ehgt.org" || request.url.host == "abcdefghij.hath.network"
        return try HTTPResponse(requestID: request.id, scope: request.scope, status: mirror ? 200 : status,
            headers: ["Content-Type": mirror ? "image/webp" : "text/html"],
            body: mirror ? Data("RIFFsyntheticWEBP".utf8) : Data("<html>denied</html>".utf8), finalURL: request.url)
    }
}

@MainActor final class PreviewTests: XCTestCase {
    let scope = SessionScope(storage: StorageScope(accountID: AccountID(UUID()), site: .ex), generation: 1)
    let url = URL(string: "https://s.exhentai.org/w/ab/cde/12345-synthetic.webp")!
    func testKnownStaticMirrorAndUnsafePaths() throws {
        XCTAssertEqual(PreviewImageLoader.publicMirror(for: url)?.absoluteString, "https://ehgt.org/w/ab/cde/12345-synthetic.webp")
        let legacy = "https://s.exhentai.org/t/ab/cd/" + String(repeating: "a", count: 40) + "-1-2-3-jpg.jpg"
        XCTAssertEqual(PreviewImageLoader.publicMirror(for: URL(string: legacy)!)?.path, String(URL(string: legacy)!.path.dropFirst(2)))
        for value in ["https://s.exhentai.org/g/42/token/", "https://s.exhentai.org/uconfig.php", url.absoluteString + "?secret=value", "https://s.exhentai.org.evil.invalid/w/ab/cde/12345-synthetic.webp", "http://s.exhentai.org/w/ab/cde/12345-synthetic.webp", "https://s.exhentai.org:444/w/ab/cde/12345-synthetic.webp"] {
            XCTAssertNil(PreviewImageLoader.publicMirror(for: URL(string: value)!))
        }
    }
    func test403UsesStaticMirrorWithoutCredentialHeadersAndCaches() async throws {
        let transport = PreviewTransport(), sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let loader = PreviewImageLoader(sessions: sessions, policy: PreviewImageLoader.productionPolicy, transport: transport)
        let data = try await loader.load(url: url, scope: scope)
        let cached = try await loader.load(url: url, scope: scope)
        XCTAssertEqual(data, cached)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.url.host), ["s.exhentai.org", "ehgt.org"])
        XCTAssertTrue(requests.allSatisfy { $0.headers.keys.allSatisfy { !["cookie", "authorization"].contains($0.lowercased()) } })
    }
    func testAuthenticationErrorDoesNotTryAnotherHost() async {
        let transport = PreviewTransport(status: 401), sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .guest))
        let loader = PreviewImageLoader(sessions: sessions, policy: PreviewImageLoader.productionPolicy, transport: transport)
        do { _ = try await loader.load(url: url, scope: scope); XCTFail() }
        catch { XCTAssertEqual(error as? AppError, .authenticationRequired) }
        let count = await transport.requests.count; XCTAssertEqual(count, 1)
    }
    func testHathSpriteLoadsDirectlyWithoutMirroringOrCredentials() async throws {
        let transport = PreviewTransport(), sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let loader = PreviewImageLoader(sessions: sessions, policy: PreviewImageLoader.productionPolicy, transport: transport)
        let sprite = URL(string: "https://abcdefghij.hath.network/c2/syntheticSignature/42-0.webp")!
        _ = try await loader.load(url: sprite, scope: scope)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests.first?.url, sprite)
        XCTAssertNil(PreviewImageLoader.publicMirror(for: sprite))
        XCTAssertTrue(requests.allSatisfy { $0.headers.keys.allSatisfy { !["cookie", "authorization"].contains($0.lowercased()) } })
    }
    func testOldScopeCannotReadCachedPreview() async throws {
        let transport = PreviewTransport(), sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let loader = PreviewImageLoader(sessions: sessions, policy: PreviewImageLoader.productionPolicy, transport: transport)
        _ = try await loader.load(url: url, scope: scope)
        await sessions.update(SessionState(scope: try scope.advanced(), authentication: .guest))
        do { _ = try await loader.load(url: url, scope: scope); XCTFail() }
        catch { XCTAssertEqual(error as? AppError, .staleSession) }
    }
    func testCompressedCacheEvictsLRUInsteadOfFlushingEveryPreview() async throws {
        let transport = PreviewTransport(), sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let loader = PreviewImageLoader(sessions: sessions, policy: PreviewImageLoader.productionPolicy,
            transport: transport, cacheMaximumBytes: 100, cacheMaximumCount: 2)
        let urls = (0..<3).map { URL(string: "https://abcdefghij.hath.network/c2/syntheticSignature/42-\($0).webp")! }
        _ = try await loader.load(url: urls[0], scope: scope)
        _ = try await loader.load(url: urls[1], scope: scope)
        _ = try await loader.load(url: urls[0], scope: scope)
        _ = try await loader.load(url: urls[2], scope: scope)
        _ = try await loader.load(url: urls[0], scope: scope)
        let before = await transport.requests.count; XCTAssertEqual(before, 3)
        _ = try await loader.load(url: urls[1], scope: scope)
        let after = await transport.requests.count; XCTAssertEqual(after, 4)
    }
    func testCompressedByteBudgetPreservesRecentItemAndClearRefetches() async throws {
        let transport = PreviewTransport(), sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let bytes = Data("RIFFsyntheticWEBP".utf8).count
        let loader = PreviewImageLoader(sessions: sessions, policy: PreviewImageLoader.productionPolicy,
            transport: transport, cacheMaximumBytes: bytes * 2, cacheMaximumCount: 100)
        let urls = (0..<3).map { URL(string: "https://abcdefghij.hath.network/c2/syntheticSignature/42-\($0).webp")! }
        for url in urls { _ = try await loader.load(url: url, scope: scope) }
        _ = try await loader.load(url: urls[1], scope: scope)
        let before = await transport.requests.count; XCTAssertEqual(before, 3)
        await loader.clearCache()
        _ = try await loader.load(url: urls[1], scope: scope)
        let after = await transport.requests.count; XCTAssertEqual(after, 4)
    }
    func testDecodedCacheScopeValidationRejectsOldGenerationAndSite() async throws {
        let sessions = MutableSessionProvider(SessionState(scope: scope, authentication: .authenticated))
        let loader = PreviewImageLoader(sessions: sessions, policy: PreviewImageLoader.productionPolicy, transport: PreviewTransport())
        try await loader.validate(scope: scope)
        await sessions.update(SessionState(scope: try scope.advanced(), authentication: .authenticated))
        do { try await loader.validate(scope: scope); XCTFail() }
        catch { XCTAssertEqual(error as? AppError, .staleSession) }
        let other = SessionScope(storage: StorageScope(accountID: scope.storage.accountID, site: .eh), generation: scope.generation)
        do { try await loader.validate(scope: other); XCTFail() }
        catch { XCTAssertEqual(error as? AppError, .staleSession) }
    }

}

extension PreviewTests {
    func testLocalOnlyPreviewReadsOwnedCacheButStartsNoNetworkOrMirror() async throws {
        let transport=PreviewTransport(),sessions=MutableSessionProvider(SessionState(scope:scope,authentication:.needsVerification,permitsNetwork:false))
        let loader=PreviewImageLoader(sessions:sessions,policy:PreviewImageLoader.productionPolicy,transport:transport)
        do{_=try await loader.load(url:url,scope:scope);XCTFail()}catch AppError.authenticationRequired{}catch{XCTFail()}
        let initial=await transport.requests.count;XCTAssertEqual(initial,0)
        await sessions.update(SessionState(scope:scope,authentication:.authenticated))
        let online=try await loader.load(url:url,scope:scope),count=await transport.requests.count
        await sessions.update(SessionState(scope:scope,authentication:.needsVerification,permitsNetwork:false))
        let cached=try await loader.load(url:url,scope:scope);XCTAssertEqual(cached,online)
        let final=await transport.requests.count;XCTAssertEqual(final,count)
    }
}
